#!/usr/bin/env python3
"""Many API keys (docs/agents.md, API keys): Claude connected with one key
the way Use an API Key does, two more Anthropic keys and two OpenRouter
keys added from Models, tasks starting on the first with room and moving
down when one is turned away, a key twice refused, the order changed and a
key removed. Pictures of Settings › AI › Models with them all, light and
dark, and of the key page.

    ./farm exec --display --needs capture -- bash -c 'set -o pipefail; ./build.sh 2>&1 | tee build.log; \
        python3 evals/agent-key/many.py --bin "build/Pane Dev.app/Contents/MacOS/pane" --out "$YAB_FARM_OUT"'

Made-up keys only, checked by YAB_AGENT_KEY_CHECK, never sent anywhere.
Prints one JSON line per check and exits 1 if any failed.
"""
import argparse
import json
import os
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from run import KeyYab, KEY, STANDIN  # noqa: E402
sys.path.insert(0, os.path.join(HERE, ".."))
import probe_capture  # noqa: E402

SECOND = "sk-ant-api03-probe-second-0000002222"
THIRD = "sk-ant-api03-probe-third-00000003333"
ROUTER = ["sk-or-v1-probe-00000000000000aaaa", "sk-or-v1-probe-00000000000000bbbb"]


def tail(key):
    return "…" + key[-4:]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bin", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    out = os.path.abspath(args.out)
    os.makedirs(out, exist_ok=True)
    failed = []

    def check(ok, what, **seen):
        print(json.dumps({"ok": bool(ok), "check": what, **seen}), flush=True)
        if not ok:
            failed.append(what)

    scratch = tempfile.mkdtemp(prefix="yab-agent-keys-")
    home = os.path.join(scratch, "home")
    os.makedirs(home)
    claude = os.path.join(scratch, "claude")
    with open(claude, "w") as f:
        f.write(STANDIN)
    os.chmod(claude, 0o755)
    yab = KeyYab(args.bin, scratch, "many", home, "taken", claude)
    try:
        yab.start()
        agents = lambda command: yab.bench(do="ui", agents=command)

        def until(test, seconds=40):
            end = time.time() + seconds
            state = agents("page")
            while time.time() < end and not test(state):
                time.sleep(0.3)
                state = agents("page")
            return state

        def shot(name):
            windows = yab.bench(do="ui", windows=True).get("windows", [])
            settings = next((w for w in windows if "Settings" in w.get("kind", "") or w.get("title") == "Settings"), None)
            if settings is None:
                return print(json.dumps({"shot": name, "error": "no Settings window", "windows": windows}))
            print(json.dumps({"shot": name, "got": str(probe_capture.picture(yab.pid, os.path.join(out, name + ".png"), window_id=settings["id"]))}))

        yab.bench(do="ui", page="models", settings=True, look="light")
        until(lambda s: s["found"][0] != "", 20)
        agents("key:claude")
        state = until(lambda s: s["flow"].startswith("asking") or s["trouble"])
        check(state["flow"].startswith("asking"), "the first key connects Claude", flow=state["flow"], trouble=state["trouble"])
        agents("finish")
        # The offer to get to know you, turned down as Not Now does.
        agents("notnow")
        state = until(lambda s: s["flow"] == "page", 15)
        check(state["flow"] == "page", "Connect ends on Models", flow=state["flow"])

        agents("addkey:claude:" + SECOND)
        until(lambda s: len(s["accounts"]["claude"]) == 2 or s["keyTrouble"])
        agents("addkey:claude:" + THIRD)
        state = until(lambda s: len(s["accounts"]["claude"]) == 3 or s["keyTrouble"])
        claude_rows = state["accounts"]["claude"]
        check([r["tail"] for r in claude_rows] == ["", tail(SECOND), tail(THIRD)], "two more keys are rows after Claude's own",
              rows=claude_rows, trouble=state["keyTrouble"])
        agents("addkey:claude:" + SECOND)
        state = until(lambda s: s["keyTrouble"])
        check(state["keyTrouble"] == "This key is already here.", "a key added twice says so", trouble=state["keyTrouble"])

        for key in ROUTER:
            agents("openrouter:" + key)
        state = until(lambda s: len(s["openRouter"]) == 2)
        check(state["openRouter"] == [tail(k) for k in ROUTER], "two OpenRouter keys, in order", keys=state["openRouter"])

        ids = [r["id"] for r in claude_rows]
        check(state["picks"]["claude"] == "claude" and state["pickKey"] == tail(KEY), "a task starts on the first",
              pick=state["picks"]["claude"], key=state["pickKey"])
        agents("ranout:claude")
        state = until(lambda s: s["picks"]["claude"] == ids[1], 5)
        check(state["pickKey"] == tail(SECOND), "turned away, the next key takes over", pick=state["picks"]["claude"], key=state["pickKey"])
        time.sleep(1)
        shot("1-models-light")
        yab.bench(do="ui", page="models", settings=True, look="dark")
        time.sleep(1)
        shot("2-models-dark")
        yab.bench(do="ui", page="models", settings=True, look="light")
        agents("ranout:" + ids[1])
        state = until(lambda s: s["picks"]["claude"] == ids[2], 5)
        check(state["pickKey"] == tail(THIRD), "and the one after it", pick=state["picks"]["claude"], key=state["pickKey"])

        agents("movekey:" + ids[2] + ":-1")
        state = until(lambda s: [r["id"] for r in s["accounts"]["claude"]] == [ids[0], ids[2], ids[1]], 5)
        check([r["id"] for r in state["accounts"]["claude"]] == [ids[0], ids[2], ids[1]], "Move Up moves it", rows=state["accounts"]["claude"])
        agents("dropkey:" + ids[2])
        state = until(lambda s: len(s["accounts"]["claude"]) == 2, 5)
        check([r["id"] for r in state["accounts"]["claude"]] == [ids[0], ids[1]], "Remove Key takes it away", rows=state["accounts"]["claude"])

        state = agents("keypage:anthropic")
        time.sleep(1)
        check(agents("page")["keyPage"] == "anthropic", "the key page opens in Models' place")
        shot("3-key-page-light")
        yab.bench(do="ui", page="models", settings=True, look="dark")
        time.sleep(1)
        shot("4-key-page-dark")
        agents("keypage:")
        runs = open(os.path.join(home, "claude-runs.log")).read() if os.path.exists(os.path.join(home, "claude-runs.log")) else ""
        check(SECOND not in runs and THIRD not in runs, "no claude ran with a key it wasn't picked for")
    finally:
        yab.stop()

    print(json.dumps({"failed": failed}))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
