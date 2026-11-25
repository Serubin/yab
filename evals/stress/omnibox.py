#!/usr/bin/env python3
"""Measure first and repeated omnibox openings in an existing --test yab.

Launch a fresh test world, then run:
    python3 evals/stress/omnibox.py --world omnibox-perf
    python3 evals/stress/omnibox.py --world omnibox-perf --case history

Run one case after a fresh app launch to measure that case's truly first open.
The default suite measures baseline first, then the heavier cases. No network
pages are needed. The bench owns only data in the named test world.
"""

import argparse
import json
import runpy
import subprocess
import sys
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
CASES = {
    "baseline": ("box-open", {"history": 0, "tabs": 0, "clips": 0}),
    "tabs": ("box-fresh", {"history": 0, "tabs": 80, "clips": 0}),
    "history": ("box-history", {"history": 10_000, "tabs": 0, "clips": 0}),
    "suggestions": ("box-open", {"history": 10_000, "tabs": 0, "clips": 0, "diary": 0}),
    "clipboard": ("box-clipboard", {"history": 0, "tabs": 0, "clips": 1_000}),
    "actions": ("box-k", {"history": 0, "tabs": 0, "clips": 1}),
}
HISTORY_KEYS = "page 999\x7f\x7f\x7f123"
HISTORY_EXPECTED = "page 123"
COLD_PAGE = "data:text/html,%3Cbody%3EOmnibox%20bench%3C/body%3E"


def seed_cold(world):
    if not world or world in ("test", "1") or any(c not in "abcdefghijklmnopqrstuvwxyz0123456789-" for c in world):
        raise RuntimeError("cold seeding needs a named test world using lowercase letters, digits and hyphens")
    probe = subprocess.run([str(ROOT / "bench"), "--world", world, "probe"],
                           capture_output=True, timeout=10)
    if probe.returncode == 0:
        raise RuntimeError("stop this test world's app before seeding its cold-start session")
    folder = Path.home() / "Library" / "Application Support" / f"Pane ({world})"
    session = folder / "session.json"
    if session.exists():
        saved = json.loads(session.read_text())
        if any(tab.get("url") != COLD_PAGE for tab in saved.get("tabs", [])):
            raise RuntimeError("this test world contains other saved tabs; use a separate omnibox test world")
    folder.mkdir(parents=True, exist_ok=True)
    session.write_text(json.dumps({"tabs": [{"url": COLD_PAGE, "title": "Omnibox bench"}], "active": 0}))
    print(f"Seeded {world}; launch its test app, then run with --require-cold")


def bench(world, *args):
    try:
        run = subprocess.run([str(ROOT / "bench"), "--world", world, *args],
                             cwd=ROOT, capture_output=True, text=True,
                             timeout=90 if "prepare" in args else 10)
    except subprocess.TimeoutExpired as error:
        raise RuntimeError(f"bench timed out during {' '.join(args)}") from error
    if run.returncode:
        raise RuntimeError(run.stderr.strip() or run.stdout.strip())
    return json.loads(run.stdout)


def measure(world, action, seconds):
    result = bench(world, "pace", action, str(seconds))
    if not all(result.get(key) for key in ("app_active", "stayed_active", "window_key", "window_visible")):
        raise RuntimeError("the test window lost focus or visibility during measurement")
    if not result.get("box_showing"):
        raise RuntimeError(f"{action} did not show the omnibox")
    if action == "box-k" and result.get("box_acting", -1) < 0:
        raise RuntimeError("the actions panel did not open")
    if action == "box-k" and result.get("box_actions", 0) < 4:
        raise RuntimeError("the actions panel has too few buttons for this case")
    if action == "box-history" and result.get("box_place") != "history":
        raise RuntimeError("the history list did not open")
    if action == "box-history" and result.get("box_history_rows", 0) < 40:
        raise RuntimeError("the history fixture did not populate the visible list")
    if action == "box-clipboard" and result.get("box_place") != "clipboard":
        raise RuntimeError("the clipboard list did not open")
    if result.get("frames", 0) < 2:
        raise RuntimeError(f"{action} produced too few display-link samples")
    return result


def check_height(world, expected, place):
    """Exercise empty, short and missing results through the native editor."""
    states = []
    for text in ("", "page 123", "zzzz-no-omnibox-match-92741"):
        bench(world, "box", "key", "cmd+a")
        bench(world, "box", "key", "delete")
        state = bench(world, "box", "type", text)
        height = state["card"][3]
        if not state["showing"] or not state["focused"] or abs(height - expected) >= 0.5:
            raise RuntimeError(f"{place} card changed height or lost focus for {text!r}: {height}")
        states.append({"text": text, "height": height,
                       "rows": len(state["items"] if place == "history" else state["offers"])})
    return {"case": place, "pass": True, "states": states}


