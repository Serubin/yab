#!/usr/bin/env python3
"""Picture every Now kind in the pen style: one row per kind, light and dark.

Run after a build: python3 evals/now-icons.py [--bin PATH] [--out DIR]. Uses a
test world of its own; one row per kind of Pictures.kinds is handed over as an
agent's finds, then all of Now is opened and pictured, in Light and in Dark.
"""

import argparse
import datetime as dt
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]

KINDS = ["mail", "reply", "calendar", "meeting", "me", "chat", "money", "failed", "invoice", "shopping", "delivery",
         "flight", "stay", "review", "code", "terminal", "document", "sign", "reading", "security", "routine", "video"]
SOON = (dt.datetime.now().astimezone() + dt.timedelta(minutes=50)).isoformat(timespec="seconds")
ITEMS = [{"kind": kind, "title": f"A {kind} row", "detail": kind, "due": SOON} for kind in KINDS]
HALVES = [ITEMS[:11], ITEMS[11:]]


def run(binary, out, look, part):
    items = HALVES[part]
    world = f"now-icons-{look}-{part}-{os.getpid()}"
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

    def box(act, **options):
        return ask(do="box", act=act, **options)

    scratch = Path(tempfile.mkdtemp(prefix="yab-now-icons-"))
    for key, kind, value in (("bench", "-bool", "true"), ("welcomed", "-bool", "true"), ("look", "-string", look)):
        subprocess.run(["defaults", "write", domain, key, kind, value], check=True)
    log = open(out / f"{look}-{part}-app.log", "w")
    process = subprocess.Popen([binary], cwd=ROOT,
                               env=dict(os.environ, YAB_PROBE=world, FAST_PROBE=world, HOME=str(scratch), YAB_HISTORY="own"),
                               stdout=log, stderr=log)
    try:
        for _ in range(80):
            if sock.exists():
                break
            assert process.poll() is None, "Test app exited"
            time.sleep(0.25)
        assert sock.exists(), "Test app did not open its socket"
        box("blur")
        print("suggest:", ask(do="agent-suggest", items=items))
        rows = []
        for _ in range(60):
            rows = [row for row in ask(do="agent-hints").get("rows", []) if row.get("title", "").startswith("A ")]
            if len(rows) >= 4:
                break
            time.sleep(0.5)
        assert len(rows) >= 4, [row.get("title") for row in rows]
        box("t")
        time.sleep(0.8)
        ask(do="winshot", path=str(out / f"{look}-{part}-list.png"))
        if part == 0:
            # Now's own place row, searched by its name, in its pen tile.
            state = box("type", text="now")
            assert any(row["kind"] == "place(now)" or "now" in row["kind"] for row in state["offers"]), state["offers"]
            time.sleep(0.6)
            ask(do="winshot", path=str(out / f"{look}-place.png"))
            box("key", keys="cmd+a")
            box("key", keys="delete")
        placed = ask(do="ui", fieldplace="now")["rows"]
        assert len(placed) == len(items), placed
        time.sleep(0.8)
        ask(do="winshot", path=str(out / f"{look}-{part}-now.png"))
        print(f"PASS: {look}, part {part + 1}: {len(items)} kinds in Now, pictured")
    finally:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
        shutil.rmtree(scratch, ignore_errors=True)
        shutil.rmtree(support, ignore_errors=True)
        subprocess.run(["defaults", "delete", domain], check=False, capture_output=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bin", help="the app's executable; the newest build/*.app when left out")
    parser.add_argument("--out", type=Path, default=ROOT / ".build" / "now-icons")
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    if not args.bin:
        apps = sorted(ROOT.glob("build/*.app/Contents/MacOS/*"), key=lambda path: path.stat().st_mtime)
        assert apps, "No build/*.app: run ./build.sh first"
        args.bin = str(apps[-1])
    print(f"Using {args.bin}")
    for look in ("light", "dark"):
        for part in range(len(HALVES)):
            run(args.bin, args.out, look, part)


if __name__ == "__main__":
    main()
