#!/usr/bin/env python3
"""Settings' scroll across pages: a page opened from another (a sub-page such
as Invite Friends › Best Friend, or one from the sidebar) starts at its top;
back comes to where the page before was left, and forward to where that one was,
already there when travel answers, before a frame is drawn: never the page's
top first and then a jump.

    evals/settings-top/check.py --bin "build/Pane Dev.app/Contents/MacOS/pane"
"""
import argparse
import os
import shutil
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "sync"))
from check import Yab  # noqa: E402

# (from, to): a long page scrolled down, then the page it leads to.
PAIRS = [("inviteFriends", "bestFriend"), ("about", "credits"),
         ("appearance", "appIcon"), ("shortcuts", "privacy"), ("bestFriend", "inviteFriends")]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bin", required=True)
    args = parser.parse_args()
    scratch = tempfile.mkdtemp(prefix="yab-settings-top-")
    yab = Yab(args.bin, scratch, "top", "http://127.0.0.1:9")
    results = []

    def scroll(**request):
        return yab.bench(wait=30, do="scroll", **request)

    def check(name, y, want, extra=""):
        ok = y is not None and abs(y - want) < 2
        results.append(ok)
        print(f"{'ok  ' if ok else 'FAIL'} {name}: y {y}, want {want} {extra}")

    try:
        yab.start()
        yab.bench(wait=30, do="ui", page="general", settings=True)
        time.sleep(1.0)
        for start, end in PAIRS:
            scroll(go=start)
            time.sleep(0.8)
            down = scroll(to=300).get("y", 0)
            time.sleep(0.3)
            scroll(go=end)
            time.sleep(0.8)
            check(f"{start} -> {end} at top", scroll(where=True).get("y"), 0, f"(left {start} at {down:.0f})")
            fwd = scroll(to=120).get("y", 0)
            time.sleep(0.3)
            check(f"back to {start} at once", scroll(travel=-1).get("y"), down)
            time.sleep(0.8)
            check(f"back to {start}", scroll(where=True).get("y"), down)
            check(f"forward to {end} at once", scroll(travel=1).get("y"), fwd)
            time.sleep(0.8)
            check(f"forward to {end}", scroll(where=True).get("y"), fwd)
    finally:
        yab.stop()
        shutil.rmtree(scratch, ignore_errors=True)
    print(f"{sum(results)}/{len(results)}")
    sys.exit(0 if all(results) else 1)


if __name__ == "__main__":
    main()
