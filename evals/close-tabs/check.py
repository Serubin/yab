#!/usr/bin/env python3
"""Close tabs for the user, end to end (docs/agent-asks.md, wave 1 item 4),
in a test world seeded with a pin, a kept tab in a folder, loose YouTube
tabs, a duplicate and a tab last used nine days ago:

- through the real stdio `yab mcp`: native_context names duplicates and
  when each tab was last used; tabs.close refuses a pin unless named, closes
  the loose YouTube tabs, and native_undo brings each back where it was,
  the pin pinned and the kept tab in its folder;
- through ⌘J with a stand-in agent (stand_in.py): "close all my YouTube
  tabs", "close my duplicate tabs" and "close the tabs I haven't used in a
  week" each close just those, the answer is one line, and ⌘Z puts them
  back.

Pictures of each state (winshot) go to --out.

    ./farm exec --display --name "Close tabs" -- bash evals/qa-batch/run.sh evals/close-tabs/check.py
"""
import argparse, http.server, json, os, plistlib, shutil, subprocess, sys, tempfile, threading, time, uuid
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "browse"))
import yab_socket  # noqa: E402
import probe_app  # noqa: E402
from prims import Mcp  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--app", required=True)
parser.add_argument("--out", default=None)
OPTS = parser.parse_args()
# A farm job's pictures go where `./farm fetch` brings them home.
OUT = os.path.join(os.environ["YAB_FARM_OUT"], "close-tabs") if os.environ.get("YAB_FARM_OUT") else OPTS.out or os.path.join(tempfile.mkdtemp(prefix="yab-close-"), "close-tabs")
os.makedirs(OUT, exist_ok=True)
WORLD = "closetabs" + uuid.uuid4().hex[:6]
FOLDER = os.path.expanduser(f"~/Library/Application Support/Pane ({WORLD})")
SUITE = f"dev.serafim.fast.test.{WORLD}"
FAILS = []
ask = yab_socket.asker(os.path.join(FOLDER, "bench.sock"))
wait_for = yab_socket.wait_for


class Page(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"<!doctype html><meta charset=utf-8><title>Front page</title><h1>Front page</h1><p>The page in front.</p>"
        self.send_response(200); self.send_header("Content-Type", "text/html; charset=utf-8"); self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


def check(what, ok, detail=""):
    line = ("✓ " if ok else "✗ ") + what + ("" if ok else f": {str(detail)[:900]}")
    print(line, flush=True)
    with open(os.path.join(OUT, "checks.txt"), "a") as f: print(line, file=f)
    if not ok: FAILS.append(what)


def shot(name):
    time.sleep(0.8)
    path = os.path.join(OUT, name + ".png")
    ask({"do": "winshot", "path": path})
    print("  picture", path, flush=True)


def row():
    """The row as a person sees it: each tab's address, pinned, kept and folder."""
    return [(t["url"], t["pinned"], t["kept"], t["folder"]) for t in ask({"do": "tabs"})["tabs"] if not t.get("bench")]


def corner():
    return (ask({"do": "teach", "action": "state"}).get("toast") or {}).get("words", "")


def corner_act():
    return (ask({"do": "teach", "action": "state"}).get("toast") or {}).get("act", "")


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Page)
threading.Thread(target=server.serve_forever, daemon=True).start()
FRONT = f"http://127.0.0.1:{server.server_address[1]}/front"
now = time.time()
folder = str(uuid.uuid4()).upper()
SEED = [
    {"url": "https://www.youtube.com/", "title": "YouTube", "pin": "Y"},
    {"url": "https://www.youtube.com/watch?v=keptvideo", "title": "Kept video", "kept": True, "folder": folder, "folderName": "Watch later", "folderOpen": True},
    {"url": FRONT, "title": "Front page"},
    {"url": "https://www.youtube.com/watch?v=aaa", "title": "Video A"},
    {"url": "https://example.com/article", "title": "Article"},
    {"url": "https://www.youtube.com/watch?v=bbb", "title": "Video B"},
    {"url": "https://example.com/article#comments", "title": "Article"},
    {"url": "https://www.youtube.com/@channel", "title": "Channel"},
    {"url": "https://example.org/old", "title": "Old page", "seen": now - 9 * 86400},
]
for entry in SEED:
    entry.setdefault("seen", now - 60)
    entry["id"] = str(uuid.uuid4()).upper()
