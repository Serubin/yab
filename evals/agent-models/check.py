#!/usr/bin/env python3
"""A model the agent's copy can't take, end to end, on the real CLIs.

    python3 evals/agent-models/check.py --app "build/Pane Dev.app" [--codex PATH] [--claude PATH]

The ChatGPT app writes `model = "gpt-6.1-sol"` into ~/.codex/config.toml;
an older Codex (Homebrew's 0.157) sends it on and is turned away with "not
supported when using Codex with a ChatGPT account". Yab is started as a
world of its own whose agents are this Mac's real ones signed in as you
(HOME is yours for them only), given that older copy, and asked:

- a task naming no model: it must finish, on a model that copy has;
- a task naming gpt-6.1-sol: finished on another, the swap said in its steps;
- Claude Code on a model that doesn't exist: tried again on its default.

And with no stand-ins, which copies the world itself picks: the newest.
Each run costs three short answers on your plans.
"""
import argparse
import json
import os
import socket
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
parser = argparse.ArgumentParser()
parser.add_argument("--app", required=True)
parser.add_argument("--exe", default="yab")
parser.add_argument("--codex", default="/opt/homebrew/bin/codex", help="an older Codex than the one that wrote the config")
parser.add_argument("--claude", default="/opt/homebrew/bin/claude")
OPTS = parser.parse_args()
OUT = tempfile.mkdtemp(prefix="yab-agent-models-")
REAL_HOME = os.path.expanduser("~")
FAILS = []


def check(what, ok, detail=""):
    print(("✓ " if ok else "✗ ") + what + ("" if ok else f": {str(detail)[:700]}"), flush=True)
    if not ok:
        FAILS.append(what)


class World:
    def __init__(self, name, stand_ins):
        self.name = name
        self.sock = os.path.expanduser(f"~/Library/Application Support/Pane ({name})/bench.sock")
        suite = f"dev.serafim.fast.test.{name}"
        subprocess.run(["defaults", "delete", suite], stderr=subprocess.DEVNULL)
        for key in ("bench", "welcomed"):
            subprocess.run(["defaults", "write", suite, key, "-bool", "true"])
        subprocess.run(["rm", "-rf", os.path.dirname(self.sock)])
        home = os.path.join(OUT, name)
        os.makedirs(home)
        env = {**os.environ, "YAB_PROBE": name, "YAB_HISTORY": "own", "YAB_OFFSCREEN": "1", "HOME": home}
        for key in [k for k in env if k.startswith(("YAB_AGENT_", "CODEX_", "CLAUDE"))]:
            del env[key]
        if stand_ins:
            env["YAB_AGENT_CODEX"] = self.wrapper("codex", OPTS.codex)
            env["YAB_AGENT_CLAUDE"] = self.wrapper("claude", OPTS.claude)
        self.process = subprocess.Popen([os.path.join(OPTS.app, "Contents/MacOS", OPTS.exe)], env=env,
                                        stdout=subprocess.DEVNULL, stderr=open(os.path.join(OUT, name + ".log"), "w"))

    def wrapper(self, name, binary):
        # The world's HOME is scratch; its agent signs in as you do.
        path = os.path.join(OUT, f"{self.name}-{name}")
        with open(path, "w") as f:
            f.write(f"#!/bin/bash\nexport HOME={REAL_HOME}\nexec {binary} \"$@\"\n")
        os.chmod(path, 0o755)
        return path

    def __call__(self, request, timeout=60):
        for _ in range(120):
            try:
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
                    s.settimeout(timeout)
                    s.connect(self.sock)
                    s.sendall((json.dumps(request) + "\n").encode())
                    data = b""
                    while True:
                        chunk = s.recv(1 << 16)
                        if not chunk:
                            break
                        data += chunk
                return json.loads(data.split(b"\n", 1)[0] or b"{}")
            except (FileNotFoundError, ConnectionRefusedError):
                time.sleep(0.5)
        raise SystemExit("yab isn't listening")

    def task(self, cli, model=None, seconds=240):
        request = {"do": "agent-run", "cli": cli, "access": "browser",
                   "prompt": "Answer with exactly the word PONG and nothing else. Use no tools."}
        if model:
            request["model"] = model
        session = self(request)["session"]
        end = time.time() + seconds
        got = {}
        while time.time() < end:
            got = self({"do": "agent-wait", "session": session, "seconds": 20, "after": 0}, timeout=40)
            if got.get("state") not in ("starting", "signing-in", "running", "waiting", "attached"):
                break
        got["notes"] = [e if isinstance(e, str) else json.dumps(e) for e in got.get("events", [])]
        return got

    def stop(self):
        self.process.terminate()
        try:
            self.process.wait(10)
        except subprocess.TimeoutExpired:
            self.process.kill()


def said(got, words):
    return any(words in n for n in got["notes"] + got.get("items", []))


old = subprocess.run([OPTS.codex, "--version"], capture_output=True, text=True).stdout.strip()
config = open(os.path.join(REAL_HOME, ".codex/config.toml")).read()
print(f"codex given: {OPTS.codex} ({old}); config: {[l for l in config.splitlines() if l.startswith('model')]}", flush=True)

world = World("agentmodels", stand_ins=True)
try:
    plain = world.task("codex")
    check("Codex on the config's model, older copy: finishes", plain.get("state") == "done" and "PONG" in plain.get("result", ""), plain)
    named = world.task("codex", model="gpt-6.1-sol")
    check("Codex asked for gpt-6.1-sol: finishes on another", named.get("state") == "done" and "PONG" in named.get("result", ""), named)
    check("…and says which", said(named, "isn't available to this Codex"), named["notes"])
    claude = world.task("claude", model="claude-made-up-9")
    notes = claude["notes"]
    swapped = next((i for i, n in enumerate(notes) if "isn't available on this plan" in n), None)
    check("Claude Code on a model that doesn't exist: tried again on its default",
          swapped is not None and any("working" in n for n in notes[swapped + 1:]), notes)
    if "limit" in claude.get("result", "") and claude.get("state") == "failed":
        # The plan's own limit, after the swap: nothing of Yab's to check.
        print("– Claude's plan is out of room: the answer itself not checked", flush=True)
    else:
        check("…and finishes", claude.get("state") == "done" and "PONG" in claude.get("result", ""), claude)
finally:
    world.stop()

world = World("agentcopies", stand_ins=False)
try:
    found = {}
    world({"do": "ui", "agents": "find"})
    for _ in range(60):
        found = world({"do": "ui", "agents": "status"})
        if found.get("found") and any(found["found"]):
            break
        time.sleep(0.5)
    print("found:", found.get("found"), flush=True)
    picked = (found.get("found") or ["", ""])[1]
    versions = {}
    for path in [OPTS.codex, "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex", picked]:
        if path and os.access(path, os.X_OK):
            versions[path] = subprocess.run([path, "--version"], capture_output=True, text=True).stdout.strip()
    print("versions:", versions, flush=True)
    newest = max(versions.values(), key=lambda v: [int(x) for x in v.split()[-1].split(".")]) if versions else ""
    check("the world picks the newest Codex", picked and versions.get(picked) == newest, versions)
finally:
    world.stop()

print("\nresult:", "PASS" if not FAILS else f"FAIL ({len(FAILS)}): " + "; ".join(FAILS), flush=True)
sys.exit(1 if FAILS else 0)
