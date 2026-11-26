#!/usr/bin/env python3
"""Check Now's Show All: two rows under the empty field, then a row into all of Now.

Run after a build: python3 evals/now-all.py [--bin PATH] [--out DIR]. Uses a
test world of its own; nine rows are handed over as an agent's finds, with no
network pages or personal mail. Pictures of each step land in --out.
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
WORLD = f"now-all-{os.getpid()}"
SUPPORT = Path.home() / "Library" / "Application Support" / f"Pane ({WORLD})"
SOCKET = SUPPORT / "bench.sock"
DOMAIN = f"dev.serafim.fast.test.{WORLD}"

ITEMS = [
    {"kind": "reply", "title": "Reply to Luca about the contract", "detail": "Contract draft v3"},
    {"kind": "task", "title": "Pay the Vercel invoice", "detail": "$20, due Friday"},
    {"kind": "task", "title": "Book flights to Lisbon", "detail": "TAP, Nov 7 to Nov 12"},
    {"kind": "delivery", "title": "Your parcel needs a signature", "detail": "Before the courier leaves"},
    {"kind": "reply", "title": "Answer Mira about Friday", "detail": "Dinner at 8?"},
    {"kind": "task", "title": "Renew the domain", "detail": "yetanotherbrowser.com, in 9 days"},
    {"kind": "task", "title": "Read the release notes draft", "detail": "0.0.25"},
    {"kind": "reply", "title": "Send Ana the design files", "detail": "She asked twice"},
    {"kind": "task", "title": "Cancel the old Figma seat", "detail": "Billed on the 20th"},
]


def ask(**request):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(30)
        connection.connect(str(SOCKET))
        connection.sendall((json.dumps(request) + "\n").encode())
        data = bytearray()
        while chunk := connection.recv(1 << 16):
            data.extend(chunk)
    reply = json.loads(data.split(b"\n", 1)[0])
    reply.pop("clipboard", None)
    assert "error" not in reply, reply
    return reply


def box(act, **options):
    return ask(do="box", act=act, **options)


def shot(out, name):
    ask(do="winshot", path=str(out / f"{name}.png"))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bin", help="the app's executable; the newest build/*.app when left out")
    parser.add_argument("--out", type=Path, default=ROOT / ".build" / "now-all")
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    if not args.bin:
        apps = sorted(ROOT.glob("build/*.app/Contents/MacOS/pane"), key=lambda path: path.stat().st_mtime)
        assert apps, "No build/*.app: run ./build.sh first"
        args.bin = str(apps[-1])
    print(f"Using {args.bin}")

    scratch = Path(tempfile.mkdtemp(prefix="yab-now-all-"))
    # Inside its .app it runs where it is, by its resources; a bare build is
    # copied, so another build cannot replace this test's executable.
    executable = Path(args.bin)
    if ".app/" not in args.bin:
        executable = scratch / "NowAll"
        shutil.copy2(args.bin, executable)
    subprocess.run(["defaults", "write", DOMAIN, "bench", "-bool", "true"], check=True)
    subprocess.run(["defaults", "write", DOMAIN, "welcomed", "-bool", "true"], check=True)
    # An agent's rows stand only where claude or codex is found: a stand-in
    # that never runs, for Macs of the farm without either.
    tools = scratch / "bin"
    tools.mkdir()
    (tools / "claude").write_text("#!/bin/sh\nexit 0\n")
    (tools / "claude").chmod(0o755)
    path = f"{tools}:{os.environ.get('PATH', '/usr/bin:/bin')}"
    process = subprocess.Popen([str(executable)], cwd=ROOT,
                               env=dict(os.environ, YAB_PROBE=WORLD, FAST_PROBE=WORLD, HOME=str(scratch), PATH=path),
                               stdout=subprocess.DEVNULL, stderr=open(args.out / "app.log", "w"))
    try:
        for _ in range(80):
            if SOCKET.exists():
                break
            assert process.poll() is None, "Test app exited: " + (args.out / "app.log").read_text()[-2000:]
            time.sleep(0.25)
        assert SOCKET.exists(), "Test app did not open its socket"
        box("blur")

        # A first launch can be busy for a while (history, favicons): one more try.
        try:
            ask(do="agent-suggest", items=ITEMS)
        except AssertionError:
            time.sleep(5)
            ask(do="agent-suggest", items=ITEMS)
        for _ in range(40):
            if len(ask(do="agent-hints").get("rows", [])) >= 4:
                break
            time.sleep(0.25)
        state = box("t")
        now = [row for row in state["offers"] if row["section"] == "Now"]
        found = [row for row in now if row["kind"].startswith("hint")]
        more = [row for row in now if row["key"] == "Show All in Now"]
        assert len(found) == 2, now
        assert len(more) == 1 and more[0]["title"] == "7" and "now" in more[0]["kind"], now
        assert now[-1]["key"] == "Show All in Now", now
        print("PASS: Two Now rows, then Show All saying seven more")
        shot(args.out, "1-list")

        # Walk to it and take it: all nine, as a place.
        target = state["offers"].index(more[0])
        for _ in range(len(state["offers"]) + 2):
            if state["current"] == target:
                break
            state = box("key", keys="down" if state["current"] < target else "up")
        assert state["current"] == target, state
        shot(args.out, "2-chosen")
        state = box("key", keys="return")
        assert state["place"] == "now", state
        assert len(state["items"]) == 9, state["items"]
        assert {item["title"] for item in state["items"]} == {item["title"] for item in ITEMS}, state["items"]
        assert state["actions"] and state["actions"][0] in ("Open", "Start", "Open Here", "Open in New Tab"), state["actions"]
        print("PASS: Return on Show All opens Now with all nine and their actions")
        shot(args.out, "3-place")

        state = box("key", keys="down")
        state = box("key", keys="down")
        assert state["spot"] == 2, state
        shot(args.out, "4-place-third")

        state = box("type", text="lisbon")
        assert [item["title"] for item in state["items"]] == ["Book flights to Lisbon"], state["items"]
        print("PASS: Typing filters Now")
        shot(args.out, "5-filtered")

        # Back: the words go first, then the place.
        for _ in range(len(state["typed"])):
            state = box("key", keys="delete")
        assert state["place"] == "now" and state["typed"] == "", state
        state = box("key", keys="delete")
        assert state["place"] == "", state
        assert any(row["key"] == "Show All in Now" for row in state["offers"]), state["offers"]
        print("PASS: Delete in the empty field goes back to the list with Show All")

        # Two or fewer: no Show All.
        # An agent's finds add to the ones kept: forget them first.
        ask(do="agent-hints", forget=True)
        ask(do="agent-suggest", items=ITEMS[:2])
        box("key", keys="escape")
        state = box("t")
        assert not any(row["key"] == "Show All in Now" for row in state["offers"]), state["offers"]
        print("PASS: With two or fewer there is no Show All")
    finally:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
        shutil.rmtree(scratch, ignore_errors=True)
        shutil.rmtree(SUPPORT, ignore_errors=True)
        subprocess.run(["defaults", "delete", DOMAIN], check=False, capture_output=True)


if __name__ == "__main__":
    main()
