#!/usr/bin/env python3
"""Many agents at once in one yab: do they keep to their own tabs, and does yab keep up?

    ./stress.py --bin PATH [--steps 5,10,20,40] [--pages 3] [--model haiku]

Each step starts N agents together in one world, Pane (stress), through the
bench socket, each told to open its own K pages in tabs of its own, read the
code word on each and save "worker:code" there. The pages (a small server on
stress.localtest.me) write down every save, so the step is graded by what
was actually done, not by what the agents said:

  done       every worker saved each of its pages once, with its own code
  crossings  a save on a page that isn't the worker's, or someone else's code
  shared     a tab two sessions claim (yab's own record of whose tab is whose)
  latency    the bench's round trip every second: yab's main thread keeping up
  memory     yab and the pages' processes, and the agents' CLIs, as they grow

A step stops early, and the next isn't started, when free memory drops under
20% or the main thread's round trip passes 3 s: this runs on a Mac people use.
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import socket
import statistics
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

HERE = os.path.dirname(os.path.abspath(__file__))
REAL_HOME = os.path.expanduser("~")
PORT = 8790
LOG, LOCK = [], threading.Lock()


def code(worker, page):
    return hashlib.sha1(f"{worker}/{page}".encode()).hexdigest()[:6]


class Pages(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def reply(self, code_, body, location=None):
        data = body.encode()
        self.send_response(code_)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        if location:
            self.send_header("Location", location)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        m = re.match(r"^/w/(\d+)/(\d+)$", urlparse(self.path).path)
        if not m:
            return self.reply(404, "no")
        w, p = m.groups()
        self.reply(200, f"""<!doctype html><title>Worker {w}, page {p}</title>
