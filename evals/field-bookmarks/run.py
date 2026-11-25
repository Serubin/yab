#!/usr/bin/env python3
"""Bookmarks among ⌘T's places: typed words find a bookmark never visited,
ranked as history ranks it, once, with "Bookmark" at its row's end.

Run after a build: python3 evals/field-bookmarks/run.py [--bin PATH] [--out DIR]
[--before]. A test world of its own, seeded with a history and bookmarks.
--before only takes the pictures, for a build without bookmark rows.
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
import uuid


ROOT = Path(__file__).resolve().parents[2]
WORLD = f"field-bookmarks-{os.getpid()}"
SUPPORT = Path.home() / "Library" / "Application Support" / f"Pane ({WORLD})"
SOCKET = SUPPORT / "bench.sock"
DOMAIN = f"dev.serafim.fast.test.{WORLD}"
NOW = time.time()


def site(title, url):
    return {"id": str(uuid.uuid4()).upper(), "title": title, "url": url}


def folder(title, children):
    return {"id": str(uuid.uuid4()).upper(), "title": title, "children": children}


BOOKMARKS = [
    site("Linear: Roadmap", "https://linear.app/yab/roadmap"),
    folder("Docs", [
        site("Quarterly Planning", "https://docs.google.com/document/d/1Qp/edit"),
        site("Swift Concurrency Guide", "https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/"),
        # Been to as well: one row, ranked higher.
        site("Hacker News", "https://news.ycombinator.com/"),
    ]),
]

# Seconds since 2001, as Foundation's Date encodes.
REFERENCE = 978_307_200


def visit(key, title, count, days_ago):
    return {"url": "https://" + key + ("" if "/" in key else "/"), "key": key, "title": title, "count": count,
            "last": NOW - REFERENCE - days_ago * 86_400}


HISTORY = [
    visit("linkedin.com", "LinkedIn", 3, 2),
    visit("news.ycombinator.com", "Hacker News", 6, 1),
    visit("newsroom.example.com", "Newsroom", 7, 1),
    visit("docs.github.com", "GitHub Docs", 4, 3),
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


def typed(text):
    box("key", keys="escape")
    box("t")
    return box("type", text=text)


def rows(state):
    return [(row["key"], row.get("bookmarked", False)) for row in state["offers"] if row["url"]]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bin", help="the app's executable; the newest build/*.app when left out")
    parser.add_argument("--out", type=Path, default=ROOT / ".build" / "field-bookmarks")
    parser.add_argument("--before", action="store_true", help="pictures only, for a build without bookmark rows")
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    if not args.bin:
        apps = sorted(ROOT.glob("build/*.app/Contents/MacOS/pane"), key=lambda path: path.stat().st_mtime)
        assert apps, "No build/*.app: run ./build.sh first"
        args.bin = str(apps[-1])
    print(f"Using {args.bin}")

    scratch = Path(tempfile.mkdtemp(prefix="yab-field-bookmarks-"))
    SUPPORT.mkdir(parents=True, exist_ok=True)
    (SUPPORT / "bookmarks.json").write_text(json.dumps(BOOKMARKS))
    (SUPPORT / "history.json").write_text(json.dumps(HISTORY))
    subprocess.run(["defaults", "write", DOMAIN, "bench", "-bool", "true"], check=True)
    subprocess.run(["defaults", "write", DOMAIN, "welcomed", "-bool", "true"], check=True)
    process = subprocess.Popen([args.bin], cwd=ROOT,
                               env=dict(os.environ, YAB_PROBE=WORLD, FAST_PROBE=WORLD, HOME=str(scratch)),
                               stdout=subprocess.DEVNULL, stderr=open(args.out / "app.log", "w"))
    prefix = "before" if args.before else "after"
    try:
        for _ in range(80):
            if SOCKET.exists():
                break
            assert process.poll() is None, "Test app exited: " + (args.out / "app.log").read_text()[-2000:]
            time.sleep(0.25)
        assert SOCKET.exists(), "Test app did not open its socket"
        box("blur")
        time.sleep(1)

        cases = [("lin", "linear.app/yab/roadmap"), ("quarterly", "docs.google.com/document/d/1qp/edit"),
                 ("swift conc", None), ("news", "news.ycombinator.com")]
        for words, first in cases:
            state = typed(words)
            time.sleep(0.4)
            ask(do="winshot", path=str(args.out / f"{prefix}-{words.replace(' ', '-')}.png"))
            found = rows(state)
            print(words, "->", found)
            if args.before:
                continue
            if words == "lin":
                # A bookmark never visited: listed, under a site's front
                # door been to lately, over the site the field only knows.
                keys = [key for key, _ in found]
                assert (first, True) in found, found
                assert "linear.app" not in keys or keys.index(first) < keys.index("linear.app"), found
            elif words == "quarterly":
                assert (first, True) in found, found
            elif words == "swift conc":
                assert any(key.startswith("docs.swift.org") and marked for key, marked in found), found
            elif words == "news":
                assert [key for key, _ in found].count("news.ycombinator.com") == 1, found
                assert ("news.ycombinator.com", True) in found, found
                # Six visits and a bookmark beat seven visits.
                keys = [key for key, _ in found]
                assert keys.index("news.ycombinator.com") < keys.index("newsroom.example.com"), found
            print(f"PASS: {words}")
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