subprocess.run(["defaults", "delete", SUITE], stderr=subprocess.DEVNULL)
for key in ("bench", "welcomed", "sidebar"):
    subprocess.run(["defaults", "write", SUITE, key, "-bool", "true"])
subprocess.run(["defaults", "write", SUITE, "agents.asking", "bypass"])
# Never tidied away at launch: the nine-day-old tab is one of the asks.
subprocess.run(["defaults", "write", SUITE, "tabs.tidy", "-int", "0"])
os.makedirs(FOLDER, exist_ok=True)
with open(os.path.join(FOLDER, "session.json"), "w") as f:
    json.dump({"tabs": SEED, "active": 2}, f)
LOG = os.path.join(OUT, "claude.log"); open(LOG, "w").close()
fixture = shutil.copy2(os.path.join(HERE, "stand_in.py"), os.path.join(OUT, "stand_in.py"))
os.chmod(fixture, 0o755)
env = {"YAB_PROBE": WORLD, "YAB_HISTORY": "own", "YAB_AGENT_CLAUDE": fixture, "CLOSE_TABS_LOG": LOG}
app = probe_app.launch(OPTS.app, env, OUT, task_name="Close tabs", extra_env_names=("CLOSE_TABS_LOG",))
exe = plistlib.load(open(os.path.join(OPTS.app, "Contents/Info.plist"), "rb"))["CFBundleExecutable"]
mcp = None
try:
    wait_for(lambda: ask({"do": "census"}).get("pid"), 30)
    time.sleep(3)
    start = row()
    print("  row:", start, flush=True)
    check("the seeded row is up", len(start) == len(SEED) and start[0][1] and start[1][2] and start[1][3] == "Watch later", start)
    shot("0-start")
    youtube = [s["url"] for s in SEED if "youtube.com" in s["url"] and not s.get("pin") and not s.get("kept")]

    # 1. Through yab mcp, as any agent calls it.
    mcp = Mcp(os.path.join(OPTS.app, "Contents/MacOS", exe), WORLD)

    def call(tool, **arguments):
        reply = mcp.call_raw("tools/call", {"name": tool, "arguments": arguments})
        text = "\n".join(i.get("text", "") for i in reply.get("content", []) if i.get("type") == "text")
        try: return json.loads(text)
        except ValueError: return {"text": text}

    acts = call("native_actions", query="close").get("actions", [])
    check("native_actions lists tabs.close with undo", any(a.get("id") == "tabs.close" and a.get("undo") for a in acts), acts)
    ctx = call("native_context", limit=50)
    tabs = ctx.get("tabs", [])
    by = {t["title"]: t for t in tabs}
    space = {"kind": "space", "id": ctx.get("activeSpaceId", "")}
    dup = [t for t in tabs if t.get("duplicateOf")]
    check("native_context: the duplicate names the first tab at its address",
          len(dup) == 1 and dup[0]["duplicateOf"] == next(t["id"] for t in tabs if t["title"] == "Article" and not t.get("duplicateOf")), dup)
    check("native_context: lastUsed says the old page was nine days ago", by.get("Old page", {}).get("lastUsed", "")[:10]
          == time.strftime("%Y-%m-%d", time.gmtime(now - 9 * 86400)), by.get("Old page"))

    refused = call("native_apply", action="tabs.close", target=space, arguments={"tabs": [by["YouTube"]["id"], by["Video A"]["id"]]}, requestId="pin")
    check("a pin not named is refused, nothing closed", refused.get("status") == "failed" and row() == start, refused)
    loose = [t["id"] for t in tabs if "youtube.com" in t.get("url", "") and not t["pinned"] and not t["kept"]]
    closed = call("native_apply", action="tabs.close", target=space, arguments={"tabs": loose}, requestId="youtube")
    after = row()
    check("tabs.close: the 3 loose YouTube tabs go, the pin and the kept stay",
          closed.get("status") == "verified" and closed.get("closed") == 3 and not any(u in youtube for u, *_ in after) and after[0][1] and after[1][2], (closed, after))
    check("the corner says it, with Undo", corner() == "Closed 3 tabs", corner())
    shot("1-mcp-closed")
    back = call("native_undo", changeId=closed.get("operationId", ""))
    check("native_undo: every tab back where it stood", back.get("undone") is True and row() == start, (back, row()))
    shot("2-mcp-undone")

    # #1433: named, the pin and the kept tab are put down as ⌘W puts them:
    # asleep, pinned and in their folder, never taken out of the sidebar.
    def tab_titled(title):
        return next(t for t in ask({"do": "tabs"})["tabs"] if t["title"] == title)
    ask({"do": "select", "id": tab_titled("YouTube")["id"]})
    wait_for(lambda: not tab_titled("YouTube")["asleep"], 20)
    ask({"do": "select", "id": next(t for t in ask({"do": "tabs"})["tabs"] if t["url"] == FRONT)["id"]})
    shot("2b-pin-awake")
    named = call("native_apply", action="tabs.close", target=space, arguments={"tabs": [t["id"] for t in call("native_context", limit=50)["tabs"]
                                                                                        if t["title"] in ("YouTube", "Kept video")], "includePinned": True}, requestId="named")
    check("named, the pin and the kept tab stay where they are, asleep, as ⌘W leaves them",
          named.get("status") == "verified" and named.get("closed") == 0 and named.get("putDown") == 2 and row() == start
          and tab_titled("YouTube")["asleep"] and tab_titled("Kept video")["asleep"], (named, row()))
    check("and nothing is offered to undo", (named.get("undo") or {}).get("available") is False and corner() != "Closed 2 tabs", (named, corner()))
    shot("2c-named-put-down")
    mcp.close(); mcp = None

    # 2. Through ⌘J, with the stand-in agent, each undone with ⌘Z.
    front = next(t for t in ask({"do": "tabs"})["tabs"] if t["url"] == FRONT)
    ask({"do": "select", "id": front["id"]})
    time.sleep(1)
    for n, (words, gone, said) in enumerate([
        ("close all my youtube tabs", youtube, "Closed 3 YouTube tabs."),
        ("close my duplicate tabs", ["https://example.com/article#comments"], "Closed 1 duplicate tab."),
        ("close the tabs I haven't used in a week", ["https://example.org/old"], "Closed 1 tab you haven't used in a week."),
    ], start=3):
        sent = ask({"do": "agent-page-ask", "how": "line", "words": words})
        session = sent.get("session", "")
        check(f"⌘J «{words}» starts", session, sent)
        end = time.monotonic() + 60
        while time.monotonic() < end:
            got = ask({"do": "agent-wait", "session": session, "seconds": 5}, timeout=25)
            if got.get("state") not in ("running", "starting", "waiting", None): break
        lines = open(LOG).read()
        check(f"«{words}»: answered in one line", f"ANSWERED {said}" in lines, lines[-800:])
        now_row = row()
        check(f"«{words}»: just those tabs are gone", [r for r in start if r[0] not in gone] == now_row, now_row)
        check(f"«{words}»: the corner says the answer, with Undo rather than Show",
              corner() == said.replace("'", "\u2019") and corner_act() == "", (corner(), corner_act()))
        shot(f"{n}-ask-closed")
        if n == 3:
            ask({"do": "teach", "action": "act"})
            how = "the answer's Undo"
        else:
            ask({"do": "kept", "action": "undo"})
            how = "⌘Z"
        time.sleep(1)
        check(f"«{words}»: {how} brings them back where they stood", row() == start, row())
        if n == 3: shot(f"{n}-ask-undone")
    lines = open(LOG).read()
    check("the agent's brief tells it about tabs.close", "brief-mentions-tabs.close: True" in lines, lines[:600])
finally:
    if mcp: mcp.close()
    app.terminate()
    with open(os.path.join(OUT, "fails.json"), "w") as f: json.dump(FAILS, f)
print("FAILED: " + "; ".join(FAILS) if FAILS else "ALL PASSED", flush=True)
sys.exit(1 if FAILS else 0)
