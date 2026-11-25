#!/usr/bin/env python3
"""The ⌘T field over no page in a short window: does its foot sit over the
list's last rows? For each app and height, a winshot (the app's own layers)
and a real window capture (ScreenCaptureKit, needs capture), so a mask
winshot can't draw is told apart from a real overlap.

    python3 evals/field-short-window.py --app base=A.app --app this=B.app --heights 352,700,900
"""
import argparse, os, socket, subprocess, sys, tempfile, time, json
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import yab_socket  # noqa: E402
import probe_capture  # noqa: E402
import threading
sys.path.insert(0, os.path.join(HERE, "mail"))
from fake_gmail import FakeGmail  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--app", action="append", required=True)
parser.add_argument("--heights", default="352,700,900")
parser.add_argument("--mail", action="store_true", help="a fake Gmail account, so the list has its Now rows")
OPTS = parser.parse_args()
if OPTS.mail:
    probe = socket.socket(); probe.bind(("127.0.0.1", 0)); GMAIL = probe.getsockname()[1]; probe.close()
    fake = FakeGmail(); fake.seed()
    threading.Thread(target=fake.serve, args=(GMAIL,), daemon=True).start()
OUT = os.environ.get("YAB_FARM_OUT") or tempfile.mkdtemp(prefix="yab-field-short-")
WORLD = "fieldshort"
SOCK = os.path.expanduser(f"~/Library/Application Support/Pane ({WORLD})/bench.sock")
SUITE = f"dev.serafim.fast.test.{WORLD}"
ask = yab_socket.asker(SOCK, timeout=None)


def census():
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.settimeout(5); s.connect(SOCK); s.sendall(b'{"do": "census"}\n')
            return json.loads(s.recv(1 << 16).split(b"\n", 1)[0] or b"{}").get("pid")
    except (OSError, ValueError):
        return None


for item in OPTS.app:
    name, app = item.split("=", 1)
    left = census()
    if left:
        os.kill(left, 15); yab_socket.wait_for(lambda: census() is None, 10)
    subprocess.run(["defaults", "delete", SUITE], stderr=subprocess.DEVNULL)
    for key in ("bench", "welcomed", "spaces") + (("mail.agents",) if OPTS.mail else ()):
        subprocess.run(["defaults", "write", SUITE, key, "-bool", "true"])
    folder = os.path.expanduser(f"~/Library/Application Support/Pane ({WORLD})")
    for old in ("session.json", "mail"):
        if os.path.exists(os.path.join(folder, old)):
            os.replace(os.path.join(folder, old), os.path.join(OUT, f"{old}-old-{time.time()}"))
    subprocess.run(["open", "-g", "-n", "--env", f"YAB_PROBE={WORLD}", "--env", "YAB_HISTORY=own", "-a", os.path.abspath(app)], check=True)
    ask({"do": "probe"})
    pid = census()
    if OPTS.mail:
        ask({"do": "agent-mail-account", "base": f"http://127.0.0.1:{GMAIL}/gmail/v1/users/me/"})
        yab_socket.wait_for(lambda: ask({"do": "agent-mail-state"}).get("synced"), 25)
        time.sleep(3)
    try:
        for h in [int(x) for x in OPTS.heights.split(",")]:
            ask({"do": "resize", "width": 1280, "height": h, "steps": 1})
            time.sleep(2.5)
            base = os.path.join(OUT, f"{name}-{h}")
            yab_socket.shot(SOCK, base + "-winshot.png")
            try:
                probe_capture.picture(pid, base + "-screen.png")
            except Exception as e:  # noqa: BLE001
                print("  capture failed:", e, flush=True)
            print(f"{name} {h}: {base}-*.png", flush=True)
    finally:
        if pid: os.kill(pid, 15)
print("out:", OUT)
