#!/usr/bin/env python3
"""Google AI Mode's follow-up box, "Ask anything" (register 1025: "this
input box appears after a lag and most of the time it doesn't even render
or appear"), in Yab against a bare WKWebView.

    ./farm exec --display --name "AI Mode Google" --estimate 1500 -- \
      bash evals/google-ai-mode/run.sh "AI Mode Google" [--runs 3] [--only yab,plain-safari]

Each way runs RUNS times, logged out, on google.com/search?udm=50 (AI
Mode) with a fresh question each time (--flow: an ordinary search first,
its AI Mode link pressed at 8 s, a follow-up typed into the box at 28 s):

  plain-webkit   a bare WKWebView, WebKit's own agent (no Safari in it)
  plain-safari   a bare WKWebView told Safari's agent, as Yab tells sites
  yab            Yab as shipped, a fresh world
  yab-<cut>      Yab with one piece taken out (YAB_LINKGAP, LinkGap.swift):
                 scripts, shield, ext, dark, ua
  yab-lists      Yab with the ad blocker's full lists fetched and built
                 first, as a person's Yab has them (a test world keeps the
                 short built-in list)

Every 250 ms detect.js says whether the box is there and seen, how much
answer there is, the page's errors (hook.js) and its longest frame. For
each run: seconds to the first answer words, to the box being there and
to it being seen; a picture of the page at the end. Writes OUT/report.json
and prints one line a run; exits 1 when Yab misses a box the bare view
showed.

2026-10-25 on aws-1 (Yab 0.40.0, macOS 27, logged out), 3 runs a way:
told no Safari (plain-webkit, yab-ua) Google serves its basic HTML page
and never AI Mode; told Safari, the box was there and seen in every run
of every way, about 0.5 s after the answer started (yab 0.78-0.87 s,
plain-safari 0.53 s, the gap is the bench's polling). --flow: the box
seen 0.5-0.6 s after the press, the follow-up answered and the box seen
in every poll after it, in Yab, in Yab with the ad blocker's full lists
(170,939 rules) and in the bare view alike. Register 1025 not reproduced.
"""
import argparse, json, os, subprocess, sys, time, uuid
from pathlib import Path
from urllib.parse import quote
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import yab_socket  # noqa: E402
from probe_app import launch  # noqa: E402

HERE = Path(__file__).resolve().parent
HOOK = (HERE / "hook.js").read_text()
DETECT = (HERE / "detect.js").read_text()
QUESTIONS = [
    "what is hellotest aptitude practice",
    "how do numerical reasoning tests work",
    "best way to prepare for an SHL test",
    "what is abstract reasoning in aptitude tests",
    "how long is a verbal reasoning test",
]

parser = argparse.ArgumentParser()
parser.add_argument("--app", default="build/Pane Dev.app")
parser.add_argument("--task", default="AI Mode Google")
parser.add_argument("--runs", type=int, default=3)
parser.add_argument("--seconds", type=float, default=35)
parser.add_argument("--only", default="")
parser.add_argument("--flow", action="store_true",
                    help="as a person gets there: an ordinary search, its AI Mode link pressed at 8 s, "
                         "a follow-up typed into the box at 28 s; 60 s a run")
options = parser.parse_args()

out = Path(os.environ.get("YAB_FARM_OUT") or Path(os.environ.get("APP", "/tmp/x")).parent) / "google-ai-mode"
out.mkdir(parents=True, exist_ok=True)
WAYS = ["plain-webkit", "plain-safari", "yab", "yab-scripts", "yab-shield", "yab-ext", "yab-dark", "yab-ua", "yab-lists"]
wanted = [w for w in WAYS if not options.only or w in options.only.split(",")]


if options.flow:
    options.seconds = max(options.seconds, 60)
PRESS_MODE = """(() => { const a = [...document.querySelectorAll('a[href*="udm=50"]')].find((e) => e.getBoundingClientRect().width > 0);
  if (!a) return 'none'; a.click(); return a.href.slice(0, 120); })()"""
