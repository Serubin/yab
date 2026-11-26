#!/usr/bin/env python3
"""yab://you as Mira would meet it (docs/get-to-know.md, The notebook).

No agent: a test world gets Mira's memory (her brief, two people, one with a
face), a home address and the report a run leaves, story, doodles, questions
and things to set up included. Then the page as the run's end opens it, and
what each press does, read back from the stores and kept as pictures:

  1-met.png         the page written out: hello, her story with faces and logos
  2-people.png      her people, the question, what forms get
  3-setup.png       Set up for you, under the Settings drawings
  4-crossed.png     a sentence crossed out, a fix, a question answered
  5-answered.png    an offer added, one put away

Checks: a crossed-out sentence takes its line out of USER.md and Undo puts
it back; a fixed one is kept as the user's words; a picked answer is kept; an
added snippet is in the snippets; Not Now is kept as put away.

    python3 evals/know-me/page.py --app "build/Pane Dev.app" --out /tmp/know-page
"""
import argparse
import json
import os
import subprocess
import sys
import time
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import yab_socket  # noqa: E402

WORLD = "know-page"
FOLDER = os.path.expanduser(f"~/Library/Application Support/Pane ({WORLD})")
SOCK = os.path.join(FOLDER, "bench.sock")

BRIEF = """# User Briefing
<!-- Who the user is, in a few lines, loaded into every task. -->
- **Mira Lindqvist**, Founding Designer at Tern Labs since 2024, in Stockholm. Works with [[people/jonas-berg|Jonas Berg]].
- Ships the UI of Tern Studio herself in tern/studio on GitHub.
- Starts the day in Linear and Gmail, then Figma most of the day.
- Writes short replies, no greetings in Slack. Posts what shipped in #design on Fridays.
- Lives in Stockholm with [[people/elin-sandberg|Elin]].
"""
PEOPLE = {
    "jonas-berg": "---\ntitle: Jonas Berg\ntype: person\n---\n\n## Current\n- Cofounder of Tern Labs, the one Mira writes to most.\n",
    "elin-sandberg": "---\ntitle: Elin Sandberg\ntype: person\n---\n\n## Current\n- Mira's partner. Dinners on Thursdays.\n",
}
LINES = [l for l in BRIEF.split("\n") if l.startswith("- ")]

REPORT = {
    "portrait": "You design calm tools, and write the same way.",
    "story": [
        [{"text": "You're a founding designer at [[sites/tern.so|Tern Labs]] in Stockholm, working with [[people/jonas-berg|Jonas]].", "line": LINES[0]},
         {"text": "You ship the UI of Tern Studio yourself in [[sites/github.com|tern/studio]].", "line": LINES[1]}],
        [{"text": "Your mornings start in [[sites/linear.app|Linear]] and [[sites/mail.google.com|Gmail]], then most of the day is [[sites/figma.com|Figma]].", "line": LINES[2]}],
        [{"text": "You keep replies short and skip the greetings in [[sites/slack.com|Slack]]. On Fridays you post what shipped.", "line": LINES[3]},
         {"text": "You live in Stockholm with [[people/elin-sandberg|Elin]].", "line": LINES[4]}],
    ],
    "doodles": [{"at": "s0.1", "mark": "star"}, {"at": "s1.0", "mark": "coffee"}, {"at": "people/elin-sandberg.md", "mark": "heart"}],
    "setups": [
        {"kind": "live", "title": "Your pull requests in tern/studio", "why": "You opened 41 of them this month", "from": "s0.1", "what": {"repo": "tern/studio"}},
        {"kind": "action", "title": "fig makes a new Figma file", "why": "You made 6 Figma files this month", "from": "s1.0", "what": {"maker": "figma", "alias": "fig"}},
        {"kind": "routine", "title": "Every weekday at 9:00, mail and Linear", "why": "You open both first thing, 18 of 20 mornings", "from": "s1.0",
         "what": {"when": "weekdays 9:00", "prompt": "Anything in mail or Linear that needs me?", "title": "Morning check", "site": "linear.app"}},
        {"kind": "snippet", "title": ";cal puts in your booking link", "why": "You sent it in 9 mails this month", "what": {"name": "cal", "words": "cal.com/mira/30min"}},
    ],
    "doubts": [{"question": "Which number is your main one?", "about": "phone", "choices": [
        {"answer": "+46 70 123 45 67", "keep": "Main phone: +46 70 123 45 67"}, {"answer": "+46 8 555 012 34", "keep": "Main phone: +46 8 555 012 34"}]}],
    "skipped": [{"site": "linkedin.com", "why": "wanted a sign-in"}],
}


def bench(request, timeout=60):
    return yab_socket.exchange(SOCK, request, timeout)


def seed():
    memory = os.path.join(FOLDER, "memory")
    os.makedirs(os.path.join(memory, "people"), exist_ok=True)
    with open(os.path.join(memory, "USER.md"), "w") as f:
        f.write(BRIEF)
    for slug, body in PEOPLE.items():
        with open(os.path.join(memory, "people", slug + ".md"), "w") as f:
            f.write(body)
    # A face for Jonas as Get to Know keeps one; Elin has none.
    pictures = "/Library/User Pictures/Animals"
    first = sorted(os.listdir(pictures))[0] if os.path.isdir(pictures) else None
    if first:
        subprocess.call(["sips", "-s", "format", "jpeg", "-z", "192", "192", os.path.join(pictures, first),
                         "--out", os.path.join(memory, "people", "jonas-berg.jpg")], stdout=subprocess.DEVNULL)


