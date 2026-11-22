#!/usr/bin/env python3
"""An extension's worker and content worlds across revives, reloads and stalls.

Drives a running test world (YAB_PROBE=WORLD, bench on) that has the
extension installed: each round restarts it one way, then asks whether its
own code ran in the worker (its listener report) and counts its content worlds
in a page.

    python3 evals/extension-empty-worker/run.py --world bw-empty --id ID --rounds 6
"""
import argparse
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import yab_socket  # noqa: E402


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--world", required=True)
    p.add_argument("--id", required=True)
    p.add_argument("--page", default="https://example.com/")
    p.add_argument("--rounds", type=int, default=6)
    p.add_argument("--steps", default="revive,reload,restart,stall-revive")
    p.add_argument("--settle", type=float, default=6)
    p.add_argument("--patience", type=float, default=30)
    p.add_argument("--stall", type=float, default=12)
    a = p.parse_args()
    sock = None
    for name in ("Pane", "Yab"):
        candidate = Path.home() / "Library/Application Support" / f"{name} ({a.world})" / "bench.sock"
        if candidate.exists():
            sock = candidate
    if sock is None:
        sys.exit("no bench socket for world " + a.world)
    ask = yab_socket.asker(sock)

    def worker():
        woke = ask({"do": "ext-lifecycle", "id": a.id, "step": "wake"}, timeout=60)
        # Its own code ran when the shim's listener report (4 s into a start) came from this context.
        for _ in range(int(a.patience * 2)):
            heard = ask({"do": "ext-lifecycle", "id": a.id, "step": "heard"})
            if heard.get("reported"):
                break
            time.sleep(0.5)
        page = ask({"do": "ext-diagnostics", "id": a.id})
        events = heard.get("events", [])
        return {"woke": woke.get("woke", woke.get("error", "no answer")), "reported": heard.get("reported"), "onConnect": "runtime.onConnect" in events, "events": len(events),
                "host_page": bool(page.get("background_url"))}

    tab = ask({"do": "open", "url": a.page})
    tab_id = tab.get("id")

    def worlds():
        ask({"do": "go", "id": tab_id, "url": a.page})
        time.sleep(3)
        found = ask({"do": "ext-worlds", "id": tab_id}).get("worlds", {})
        return {k: v for k, v in found.items() if k.startswith("WebExtension")}

    def trace():
        item = next((x for x in ask({"do": "extensions"}).get("extensions", []) if x.get("id") == a.id), {})
        return [line for line in item.get("reported", []) if "Autofill monitoring" not in line][-12:]

    rows = [{"round": 0, "step": "start", **worker(), "worlds": worlds()}]
    print(json.dumps(rows[-1]), flush=True)
    steps = a.steps.split(",")
    for n in range(1, a.rounds + 1):
        step = steps[(n - 1) % len(steps)]
        began = time.monotonic()
        if step == "revive":
            did = ask({"do": "ext-lifecycle", "id": a.id, "step": "revive"}, timeout=60)
        elif step == "reload":
            ask({"do": "ext-lifecycle", "id": a.id, "step": "unload"}, timeout=60)
            did = ask({"do": "ext-lifecycle", "id": a.id, "step": "load"}, timeout=60)
        elif step == "restart":
            did = ask({"do": "ext-lifecycle", "id": a.id, "step": "restart"}, timeout=60)
        elif step == "stall-revive":
            # The revive lands while the main thread is held, as a watchdog's would.
            ask({"do": "ext-lifecycle", "id": a.id, "step": "revive"}, timeout=60)
            did = ask({"do": "ext-lifecycle", "step": "stall", "seconds": a.stall}, timeout=a.stall + 30)
        else:
            sys.exit("unknown step " + step)
        time.sleep(a.settle)
        row = {"round": n, "step": step, "did": did, "secs": round(time.monotonic() - began, 1), **worker(), "worlds": worlds()}
        if not row["reported"]:
            row["trace"] = trace()
            # Left alone for a minute: whether it ever comes up without a restart.
            time.sleep(60)
            row["later"] = worker()
        rows.append(row)
        print(json.dumps(row), flush=True)
    empty = [r for r in rows if not r["reported"] or not r["onConnect"]]
    stacked = [r for r in rows if any(v > 1 for v in r["worlds"].values())]
    print(json.dumps({"rounds": len(rows), "empty_workers": len(empty), "stacked_worlds": len(stacked)}))


if __name__ == "__main__":
    main()