FOCUS_BOX = """(() => { const b = [...document.querySelectorAll('textarea, [contenteditable]')].find((e) =>
  /ask anything/i.test((e.getAttribute('placeholder') || '') + (e.getAttribute('aria-label') || '') + (e.getAttribute('data-placeholder') || '')));
  if (!b) return 'none'; b.scrollIntoView({block: 'center'}); b.focus(); b.click(); return 'ok'; })()"""
FOLLOW = "what does it cost"


def address(n):
    mode = "" if options.flow else "udm=50&"
    return "https://www.google.com/search?" + mode + "hl=en&q=" + quote(QUESTIONS[n % len(QUESTIONS)])


def summary(way, n, polls, shot):
    def first(test):
        return next((p["t"] for p in polls if isinstance(p.get("seen"), dict) and test(p["seen"])), None)
    last = next((p["seen"] for p in reversed(polls) if isinstance(p.get("seen"), dict) and "ask" in p["seen"]), {})
    row = {
        "way": way, "run": n, "question": QUESTIONS[n % len(QUESTIONS)],
        "words": first(lambda s: s.get("text", 0) > 400),
        "box": first(lambda s: s.get("ask", 0) > 0),
        "boxSeen": first(lambda s: s.get("askSeen")),
        "end": {k: last.get(k) for k in ("href", "ask", "askSeen", "text", "frames", "agent", "visibility", "consent", "follow")},
        "boxes": last.get("boxes"), "errors": last.get("errors"), "shot": shot,
    }
    if options.flow:
        pressed = next((p for p in polls if "pressed" in p), {})
        asked = next((p for p in polls if "focused" in p), {})
        after = lambda t0, test: next((round(p["t"] - t0, 2) for p in polls if t0 is not None and p["t"] >= t0
                                       and isinstance(p.get("seen"), dict) and test(p["seen"])), None)
        row["flow"] = {
            "overview": first(lambda s: s.get("overview")), "modeLink": first(lambda s: s.get("modeLink")),
            "pressed": pressed.get("pressed"), "pressedAt": pressed.get("t"),
            "boxSeenAfterPress": after(pressed.get("t"), lambda s: s.get("askSeen") and "udm=50" in s.get("href", "")),
            "focused": asked.get("focused"), "askedAt": asked.get("t"),
            "followShown": after(asked.get("t"), lambda s: (s.get("follow") or 0) > 0),
            # Once the follow-up is on the page, the share of polls the box was seen in.
            "boxSeenShareAfterFollow": (lambda ps: round(sum(1 for p in ps if p["seen"].get("askSeen")) / len(ps), 2) if ps else None)(
                [p for p in polls if asked.get("t") is not None and p["t"] >= asked["t"] + 3 and isinstance(p.get("seen"), dict) and "ask" in p["seen"]]),
            "boxSeenAtEnd": last.get("askSeen"),
        }
    print(json.dumps({k: row[k] for k in ("way", "run", "words", "box", "boxSeen")} | {"flow": row.get("flow"), "end": row["end"], "errors": len(row["errors"] or [])}), flush=True)
    return row


def plain(way, n, tool):
    shot = out / f"{way}-{n}.png"
    proc = subprocess.run([str(tool), address(n), way.split("-", 1)[1], str(options.seconds), str(shot),
                           str(HERE / "hook.js"), str(HERE / "detect.js")] + ([FOLLOW] if options.flow else []), capture_output=True, text=True, timeout=options.seconds + 60)
    polls = []
    for line in proc.stdout.splitlines():
        try:
            p = json.loads(line)
            if isinstance(p.get("seen"), str):
                p["seen"] = json.loads(p["seen"])
            polls.append(p)
        except ValueError:
            pass
    return summary(way, n, polls, str(shot))


