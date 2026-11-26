#!/usr/bin/env python3
"""#709: real rows at 4/5/6, whole-column hover and stable geometry.

Uses the existing isolated app launcher and native winshots. The optional
--pointer mode needs an exclusive farm job with --needs pointer; modeled
mouse moves alone do not cause SwiftUI's hover enter/exit. Saved pictures
are the visual oracle; row frames also detect any layout movement.
"""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import threading
import time
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from probe_app import launch


class Pages(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        data = ("<!doctype html><title>Today " + self.path.strip("/") +
                "</title><body style='background:#e9edf0;font:24px sans-serif;padding:40px'>" +
                "Tidy hover fixture " + self.path.strip("/")).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


def run(app_path, out, mode, expected_threshold, real_pointer=False):
    out.mkdir(parents=True, exist_ok=True)
    world = "tidy-hover-" + uuid.uuid4().hex[:8]
    domain = "dev.serafim.fast.test." + world
    support = Path.home() / "Library/Application Support" / ("Pane (" + world + ")")
    sock = support / "bench.sock"
    server = ThreadingHTTPServer(("127.0.0.1", 0), Pages)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    report = {"mode": mode, "source": os.environ.get("YAB_FARM_SNAPSHOT"), "steps": [], "checks": {}}
    proc = None

    def ask(**request):
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as c:
            c.settimeout(30)
            c.connect(str(sock))
            c.sendall((json.dumps(request) + "\n").encode())
            data = bytearray()
            while chunk := c.recv(65536):
                data.extend(chunk)
                if b"\n" in data:
                    break
        value = json.loads(data.split(b"\n", 1)[0])
        if "error" in value:
            raise RuntimeError(value)
        return value

    def check(name, ok):
        report["checks"][name] = bool(ok)
        print(("PASS " if ok else "FAIL ") + name, flush=True)

    try:
        for key, kind, value in [("bench", "-bool", "true"), ("welcomed", "-bool", "true"),
                                  ("dev.offer", "-bool", "false"), ("look", "-string", mode)]:
            subprocess.run(["defaults", "write", domain, key, kind, value], check=True)
        proc = launch(app_path, {"YAB_PROBE": world, "FAST_PROBE": world, "YAB_HISTORY": "own",
                                "YAB_STAGE": "/nonexistent-tidy-hover-stage", "YAB_TIDY_ANSWER": '{"groups":[]}'},
                      out, extra_env_names=("YAB_TIDY_ANSWER",), task_name="Tidy: hover " + mode)
        end = time.monotonic() + 50
        while not sock.exists() and time.monotonic() < end:
            time.sleep(.2)
        ask(do="ui", welcome=False, sidebar=True)
        ask(do="front")
        ask(do="window", frame=[100, 100, 1000, 740])
        for n in range(1, 7):
            ask(do="research", verb="go", url=f"http://127.0.0.1:{server.server_address[1]}/{n}", wait=.3)
            if n < 4:
                continue
            time.sleep(.5)
            state = ask(do="research", verb="state", wait=.1)
            check(f"{n} tabs: Tidy threshold {expected_threshold}", state["tidy"]["can"] == (n >= expected_threshold))
            frames = {}
            for where, x, y in [("out", 650, 330), ("in", 100, 330), ("out-again", 650, 330)]:
                if real_pointer:
                    # The explicit --needs pointer job uses the unchanged
                    # authorized hand. Coordinates match this owned window.
                    subprocess.run([sys.executable, str(Path(__file__).resolve().parents[1] / "window-tiling/pointer.py"),
                                    "move", str(100 + x), str(100 + y)], check=True, capture_output=True)
                    time.sleep(.3)
                else:
                    ask(do="pointer-move", x=x, y=y, wait=.3)
                frames[where] = ask(do="rowframes")
                ask(do="winshot", path=str(out / f"{n}-{where}.png"))
            check(f"{n} tabs: hover leaves geometry unchanged", frames["out"] == frames["in"] == frames["out-again"])
            report["steps"].append({"count": n, "tidy": state["tidy"], "frames": frames})
        # A shortcut hides/reveals a layered column without destroying its
        # SwiftUI view. Capture this state too; source review flagged it.
        ask(do="pointer-move", x=650, y=330, wait=.3)
        ask(do="ui", shut=True)
        time.sleep(.65)
        ask(do="ui", shut=False)
        time.sleep(.65)
        ask(do="winshot", path=str(out / "reveal-pointer-out.png"))
    finally:
        if proc is not None:
            proc.terminate()
            proc.wait(timeout=10)
        server.shutdown()
        subprocess.run(["defaults", "delete", domain], capture_output=True)
        shutil.rmtree(support, ignore_errors=True)
        (out / "report.json").write_text(json.dumps(report, indent=2))
    return all(report["checks"].values())


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--base-app", required=True, type=Path)
    parser.add_argument("--threshold", type=int, default=5)
    parser.add_argument("--pointer", action="store_true")
    parser.add_argument("--only-this", action="store_true")
    args = parser.parse_args()
    out = Path(os.environ["YAB_FARM_OUT"]) / "tidy-hover"
    outcomes = []
    for label, app, threshold in [("base", args.base_app, 6), ("this", args.app, args.threshold)]:
        if args.only_this and label == "base":
            continue
        for mode in ("light", "dark"):
            outcomes.append(run(app, out / label / mode, mode, threshold, args.pointer))
    return 0 if all(outcomes) else 1


if __name__ == "__main__":
    raise SystemExit(main())