<h1>Worker {w}, page {p}</h1><p>The code word is <b id=code>{code(w, p)}</b>.</p>
<form method=post action="/w/{w}/{p}/save"><input id=answer name=answer aria-label="Answer" size=30>
<button>Save</button></form>""")

    def do_POST(self):
        m = re.match(r"^/w/(\d+)/(\d+)/save$", urlparse(self.path).path)
        if not m:
            return self.reply(404, "no")
        form = parse_qs(self.rfile.read(int(self.headers.get("Content-Length") or 0)).decode())
        with LOCK:
            LOG.append({"worker": m.group(1), "page": m.group(2), "answer": form.get("answer", [""])[0].strip(), "at": time.time()})
        self.reply(303, "", location=f"/w/{m.group(1)}/{m.group(2)}?saved")


def serve():
    httpd = ThreadingHTTPServer(("127.0.0.1", PORT), Pages)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()


class Yab:
    def __init__(self, world):
        self.sock = os.path.join(REAL_HOME, f"Library/Application Support/Pane ({world})/bench.sock")

    def __call__(self, request, timeout=60):
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.settimeout(timeout)
            # Refused for a moment when many callers queue at once, as yab's
            # own MCP helpers allow for; refused for three seconds is gone.
            for pause in (0.05, 0.1, 0.2, 0.4, 0.8, 1.2, None):
                try:
                    s.connect(self.sock)
                    break
                except ConnectionRefusedError:
                    if pause is None:
                        raise
                    self.refused = getattr(self, "refused", 0) + 1
                    time.sleep(pause)
            s.sendall((json.dumps(request) + "\n").encode())
            chunks = []
            while True:
                chunk = s.recv(1 << 16)
                if not chunk:
                    break
                chunks.append(chunk)
        return json.loads(b"".join(chunks).split(b"\n", 1)[0] or b"{}")


def rss(pattern):
    out = subprocess.run(["ps", "-Ao", "rss=,command="], capture_output=True, text=True).stdout
    rows = [line.strip().split(None, 1) for line in out.splitlines()]
    hits = [int(r[0]) for r in rows if len(r) == 2 and re.search(pattern, r[1])]
    return round(sum(hits) / 1024), len(hits)


def free_percent():
    out = subprocess.run(["memory_pressure"], capture_output=True, text=True).stdout
    m = re.search(r"free percentage: (\d+)%", out)
    return int(m.group(1)) if m else 100


def start(opts, folder):
    world = "stress"
    for key, kind, value in (("bench", "-bool", "true"), ("agents.asking", None, "bypass")):
        subprocess.run(["defaults", "write", f"dev.serafim.fast.test.{world}", key] + ([kind] if kind else []) + [value], check=True)
    home = os.path.join(folder, "home")
    os.makedirs(home, exist_ok=True)
    claude = os.path.join(folder, "claude-real")
    with open(claude, "w") as f:
        f.write(f"#!/bin/bash\nexport HOME={REAL_HOME}\nexec {shutil.which('claude')} \"$@\"\n")
    os.chmod(claude, 0o755)
    env = dict(os.environ, YAB_PROBE=world, HOME=home, YAB_OFFSCREEN="1", YAB_HISTORY="own", YAB_AGENT_CLAUDE=claude, YAB_HANGS="1")
    process = subprocess.Popen([opts.bin], env=env, stdout=open(os.path.join(folder, "yab.log"), "w"), stderr=subprocess.STDOUT,
                               start_new_session=True)
    yab = Yab(world)
    for _ in range(60):
        try:
            yab({"do": "tabs"}, timeout=5)
            yab({"do": "ui", "welcome": False})
            return process, yab
        except OSError:
            time.sleep(1)
    process.kill()
    sys.exit("the stress world didn't start")


def step(yab, process, n, opts, folder):
    with LOCK:
        LOG.clear()
    prompt = lambda w: (
        f"You are worker {w}. Open each of these pages in a new tab of your own and keep each tab open until all are done: "
        + ", ".join(f"http://stress.localtest.me:{PORT}/w/{w}/{p}" for p in range(1, opts.pages + 1))
        + f". On each page read the code word, type exactly {w}:<the code word> into the Answer box and press Save. "
        "Work only in the tabs you opened. When every page is saved, close your tabs and answer with the codes.")
    sessions = {}
    # The pages' processes and the CLIs are counted system-wide: what the
    # step adds is the growth over where they stood before it.
    web0, _ = rss(r"com\.apple\.WebKit\.WebContent")
    cli0, clis0 = rss(r"claude .*--input-format stream-json")
    began = time.time()
    try:
        yab({"do": "hangs"})
    except OSError:
        pass
    # Where the main thread was, the whole step: a stall of seconds is most
    # of its tree.
    sampler = subprocess.Popen(["arch", "-arm64", "/usr/bin/sample", str(process.pid), str(min(opts.limit, 60)), "10", "-file",
                                os.path.join(folder, f"step-{n}.sample.txt")], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) if opts.sample else None
    for w in range(1, n + 1):
        got = yab({"do": "agent-run", "prompt": prompt(w), "access": "browser", "model": opts.model})
        sessions[w] = got.get("session")
    latencies, peak = [], {"tabs": 0, "yab_mb": 0, "web_mb": 0, "cli_mb": 0, "cli": 0}
    slow = 0
    shared, stopped = set(), None
    while time.time() - began < opts.limit:
        t = time.time()
        try:
            agents = yab({"do": "agents"}, timeout=30).get("agents", [])
        except OSError as trouble:
            stopped = f"bench: {trouble}" + ("" if process.poll() is None else f", yab gone ({process.returncode})")
            break
        latencies.append((time.time() - t) * 1000)
        mine = [a for a in agents if a["session"] in sessions.values()]
        owners = {}
        for a in mine:
            for tab in a.get("tabs", []):
                if tab in owners and owners[tab] != a["session"]:
                    shared.add(tab)
                owners[tab] = a["session"]
        yab_mb, _ = rss(re.escape(opts.bin) + r"$")
        web_mb, _ = rss(r"com\.apple\.WebKit\.WebContent")
        cli_mb, cli = rss(r"claude .*--input-format stream-json")
        peak = {"tabs": max(peak["tabs"], len(owners)), "yab_mb": max(peak["yab_mb"], yab_mb), "web_mb": max(peak["web_mb"], web_mb - web0),
                "cli_mb": max(peak["cli_mb"], cli_mb - cli0), "cli": max(peak["cli"], cli - clis0)}
        live = [a for a in mine if a["state"] in ("starting", "signing-in", "running", "waiting", "attached")]
        if not live:
            break
        if free_percent() < 20:
            stopped = "free memory under 20%"
            break
        # One long stall is written down; three in a row stop the step.
        slow = slow + 1 if latencies[-1] > 3000 else 0
        if slow >= 3:
            stopped = f"main thread round trip over 3 s three times running ({round(latencies[-1])} ms)"
            break
        time.sleep(1)
    # What each worker that didn't finish said, and where it was.
    with LOCK:
        saved = {(x["worker"], x["page"]) for x in LOG}
    missed = {}
    for w, s in sessions.items():
        if all((str(w), str(p)) in saved for p in range(1, opts.pages + 1)):
            continue
        try:
            got = yab({"do": "agent-wait", "session": s, "after": 0, "seconds": 1})
            missed[w] = {"state": got.get("state"), "result": str(got.get("result", ""))[:300], "last": (got.get("events") or [])[-6:]}
        except OSError:
            missed[w] = {"state": "unknown"}
    for s in sessions.values():
        try:
            yab({"do": "agent-stop", "session": s})
        except OSError:
            break
    try:
        hangs = yab({"do": "hangs"}).get("report", "")
    except OSError:
        hangs = ""
    with open(os.path.join(folder, f"step-{n}.hangs.txt"), "w") as f:
        f.write(str(hangs))
    if sampler:
        sampler.terminate()
    seconds = round(time.time() - began)
    with LOCK:
        saves = list(LOG)
    crossings = [s for s in saves if not s["answer"].startswith(f"{s['worker']}:") or s["answer"].split(":", 1)[-1] != code(s["worker"], s["page"])]
    good = {(s["worker"], s["page"]) for s in saves if s not in crossings}
    done = sum(1 for w in range(1, n + 1) if all((str(w), str(p)) in good for p in range(1, opts.pages + 1)))
    twice = len(saves) - len({(s["worker"], s["page"]) for s in saves})
    return {"agents": n, "pages": opts.pages, "done": done, "crossings": len(crossings), "crossed": crossings[:5], "saved_twice": twice,
            "shared_tabs": len(shared), "missed": missed, "seconds": seconds, "stopped": stopped, "stalls_over_1s": sum(1 for l in latencies if l > 1000),
            "latency_ms": {"median": round(statistics.median(latencies)) if latencies else None,
                           "p95": round(sorted(latencies)[int(len(latencies) * 0.95) - 1]) if len(latencies) > 1 else None,
                           "max": round(max(latencies)) if latencies else None},
            "peak": peak, "yab_alive": process.poll() is None}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bin", required=True, help="a copy of a yab built from this tree")
    parser.add_argument("--steps", default="5,10,20,40")
    parser.add_argument("--pages", type=int, default=3)
    parser.add_argument("--model", default="haiku", help="a cheap one: the agents only open, read and type")
    parser.add_argument("--limit", type=int, default=600, help="seconds a step may take")
    parser.add_argument("--sample", action="store_true", help="sample yab the whole step (every 10 ms), for a stall's stack")
    opts = parser.parse_args()
    opts.bin = os.path.abspath(opts.bin)
    folder = os.path.join(HERE, "results", time.strftime("%Y%m%d-%H%M%S"))
    os.makedirs(folder, exist_ok=True)
    serve()
    process, yab = start(opts, folder)
    results = []
    try:
        for n in [int(x) for x in opts.steps.split(",")]:
            print(f"step: {n} agents × {opts.pages} tabs", flush=True)
            result = step(yab, process, n, opts, folder)
            results.append(result)
            print(json.dumps(result), flush=True)
            if result["stopped"] or not result["yab_alive"]:
                print("stopping: " + (result["stopped"] or "yab died"), flush=True)
                break
            # The tabs of the step before are closed, whatever the agents left.
            for tab in [t["id"] for t in yab({"do": "tabs"}).get("tabs", []) if "stress.localtest" in t.get("url", "")]:
                yab({"do": "close", "id": tab})
            time.sleep(10)
    finally:
        with open(os.path.join(folder, "results.json"), "w") as f:
            json.dump(results, f, indent=1)
        process.terminate()
    print(f"\n{'agents':>6} {'done':>6} {'cross':>6} {'shared':>6} {'twice':>6} {'secs':>5} {'lat p95':>8} {'tabs':>5} {'yab MB':>7} {'+pages MB':>9} {'+CLIs MB':>8}")
    for r in results:
        print(f"{r['agents']:>6} {r['done']:>6} {r['crossings']:>6} {r['shared_tabs']:>6} {r['saved_twice']:>6} {r['seconds']:>5} "
              f"{str(r['latency_ms']['p95']):>8} {r['peak']['tabs']:>5} {r['peak']['yab_mb']:>7} {r['peak']['web_mb']:>9} {r['peak']['cli_mb']:>8}")


if __name__ == "__main__":
    main()