def yab(way, n):
    cut = way.split("-", 1)[1] if "-" in way else ""
    lists = cut == "lists"
    cut = "" if lists else cut
    world = "ai-mode-" + uuid.uuid4().hex[:8]
    support = Path.home() / "Library/Application Support" / ("Pane (" + world + ")")
    domain = "dev.serafim.fast.test." + world
    for key in ("bench", "welcomed"):
        subprocess.run(["defaults", "write", domain, key, "-bool", "true"], check=True)
    env = dict(os.environ, YAB_PROBE=world, YAB_HISTORY="own")
    if cut:
        env["YAB_LINKGAP"] = cut
    bench = yab_socket.bencher(support / "bench.sock", timeout=60, strict=False)
    process = launch(options.app, env, out, task_name=options.task)
    try:
        deadline = time.monotonic() + 60
        while True:
            if (support / "bench.sock").exists():
                try:
                    bench("tabs")
                    break
                except OSError:
                    pass
            if time.monotonic() > deadline or process.poll() is not None:
                raise SystemExit("the probe did not start")
            time.sleep(.2)
        time.sleep(2)
        if lists:
            bench("shield", refresh=True)
            limit = time.monotonic() + 240
            while time.monotonic() < limit:
                said = bench("shield")
                if not said.get("refreshing") and not said.get("building") and said.get("rules_made", 0) > 20_000:
                    break
                time.sleep(2)
            print(json.dumps({"lists": {k: said.get(k) for k in ("rules_made", "attached_lists", "trouble", "refresh_failed")}}), flush=True)
            time.sleep(3)
        before = {r["id"] for r in bench("tabs").get("tabs", [])}
        start = time.monotonic()
        bench("flood", urls=[address(n)])
        tab = None
        while tab is None and time.monotonic() - start < 10:
            new = [r["id"] for r in bench("tabs").get("tabs", []) if r["id"] not in before]
            tab = new[0] if new else None
            time.sleep(.05)
        bench("select", id=tab)
        polls = []
        pressed = asked = False
        while time.monotonic() - start < options.seconds:
            t = round(time.monotonic() - start, 2)
            if options.flow and t > 8 and not pressed:
                pressed = True
                polls.append({"t": t, "pressed": bench("eval", id=tab, js=PRESS_MODE).get("value")})
            if options.flow and t > 28 and not asked:
                asked = True
                polls.append({"t": t, "focused": bench("eval", id=tab, js=FOCUS_BOX).get("value")})
                time.sleep(.5)
                polls.append({"t": t, "typed": bench("key", id=tab, text=FOLLOW + "\r")})
            try:
                bench("eval", id=tab, js=HOOK + ";window.__aiFollow=" + json.dumps(FOLLOW) + ";'ok'")
                raw = bench("eval", id=tab, js=DETECT).get("value")
                polls.append({"t": t, "seen": json.loads(raw) if isinstance(raw, str) else raw})
            except Exception as error:  # noqa: BLE001
                polls.append({"t": t, "seen": {"error": repr(error)}})
            time.sleep(.25)
        shot = out / f"{way}-{n}.png"
        bench("shot", id=tab, path=str(shot))
        for _ in range(50):
            if shot.exists() and shot.stat().st_size:
                break
            time.sleep(.1)
        return summary(way, n, polls, str(shot))
    finally:
        try:
            process.terminate()
            process.wait(10)
        except Exception:  # noqa: BLE001
            process.kill()
        subprocess.run(["defaults", "delete", domain], capture_output=True)


tool = None
if any(w.startswith("plain") for w in wanted):
    tool = out / "plain"
    subprocess.run(["swiftc", "-O", str(HERE / "plain.swift"), "-o", str(tool)], check=True)
rows = []
for n in range(options.runs):
    for way in wanted:
        try:
            rows.append(plain(way, n, tool) if way.startswith("plain") else yab(way, n))
        except Exception as error:  # noqa: BLE001
            rows.append({"way": way, "run": n, "error": repr(error)})
            print(json.dumps(rows[-1]), flush=True)
        (out / "report.json").write_text(json.dumps(rows, indent=1))

seen = {w: sum(1 for r in rows if r.get("way") == w and r.get("boxSeen") is not None) for w in wanted}
print(json.dumps({"boxSeenRuns": seen, "of": options.runs}), flush=True)
best_plain = max([seen[w] for w in wanted if w.startswith("plain")] or [0])
sys.exit(1 if "yab" in seen and seen["yab"] < best_plain else 0)
