#!/usr/bin/env python3
"""Whether an agent's page keeps running in a hidden Yab while the Mac's
display sleeps or its screen is locked: the question docs/headless.md
leaves open for a Mac used only by agents (`yab serve`).

It needs someone at the Mac: a locked screen is unlocked with a password,
so run it there, then sleep the display (or lock the screen, ⌃⌘Q), wait,
and come back. Every few seconds it writes a line: the time, whether the
display is asleep and the screen locked, the page's visibilityState, and
its animation frames and 100 ms timer ticks since the line before.

    evals/headless/sleep.py --app "build/Pane Dev.app" [--minutes 5] [--every 5]

It starts the app as a test world of its own, hidden and serving
(`--headless --serve`), opens a page drawn by animation frames, reads it
through the app's own `yab mcp`, and quits it at the end.
"""
import argparse
import json
import os
import socket
import subprocess
import sys
import time

WORLD = "headless-sleep"
PAGE = "data:text/html,<title>ticks</title><h1>ticks</h1>"


def locked():
    out = subprocess.run(["ioreg", "-n", "Root", "-d1"], capture_output=True, text=True).stdout
    return '"CGSSessionScreenIsLocked"=Yes' in out


def asleep():
    js = "ObjC.import('CoreGraphics'); $.CGDisplayIsAsleep($.CGMainDisplayID())"
    out = subprocess.run(["osascript", "-l", "JavaScript", "-e", js], capture_output=True, text=True).stdout.strip()
    return out in ("1", "true")


class Mcp:
    def __init__(self, binary):
        env = dict(os.environ, YAB_PROBE=WORLD, FAST_PROBE=WORLD)
        self.p = subprocess.Popen([binary, "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=env, text=True)
        self.n = 0
        self.call("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "sleep", "version": "1"}})

    def call(self, method, params):
        self.n += 1
        self.p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": self.n, "method": method, "params": params}) + "\n")
        self.p.stdin.flush()
        while True:
            msg = json.loads(self.p.stdout.readline())
            if msg.get("id") == self.n:
                return msg["result"]

    def tool(self, name, **args):
        return self.call("tools/call", {"name": name, "arguments": args})["content"][0]["text"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--app", required=True)
    ap.add_argument("--minutes", type=float, default=5)
    ap.add_argument("--every", type=float, default=5)
    opts = ap.parse_args()
    app = os.path.abspath(opts.app)
    macos = os.path.join(app, "Contents", "MacOS")
    binary = os.path.join(macos, os.listdir(macos)[0])
    for key, kind, value in (("bench", "-bool", "true"), ("agents.asking", "-string", "bypass"), ("welcomed", "-bool", "true")):
        subprocess.call(["defaults", "write", f"dev.serafim.fast.test.{WORLD}", key, kind, value])
    subprocess.call(["open", "-g", "-j", "-n", "--env", f"YAB_PROBE={WORLD}", "--env", f"FAST_PROBE={WORLD}", "-a", app,
                     "--args", "--headless", "--serve"])
    sock = os.path.expanduser(f"~/Library/Application Support/Pane ({WORLD})/bench.sock")
    for _ in range(100):
        try:
            socket.socket(socket.AF_UNIX).connect(sock)
            break
        except OSError:
            time.sleep(0.1)
    m = Mcp(binary)
    tab = m.tool("open", url=PAGE).split()[1]
    m.tool("eval", tab=tab, js="const d=document.documentElement.dataset;d.raf=0;d.tick=0;"
           "(function f(){d.raf=+d.raf+1;requestAnimationFrame(f)})();setInterval(()=>d.tick=+d.tick+1,100);1")
    print("time      display  screen   page      frames/s  ticks/s", flush=True)
    last = (0, 0, time.time())
    end = time.time() + opts.minutes * 60
    try:
        while time.time() < end:
            time.sleep(opts.every)
            # Each read is a call in the tab, as an agent at work makes: the
            # question is whether a page being worked in still runs.
            said = json.loads(m.tool("eval", tab=tab, js="JSON.stringify([document.visibilityState, +document.documentElement.dataset.raf, +document.documentElement.dataset.tick])"))
            state, raf, tick = json.loads(said) if isinstance(said, str) else said
            now = time.time()
            span = now - last[2]
            print(f"{time.strftime('%H:%M:%S')}  {'asleep ' if asleep() else 'awake  '}  {'locked ' if locked() else 'open   '}  "
                  f"{state:8}  {(raf - last[0]) / span:8.1f}  {(tick - last[1]) / span:7.1f}", flush=True)
            last = (raf, tick, now)
    finally:
        try:
            m.tool("close", tab=tab)
        except Exception:
            pass
        m.p.terminate()
        subprocess.call([binary, "quit"], env=dict(os.environ, YAB_PROBE=WORLD, FAST_PROBE=WORLD), stdout=subprocess.DEVNULL)


if __name__ == "__main__":
    sys.exit(main())
