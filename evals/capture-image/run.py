#!/usr/bin/env python3
"""Capture Image end to end in the built app (register 1808, docs/capture.md).

    swift build && python3 evals/capture-image/run.py evals/capture-image/fixture.webp

Serves a page with a real WebP from localhost, right-clicks it through the
page's own menu and checks: the row is there, the corner card holds the file's
pixels with no backdrop, Save writes a PNG under the picture's name, the next
capture keeps its saved look, Capture… opens from the plain page's menu, and
Download Image lands a PNG rather than a .webp. Separate test world.
"""
import functools
import http.server
import json
import os
from pathlib import Path
import shutil
import socket
import socketserver
import struct
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[2]
WORLD = f"capture-image-{os.getpid()}"
SOCKET = None
DOMAIN = f"dev.serafim.fast.test.{WORLD}"
OUT = Path(os.environ.get("YAB_FARM_OUT") or tempfile.mkdtemp())
STEM = f"cabin-{os.getpid()}"
failures = []


def check(what, ok, seen=""):
    print(("PASS: " if ok else "FAIL: ") + what + (f" ({seen})" if seen != "" and not ok else ""), flush=True)
    if not ok:
        failures.append(what)


def ask(**request):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(30)
        connection.connect(str(SOCKET))
        connection.sendall((json.dumps(request) + "\n").encode())
        data = bytearray()
        while chunk := connection.recv(1 << 16):
            data.extend(chunk)
    reply = json.loads(data.split(b"\n", 1)[0] or b"{}")
    reply.pop("clipboard", None)
    return reply


def grab(act, **options):
    return ask(do="grab", act=act, **options)


def menu(at, pick):
    ask(do="pointer", op="menu", at=at, pick=pick, wait=0.4)
    time.sleep(1.6)
    return json.dumps(ask(do="pointer", op="rows"), ensure_ascii=False)


def webp_size(data):
    # VP8X, VP8L or VP8, enough for the sizes a test picture comes in.
    kind = data[12:16]
    if kind == b"VP8X":
        return 1 + int.from_bytes(data[24:27], "little"), 1 + int.from_bytes(data[27:30], "little")
    if kind == b"VP8L":
        bits = int.from_bytes(data[21:25], "little")
        return (bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1
    return struct.unpack("<H", data[26:28])[0] & 0x3FFF, struct.unpack("<H", data[28:30])[0] & 0x3FFF


def main():
    global SOCKET
    picture = Path(sys.argv[1]).read_bytes()
    pixels = list(webp_size(picture))
    site = Path(tempfile.mkdtemp())
    (site / f"{STEM}.webp").write_bytes(picture)
    (site / "page.html").write_text(
        f'<!doctype html><title>Capture Image</title><body style="margin:0;height:900px">'
        f'<img src="/{STEM}.webp" style="position:absolute;left:40px;top:60px;width:500px">')
    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(site))
    server = socketserver.ThreadingTCPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    page = f"http://127.0.0.1:{server.server_address[1]}/page.html"

    home = Path(tempfile.mkdtemp())
    SOCKET = home / "Library" / "Application Support" / f"Pane ({WORLD})" / "bench.sock"
    fallback = Path.home() / "Library" / "Application Support" / f"Pane ({WORLD})" / "bench.sock"
    binary = subprocess.run(["swift", "build", "--show-bin-path"], cwd=ROOT, capture_output=True, text=True, check=True).stdout.strip()
    subprocess.run(["defaults", "write", DOMAIN, "bench", "-bool", "true"], check=True)
    subprocess.run(["defaults", "write", DOMAIN, "welcomed", "-bool", "true"], check=True)
    process = subprocess.Popen([str(Path(binary) / "Fast")], cwd=ROOT,
                               env=dict(os.environ, YAB_PROBE=WORLD, FAST_PROBE=WORLD, HOME=str(home)),
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(240):
            if fallback.exists():
                SOCKET = fallback
            if SOCKET.exists():
                break
            time.sleep(0.25)
        folder = SOCKET.parent / "Downloads"
        tab = ask(do="open", url=page, plain=True)
        short = tab.get("id", "")[:8]
        ask(do="select", id=short)
        ask(do="wait", id=short, seconds=15)
        time.sleep(1)

        rows = menu([200, 200], "YabCaptureImage")
        check("the picture's menu has Capture Image", "Capture Image" in rows, rows)
        state = grab("state")
        check("the corner card is up", state.get("stage") == "plate", state)
        check("it holds the file's own pixels", state.get("pixels") == pixels, f"{state.get('pixels')} vs {pixels}")
        check("no backdrop", state.get("style", {}).get("backdrop") == "none", state.get("style"))
        grab("hold")
        ask(do="winshot", path=str(OUT / "card.png"))
        paste = grab("paste")
        print("paste:", json.dumps(paste)[:200], flush=True)

        before = {str(p) for p in folder.glob(STEM + "*")}
        grab("save")
        time.sleep(1.5)
        made = {str(p) for p in folder.glob(STEM + "*")} - before
        check("Save writes a PNG under the picture's name", any(Path(p).name == STEM + ".png" for p in made), made)

        grab("start")
        time.sleep(0.4)
        state = grab("state")
        check("the next capture keeps its saved look", state.get("style", {}).get("backdrop") != "none", state.get("style"))
        grab("close")
        time.sleep(0.5)

        rows = menu([800, 700], "YabCapturePage")
        check("the plain page's menu has Capture…", "Capture…" in rows, rows)
        state = grab("state")
        check("Capture… opens picking", state.get("stage") == "picking", state)
        grab("close")
        time.sleep(0.5)

        before = {str(p) for p in folder.glob(STEM + "*")}
        menu([200, 200], "WKMenuItemIdentifierDownloadImage")
        time.sleep(2)
        made = {str(p) for p in folder.glob(STEM + "*")} - before
        check("Download Image lands a PNG", any(p.endswith(".png") for p in made), made)
        check("and no .webp stays", not any(p.endswith(".webp") for p in made), made)
        for name in made:
            check("the file is really a PNG", Path(name).read_bytes()[:4] == b"\x89PNG", name)
            shutil.copy(name, OUT)
    finally:
        process.terminate()
    print("FAILED" if failures else "ALL PASSED", failures)
    sys.exit(1 if failures else 0)


main()