def check_focus(world):
    """Type before the first layout, then dismiss before deferred focus."""
    api = runpy.run_path(str(ROOT / "bench"))
    path = str(Path(api["folder"](world)) / "bench.sock")

    def ask(**request):
        result = api["ask"](path, request)
        if "error" in result:
            raise RuntimeError(result["error"])
        return result

    bench(world, "front")
    time.sleep(0.15)
    checks = []
    for _ in range(3):
        ask(do="pace", action="box-close", seconds=0.2)
        ask(do="box", act="l", wait=0)
        for key in "abcd":
            ask(do="box", act="key", keys=key, wait=0)
        time.sleep(0.15)
        state = ask(do="box", act="state", wait=0)
        correct = state["typed"] == "abcd" and state["focused"]
        checks.append({"case": "immediate-typing", "pass": correct})
        ask(do="pace", action="box-close", seconds=0.2)
        ask(do="box", act="l", wait=0)
        ask(do="box", act="key", keys="escape", wait=0)
        time.sleep(0.15)
        state = ask(do="box", act="state", wait=0)
        correct = not state["showing"] and not state["focused"]
        checks.append({"case": "immediate-escape", "pass": correct})
    return checks


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--world", default="omnibox-perf", help="name of an already running YAB_PROBE test world")
    parser.add_argument("--case", choices=["all", *CASES], default="all")
    parser.add_argument("--require-cold", action="store_true",
                        help="fail unless the first case is this process's first visible omnibox opening")
    parser.add_argument("--seed-cold", action="store_true",
                        help="with this test app stopped, seed a local startup page and exit")
    parser.add_argument("--seconds", type=float, default=0.7)
    parser.add_argument("--typing-interval-ms", type=float, default=16.0,
                        help="time between History keystrokes (default: 16 ms)")
    parser.add_argument("--typing-seconds", type=float, default=2.5,
                        help="time to measure typing and wait for the last search result")
    parser.add_argument("--warm-runs", type=int, default=3,
                        help="repeated openings after the first (default: 3)")
    parser.add_argument("--settle", type=float, default=2.0,
                        help="seconds to let fixture page loads and queued saves finish before timing")
    parser.add_argument("--max-gap-ms", type=float,
                        help="largest acceptable frame gap (default: max of 25 ms or two refresh periods)")
    parser.add_argument("--max-toggle-ms", type=float, default=25.0,
                        help="largest acceptable synchronous opening time")
    parser.add_argument("--json", type=Path, help="write full frame traces and checks here")
    args = parser.parse_args()
    if args.seed_cold:
        seed_cold(args.world)
        return 0
    if args.seconds < 0.2:
        parser.error("--seconds must be at least 0.2")
    if args.settle < 0:
        parser.error("--settle cannot be negative")
    if args.warm_runs < 0:
        parser.error("--warm-runs cannot be negative")
    if not 5 <= args.typing_interval_ms <= 100:
        parser.error("--typing-interval-ms must be from 5 to 100")
    if args.typing_seconds < len(HISTORY_KEYS) * args.typing_interval_ms / 1000 + 0.3:
        parser.error("--typing-seconds must leave at least 0.3 s after the final key")
    bench(args.world, "front")
    bench(args.world, "ui", "welcome", "off")
    names = list(CASES) if args.case == "all" else [args.case]
    report = []
    controls = []
    layouts = []
    focus = []
    failed = False
    def save_report(completed=False):
        if args.json:
            args.json.parent.mkdir(parents=True, exist_ok=True)
            args.json.write_text(json.dumps({"world": args.world, "completed": completed, "limits": {
                "gap_ms": args.max_gap_ms or "max(25 ms, two refresh periods)",
                "toggle_ms": args.max_toggle_ms},
                "controls": controls, "layouts": layouts, "focus": focus, "runs": report}, indent=2) + "\n")

    for name in names:
        action, fixture = CASES[name]
        ready = bench(args.world, "box", "prepare", *(f"{k}={v}" for k, v in fixture.items()))
        if not ready.get("ready"):
            raise RuntimeError(f"{name} fixture could not write its history")
        time.sleep(args.settle)
        bench(args.world, "front")
        time.sleep(0.15)
        control = bench(args.world, "pace", "idle", str(args.seconds))
        controls.append({"case": name, **control})
        print(f"{name:10} idle     main {control['main_latency_ms']:5.1f} ms  "
              f"gap {control['worst_callback_ms']:5.1f} ms")
        for phase in ["first", *(f"warm-{run}" for run in range(1, args.warm_runs + 1))]:
            bench(args.world, "front")
            time.sleep(0.15)
            if action == "box-k":
                bench(args.world, "box", "open-place", "clipboard")
            result = measure(args.world, action, args.seconds)
            if args.require_cold and name == names[0] and phase == "first":
                if action == "box-k":
                    raise RuntimeError("actions needs an open field; use a separate cold-opening case")
                if result.get("field_presentations_before") != 0:
                    raise RuntimeError("the omnibox was already shown; stop this test app, use --seed-cold, and relaunch")
            gap = max(result["first_callback_ms"], result["worst_callback_ms"], result["main_latency_ms"])
            gap_limit = args.max_gap_ms if args.max_gap_ms is not None else max(25.0, 2 * result["refresh_ms"])
            ok = gap <= gap_limit and result["toggle_ms"] <= args.max_toggle_ms
            failed |= not ok
            report.append({"case": name, "phase": phase, "gap_ms": gap,
                           "gap_limit_ms": gap_limit, "pass": ok, **result})
            save_report()
            print(f"{name:10} {phase:6}  first {result['first_callback_ms']:5.1f} ms  "
                  f"gap {result['worst_callback_ms']:5.1f} ms  main {result['main_latency_ms']:5.1f} ms  "
                  f"toggle {result['toggle_ms']:5.1f} ms  "
                  f"late ticks {result['dropped']:2}  {'PASS' if ok else 'FAIL'}")
            if name in ("history", "suggestions"):
                typed = bench(args.world, "pace", "box-type", HISTORY_KEYS,
                              str(args.typing_seconds), str(args.typing_interval_ms / 1000))
                if not all(typed.get(key) for key in ("app_active", "stayed_active", "window_key", "window_visible")):
                    raise RuntimeError("the test window lost focus or visibility while typing")
                at = typed["typing_at_ms"]
                lag = max((actual - (index + 1) * args.typing_interval_ms
                           for index, actual in enumerate(at)), default=0)
                key_cost = max(typed["typing_key_cost_ms"], default=0)
                typing_gap = max(typed["first_callback_ms"], typed["worst_callback_ms"],
                                 typed["main_latency_ms"], lag, key_cost)
                found = (typed["box_history_rows"] > 0 and "123" in typed["box_history_first_title"]
                         if name == "history" else
                         any("page 123" in title for title in typed["box_offer_titles"]))
                correct = (typed["typing_count"] == len(HISTORY_KEYS)
                           and typed["box_text"] == HISTORY_EXPECTED and found)
                heights = [result["box_height"], *typed["typing_card_heights"], typed["box_height"]]
                fixed_height = min(heights) > 0 and max(heights) - min(heights) < 0.5
                correct &= fixed_height
                typing_ok = correct and typing_gap <= gap_limit
                failed |= not typing_ok
                report.append({"case": f"{name}-typing", "phase": phase,
                               "gap_ms": typing_gap, "gap_limit_ms": gap_limit,
                               "typing_lag_ms": round(lag, 1), "key_cost_ms": key_cost,
                               "fixed_height": fixed_height,
                               "correct": correct, "pass": typing_ok, **typed})
                save_report()
                print(f"{name + '-key':10} {phase:6}  main {typed['main_latency_ms']:5.1f} ms  "
                      f"gap {typed['worst_callback_ms']:5.1f} ms  key {key_cost:5.1f} ms  "
                      f"lag {lag:5.1f} ms  "
                      f"{'PASS' if typing_ok else 'FAIL'}")
            if name in ("history", "suggestions") and phase == "first":
                layouts.append(check_height(args.world, result["box_height"], name))
                save_report()
                print(f"{name:10} layout   empty / matches / no matches: fixed {result['box_height']:.0f} pt")
            if action == "box-k":
                bench(args.world, "pace", "box-k", "0.2")
            bench(args.world, "pace", "box-close", "0.2")
    focus.extend(check_focus(args.world))
    focus_ok = all(check["pass"] for check in focus)
    failed |= not focus_ok
    print(f"focus      immediate typing / Escape: {'PASS' if focus_ok else 'FAIL'}")
    save_report(completed=True)
    return 1 if failed else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except RuntimeError as error:
        sys.exit(f"omnibox bench: {error}")
