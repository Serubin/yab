#!/usr/bin/env python3
"""Capture folder strip states and measure its opening in an isolated world."""

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
WORLD = f"strip-review-{os.getpid()}"
SCRATCH = Path(tempfile.mkdtemp(prefix="yab-strip-review-"))
SUPPORT = Path.home() / "Library" / "Application Support" / f"Pane ({WORLD})"
SOCKET = SUPPORT / "bench.sock"
OUT = ROOT / ".build" / "strip-folders-review"
OUT.mkdir(parents=True, exist_ok=True)
DOMAIN = f"dev.serafim.fast.test.{WORLD}"


ask = yab_socket.kwasker(SOCKET, timeout=60, strict=True, fail=lambda request, reply: AssertionError(f"{request}: {reply['error']}"))


def shot(name):
    path = OUT / f"{name}.png"
    ask(do="winshot", path=str(path))
    assert path.stat().st_size > 10_000, path
    return str(path)


def folder_state():
    return next(folder for folder in ask(do="kept", action="state")["folders"] if folder["name"] == "Work")


def disjoint(frames):
    visible = sorted((tab["tab"] for tab in frames["tabs"] if "tab" in tab), key=lambda rect: rect[0])
    for left, right in zip(visible, visible[1:]):
        if abs(left[1] - right[1]) < 1:
            assert left[0] + left[2] <= right[0] + 0.5, (left, right)
    return len(visible)


def set_open(want):
    if folder_state()["open"] != want:
        ask(do="kept", action="toggle", folder="Work")
        time.sleep(0.4)
    assert folder_state()["open"] == want, folder_state()


def main():
    binary = Path(os.environ["APP"]) / "Contents" / "MacOS" / "pane"
    subprocess.run(["defaults", "write", DOMAIN, "bench", "-bool", "true"], check=True)
    env = dict(os.environ, YAB_PROBE=WORLD, FAST_PROBE=WORLD, HOME=str(SCRATCH))
    process = subprocess.Popen([str(binary)], cwd=ROOT, env=env,
                               stdout=(OUT / "app.log").open("w"), stderr=subprocess.STDOUT)
    result = {"world": WORLD, "screenshots": {}, "pace_small": [], "pace": []}
    try:
        for attempt in range(480):
            if SOCKET.exists() and process.poll() is None:
                break
            if attempt % 40 == 0:
                print(f"Waiting for test socket: {attempt // 4}s, process={process.poll()}", flush=True)
            time.sleep(0.25)
        assert SOCKET.exists(), f"app did not start, exit={process.poll()}"
        ask(do="ui", sidebar=False, look="light", welcome=False)
        time.sleep(0.3)
        ask(do="resize", width=1200, height=760, steps=1)
        urls = [f"https://{host}/" for host in ["figma.com", "linear.app", "notion.so", "github.com", "google.com", "example.org", "wikipedia.org", "apple.com"]]
        ask(do="flood", urls=urls, asleep=True)
        ids = [tab["id"] for tab in ask(do="tabs")["tabs"] if tab["url"] in urls]
        assert len(ids) == len(urls), ids
        ask(do="select", id=ids[5])
        time.sleep(0.8)
        ask(do="kept", action="folder", ids=ids[:3], name="Work")
        set_open(False)
        result["screenshots"]["light-closed"] = shot("light-closed")
        set_open(True)
        result["screenshots"]["light-open"] = shot("light-open")
        ask(do="ui", look="dark")
        result["screenshots"]["dark-open"] = shot("dark-open")
        set_open(False)
        ask(do="resize", width=650, height=680, steps=1)
        result["screenshots"]["dark-compact"] = shot("dark-compact")
        result["hover"] = ask(do="glance", folder="Work", on=True)
        result["screenshots"]["dark-hover"] = shot("dark-hover")
        ask(do="glance", folder="Work", on=False)
        ask(do="resize", width=1200, height=760, steps=1)
        set_open(True)
        for look in ["dark", "light"]:
            ask(do="ui", look=look)
            for direction in ["close", "open"]:
                assert folder_state()["open"] == (direction == "close")
                sample = ask(do="pace", action="folder", folder="Work", seconds=0.8, screen=True)
                assert not sample["box_showing"], sample["box_showing"]
                sample["look"] = look
                sample["direction"] = direction
                result["pace_small"].append(sample)
        ask(do="kept", action="empty", name="Empty")
        result["screenshots"]["empty-open"] = shot("empty-open")
        ask(do="kept", action="remove-empty", folder="Empty")
        ask(do="select", id=ids[0])
        set_open(False)
        result["screenshots"]["closed-active"] = shot("closed-active")
        ask(do="select", id=ids[5])
        set_open(True)
        ask(do="ui", look="dark")
        ask(do="flood", urls=[f"https://example.com/page-{index + 1}" for index in range(32)], asleep=True)
        more = [tab["id"] for tab in ask(do="tabs")["tabs"]
                if tab["url"].startswith("https://example.com/page-")][:3]
        ask(do="kept", action="file", folder="Work", ids=more)
        assert len(ask(do="tabs")["tabs"]) >= 40
        assert folder_state()["tabs"] == 6, folder_state()
        time.sleep(0.5)
        result["screenshots"]["dark-40-tabs"] = shot("dark-40-tabs")
        for look in ["dark", "light"]:
            ask(do="ui", look=look)
            for direction in ["close", "open", "close", "open"]:
                assert folder_state()["open"] == (direction == "close")
                sample = ask(do="pace", action="folder", folder="Work", seconds=0.8, screen=True)
                assert not sample["box_showing"], sample["box_showing"]
                sample["look"] = look
                sample["direction"] = direction
                result["pace"].append(sample)
                time.sleep(0.2)
        result["idle"] = ask(do="idle", seconds=2)
        result["frames"] = ask(do="frames")
        result["disjoint_stress_tabs"] = disjoint(result["frames"])
        result["layers"] = ask(do="layer-audit")
        remaining = [tab["id"] for tab in ask(do="tabs")["tabs"] if tab["id"] != ids[5]]
        ask(do="kept", action="close", ids=remaining)
        session = ask(do="agent-attach", name="Research")["session"]
        agent_ids = [ask(do="open", url=f"https://example.net/agent-{index}", session=session)["id"]
                     for index in range(6)]
        ask(do="select", id=agent_ids[0])
        time.sleep(0.3)
        agent = ask(do="agent-folder", folder=session)
        assert agent["open"] and agent["tabs"] == 6, agent
        time.sleep(0.5)
        result["screenshots"]["agent-more"] = shot("agent-more")
        result["disjoint_agent_tabs"] = disjoint(ask(do="frames"))
        result["pace_agent_close"] = ask(do="pace", action="folder", folder=session, seconds=0.8, screen=True)
        result["pace_agent_open"] = ask(do="pace", action="folder", folder=session, seconds=0.8, screen=True)
        (OUT / "results.json").write_text(json.dumps(result, indent=2))
        print(json.dumps({key: value for key, value in result.items() if key != "frames"}, indent=2))
    finally:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        shutil.rmtree(SCRATCH, ignore_errors=True)
        shutil.rmtree(SUPPORT, ignore_errors=True)
        subprocess.run(["defaults", "delete", DOMAIN], capture_output=True)


if __name__ == "__main__":
    main()
