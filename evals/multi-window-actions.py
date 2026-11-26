#!/usr/bin/env python3
"""Exercise command-menu switch and move in two real yab windows on one Mac.

Run after a debug build: python3 evals/multi-window-actions.py. The test uses
an isolated YAB_PROBE world, posts the same keys as a user, and saves a native
window screenshot in .build/multi-window-actions-before.png.
"""

import argparse
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import time
import yab_socket  # noqa: E402


ROOT = Path(__file__).resolve().parents[1]
WORLD = f"window-actions-{os.getpid()}"
SUPPORT = Path.home() / "Library" / "Application Support" / f"Pane ({WORLD})"
SOCKET = SUPPORT / "bench.sock"
DOMAIN = f"dev.serafim.fast.test.{WORLD}"
SOURCE = "https://example.com/yab-window-source"
SOURCE_CLICK = "https://example.com/yab-window-source-click"
MAIL = "https://example.org/yab-window-mail"
SHOT = ROOT / ".build" / "multi-window-actions-before.png"
SCREEN = ROOT / ".build" / "multi-window-actions-screen.png"


ask = yab_socket.kwasker(SOCKET, timeout=40, strict=True, fail=lambda request, reply: AssertionError(f"{request}: {reply['error']}"))


def box(act, **options):
    return ask(do="box", act=act, **options)


def windows():
    return box("windows")["windows"]


def wait_for(predicate, label):
    for _ in range(40):
        result = predicate()
        if result:
            return result
        time.sleep(0.2)
    raise AssertionError(f"Timed out waiting for {label}")


def selected_source(url=SOURCE):
    box("t")
    state = box("type", text=url.rsplit("/", 1)[-1])
    found = next(index for index, offer in enumerate(state["offers"])
                 if offer["kind"] == "open" and offer["url"] == url)
    for _ in range(len(state["offers"])):
        if state["current"] == found:
            break
        state = box("key", keys="down")
    assert state["current"] == found, state
    assert state["offers"][found]["title"] == url.removeprefix("https://"), state
    assert "Move Tab Here" in state["actions"], state
    assert "Switch to Other Window" in state["actions"], state
    assert state["featured"] == ["Move Tab Here"], state
    return state


def main():
    global SHOT, SCREEN
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bin", type=Path, default=ROOT / ".build" / "debug" / "Fast")
    parser.add_argument("--out", type=Path, default=ROOT / ".build")
    parser.add_argument("--launch-services", action="store_true")
    args = parser.parse_args()
    binary = args.bin.resolve()
    args.out.mkdir(parents=True, exist_ok=True)
    SHOT = args.out / "multi-window-actions-before.png"
    SCREEN = args.out / "multi-window-actions-screen.png"
    if not binary.exists():
        raise SystemExit(f"Missing test binary: {binary}")
    subprocess.run(["defaults", "write", DOMAIN, "bench", "-bool", "true"], check=True)
    scratch = tempfile.mkdtemp(prefix="yab-window-actions-")
    env = dict(os.environ, YAB_PROBE=WORLD, FAST_PROBE=WORLD, HOME=scratch)
    app_log = (args.out / "multi-window-app.log").open("w")
    if args.launch_services:
        from probe_app import launch
        process = launch(binary.parents[2], env, args.out)
    else:
        process = subprocess.Popen([str(binary)], cwd=ROOT, env=env,
                                   stdin=subprocess.DEVNULL, stdout=app_log, stderr=subprocess.STDOUT)
    try:
        wait_for(lambda: SOCKET.exists() and process.poll() is None, "test yab socket")
        box("reset", urls=[SOURCE])
        original = next(tab["id"] for tab in windows()[0]["tabs"] if tab["url"] == SOURCE)

        box("key", keys="cmd+n")
        wait_for(lambda: len(windows()) == 2, "second window")
        wait_for(lambda: windows()[1]["key"], "second window becomes key")
        box("reset", urls=[MAIL])
        named = windows()
        assert "example.com" in named[0]["title"] and "example.org" in named[1]["title"], named

        selected = selected_source()
        SHOT.parent.mkdir(exist_ok=True)
        ask(do="winshot", path=str(SHOT))
        assert SHOT.exists() and SHOT.stat().st_size > 10_000, SHOT
        captured = subprocess.run(["screencapture", "-x", "-l", str(selected["window"]), str(SCREEN)],
                                  capture_output=True)
        if captured.returncode != 0:
            print("Native screen capture unavailable:", captured.stderr.decode(errors="replace").strip())

        box("key", keys="return")
        after_switch = windows()
        assert after_switch[0]["key"], after_switch
        assert any(tab["id"] == original for tab in after_switch[0]["tabs"]), after_switch
        assert all(tab["id"] != original for tab in after_switch[1]["tabs"]), after_switch

        box("focus-window", number=2)
        selected_source()
        box("key", keys="shift+return")
        after_move = windows()
        assert after_move[1]["key"], after_move
        assert all(tab["id"] != original for tab in after_move[0]["tabs"]), after_move
        assert sum(tab["id"] == original for tab in after_move[1]["tabs"]) == 1, after_move
        assert after_move[1]["active"] == original, after_move

        box("focus-window", number=1)
        box("reset", urls=[SOURCE_CLICK])
        clicked_id = next(tab["id"] for tab in windows()[0]["tabs"] if tab["url"] == SOURCE_CLICK)
        box("focus-window", number=2)
        selected = selected_source(SOURCE_CLICK)
        card = selected["card"]
        # The extra action sits immediately left of the visible Actions button.
        assert card[2] > 0 and card[3] > 0, selected
        x = round(card[0] + card[2] - 205)
        y = round(card[1] + card[3] - 26)
        (args.out / "click-state.json").write_text(json.dumps({"selected": selected, "point": [x, y]}, indent=2))
        ask(do="winshot", window=selected["window"], path=str(args.out / "multi-window-click.png"))
        ask(do="drag", window=selected["window"], path=[[x, y, 0]], direct=True)
        time.sleep(.3)
        after_click = windows()
        assert all(tab["id"] != clicked_id for tab in after_click[0]["tabs"]), after_click
        assert sum(tab["id"] == clicked_id for tab in after_click[1]["tabs"]) == 1, after_click
        assert after_click[1]["active"] == clicked_id, after_click
        print("PASS: Window menus identify each window by its active tab and host")
        print("PASS: Return focuses the source window without moving the tab")
        print("PASS: Shift+Return moves the same live tab into the current window and selects it")
        print("PASS: Clicking Move Tab Here moves another live tab into the current window")
        print(f"Screenshot: {SHOT}")
        if SCREEN.exists():
            print(f"Native screenshot: {SCREEN}")
    except Exception:
        # Preserve the owned probe's blocked stack before cleanup. This runs
        # on the same remote farm host as the test, never on the coordinator.
        if process.poll() is None:
            try:
                subprocess.run(["sample", str(process.pid), "2", "-file",
                                str(args.out / "multi-window-failure.sample.txt")],
                               capture_output=True, timeout=15)
            except (OSError, subprocess.TimeoutExpired):
                pass
        raise
    finally:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        app_log.close()
        subprocess.run(["defaults", "delete", DOMAIN], capture_output=True)
        shutil.rmtree(SUPPORT, ignore_errors=True)
        shutil.rmtree(scratch, ignore_errors=True)


if __name__ == "__main__":
    main()