def start(app):
    domain = f"dev.serafim.fast.test.{WORLD}"
    for key, kind, value in (("bench", "-bool", "true"), ("agents.remember", "-bool", "true")):
        subprocess.call(["defaults", "write", domain, key, kind, value])
    if os.path.exists(SOCK):
        os.remove(SOCK)
    subprocess.call(["open", "-n", "--env", f"YAB_PROBE={WORLD}", "--env", f"FAST_PROBE={WORLD}", app])
    for _ in range(120):
        if os.path.exists(SOCK):
            break
        time.sleep(0.25)
    time.sleep(2)


def stop():
    for pid in subprocess.run(["lsof", "-t", SOCK], capture_output=True, text=True).stdout.split():
        subprocess.call(["kill", pid])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True)
    parser.add_argument("--out", default=os.environ.get("YAB_FARM_OUT", "/tmp/know-page"))
    opts = parser.parse_args()
    os.makedirs(opts.out, exist_ok=True)
    os.makedirs(FOLDER, exist_ok=True)
    seed()
    start(opts.app)
    rows, ok = [], True

    def check(good, what, got=""):
        nonlocal ok
        ok = ok and bool(good)
        rows.append(("✓ " if good else "✗ ") + what + ("" if good else f"  {str(got)[:300]}"))
        print(rows[-1], flush=True)

    try:
        bench({"do": "know", "action": "address", "id": "home", "name": "Mira Lindqvist", "street": "Hornsgatan 54",
               "city": "Stockholm", "postal": "118 21", "country": "SE", "found": "your order on nordbutik.se"})
        bench({"do": "know", "action": "report", "report": REPORT})
        tabs = bench({"do": "know", "action": "arrive"}).get("tabs", [])
        page = next((t for t in tabs if t["url"].startswith("yab://you")), None)
        check(page, "the page where the run's folder stood", tabs)
        if not page:
            return 1
        tab = page["id"]
        bench({"do": "select", "id": tab})
        time.sleep(6)

        def js(code):
            return bench({"do": "eval", "id": tab, "js": code}).get("value")

        def shot(name, scroll=None):
            if scroll:
                js(f"(document.querySelector('{scroll}') || document.body).scrollIntoView({{block: 'start'}}); window.scrollBy(0, -24); true")
                time.sleep(0.6)
            bench({"do": "shot", "id": tab, "path": os.path.join(opts.out, name)})

        state = json.loads(js("JSON.stringify({s: document.querySelectorAll('.s').length, ents: document.querySelectorAll('.ent').length, faces: document.querySelectorAll('.ent.who img').length, doo: document.querySelectorAll('.doo').length, tiles: document.querySelectorAll('.tile .in').length, offers: document.querySelectorAll('.offer').length, q: document.querySelectorAll('.q').length, title: document.querySelector('.ttl').textContent})") or "{}")
        check(state.get("s") == 5, "five sentences of her story", state)
        check(state.get("ents", 0) >= 8 and state.get("faces") == 1, "people and sites as pills, Jonas with his face", state)
        check(state.get("doo") == 3, "three doodles", state)
        check(state.get("offers") == 4 and state.get("tiles", 0) >= 4, "four offers under their drawings", state)
        check(state.get("q") == 1, "the question", state)
        check("Mira" in state.get("title", ""), "greets her by name", state)
        shot("1-met.png")
        shot("2-people.png", ".cards.three")
        shot("3-setup.png", "#p-setup")

        def brief():
            with open(os.path.join(FOLDER, "memory", "USER.md")) as f:
                return f.read()

        # Cross out a sentence: its line leaves the brief; Undo puts it back.
        js("document.querySelector('.s[data-id=\"s2.0\"]').dispatchEvent(new MouseEvent('mouseover', {bubbles: true, clientX: 300, clientY: 300})); true")
        js("cross('s2.0'); true")
        time.sleep(1.5)
        check(LINES[3] not in brief(), "crossed out: its line left the brief", brief())
        js("undo(undos[undos.length - 1]); true")
        time.sleep(1.5)
        check(LINES[3] in brief(), "Undo: the line is back", brief())
        js("cross('s2.0'); true")
        time.sleep(1.2)
        # Fix one: the brief keeps her words as hers.
        js("fix('s2.1'); setTimeout(() => { const i = document.querySelector('.fixin'); i.value = 'You live in Stockholm with Elin and a cat.'; i.dispatchEvent(new KeyboardEvent('keydown', {key: 'Enter', bubbles: true})); }, 300); true")
        time.sleep(1.8)
        check("Corrected by the user: “You live in Stockholm with Elin and a cat.”" in brief(), "fixed: her words in the brief", brief())
        # Answer the question.
        js("document.querySelector('.choice[data-pick=\"0\"]').click(); true")
        time.sleep(1.5)
        check("Main phone: +46 70 123 45 67" in brief(), "the answer kept", brief())
        shot("4-crossed.png", "#p-know")

        # Add the snippet, put the routine away.
        js("setup('setup:snippet:1', 'add'); true")
        time.sleep(1.5)
        js("setup('setup:routine:1', 'away'); true")
        time.sleep(1.5)
        with open(os.path.join(FOLDER, "know.json")) as f:
            setups = {s["id"]: s.get("state") for s in json.load(f).get("setups", [])}
        check(setups.get("setup:snippet:1") == "added", "the snippet added", setups)
        check(setups.get("setup:routine:1") == "away", "the routine put away", setups)
        shot("5-answered.png", "#p-setup")
    finally:
        stop()
    with open(os.path.join(opts.out, "checks.txt"), "w") as f:
        f.write("\n".join(rows) + "\n")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
