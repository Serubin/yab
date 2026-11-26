"""Record the floating agent foot states in an isolated test world on macOS."""

import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import time


world = f"foot-motion-{os.getpid()}"
scratch = Path(tempfile.mkdtemp(prefix="yab-foot-motion-"))
support = Path.home() / "Library" / "Application Support" / f"Pane ({world})"
sock = support / "bench.sock"
out = Path.cwd() / ".build" / "foot-states-current"
out.mkdir(parents=True, exist_ok=True)


def ask(**request):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(60)
        connection.connect(str(sock))
        connection.sendall((json.dumps(request) + "\n").encode())
        data = bytearray()
        while chunk := connection.recv(1 << 16):
            data.extend(chunk)
    result = json.loads(data.split(b"\n", 1)[0])
    if "error" in result:
        raise RuntimeError(f"{request}: {result['error']}")
    return result


def record(name, action, window, seconds=1.5):
    path = out / f"{name}.mov"
    path.unlink(missing_ok=True)
    film = subprocess.Popen(["screencapture", "-v", "-V", str(seconds), "-l", str(window), "-x", str(path)])
    time.sleep(0.18)
    result = action()
    if film.wait(timeout=seconds + 10) != 0 or not path.exists():
        raise RuntimeError(f"capture failed: {path}")
    subprocess.run(["screencapture", "-x", "-l", str(window), str(out / f"{name}-end.png")], check=True)
    print(json.dumps({"name": name, "result": result}), flush=True)
    time.sleep(0.2)


subprocess.run(["defaults", "write", f"dev.serafim.fast.test.{world}", "bench", "-bool", "true"], check=True)
env = dict(os.environ, YAB_PROBE=world, FAST_PROBE=world, HOME=str(scratch))
binary = Path(os.environ.get("APP", "build/Pane Dev.app")) / "Contents" / "MacOS" / "pane"
with (out / "app.log").open("w") as log:
    process = subprocess.Popen([str(binary)], cwd=scratch, env=env, stdout=log, stderr=subprocess.STDOUT)
    try:
        for _ in range(240):
            if sock.exists() and process.poll() is None:
                break
            time.sleep(0.25)
        else:
            raise RuntimeError(f"app did not start: {process.poll()}")
        ask(do="ui", sidebar=False, look="light", welcome=False)
        ask(do="resize", width=1000, height=700, steps=1)
        tab = ask(do="open", url="https://example.com/", plain=True)["id"]
        ask(do="select", id=tab)
        ask(do="wait", id=tab, seconds=15)
        ask(do="front")
        window = ask(do="probe")["window"]
        answer = {"do": "agent-foot-preview", "id": tab, "state": "answer", "text": "The page is ready to review.\n\n• The primary action remains available.\n• You can continue from this point."}
        clear = {"do": "agent-foot-preview", "id": tab, "state": "clear"}

        record("offer-enter", lambda: ask(do="pace", action="glass-offer", seconds=0.5, screen=True), window)
        record("offer-to-answer", lambda: ask(**answer), window)
        record("answer-to-offer", lambda: ask(**clear), window)
        record("offer-skip", lambda: ask(do="pace", action="glass-unoffer", seconds=0.5, screen=True), window)
        record("answer-enter", lambda: ask(**answer), window)
        record("answer-close", lambda: ask(**clear), window)
    finally:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        shutil.rmtree(scratch, ignore_errors=True)
        shutil.rmtree(support, ignore_errors=True)
        subprocess.run(["defaults", "delete", f"dev.serafim.fast.test.{world}"], capture_output=True)
