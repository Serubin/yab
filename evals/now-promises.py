#!/usr/bin/env python3
"""Promises in Now, end to end, with a moving clock: nothing on the day it was
said, one row on its day, at most one promise beside the rest, two different
ones a day, none left standing after three days untouched, nothing after two
weeks of nobody opening them, Done and Not a Promise for good, theirs only once
late and silent, a nudge giving them three days, and Do It in the foot.

Run after a build: python3 evals/now-promises.py [--bin PATH] [--out DIR].
A test world of its own is handed promises as mail would have them (bench
`promises`); the field's two rows are read as a person opening ⌘T would get
them. Prints PASS or the failures, and a JSON report in --out.
"""

import argparse
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]
DAY = 86_400

# A maybe, a plan, a condition and a company's words never become a row.
NOT_PROMISES = [
    "I'll try to send it tomorrow.", "Hopefully I can share it this week.", "I'll be in Berlin next week.",
    "If you send the logo, I'll update the deck.", "We'll email you when your order ships.", "I'll probably have it by Friday.",
    "Let me know if Friday works.", "Can you send the deck?", "I'll need the numbers by Friday.", "We'll see how it goes.",
]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bin", help="the app's executable; the newest build/*.app when left out")
    parser.add_argument("--out", type=Path, default=ROOT / ".build" / "now-promises")
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    if not args.bin:
        apps = sorted(ROOT.glob("build/*.app/Contents/MacOS/*"), key=lambda path: path.stat().st_mtime)
        assert apps, "No build/*.app: run ./build.sh first"
        args.bin = str(apps[-1])
    print(f"Using {args.bin}")

    world = f"now-promises-{os.getpid()}"
    support = Path.home() / "Library" / "Application Support" / f"Pane ({world})"
    sock = support / "bench.sock"
    domain = f"dev.serafim.fast.test.{world}"

    def ask(**request):
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(90)
            connection.connect(str(sock))
            connection.sendall((json.dumps(request) + "\n").encode())
            data = bytearray()
            while chunk := connection.recv(1 << 16):
                data.extend(chunk)
        reply = json.loads(data.split(b"\n", 1)[0])
        reply.pop("clipboard", None)
        assert "error" not in reply, reply
        return reply

    def promises(**request):
        return ask(do="hints-promises", **request)

    def field():
        return promises(field=True)

    failures = []
    report = {}

    def check(name, ok, detail):
        report[name] = {"ok": bool(ok), "detail": detail}
        print(("ok   " if ok else "FAIL ") + name + ": " + json.dumps(detail, default=str)[:400])
        if not ok:
            failures.append(name)

    def rows(state):
        return [row["id"] for row in state.get("field", [])]

    def statuses(state):
        return {row["id"]: row["status"] for row in state.get("field", [])}

    def fresh():
        ask(do="agent-hints", reset=True, forget=True)
        promises(forget=True)

    scratch = Path(tempfile.mkdtemp(prefix="yab-now-promises-"))
    for key, kind, value in (("bench", "-bool", "true"), ("welcomed", "-bool", "true"), ("look", "-string", "dark")):
        subprocess.run(["defaults", "write", domain, key, kind, value], check=True)
    log = open(args.out / "app.log", "w")
    process = subprocess.Popen([args.bin], cwd=ROOT,
                               env=dict(os.environ, YAB_PROBE=world, FAST_PROBE=world, HOME=str(scratch), YAB_HISTORY="own"),
                               stdout=log, stderr=log)
    try:
        for _ in range(80):
            if sock.exists():
                break
            assert process.poll() is None, "Test app exited"
            time.sleep(0.25)
        assert sock.exists(), "Test app did not open its socket"
        ask(do="box", act="blur")

        # 1. The rules keep maybes, plans and robots out.
        read = promises(read=NOT_PROMISES)["read"]
        caught = [one["sentence"] for one in read if one["mine"] or one["theirs"]]
        check("no maybes, plans or robots", not caught, caught)

        # 2. Said today for tomorrow: nothing today; on its day, one row.
        fresh()
        state = promises(add=[{"quote": "I'll send you the deck tomorrow.", "person": "Olya Petrova", "address": "olya@acme.io",
                               "said": 1, "thread": "deck"}])
        state = field()
        check("nothing on the day it was said", "promise.mine.mail.deck" not in rows(state), state.get("field"))
        state = promises(clock=DAY, field=True)
        mine = "promise.mine.mail.deck"
        check("one row on its day", mine in rows(state), state.get("field"))
        titles = {row["id"]: row["title"] for row in state.get("field", [])}
        check("its title is the thing to do", titles.get(mine) == "Send Olya the deck", titles)
        check("its end says its day", statuses(state).get(mine) in ("Due today", "Due this morning"), statuses(state))

        # 3. Done is for good, the next day too.
        promises(act={"id": mine, "what": "done"})
        state = promises(clock=DAY, field=True)
        check("done is for good", mine not in state.get("queue", []), state.get("queue"))

        # 4. Three due today: two stand, Show All has the third.
        fresh()
        add = [{"quote": f"I'll send you the {thing} today.", "person": "Ana Ruiz", "address": "ana@acme.io", "said": 1, "thread": thing}
               for thing in ("logo", "brief", "invoice")]
        promises(add=add)
        state = field()
        standing = rows(state)
        check("only promises: two stand", len(standing) == 2 and all(r.startswith("promise.") for r in standing), state.get("field"))
        check("the third under Show All", state.get("more") == 1, state.get("more"))
        # Opened again the same day: the same two, never a third different one.
        again = rows(field())
        check("two different ones a day", set(again) == set(standing), again)

        # 5. Three days in the rows untouched: they leave the rows.
        promises(clock=DAY, field=True)
        state = promises(clock=DAY, field=True)
        state = promises(clock=DAY, field=True)
        stood = [r for r in rows(state) if r in standing]
        check("untouched three days, out of the rows", not stood, {"field": state.get("field"), "attention": state.get("attention")})
        check("still in Now under Show All", all(r in state.get("queue", []) for r in standing), state.get("queue"))

        # 6. Not a Promise: gone, and its shape never comes back.
        fresh()
        promises(add=[{"quote": "I'll take a look tomorrow at 9.", "person": "Mark", "address": "mark@north.vc", "said": 30,
                       "thread": "online"}])
        state = field()
        shown = "promise.mine.mail.online" in state.get("queue", [])
        promises(act={"id": "promise.mine.mail.online", "what": "not"})
        promises(add=[{"quote": "I'll take a look tomorrow at 10.", "person": "Mark", "address": "mark@north.vc", "said": 30,
                       "thread": "online2"}])
        state = field()
        check("not a promise, and its shape stays out",
              "promise.mine.mail.online2" not in state.get("queue", []) and "promise.mine.mail.online" not in state.get("queue", []),
              {"first was a row": shown, "queue": state.get("queue")})

        # 7. Theirs: only once late and silent; a nudge gives them three days.
        fresh()
        theirs = "promise.theirs.mail.contract"
        promises(add=[{"quote": "I'll send you the contract tomorrow.", "person": "Dana Lee", "address": "dana@north.vc",
                       "theirs": True, "said": 1, "thread": "contract"}])
        state = promises(clock=DAY, field=True)
        check("theirs not on its day", theirs not in state.get("queue", []), state.get("queue"))
        state = promises(clock=DAY, field=True)
        check("theirs once late", theirs in rows(state), state.get("field"))
        check("theirs says late", statuses(state).get(theirs) == "1 day late", statuses(state))
        promises(act={"id": theirs, "what": "nudge"})
        state = promises(clock=DAY, field=True)
        check("a nudge gives them three days", theirs not in state.get("queue", []), state.get("queue"))
        state = promises(clock=3 * DAY, field=True)
        check("back after three days", theirs in state.get("queue", []), state.get("queue"))
        fresh()
        promises(add=[{"quote": "I'll send you the contract tomorrow.", "person": "Dana Lee", "address": "dana@north.vc",
                       "theirs": True, "said": 50, "thread": "heard", "heard": True}])
        state = field()
        check("theirs heard from: no row", "promise.theirs.mail.heard" not in state.get("queue", []), state.get("queue"))

        # 8. Nobody opens them for two weeks: none stand at all.
        fresh()
        for day in range(6):
            promises(add=[{"quote": f"I'll send you part {day} today.", "person": "Ana Ruiz", "address": "ana@acme.io", "said": 1,
                           "thread": f"part{day}"}])
            state = field()
            promises(clock=DAY)
        promises(add=[{"quote": "I'll send you the final part today.", "person": "Ana Ruiz", "address": "ana@acme.io", "said": 1,
                       "thread": "final"}])
        state = field()
        check("unused two weeks: none stand", not [r for r in rows(state) if r.startswith("promise.")],
              {"field": state.get("field"), "attention": state.get("attention")})
        # Opened once, they may stand again.
        promises(act={"id": "promise.mine.mail.final", "what": "open"})
        state = field()
        check("opened once, back", any(r.startswith("promise.") for r in rows(state)), state.get("field"))

        # 9. Do It in the foot of a promise row, when an agent is on this Mac.
        fresh()
        promises(add=[{"quote": "I'll send you the logo files today.", "person": "Ana Ruiz", "address": "ana@acme.io", "said": 1,
                       "thread": "logo"}])
        ask(do="box", act="t")
        time.sleep(2)
        state = ask(do="box", act="state")
        ask(do="winshot", path=str(args.out / "now.png"))
        featured = state.get("featured", [])
        agent = shutil.which("claude") or shutil.which("codex")
        check("Do It in the foot", "Do It" in featured or not agent, {"featured": featured, "agent on this Mac": bool(agent)})
        check("no agent's name on the button", not any("Claude" in title or "ChatGPT" in title for title in featured), featured)
        ask(do="box", act="close")
    finally:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
        shutil.rmtree(scratch, ignore_errors=True)
        shutil.rmtree(support, ignore_errors=True)
        subprocess.run(["defaults", "delete", domain], check=False, capture_output=True)
    (args.out / "report.json").write_text(json.dumps(report, indent=2))
    if failures:
        print("FAIL:", ", ".join(failures))
        raise SystemExit(1)
    print(f"PASS: {len(report)} checks; report in {args.out / 'report.json'}")


if __name__ == "__main__":
    main()
