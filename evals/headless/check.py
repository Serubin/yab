#!/usr/bin/env python3
"""Yab hidden for the command line (docs/headless.md), every case once, no
model: a build of this tree wrapped as a probe app, a test world of its
own, a stand-in Claude (./fake-claude). A few minutes; exit 1 on a failure.

    evals/headless/check.py [--bin .build/debug/Fast] [--only a,b] [--keychain]

--keychain adds the session cookies kept across an idle quit, which need
the real HOME's keychain (not over ssh). Cases that need to see windows or
the menu bar use a small Swift helper compiled on the spot; the menu bar
needs Accessibility for it and says skip without.
"""
import argparse
import json
import os
import plistlib
import select
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
BROWSE = os.path.join(ROOT, "evals", "browse")
WORLD = "headless-check-" + uuid.uuid4().hex[:12]
PAGE = os.environ.get("YAB_HEADLESS_PAGE", "http://127.0.0.1:8751/button.html")
NAME = os.environ.get("YAB_TASK_NAME", "Yab Dev Headless Check")

HELPER = r'''
import AppKit
import ApplicationServices
let args = CommandLine.arguments
let pid = Int32(args.count > 2 ? args[2] : "0") ?? 0
switch args[1] {
case "wins":
    let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
    let mine = list.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid }.map { w -> [String: Any] in
        let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
        return ["x": b["X"] ?? 0, "y": b["Y"] ?? 0, "w": b["Width"] ?? 0, "h": b["Height"] ?? 0,
                "layer": w[kCGWindowLayer as String] ?? 0, "on": w[kCGWindowIsOnscreen as String] ?? false,
                "name": w[kCGWindowName as String] ?? ""]
    }
    print(String(data: try! JSONSerialization.data(withJSONObject: mine), encoding: .utf8)!)
case "policy":
    print(NSRunningApplication(processIdentifier: pid)?.activationPolicy.rawValue ?? -1)
case "extras":
    guard AXIsProcessTrusted() else { print(-1); break }
    let app = AXUIElementCreateApplication(pid)
    var extras: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &extras) == .success, let bar = extras else { print(0); break }
    var kids: CFTypeRef?
    AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &kids)
    print((kids as? [Any])?.count ?? 0)
case "front":
    print(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)
default: break
}
'''


class Skip(Exception):
    pass


def bounded_lines(proc, timeout):
    """Read process output even when it never finishes a line."""
    end, pending = time.monotonic() + timeout, b""
    while True:
        left = end - time.monotonic()
        if left <= 0 or not select.select([proc.stdout], [], [], left)[0]:
            raise subprocess.TimeoutExpired(proc.args, timeout, output=pending)
        chunk = os.read(proc.stdout.fileno(), 65536)
        if not chunk:
            if pending:
                yield pending.decode(errors="replace")
            return
        pending += chunk
        if len(pending) > 16 * 1024 * 1024:
            raise ValueError("CLI output exceeded 16 MiB without a newline")
        while b"\n" in pending:
            line, pending = pending.split(b"\n", 1)
            yield line.decode(errors="replace") + "\n"


