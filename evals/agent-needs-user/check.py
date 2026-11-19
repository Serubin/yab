#!/usr/bin/env python3
"""An agent outside Yab hears at once that Yab is waiting for its user.

Claude Code or Codex in a terminal, using Yab through `yab mcp` or the `yab`
command, used to sit silent for minutes while Yab waited for the user's yes,
sign-in or pick: the user looked at the agent's chat, not at Yab. This runs
the real binary's MCP server and CLI against a stand-in browser socket:

- as Claude Code (it sends a progress token): the progress line says what Yab
  asks within a couple of seconds, and the call waits on and finishes by
  itself once the user answers;
- as Codex (no progress token, 60 s limit): the call comes back within about
  15 seconds saying what Yab asks and to tell the user;
- `yab "task"` run by an agent: exit 3 within about 15 seconds, the same.

    python3 evals/agent-needs-user/check.py --bin build/Yab.app/Contents/MacOS/Yab --out OUT
"""
import argparse
import glob
import json
import os
import socket
import subprocess
import tempfile
import threading
import time
from pathlib import Path

QUESTION = "Sign in to Google"
# When the stand-in user answers in Yab: None while nobody does.
ANSWERED = {"at": None}


def answered():
    return ANSWERED["at"] is not None and time.time() >= ANSWERED["at"]


def answer(request):
    verb = request.get("do")
    if verb == "agent-attach":
        return {"session": "outside-1"}
    if verb == "handoff":
        return {}
    if verb == "agent-sign-in":
        if answered():
            return {"said": "Signed in."}
        return {"error": "signing in waits for the person's yes; asking them now", "asking": True, "tab": "t1"}
    if verb == "handoff-wait":
        limit = time.time() + min(request.get("seconds", 20), 2)
        while time.time() < limit:
            if answered():
                return {"state": "done", "answer": ""}
            time.sleep(0.1)
        return {"state": "waiting", "question": QUESTION}
    if verb == "agent-run":
        return {"session": "task-1"}
    if verb == "agent-wait":
        time.sleep(1)
        return {"state": "waiting", "needs": QUESTION, "needs_kind": "hands", "seen": 0, "events": []}
    return {}


def serve(path, heard):
    server = socket.socket(socket.AF_UNIX)
    server.bind(path)
    server.listen(16)

    def one(connection):
        try:
            talk(connection)
        except OSError:
            pass  # the client went (killed after its answer)

    def talk(connection):
        with connection:
            data = b""
            while b"\n" not in data:
                chunk = connection.recv(65536)
                if not chunk:
                    return
                data += chunk
            request = json.loads(data.split(b"\n")[0])
            heard.append(request.get("do"))
            connection.sendall((json.dumps(answer(request)) + "\n").encode())

    def loop():
        while True:
            connection, _ = server.accept()
            threading.Thread(target=one, args=(connection,), daemon=True).start()

    threading.Thread(target=loop, daemon=True).start()


def mcp_call(binary, path, tool, arguments, client, progress=False):
    """The call's answer, how long it took, and each progress line with when it came."""
    proc = subprocess.Popen([binary, "mcp", "--socket", path], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, text=True)

    def send(message):
        proc.stdin.write(json.dumps(message) + "\n")
        proc.stdin.flush()

    lines = []

    def until(id_, started=0.0):
        while True:
            line = proc.stdout.readline()
            if not line:
                raise RuntimeError("yab mcp closed: " + proc.stderr.read()[-400:])
            message = json.loads(line)
            if message.get("method") == "notifications/progress":
                lines.append((round(time.time() - started, 1), message["params"].get("message", "")))
            if message.get("id") == id_:
                return message

    try:
        send({"jsonrpc": "2.0", "id": 1, "method": "initialize",
              "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": client, "version": "1"}}})
        until(1)
        send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        started = time.time()
        params = {"name": tool, "arguments": arguments}
        if progress:
            params["_meta"] = {"progressToken": 7}
        send({"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": params})
        reply = until(2, started)
        took = time.time() - started
        text = "".join(part.get("text", "") for part in reply.get("result", {}).get("content", []))
        return took, text, lines
    finally:
        proc.kill()
        proc.communicate(timeout=5)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bin")
    parser.add_argument("--out", default=os.environ.get("YAB_FARM_OUT", "work/agent-needs-user"))
    args = parser.parse_args()
    binary = args.bin or next(p for p in sorted(glob.glob("build/*.app/Contents/MacOS/*")) if not p.endswith("PaneUpdater"))
    results = []
    with tempfile.TemporaryDirectory(prefix="yab-needs-") as scratch:
        path = str(Path(scratch) / "bench.sock")
        heard = []
        serve(path, heard)

        # Codex: no progress line, so the call itself says it in 15 s.
        for tool, arguments in [("handoff", {"tab": "t1", "reason": QUESTION}), ("sign_in", {"tab": "t1"})]:
            took, text, lines = mcp_call(binary, path, tool, arguments, "codex-mcp-client")
            passed = took < 25 and "status: needs_user" in text and QUESTION in text and "Tell the user" in text
            results.append(dict(case=f"codex {tool}", seconds=round(took, 1), text=text, progress=lines, passed=passed))

        # Claude Code: the line at once, the call waiting on, done by itself
        # once the user answers (here after 40 s, past the old 15 s).
        for tool, arguments in [("handoff", {"tab": "t1", "reason": QUESTION}), ("sign_in", {"tab": "t1"})]:
            ANSWERED["at"] = time.time() + 40
            took, text, lines = mcp_call(binary, path, tool, arguments, "claude-code", progress=True)
            ANSWERED["at"] = None
            first = lines[0] if lines else (None, "")
            passed = (first[0] is not None and first[0] < 3 and QUESTION in first[1]
                      and took >= 38 and "needs_user" not in text)
            results.append(dict(case=f"claude {tool}", seconds=round(took, 1), text=text, progress=lines, passed=passed))

        started = time.time()
        # A farm job sets its own person wait (YAB_WAIT_PERSON): the default is what's checked.
        env = {k: v for k, v in os.environ.items() if k != "YAB_WAIT_PERSON"}
        proc = subprocess.run([binary, "agent", "--socket", path, "sign in to google for me"], stdin=subprocess.DEVNULL,
                              capture_output=True, text=True, timeout=120, env=env)
        took = time.time() - started
        passed = proc.returncode == 3 and took < 25 and QUESTION in proc.stdout and "tell your user now" in proc.stdout
        results.append(dict(case="cli task", seconds=round(took, 1), exit=proc.returncode, text=proc.stdout + proc.stderr, passed=passed))

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    (out / "agent-needs-user.json").write_text(json.dumps(results, indent=2) + "\n")
    for r in results:
        print(f"{'PASS' if r['passed'] else 'FAIL'}  {r['case']}  {r['seconds']} s")
        for at, line in r.get("progress", [])[:2]:
            print(f"    progress at {at} s: {line}")
        print("    " + r["text"].strip().replace("\n", "\n    "))
    return int(not all(r["passed"] for r in results))


if __name__ == "__main__":
    raise SystemExit(main())
