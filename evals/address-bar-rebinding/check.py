#!/usr/bin/env python3
"""Exercise both standard Settings recorders in an isolated persistent world."""
import argparse
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import time
import traceback
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from probe_app import launch
from probe_capture import picture, quartz_picture


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True, type=Path)
    options = parser.parse_args()
    out = Path(os.environ["YAB_FARM_OUT"])
    world = "address-bar-rebinding-" + uuid.uuid4().hex[:8]
    domain = "dev.serafim.fast.test." + world
    sock = Path.home() / "Library/Application Support" / f"Pane ({world})" / "bench.sock"
    report = {"world": world, "checks": [], "states": {}, "pictures": []}
    app = None

    def ask(command, **fields):
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(60)
            connection.connect(str(sock))
            connection.sendall((json.dumps(dict(do=command, **fields)) + "\n").encode())
            data = bytearray()
            while chunk := connection.recv(1 << 20):
                data.extend(chunk)
                if b"\n" in data:
                    break
        result = json.loads(data.split(b"\n", 1)[0])
        if "error" in result:
            raise RuntimeError(f"{command}: {result['error']}")
        return result

    def check(name, passed, detail=None):
        report["checks"].append(dict(name=name, passed=bool(passed), detail=detail))
        print(("PASS " if passed else "FAIL ") + name, flush=True)
        if not passed:
            raise AssertionError(f"{name}: {detail}")

    def state(label):
        result = ask("keys")
        report["states"][label] = result
        return result

    def key(state, action):
        return next(row.split("=", 1)[1] for row in state["keys"] if row.startswith(action + "="))

    def start():
        nonlocal app
        app = launch(options.app, dict(os.environ, YAB_PROBE=world, YAB_HISTORY="own"),
                     out, task_name=os.environ["YAB_TASK_NAME"])
        end = time.monotonic() + 60
        while time.monotonic() < end:
            try:
                if ask("census").get("pid") == app.pid:
                    return
            except (OSError, ValueError):
                pass
            if app.poll() is not None:
                raise RuntimeError("probe exited during startup")
            time.sleep(.2)
        raise RuntimeError("probe socket did not start")

    def stop():
        nonlocal app
        if app:
            app.terminate()
            app.wait(15)
            app = None

    def shot(name, words):
        ask("ui", page="shortcuts", settings=True)
        ask("keys", act="filter", text=words, keep=True)
        time.sleep(.4)
        path = out / (name + ".png")
        windows = ask("ui", windows=True)["windows"]
        window = next(row["id"] for row in windows if "Settings" in row["kind"])
        # SwiftUI's settings content can be blank in cacheDisplay. Capture
        # the actual window instead, retaining adhd's blackout verification.
        if os.environ["WHERE"] == "adhd":
            picture(app.pid, path, window_id=window)
        else:
            check(name + " window capture", quartz_picture({"window": window}, path))
        path.with_suffix(".capture.json").write_text(json.dumps(
            dict(window=window, pid=app.pid, host=os.environ["WHERE"],
                 capture="ScreenCaptureKit" if os.environ["WHERE"] == "adhd" else "Quartz"), indent=2) + "\n")
        report["pictures"].append(str(path))

    def record(action, chord, expected):
        ask("ui", page="shortcuts", settings=True)
        ask("keys", act="filter", text="", keep=True)
        listening = ask("keys", act="record", action=action)
        check(action + " Settings recorder opens", listening["recording"])
        ask("keys", act="press", keys=chord)
        saved = ask("keys", act="press", keys="escape")
        check(action + " recorder saves custom key", key(saved, action) == expected + " (chosen)", saved)
        check(action + " custom key is stored", saved["stored"].get(action) == expected[:-1] + expected[-1].lower(), saved["stored"])
        return saved

    try:
        for setting in ("bench", "welcomed", "sidebar"):
            subprocess.run(["defaults", "write", domain, setting, "-bool", "true"], check=True)
        subprocess.run(["defaults", "write", domain, "dev.offer", "-bool", "false"], check=True)
        start()
        ask("ui", welcome=False, look="light", bar=True)
        original = state("defaults")
        check("Shift-Command-D belongs to address bar", key(original, "addressBar") == "⇧⌘D", original)
        check("Pin Tab has no conflicting default", key(original, "pin") == "", original)
        shot("shortcuts-address-bar-default", "address bar")
        shot("shortcuts-pin-default", "pin")
        record("addressBar", "ctrl+opt+cmd+d", "⌃⌥⌘D")
        record("pin", "shift+cmd+d", "⇧⌘D")
        before = state("custom-before-relaunch")
        check("Keep Tab retains Command-D", key(before, "keepTab") == "⌘D", before)
        stop()
        start()
        restored = state("custom-after-relaunch")
        check("address bar custom binding survives relaunch", key(restored, "addressBar") == "⌃⌥⌘D (chosen)", restored)
        check("Pin Tab custom binding survives relaunch", key(restored, "pin") == "⇧⌘D (chosen)", restored)
        check("stored choices survive relaunch", restored["stored"] == before["stored"], restored["stored"])
        shot("shortcuts-address-bar-relaunched", "address bar")
        shot("shortcuts-pin-relaunched", "pin")
        ask("keys", act="reset", action="pin")
        reset = ask("keys", act="reset", action="addressBar")
        check("reset restores address bar default", key(reset, "addressBar") == "⇧⌘D", reset)
        check("reset leaves Pin Tab unbound", key(reset, "pin") == "", reset)
        check("reset clears saved overrides", not reset["stored"], reset["stored"])
    except Exception:
        report["error"] = traceback.format_exc()
        print(report["error"], flush=True)
        if app and app.poll() is None:
            try:
                ask("winshot", settings=True, path=str(out / "failure.png"))
            except Exception:
                pass
    finally:
        stop()
        subprocess.run(["defaults", "delete", domain], capture_output=True)
        (out / "summary.json").write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
    passed = sum(row["passed"] for row in report["checks"])
    print(json.dumps(dict(passed=passed, total=len(report["checks"]), error=report.get("error"))), flush=True)
    return 1 if report.get("error") else 0


if __name__ == "__main__":
    sys.exit(main())
