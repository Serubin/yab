#!/usr/bin/env python3
"""Winshots of the private window as it is today, for a before/after.

A normal window with a page and its ⌘T field, then File > New Private
Window: empty, with a page, and after ⌘T. Light look, so the private
window's own dark ground shows against the normal one. No checks.
"""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import threading
import time
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from probe_app import launch


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        name = self.path.strip("/") or "page"
        body = ("<title>%s · Example</title><body style='font:20px -apple-system;padding:56px;max-width:720px'>"
                "<h1>%s</h1><p>An ordinary page, to see the window round it.</p>"
                "<p style='color:#666'>Lorem ipsum dolor sit amet, consectetur adipiscing elit.</p>" % (name.title(), name.title())).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def run(app, out, url, look):
    out.mkdir(parents=True, exist_ok=True)
    world = "private-look-" + uuid.uuid4().hex[:12]
    domain = "dev.serafim.fast.test." + world
    for key in ("bench", "welcomed"):
        subprocess.run(["defaults", "write", domain, key, "-bool", "true"], check=True)
    support = Path.home() / "Library/Application Support" / ("Pane (" + world + ")")

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

    def windows():
        return ask("box", act="windows")["windows"]

    def key(keys, number):
        ask("box", act="key", keys=keys, browserWindow=number)
        time.sleep(.9)

    def shot(name, number):
        time.sleep(1.2)
        path = out / (look + "-" + name + ".png")
        ask("winshot", path=str(path), browserWindow=number, page=True)
        print("shot", path.name, json.dumps(windows(), ensure_ascii=False), flush=True)

    def private_number():
        return next(i for i, w in enumerate(windows(), 1) if w["title"].startswith("Private Window"))

    process = launch(app, dict(os.environ, YAB_PROBE=world, YAB_HISTORY="own"), out,
                     task_name=os.environ.get("YAB_TASK_NAME", "Private look"))
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
        ask("ui", welcome=False, sidebar=True, look=look, density="comfortable", sideWidth=240)
        ask("box", act="reset", urls=[url + "/inbox", url + "/docs"], browserWindow=1)
        time.sleep(1)
        shot("1-normal-page", 1)
        key("cmd+t", 1)
        shot("2-normal-cmd-t", 1)
        key("escape", 1)
        ask("app-menu", menu="File", press="New Private Window")
        time.sleep(1.5)
        p = private_number()
        shot("3-private-empty", p)
        ask("box", act="type", text=url + "/news", browserWindow=p)
        key("return", p)
        time.sleep(1)
        shot("4-private-page", p)
        key("cmd+t", p)
        shot("5-private-cmd-t", p)
        ask("box", act="type", text=url + "/weather", browserWindow=p)
        key("return", p)
        time.sleep(1)
        shot("6-private-two-pages", p)
        key("cmd+t", p)
        shot("7-private-cmd-t-two-pages", p)
        key("escape", p)
        key("cmd+n", p)
        time.sleep(1)
        print("frames after cmd+n", json.dumps([(w["title"], w["frame"]) for w in windows()], ensure_ascii=False), flush=True)
        print("tabs", json.dumps(ask("tabs", browserWindow=p), ensure_ascii=False), flush=True)
    finally:
        process.terminate()
        process.wait(10)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True)
    parser.add_argument("--out", type=Path, default=Path(os.environ.get("YAB_FARM_OUT", "build")) / "private-look")
    args = parser.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", 0), Page)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    url = "http://127.0.0.1:%d" % server.server_address[1]
    for look in ("light", "dark"):
        try:
            run(args.app, args.out, url, look)
        except Exception as error:
            print("FAILED", look, error, flush=True)


if __name__ == "__main__":
    main()
