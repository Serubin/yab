#!/usr/bin/env python3
"""The column's scroll bar, a thread (ThreadScroller), with the old
scroller asked for, as a mouse plugged in asks (AppleShowScrollBars Always):
none at rest, a thread as the rows scroll, gone a second after, wider under
the pointer. Pictures in-process (winshot) for the timing, and from the
screen (./stage shot) where there is a test screen.

    python3 evals/column-thread/run.py --app "build/Pane Dev.app" --out shots/
"""
import argparse, http.server, json, os, subprocess, sys, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
os.environ.setdefault("MAIL_WORLD", "thread")
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "mail"))
import check as mail  # noqa: E402


# Moves the pointer into the probe's window, x points from its left edge,
# half way down.
MOUSE = r"""
import CoreGraphics
let pid = Int32(CommandLine.arguments[1])!, x = Double(CommandLine.arguments[2])!
let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as! [[String: Any]]
for w in list where (w[kCGWindowOwnerPID as String] as? Int32) == pid {
    let b = w[kCGWindowBounds as String] as! [String: Double]
    guard b["Height"]! > 300 else { continue }
    let at = CGPoint(x: b["X"]! + x, y: b["Y"]! + b["Height"]! / 2)
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: at, mouseButton: .left)!.post(tap: .cghidEventTap)
    print("pointer", at, "window", b)
    break
}
"""


class Pages(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = ("<title>Page %s</title><p>%s" % (self.path[1:], self.path)).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True)
    parser.add_argument("--exe", default="yab")
    parser.add_argument("--out", required=True)
    opts = parser.parse_args()
    os.makedirs(opts.out, exist_ok=True)
    suite = f"dev.serafim.fast.test.{mail.WORLD}"
    subprocess.run(["defaults", "delete", suite], stderr=subprocess.DEVNULL)
    for key in ("bench", "welcomed", "passwords.fill"):
        subprocess.run(["defaults", "write", suite, key, "-bool", "true"])
    env = {**os.environ, "YAB_PROBE": mail.WORLD}
    proc = subprocess.Popen([os.path.join(opts.app, "Contents/MacOS", opts.exe), "-AppleShowScrollBars", "Always"], env=env,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    stage = os.path.join(os.path.dirname(os.path.dirname(HERE)), "stage")
    staged = False
    try:
        print("probe:", json.dumps(mail.ask({"do": "probe"}))[:300], flush=True)
        if os.path.exists(stage):
            staged = subprocess.run([stage, "put", str(proc.pid), "2"], capture_output=True).returncode == 0
        mail.ask({"do": "ui", "sidebar": True})
        mail.ask({"do": "ui", "look": "dark"})
        pages = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Pages)
        threading.Thread(target=pages.serve_forever, daemon=True).start()
        for n in range(45):
            mail.ask({"do": "open", "url": f"http://127.0.0.1:{pages.server_port}/{n}", "plain": True})
        time.sleep(4)
        space = lambda **kw: mail.ask({"do": "agent-mail-space", **kw})

        sys.path.insert(0, os.path.dirname(HERE))
        import probe_capture

        def win(name):
            path = os.path.join(opts.out, name + ".png")
            try:
                probe_capture.picture(proc.pid, path)
            except Exception as error:  # no Screen Recording here: the layers instead
                mail.ask({"do": "winshot", "path": path})
                print("  (winshot:", error, ")")
            print("  picture:", path, round(time.time() - t0, 2), flush=True)

        def screen(name):
            pass

        got = space(act="columnscroll", value="top")
        mail.check("the tabs scroll", bool(got.get("scrolled")) and got.get("doc", 0) > got.get("room", 0), got)
        time.sleep(2)
        t0 = time.time()
        win("1-rest")
        screen("1-rest-screen")
        t0 = time.time()
        space(act="columnscroll", value="300")
        win("2-scrolled")
        screen("2-scrolled-screen")
        time.sleep(1.6)
        t0 = time.time()
        win("3-after")
        screen("3-after-screen")

        # Under the pointer: the mouse to the thread's place, on the screen.
        mouse = os.path.join(opts.out, "mouse")
        with open(mouse + ".swift", "w") as f:
            f.write(MOUSE)
        subprocess.run(["swiftc", "-O", mouse + ".swift", "-o", mouse], check=True)
        side = mail.ask({"do": "sidecol"}).get("shown") or 260
        print("  side width", side, flush=True)
        for dx in (-60, -30, -12, -4):
            print("  ", subprocess.run([mouse, str(proc.pid), str(side + dx)], capture_output=True, text=True).stdout.strip())
            time.sleep(0.05)
        time.sleep(0.5)
        t0 = time.time()
        win("4-hover")
        subprocess.run([mouse, str(proc.pid), str(side + 400)])
        time.sleep(1.6)
        t0 = time.time()
        win("5-left")
    finally:
        proc.terminate()
        if staged:
            subprocess.run([stage, "free", str(proc.pid)], capture_output=True)
    print("FAIL: " + ", ".join(mail.FAILS) if mail.FAILS else "OK")
    return 1 if mail.FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
