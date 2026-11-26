#!/usr/bin/env python3
"""A private window lists none of your spaces and goes to none (register 1015).

Spaces on, two of them; File > New Private Window. The private window's foot
has no row of spaces, its Spaces menu lists none, and a switch asked of it
leaves it where it is. The normal window keeps both. Winshots of each.
--base-app runs the untouched main build first, where the private checks fail.
"""
import argparse
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import time
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from probe_app import launch

PRIVATE_CHECKS = ["the private window shows no spaces", "the private window's foot has no row of spaces",
                  "the private window goes to no other space", "the private Spaces menu lists none of yours",
                  "the private column names no space", "the private window's title names no space"]


def run(app, out, baseline=False):
    out.mkdir(parents=True, exist_ok=True)
    world = "private-spaces-" + uuid.uuid4().hex[:12]
    domain = "dev.serafim.fast.test." + world
    for key in ("bench", "welcomed"):
        subprocess.run(["defaults", "write", domain, key, "-bool", "true"], check=True)
    support = Path.home() / "Library/Application Support" / ("Pane (" + world + ")")
    checks = []

    def ask(verb, **fields):
        with socket.socket(socket.AF_UNIX) as connection:
            connection.settimeout(40)
            connection.connect(str(support / "bench.sock"))
            connection.sendall((json.dumps(dict(do=verb, **fields)) + "\n").encode())
            data = b""
            while b"\n" not in data:
                chunk = connection.recv(1 << 16)
                if not chunk:
                    break
                data += chunk
        reply = json.loads(data.split(b"\n", 1)[0])
        if "error" in reply:
            raise RuntimeError(str(reply))
        return reply

    def check(name, ok, seen=None):
        checks.append(dict(name=name, ok=bool(ok), seen=seen))
        print(("PASS " if ok else "FAIL ") + name, json.dumps(seen, ensure_ascii=False), flush=True)

    def windows():
        return ask("box", act="windows")["windows"]

    def shot(name, number):
        time.sleep(.8)
        path = out / (name + ".png")
        ask("winshot", path=str(path), browserWindow=number)
        if not path.exists() or path.stat().st_size < 1000:
            raise RuntimeError("Missing screenshot: " + str(path))

    process = launch(app, dict(os.environ, YAB_PROBE=world, YAB_HISTORY="own"), out,
                     task_name=os.environ.get("YAB_TASK_NAME", "Private spaces") + (" A" if baseline else " B"))
    try:
        deadline = time.monotonic() + 60
        while True:
            try:
                windows()
                break
            except (OSError, ValueError, RuntimeError):
                if process.poll() is not None or time.monotonic() >= deadline:
                    raise RuntimeError("The isolated app did not answer")
                time.sleep(.3)
        ask("ui", welcome=False, sidebar=True, look="dark", density="comfortable", sideWidth=240)
        ask("space", on=True, new="Work")
        normal = ask("spaces", browserWindow=1)
        check("the normal window has two spaces", len(normal["spaces"]) >= 2, normal)
        answer = ask("app-menu", menu="File", press="New Private Window")
        check("File opened a private window", answer.get("pressed"), None)
        time.sleep(1)
        listed = windows()
        private = next((i for i, w in enumerate(listed, 1) if w["title"].startswith("Private Window")), None)
        plain = next((i for i, w in enumerate(listed, 1) if not w["title"].startswith("Private Window")), None)
        check("there is a private window beside the normal one", private and plain, listed)
        if not (private and plain):
            return False
        seen = ask("spaces", browserWindow=private)
        check("the private window shows no spaces", seen.get("shown") is False, seen)
        check("the private window's foot has no row of spaces", seen.get("foot") is False, seen)
        check("the private column names no space", seen.get("named") is False, seen)
        before = next((s["name"] for s in seen["spaces"] if s["current"]), None)
        ask("space", to="Work", browserWindow=private)
        after = ask("spaces", browserWindow=private)
        moved = next((s["name"] for s in after["spaces"] if s["current"]), None)
        check("the private window goes to no other space", moved == before and "Work" not in after.get("order", ["Work"]), after)
        ask("box", act="focus-window", number=private)
        time.sleep(.5)
        names = [s["name"] for s in seen["spaces"]]
        title = next(w["title"] for w in windows() if w["title"].startswith("Private Window"))
        check("the private window's title names no space", not any(name in title for name in names), title)
        menu = ask("app-menu", menu="Spaces")
        # The items as the opened menu shows them (SwiftUI updates on open);
        # "unopened" can still be the normal window's.
        opened = [item["title"] for item in menu.get("items", [])]
        opened += [sub["title"] for item in menu.get("items", []) for sub in item.get("items", [])]
        check("the private Spaces menu lists none of yours",
              not any(name in title for name in names for title in opened), opened)
        shot("private-window", private)
        mine = ask("spaces", browserWindow=plain)
        check("the normal window still shows its spaces", mine.get("shown", True) and len(mine["spaces"]) >= 2, mine)
        shot("normal-window", plain)
    finally:
        (out / "report.json").write_text(json.dumps(dict(checks=checks, world=world, baseline=baseline),
                                                    indent=2, ensure_ascii=False) + "\n")
        process.terminate()
        process.wait(10)
    failed = [c["name"] for c in checks if not c["ok"]]
    accepted = bool(failed) and set(failed) <= set(PRIVATE_CHECKS) if baseline else not failed
    print(json.dumps(dict(baseline=baseline, passed=len(checks) - len(failed), total=len(checks),
                          failures=failed, accepted=accepted)), flush=True)
    return accepted


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True)
    parser.add_argument("--base-app")
    parser.add_argument("--out", type=Path, default=Path(os.environ.get("YAB_FARM_OUT", "build")) / "private-spaces")
    args = parser.parse_args()
    before = run(args.base_app, args.out / "before", baseline=True) if args.base_app else True
    after = run(args.app, args.out / "after")
    raise SystemExit(0 if before and after else 1)


if __name__ == "__main__":
    main()