class Probe:
    """The build as an app of its own, in a world of its own."""

    def __init__(self, binary, scratch, keychain):
        self.keychain = keychain
        self.clients = []
        self.commands = []
        self.scratch = scratch
        # LaunchServices' child Python can block opening code in Documents.
        # Only the synthetic stand-in is copied; protected user files stay put.
        self.fake_agent = shutil.copy2(os.path.join(HERE, "fake-claude"), os.path.join(scratch, "fake-claude"))
        self.bundle_id = "dev.serafim.yab.probe.headless-check." + uuid.uuid4().hex
        self.app = os.path.join(scratch, NAME + ".app")
        macos = os.path.join(self.app, "Contents", "MacOS")
        os.makedirs(macos)
        self.bin = os.path.join(macos, "YabHeadlessCheck")
        shutil.copy(binary, self.bin)
        # A probe needs the bundled skills too. A bare executable falls back
        # to its compile-time source directory, which may require file access.
        bundled = os.path.join(os.path.dirname(os.path.dirname(binary)), "Resources", "skills")
        skills = bundled if os.path.isdir(bundled) else os.path.join(ROOT, "Skills")
        shutil.copytree(skills, os.path.join(self.app, "Contents", "Resources", "skills"))
        with open(os.path.join(self.app, "Contents", "Info.plist"), "wb") as f:
            plistlib.dump({"CFBundleIdentifier": self.bundle_id, "CFBundleExecutable": "YabHeadlessCheck",
                           "CFBundleName": NAME, "CFBundleDisplayName": NAME, "CFBundlePackageType": "APPL", "NSPrincipalClass": "NSApplication",
                           "LSMinimumSystemVersion": "15.4"}, f)
        subprocess.run(["codesign", "-s", "-", "--force", self.app], capture_output=True)
        self.home = None if keychain else os.path.join(scratch, "home")
        if self.home:
            os.makedirs(self.home, exist_ok=True)
        self.sock = os.path.expanduser(f"~/Library/Application Support/Pane ({WORLD})/bench.sock")
        self.helper = os.path.join(scratch, "helper")
        with open(self.helper + ".swift", "w") as f:
            f.write(HELPER)
        subprocess.run(["swiftc", "-O", self.helper + ".swift", "-o", self.helper], capture_output=True)
        for key, kind, value in (("bench", "-bool", "true"), ("agents.asking", "-string", "bypass"), ("welcomed", "-bool", "true")):
            subprocess.call(["defaults", "write", f"dev.serafim.fast.test.{WORLD}", key, kind, value])

    def env(self, **more):
        e = dict(os.environ, YAB_PROBE=WORLD, FAST_PROBE=WORLD, FAKE_PAGE=PAGE,
                 YAB_AGENT_CLAUDE=self.fake_agent, FAKE_LOG=os.path.join(self.scratch, "fake-agent.log"),
                 YAB_TEST_KEYCHAIN="1" if self.keychain else "0")
        if self.home:
            e["HOME"] = self.home
        e.update(more)
        return e

    def open_env(self, **more):
        out = []
        for key in ("YAB_PROBE", "FAST_PROBE", "FAKE_PAGE", "FAKE_LOG", "YAB_AGENT_CLAUDE", "HOME", "YAB_HEADLESS_IDLE", "YAB_TEST_KEYCHAIN",
                    "YAB_LOGIN_START"):
            value = self.env(**more).get(key)
            if value and (key != "HOME" or self.home):
                out += ["--env", f"{key}={value}"]
        return out

    def listening(self, seconds=15):
        end = time.time() + seconds
        while time.time() < end:
            try:
                s = socket.socket(socket.AF_UNIX)
                s.connect(self.sock)
                s.close()
                return True
            except OSError:
                time.sleep(0.1)
        return False

    def start(self, *flags, hidden=True, **more):
        self.stop()
        args = ["open", "-g", "-n", "--stdout", os.path.join(self.evidence, "browser.stdout.log"),
                "--stderr", os.path.join(self.evidence, "browser.stderr.log")] + (["-j"] if hidden else []) + self.open_env(**more) + ["-a", self.app]
        if flags:
            args += ["--args"] + list(flags)
        started = time.time()
        subprocess.call(args)
        if not self.listening():
            raise AssertionError("no socket after 15 s")
        return time.time() - started

    def pid(self):
        """The browser's, not a `yab mcp` or a task's run of the same binary:
        its words after the path are only flags."""
        for pid in subprocess.run(["pgrep", "-f", self.bin], capture_output=True, text=True).stdout.split():
            args = subprocess.run(["ps", "-o", "args=", "-p", pid], capture_output=True, text=True).stdout.strip()
            if args.startswith(self.bin) and all(w.startswith("-") for w in args[len(self.bin):].split()):
                return int(pid)
        return 0

    def alive(self):
        return self.pid() != 0

    def stop(self):
        for proc in self.commands:
            if proc.poll() is None:
                proc.kill()
            proc.wait()
        self.commands.clear()
        for client in self.clients:
            client.end(kill=True)
        self.clients.clear()
        pid = self.pid()
        if pid:
            os.kill(pid, signal.SIGKILL)
            for _ in range(50):
                if not self.alive():
                    break
                time.sleep(0.1)

    def yab(self, *words, stdin=subprocess.DEVNULL, timeout=120, **more):
        r = subprocess.run([self.bin] + list(words), env=self.env(**more), stdin=stdin, capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout + r.stderr

    def tty(self, feed, *words, timeout=120):
        """Words run in a pseudo-terminal, lines fed to it on a clock."""
        p = subprocess.Popen(["script", "-q", "/dev/null", self.bin] + list(words), env=self.env(), stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.commands.append(p)
        stopped = threading.Event()

        def feeder():
            for delay, line in feed:
                if stopped.wait(delay):
                    return
                try:
                    p.stdin.write((line + "\n").encode())
                    p.stdin.flush()
                except OSError:
                    return

        thread = threading.Thread(target=feeder, daemon=True)
        thread.start()
        try:
            out = list(bounded_lines(p, timeout))
            p.wait(timeout=2)
            return p.returncode, "".join(out).replace("\r", "")
        finally:
            stopped.set()
            thread.join(timeout=2)
            if p.poll() is None:
                p.kill()
            p.wait()
            try:
                p.stdin.close()
            except OSError:
                pass

    def bench(self, request):
        with socket.socket(socket.AF_UNIX) as s:
            s.settimeout(10)
            s.connect(self.sock)
            s.sendall((json.dumps(request) + "\n").encode())
            data = b""
            while not data.endswith(b"\n"):
                chunk = s.recv(65536)
                if not chunk:
                    break
                data += chunk
            return json.loads(data)

    def look(self, what, pid=0):
        out = subprocess.run([self.helper, what, str(pid)], capture_output=True, text=True).stdout.strip()
        if not out:
            raise Skip("the window helper didn't build")
        return json.loads(out)


class Mcp:
    def __init__(self, probe):
        self.p = subprocess.Popen([probe.bin, "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=probe.env())
        self.n = 0
        self.pending = b""
        probe.clients.append(self)
        try:
            self.call("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "check", "version": "1"}})
        except BaseException:
            self.end(kill=True)
            raise

    def call(self, method, params, timeout=60):
        self.n += 1
        self.p.stdin.write((json.dumps({"jsonrpc": "2.0", "id": self.n, "method": method, "params": params}) + "\n").encode())
        self.p.stdin.flush()
        deadline = time.monotonic() + timeout
        while True:
            while b"\n" not in self.pending:
                remaining = deadline - time.monotonic()
                if remaining <= 0 or not select.select([self.p.stdout], [], [], remaining)[0]:
                    raise subprocess.TimeoutExpired(["headless MCP", method, params.get("name", "")], timeout)
                chunk = os.read(self.p.stdout.fileno(), 65536)
                if not chunk:
                    raise ValueError("headless MCP closed stdout during " + method)
                self.pending += chunk
                if len(self.pending) > 16 * 1024 * 1024:
                    raise ValueError("headless MCP response exceeds 16 MB")
            line, self.pending = self.pending.split(b"\n", 1)
            msg = json.loads(line)
            if msg.get("id") == self.n:
                if "error" in msg:
                    raise ValueError("headless MCP error: " + json.dumps(msg["error"]))
                return msg["result"]

    def tool(self, name, **args):
        return self.call("tools/call", {"name": name, "arguments": args})["content"][0]["text"]

    def end(self, kill=False):
        if self.p.poll() is None:
            if kill:
                self.p.kill()
            else:
                self.p.terminate()
            try:
                self.p.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.p.kill()
                self.p.wait()
        for stream in (self.p.stdin, self.p.stdout):
            if stream and not stream.closed:
                stream.close()


def seen_page(probe):
    m = Mcp(probe)
    tab = m.tool("open", url=PAGE).split()[1]
    m.tool("eval", tab=tab, js="const d=document.documentElement.dataset;d.raf=0;(function f(){d.raf=+d.raf+1;requestAnimationFrame(f)})();1")
    time.sleep(1.5)
    said = m.tool("eval", tab=tab, js="document.visibilityState+' '+document.documentElement.dataset.raf")
    m.tool("close", tab=tab)
    m.end()
    state, raf = json.loads(said).split()
    return state, int(raf)


def session_of(out):
    for word in out.split("session ")[1:2]:
        return word.split()[0]
    raise AssertionError(f"no session in: {out[-300:]}")


# MARK: - the cases

def c_hidden_start(p):
    front = p.look("front")
    took = p.start("--headless")
    pid = p.pid()
    assert took < 8, f"socket after {took:.1f} s"
    assert p.look("policy", pid) == 1, "not an accessory app: a Dock tile"
    on = [w for w in p.look("wins", pid) if w["on"] and w["layer"] == 0]
    assert not on, f"a window on screen: {on}"
    assert p.look("front") == front, "something came to the front"
    return f"listening in {took:.1f} s, no window, no Dock tile, focus kept"


def c_seen(p):
    p.start("--headless")
    state, raf = seen_page(p)
    assert state == "visible" and raf > 45, f"{state}, {raf} frames in 1.5 s"
    r = subprocess.run([sys.executable, os.path.join(BROWSE, "prims.py"), "--bin", p.bin, "--world", WORLD],
                       capture_output=True, text=True, env=p.env())
    evidence = os.path.join(p.evidence, "primitives.log")
    with open(evidence, "w") as log:
        log.write(r.stdout + "\n--- stderr ---\n" + r.stderr)
    last = r.stdout.strip().splitlines()[-1] if r.stdout.strip() else r.stderr[-300:]
    assert r.returncode == 0 and " 0 fail" in last, f"prims exit {r.returncode}; {r.stderr[-500:] or last}; log: {evidence}"
    return f"agent page {state}, {raf} frames in 1.5 s; prims hidden: {last}"


def c_plain_start(p):
    p.stop()
    proc = subprocess.Popen([p.bin, "--headless"], env=p.env(), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    shown = 0
    end = time.time() + 5
    while time.time() < end:
        shown += sum(1 for w in p.look("wins", proc.pid) if w["on"] and w["layer"] == 0)
        time.sleep(0.05)
    assert p.listening(), "no socket"
    state, raf = seen_page(p)
    proc.kill()
    assert shown == 0, f"the window was on screen in {shown} samples"
    assert state == "visible", f"agent page {state} after a plain start"
    return f"no window on screen in 5 s of 50 ms samples, agent page {state}"


def c_killed_mcp(p):
    p.start("--headless")
    m = Mcp(p)
    tab = m.tool("open", url=PAGE).split()[1]
    m.end(kill=True)
    time.sleep(2)
    assert p.alive(), "Yab died with its agent's server (SIGPIPE)"
    m = Mcp(p)
    m.tool("close", tab=tab)
    m.end()
    return "alive after its agent's `yab mcp` was killed mid-session"


def c_status_quit(p):
    p.start("--headless")
    code, out = p.yab("status")
    assert code == 0 and "running hidden" in out, out
    code, out = p.yab("quit")
    assert code == 0, out
    time.sleep(3)
    assert not p.alive(), "still running after `yab quit`"
    code, out = p.yab("status")
    assert code == 1 and "isn't running" in out, out
    code, out = p.yab("session", "list")
    assert "isn't running" in out and not p.alive(), f"a list woke it: {out}"
    return "status, quit, and nothing woken by a list"


def c_lock(p):
    p.start("--headless")
    first = p.pid()
    code, out = p.yab("--headless", timeout=20)
    assert code == 1 and "already running on these files" in out, (code, out)
    assert p.pid() == first and p.listening(2), "the first lost its socket"
    return "a second process on the same files exits, the first keeps its socket"


def c_idle_quit(p):
    p.start("--headless", YAB_HEADLESS_IDLE="8")
    t0 = time.time()
    while p.alive() and time.time() - t0 < 40:
        time.sleep(1)
    if p.alive():
        code, status = p.yab("status", timeout=10)
        with open(os.path.join(p.evidence, "idle-status.txt"), "w") as log:
            log.write(status)
        raise AssertionError(f"still running 40 s past an 8 s idle; status={status[:1200]}")
    assert not os.path.exists(p.sock), "its socket is left behind"
    return f"quit {time.time() - t0:.0f} s after start with an 8 s idle, socket gone"


def c_reopen(p):
    p.start("--headless")
    pid = p.pid()
    subprocess.call(["open", "-a", p.app])
    # By size: a window's name needs Screen Recording to be read. Looked
    # for a while: ./stage watch may be moving it onto the test screen.
    shown = []
    end = time.time() + 6
    while not shown and time.time() < end:
        time.sleep(0.25)
        shown = [w for w in p.look("wins", pid) if w["on"] and w["layer"] == 0 and w["w"] > 400 and w["h"] > 300]
    assert p.look("policy", pid) == 0, "no Dock tile after being opened"
    if not shown:
        try:
            state = p.bench({"do": "probe"})
        except (OSError, ValueError) as error:
            state = {"error": str(error)}
        with open(os.path.join(p.evidence, "reopen-probe.json"), "w") as log:
            json.dump(state, log, indent=2)
        code, status = p.yab("status", timeout=10)
        with open(os.path.join(p.evidence, "reopen-status.txt"), "w") as log:
            log.write(status)
        # Diagnostic second request cannot rescue the first-request assertion.
        subprocess.call(["open", "-a", p.app])
        time.sleep(2)
        with open(os.path.join(p.evidence, "reopen-second.json"), "w") as log:
            json.dump({"windows": p.look("wins", pid), "status": p.bench({"do": "app-status"}),
                       "probe": p.bench({"do": "probe"})}, log, indent=2)
    assert shown, f"no window after being opened: {p.look('wins', pid)}"
    code, out = p.yab("quit")
    assert code == 1 and "someone may be using it" in out, out
    p.stop()
    return f"opened: a Dock tile and its window ({shown[0]['w']}x{shown[0]['h']}); `yab quit` leaves an open one alone"


def c_at_login(p):
    """Opened by macOS at login with Open at Login on (YAB_LOGIN_START stands
    in for the login item's Apple event): a plain launch, no flag, put away
    as a woken Yab is, and kept, not quitting when idle; opened by the
    person, the browser as usual."""
    p.stop()
    front = p.look("front")
    p.start(hidden=False, YAB_LOGIN_START="1", YAB_HEADLESS_IDLE="8")
    pid = p.pid()
    seen = 0
    end = time.time() + 4
    while time.time() < end:
        seen += sum(1 for w in p.look("wins", pid) if w["on"] and w["layer"] == 0 and w["w"] > 400 and w["h"] > 300)
        time.sleep(0.1)
    status = p.bench({"do": "app-status"})
    assert status.get("atLogin") is True and status.get("hidden") is True and status.get("serving") is True, status
    assert status.get("headless") is False, "an --headless start, not a login one"
    assert p.look("policy", pid) == 1, "not an accessory app: a Dock tile"
    assert seen == 0, f"the window was on screen in {seen} samples"
    assert p.look("front") == front, "something came to the front"
    time.sleep(14)
    assert p.alive(), "a Yab opened at login quit when idle"
    subprocess.call(["open", "-a", p.app])
    shown = []
    end = time.time() + 6
    while not shown and time.time() < end:
        time.sleep(0.25)
        shown = [w for w in p.look("wins", pid) if w["on"] and w["layer"] == 0 and w["w"] > 400 and w["h"] > 300]
    assert p.look("policy", pid) == 0 and shown, f"opened: policy {p.look('policy', pid)}, windows {p.look('wins', pid)}"
    p.stop()
    return "no window or Dock tile at login, kept past an 8 s idle, its window and Dock tile once opened"


def c_serve(p):
    p.stop()
    code, out = p.yab("serve", YAB_HEADLESS_IDLE="8")
    assert code == 0 and "serving agents" in out, out
    time.sleep(25)
    assert p.alive(), "a served Yab quit when idle"
    code, out = p.yab("status")
    assert "serving" in out, out
    code, out = p.yab("serve", "--stop")
    time.sleep(3)
    assert code == 0 and not p.alive(), out
    p.start("--headless", YAB_HEADLESS_IDLE="8")
    code, out = p.yab("serve")
    with open(os.path.join(p.evidence, "serve-existing.json"), "w") as log:
        json.dump({"exit": code, "stdout": out, "pid": p.pid(),
                   "status": p.bench({"do": "app-status"}) if p.alive() else None}, log, indent=2)
    assert code == 0 and "serving agents" in out, (code, out)
    time.sleep(20)
    alive = p.alive()
    p.yab("serve", "--stop")
    assert alive, "a hidden Yab told to serve quit when idle"
    return "serves past an 8 s idle, started or told; --stop quits"


def c_person(p):
    p.start("--headless")
    code, out = p.yab("agent", "--cli", "claude", "pick a color")
    assert code == 3 and "session resume" in out, (code, out[-300:])
    code, again = p.yab("session", "resume", session_of(out), "red")
    assert code == 0 and "Going with red" in again, (code, again[-300:])
    code, out = p.tty([(5, "blue"), (4, "")], "agent", "--cli", "claude", "pick a color")
    assert "Needs you: Which color?" in out and "picked: blue" in out, out[-400:]
    code, out = p.yab("agent", "--cli", "claude", "--no-person", "hands please")
    assert "nobody is" in out, out[-300:]
    t0 = time.time()
    code, out = p.yab("agent", "--cli", "claude", "--wait-person", "0.1", "hands please")
    assert code == 3 and "Still waiting in Yab" in out, (code, out[-300:])
    p.yab("session", "stop", session_of(out))
    return f"caller exit 3 then resume, terminal answer, --no-person refused, sign-in gave the terminal back in {time.time() - t0:.0f} s"


def c_attached_idle(p):
    # An agent attached through `yab mcp` and quiet between its calls is
    # not a task at work: the idle clock runs, and ⌘Q doesn't wait on it.
    # Leave time for MCP startup and the six-second quiet status observation.
    p.start("--headless", YAB_HEADLESS_IDLE="20")
    m = Mcp(p)
    tab = m.tool("open", url=PAGE).split()[1]
    # A call counts as work for five seconds after it.
    time.sleep(6)
    code, out = p.yab("status")
    t0 = time.time()
    while p.alive() and time.time() - t0 < 40:
        time.sleep(1)
    gone = not p.alive()
    m.end(kill=True)
    assert "nothing running" in out, out
    assert gone, "an idle attached agent kept a hidden Yab past its idle clock"
    p.start(hidden=False)
    time.sleep(2)
    m = Mcp(p)
    m.tool("open", url=PAGE)
    time.sleep(6)
    got = p.bench({"do": "quit-ask", "yes": False})
    m.end(kill=True)
    assert got["asked"].get("yes") == "Quit", got["asked"]
    p.stop()
    return f"quit with an agent attached and a 20 s idle; ⌘Q asks a plain Quit"


def c_nobody_send(p):
    # Send asks a person; with nobody there it is no, at once.
    subprocess.call(["defaults", "write", f"dev.serafim.fast.test.{WORLD}", "agents.asking", "-string", "ask"])
    try:
        p.start("--headless", "--serve", "--no-person")
        subprocess.run(["curl", "-s", "http://127.0.0.1:8751/reset?task=reply"], capture_output=True)
        t0 = time.time()
        code, out = p.yab("agent", "--cli", "claude", "press send", timeout=60)
        took = time.time() - t0
        sent = json.loads(subprocess.run(["curl", "-s", "http://127.0.0.1:8751/state?task=reply"], capture_output=True, text=True).stdout or "{}")
        p.yab("serve", "--stop")
    finally:
        subprocess.call(["defaults", "write", f"dev.serafim.fast.test.{WORLD}", "agents.asking", "-string", "bypass"])
    assert took < 30, f"{took:.0f} s: it waited on a card nobody sees"
    assert "sent" not in sent, f"sent with nobody to say yes: {sent}"
    return f"Send refused in {took:.0f} s with nobody there, nothing sent"


def c_import_gate(p):
    # The yes to bring in another browser is Yab's own card: said no there,
    # nothing is read.
    p.start("--headless")
    code, browsers = p.tty([], "import")
    if "From:" not in browsers:
        raise Skip("no other browser on this Mac")
    name = browsers.split("From:")[1].split(",")[0].split(".")[0].strip()
    proc = subprocess.Popen(["script", "-q", "/dev/null", p.bin, "import", name.split()[0].lower()], env=p.env(),
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, stdin=subprocess.PIPE, text=True)
    asked = {}
    for _ in range(40):
        time.sleep(0.5)
        try:
            asked = p.bench({"do": "question", "yes": False})
        except OSError:
            continue
        if "title" in asked:
            break
    out = proc.communicate(timeout=30)[0].replace("\r", "")
    p.stop()
    assert "sign-ins?" in asked.get("title", ""), asked
    assert "Not brought in" in out, out[-300:]
    return f"asked in Yab ({asked['title']}), no there: nothing brought in"


def c_nobody(p):
    p.stop()
    p.start("--headless", "--serve", "--no-person")
    t0 = time.time()
    code, out = p.yab("agent", "--cli", "claude", "hands please")
    took = time.time() - t0
    assert "nobody is at Yab" in out and took < 20, (took, out[-300:])
    code, out = p.yab("agent", "--cli", "claude", "pick a color")
    assert code == 3, (code, out[-300:])
    p.yab("serve", "--stop")
    return f"sign-in refused in {took:.0f} s, a caller's question still exit 3"


def c_mark(p):
    p.start("--headless")
    pid = p.pid()
    if p.look("extras", pid) == -1:
        raise Skip("the helper has no Accessibility to read the menu bar")
    before = p.look("extras", pid)
    proc = subprocess.Popen([p.bin, "agent", "--cli", "claude", "hands please"], env=p.env(), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    p.commands.append(proc)
    time.sleep(8)
    during = p.look("extras", pid)
    for line in bounded_lines(proc, 60):
        if line.startswith("session "):
            p.yab("session", "stop", line.split()[1])
            break
    time.sleep(8)
    after = p.look("extras", pid)
    proc.kill()
    assert (before, during, after) == (0, 1, 0), (before, during, after)
    return "the mark: none, there while a task runs, gone after"


def waiting_task(p):
    """A task started and waiting on a sign-in, and its session."""
    proc = subprocess.Popen([p.bin, "agent", "--cli", "claude", "hands please"], env=p.env(), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    p.commands.append(proc)
    session = None
    for line in bounded_lines(proc, 60):
        if line.startswith("session "):
            session = line.split()[1]
        if "Needs you" in line:
            break
    assert session, "agent exited without a session"
    return proc, session


def c_linger(p):
    p.stop()
    p.start(hidden=False)
    pid = p.pid()
    time.sleep(2)
    proc, session = waiting_task(p)
    got = p.bench({"do": "quit-ask", "yes": True, "ticked": False})
    assert got["asked"].get("yes") == "Quit When Done", got
    assert got["asked"].get("other") == "Stop and Quit", got
    assert got["status"]["lingering"] is True, got
    time.sleep(1)
    assert p.look("policy", pid) == 1, "a Dock tile while finishing"
    on = [w for w in p.look("wins", pid) if w["on"] and w["layer"] == 0]
    assert not on, f"a window left on screen: {on}"
    p.yab("session", "stop", session)
    t0 = time.time()
    while p.alive() and time.time() - t0 < 15:
        time.sleep(0.5)
    assert not p.alive(), "didn't quit when the task ended"
    proc.kill()
    took = time.time() - t0
    p.start(hidden=False)
    time.sleep(2)
    proc, session = waiting_task(p)
    try:
        p.bench({"do": "quit-ask", "yes": True, "ticked": True})
    except (OSError, ValueError):
        pass  # gone before it could answer: quit at once
    time.sleep(3)
    ticked = p.alive()
    proc.kill()
    assert not ticked, "Stop and Quit didn't quit at once"
    return f"Quit When Done: windows and Dock tile gone, quit {took:.0f} s after the task; Stop and Quit: at once"


def c_cookies(p):
    if p.home:
        raise Skip("needs --keychain (the real HOME's keychain)")
    service = f"{p.bundle_id}.session-cookies.Pane ({WORLD})"
    subprocess.run(["security", "delete-generic-password", "-s", service], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
    name = f"k{int(time.time())}"

    def cookie(set_it):
        m = Mcp(p)
        tab = m.tool("open", url=PAGE).split()[1]
        if set_it:
            m.tool("eval", tab=tab, js=f"document.cookie='{name}=1; path=/'; 1")
        said = m.tool("eval", tab=tab, js="document.cookie")
        m.tool("close", tab=tab)
        m.end()
        # A call counts as work for five seconds after it, and `yab quit`
        # doesn't stop work.
        time.sleep(6)
        return name in said

    p.start("--headless")
    assert cookie(True), "the page's cookie wasn't set"
    p.yab("quit")
    time.sleep(3)
    p.start("--headless")
    back = cookie(False)
    p.stop()
    time.sleep(1)
    p.start("--headless")
    after_kill = cookie(False)
    p.yab("quit")
    time.sleep(3)
    # ⌘Q in a window, as a person quits: kept as well (YouTube's account).
    p.start(hidden=False)
    time.sleep(2)
    assert cookie(True), "the page's cookie wasn't set in a window"
    try:
        p.bench({"do": "quit-ask", "yes": True})
    except (OSError, ValueError):
        pass  # gone before it could answer
    time.sleep(4)
    p.start("--headless")
    after_quit = cookie(False)
    p.yab("quit")
    subprocess.run(["security", "delete-generic-password", "-s", service], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
    assert back and not after_kill and after_quit, (back, after_kill, after_quit)
    return "a session cookie back after quitting on its own and after ⌘Q, gone after a kill"


def c_import(p):
    p.start("--headless")
    code, out = p.yab("import", "chrome")
    assert code == 2 and "Ask the user" in out, (code, out)
    code, out = p.tty([], "import", "netscape")
    assert "no browser netscape" in out, out
    return "refused from a script, a wrong browser named when typed"


CASES = {
    "hidden-start": c_hidden_start, "seen": c_seen, "plain-start": c_plain_start, "killed-mcp": c_killed_mcp,
    "status-quit": c_status_quit, "lock": c_lock, "idle-quit": c_idle_quit, "reopen": c_reopen, "at-login": c_at_login, "serve": c_serve,
    "person": c_person, "nobody": c_nobody, "attached-idle": c_attached_idle, "nobody-send": c_nobody_send,
    "mark": c_mark, "linger": c_linger, "cookies": c_cookies, "import": c_import, "import-gate": c_import_gate,
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", default=os.path.join(ROOT, ".build", "debug", "Fast"))
    ap.add_argument("--only", default="")
    ap.add_argument("--out", help="directory for complete child-process diagnostics")
    ap.add_argument("--keychain", action="store_true")
    ap.add_argument("--scratch-agent", action="store_true", help=argparse.SUPPRESS)  # compatibility with diagnostic jobs
    ap.add_argument("--repository-agent", action="store_true", help="diagnose access to the original fake CLI path")
    opts = ap.parse_args()
    # The path as processes show it (/private/var, not /var).
    scratch = os.path.realpath(tempfile.mkdtemp(prefix="yab-headless-"))
    probe = Probe(os.path.abspath(opts.bin), scratch, opts.keychain)
    if opts.repository_agent:
        probe.fake_agent = os.path.join(HERE, "fake-claude")
    probe.evidence = os.path.abspath(opts.out) if opts.out else scratch
    os.makedirs(probe.evidence, exist_ok=True)
    sys.path.insert(0, BROWSE)
    import server  # noqa: E402
    try:
        urllib_ok = subprocess.run(["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", PAGE], capture_output=True, text=True).stdout
    except OSError:
        urllib_ok = ""
    if urllib_ok != "200":
        try:
            servers = server.serve()
            threading.Thread(target=servers[0].serve_forever, daemon=True).start()
        except OSError:
            pass  # another run's pages are up on these ports
    names = opts.only.split(",") if opts.only else list(CASES)
    tally = {"pass": 0, "fail": 0, "skip": 0}
    results = []
    try:
        for name in names:
            started = time.time()
            try:
                said = CASES[name](probe)
                verdict = "pass"
            except Skip as e:
                verdict, said = "skip", str(e)
            except (AssertionError, subprocess.TimeoutExpired, OSError, KeyError, ValueError) as e:
                verdict, said = "fail", str(e) or type(e).__name__
                if isinstance(e, subprocess.TimeoutExpired) and probe.pid():
                    subprocess.run(["sample", str(probe.pid()), "2", "-file",
                                    os.path.join(probe.evidence, name + ".sample.txt")],
                                   capture_output=True, timeout=15)
            tally[verdict] += 1
            results.append({"case": name, "verdict": verdict, "seconds": time.time() - started, "detail": said})
            with open(os.path.join(probe.evidence, "cases.json"), "w") as f:
                json.dump(results, f, indent=2)
            mark = {"pass": "✓", "fail": "✗", "skip": "·"}[verdict]
            print(f"{mark} {name:13} {time.time() - started:5.0f} s  {said[:220]}", flush=True)
    finally:
        probe.stop()
        fake_log = os.path.join(scratch, "fake-agent.log")
        if os.path.exists(fake_log) and probe.evidence != scratch:
            shutil.copy2(fake_log, os.path.join(probe.evidence, "fake-agent.log"))
        subprocess.call(["defaults", "delete", f"dev.serafim.fast.test.{WORLD}"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        shutil.rmtree(os.path.expanduser(f"~/Library/Application Support/Pane ({WORLD})"), ignore_errors=True)
        shutil.rmtree(scratch, ignore_errors=True)
    print(f"\n{tally['pass']} pass, {tally['fail']} fail, {tally['skip']} skip")
    return 1 if tally["fail"] else 0


if __name__ == "__main__":
    sys.exit(main())
