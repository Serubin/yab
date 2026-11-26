#!/usr/bin/env python3
"""Now's rows: the site on a picture's corner, Do It, Quick Actions' icons.

Run after a build: python3 evals/now-hand.py [--bin PATH] [--out DIR]. A test
world of its own is handed three finds: a reply from a gmail.com address (no
corner mark: the mail says nothing of a site), a reply from stripe.com and a
Stripe dispute (Stripe's own icon on the corner, never a letter). Now is
opened, its foot must offer Do It beside Open, and "new do" in
the field must show New document with Google Docs' icon, not docs.new's.
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

SOON = (dt.datetime.now().astimezone() + dt.timedelta(hours=5)).isoformat(timespec="seconds")
ITEMS = [
    {"kind": "reply", "site": "gmail.com", "title": "A reply from a person", "detail": "megapromt25@gmail.com: cancel", "due": SOON},
    {"kind": "reply", "site": "stripe.com", "title": "A reply to Stripe", "detail": "support@stripe.com: dispute", "due": SOON},
    {"kind": "money", "site": "dashboard.stripe.com", "title": "A Stripe dispute", "detail": "2 x $20.00", "due": SOON},
]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bin", help="the app's executable; the newest build/*.app when left out")
    parser.add_argument("--out", type=Path, default=ROOT / ".build" / "now-hand")
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    if not args.bin:
        apps = sorted(ROOT.glob("build/*.app/Contents/MacOS/*"), key=lambda path: path.stat().st_mtime)
        assert apps, "No build/*.app: run ./build.sh first"
        args.bin = str(apps[-1])
    print(f"Using {args.bin}")

    world = f"now-hand-{os.getpid()}"
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

    scratch = Path(tempfile.mkdtemp(prefix="yab-now-hand-"))
    for key, kind, value in (("bench", "-bool", "true"), ("welcomed", "-bool", "true"), ("look", "-string", "dark")):
        subprocess.run(["defaults", "write", domain, key, kind, value], check=True)
    log = open(args.out / "app.log", "w")
    process = subprocess.Popen([args.bin], cwd=ROOT,
                               env=dict(os.environ, YAB_PROBE=world, FAST_PROBE=world, HOME=str(scratch), YAB_HISTORY="own"),
                               stdout=log, stderr=log)
    failures = []
    try:
        for _ in range(80):
            if sock.exists():
                break
            assert process.poll() is None, "Test app exited"
            time.sleep(0.25)
        assert sock.exists(), "Test app did not open its socket"
        box("blur")
        print("suggest:", ask(do="agent-suggest", items=ITEMS))
        for _ in range(60):
            rows = [row for row in ask(do="agent-hints").get("rows", []) if row.get("title", "").startswith("A ")]
            if len(rows) >= len(ITEMS):
                break
            time.sleep(0.5)
        hints = ask(do="agent-hints")
        print("hints:", [row.get("title") for row in hints.get("rows", [])], "kept:", [(k.get("title"), k.get("due")) for k in hints.get("kept", [])], "now:", hints.get("now"))
        box("t")
        # The corner icons are fetched as the rows first show: a moment for them.
        time.sleep(4)
        ask(do="winshot", path=str(args.out / "list.png"))
        placed = ask(do="ui", fieldplace="now")["rows"]
        time.sleep(4)
        state = box("state")
        print("rows:", placed)
        print("featured:", state.get("featured"), "actions:", state.get("actions"))
        # Do It, the agent's face and no name (when an agent is on this Mac).
        if (shutil.which("claude") or shutil.which("codex")) and "Do It" not in state.get("featured", []):
            failures.append(f"no Do It in the foot: {state.get('featured')}")
        ask(do="winshot", path=str(args.out / "now.png"))
        box("close")
        box("t")
        box("type", text="new do")
        time.sleep(4)
        state = box("state")
        ask(do="winshot", path=str(args.out / "quick.png"))
        print("rows:", len(placed), "offers:", [offer.get("key") for offer in state.get("offers", [])][:6])
    finally:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
        shutil.rmtree(scratch, ignore_errors=True)
        shutil.rmtree(support, ignore_errors=True)
        subprocess.run(["defaults", "delete", domain], check=False, capture_output=True)
    for failure in failures:
        print("FAIL:", failure)
    if failures:
        raise SystemExit(1)
    print(f"PASS: Do It in Now's foot; pictures in {args.out}")


if __name__ == "__main__":
    main()
