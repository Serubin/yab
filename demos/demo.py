#!/usr/bin/env python3
"""./demo: Mira's browser, ready to film (docs/demos.md).

    ./demo                      the scenes, one line each
    ./demo SCENE                build that scene's world fresh and open it in front, then say the take
    ./demo SCENE again          open it as it was left, no rebuild (in-memory parts staged again)
    ./demo SCENE --frame 4:3|square|16:9|screen   the window's frame, centered (4:3, 1200x900, unless the scene says)
    ./demo SCENE --size 1440x900   the window at exactly that size, centered
    ./demo SCENE --background   build and open it without taking the screen (checks)
    ./demo install [--app PATH] build Yab from HEAD (or take a built pane.app) as the demo copy
    ./demo cli [--terminal]     the command that starts Claude Code driving the cli scene's world
    ./demo check [SCENE]        build each scene out of sight, check what it holds, keep a picture of it
    ./demo launchers            an app for each scene beside the demo copy of Yab, to double-click
    ./demo stop                 quit every demo world and the demo sites
    ./demo sites                start the demo sites and mail only
"""
import argparse
import json
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
sys.path.insert(0, str(HERE))
import world as Wd  # noqa: E402
from scenes import ORDER, SCENES  # noqa: E402


def world_name(scene):
    return "demo-" + scene


def show_story(name):
    scene = SCENES[name]
    print("\n%s\n%s" % (scene["title"], "-" * min(len(scene["title"]), 72)))
    for n, line in enumerate(scene["story"], 1):
        print("%2d. %s" % (n, line))
    print()


def listing():
    print("Scenes (./demo NAME builds one and opens it):\n")
    for name in ORDER:
        print("  %-10s %s" % (name, SCENES[name]["title"]))
    print("\n./demo install first, once, and after Yab changes. Docs: docs/demos.md")


def open_scene(name, again=False, background=False, size=None, pretend=False, stage=None, quiet=False, frame=None):
    scene = dict(SCENES[name])
    world = world_name(name)
    after = list(scene.get("after", []))
    if name == "island" and pretend:
        after.append({"do": "band", "action": "pretend:2"})
    if name == "update" and stage:
        after = [{"do": "ui", "update": stage}]
    scene["after"] = after
    if again:
        Wd.ensure_server()
        if not Wd.pid_of(world):
            command = ["open", "-n"] + (["-g"] if background else []) + ["-a", str(Wd.APP)]
            for key, value in {"YAB_PROBE": world, "YAB_HISTORY": "own", "YAB_RECORDING": "1", **scene.get("env", {})}.items():
                command += ["--env", "%s=%s" % (key, value)]
            subprocess.run(command, check=True)
            if not Wd.wait_for_socket(world):
                raise SystemExit("Yab didn't open %s." % world)
        state = json.loads(Wd.STATE.read_text()) if Wd.STATE.exists() else {}
        meeting = state.get("meeting") or {"title": "Design review · Onboarding v3", "start": time.time() + 720, "link": Wd.P.CALL}
        Wd.seed(world, scene, meeting, time.time())
    else:
        if not quiet:
            print("Building %s…" % world, flush=True)
        start = time.time()
        Wd.build(world, scene, background=background, size=size, frame=frame)
        if not quiet:
            print("Ready in %.0f s." % (time.time() - start))
    if quiet:
        return
    if name == "cli":
        print(cli_command(world))
    show_story(name)
    if not background:
        print(record_hint(world, name))


STUDIO = Wd.HOME / "Documents/GitHub/Pulso/tools/demo-studio"


def record_hint(world, name):
    """How to film this take with Demo Studio (Pulso's recorder: the window
    without the pointer, on its wallpaper, clicks from real input)."""
    if not STUDIO.exists():
        return ""
    scene = SCENES[name]
    try:
        window = Wd.bench(world, {"do": "box", "act": "instant"}).get("window")
    except OSError:
        window = None
    take = "output/yab-%s-01" % name
    capture = scene.get("capture", "window")
    audio = " --audio" if scene.get("audio") else ""
    seconds = scene.get("seconds", 45)
    if capture == "window":
        record = "./demo record --window %s --seconds %d%s --output %s" % (window, seconds, audio, take)
    else:
        x, y, w, h, sw, sh = Wd.screen_frame()
        record = ("./demo record --window %s --scope app --region %d,%d,%d,%d --seconds %d%s --output %s"
                  % (window, x, sh - y - h, w, h, seconds, audio, take))
    note = {"window": "the window alone", "app": "every Yab window over the whole screen (the floating one goes past the edge)"}[capture]
    return ("Film it with Demo Studio (%s):\n\n  cd %s\n  %s\n"
            "  ./demo render %s --background wallpaper --format wide --output output/yab-%s-wide.mp4\n"
            % (note, STUDIO, record, take, name))


def cli_command(world):
    """Claude Code with Yab's MCP server, pointed at this world only."""
    binary = Wd.APP / "Contents/MacOS/pane"
    config = Wd.CACHE / ("mcp-%s.json" % world)
    config.parent.mkdir(parents=True, exist_ok=True)
    config.write_text(json.dumps({"mcpServers": {"yab-browser": {
        "command": str(binary), "args": ["mcp"], "env": {"YAB_PROBE": world}}}}, indent=1))
    bin_dir = Wd.CACHE / "bin"
    bin_dir.mkdir(parents=True, exist_ok=True)
    shim = bin_dir / "yab"
    shim.write_text('#!/bin/bash\nexport YAB_PROBE="%s"\nexec "%s" "$@"\n' % (world, binary))
    shim.chmod(0o755)
    return ('\nIn a terminal (Claude Code drives the %s world, nothing else):\n\n'
            '  export PATH="%s:$PATH"\n'
            '  claude --mcp-config "%s" --strict-mcp-config --allowedTools "mcp__yab-browser"\n\n'
            'or one line, Yab\'s own agent: yab "compare Alfama hotels under €220"\n' % (world, bin_dir, config))


def open_terminal(world):
    command = cli_command(world)
    lines = [l.strip() for l in command.splitlines() if l.strip().startswith(("export", "claude"))]
    script = " && ".join(lines)
    subprocess.run(["osascript", "-e", 'tell application "Terminal" to do script "%s"' % script.replace('"', '\\"'),
                    "-e", 'tell application "Terminal" to activate'], check=True)


def install(app=None):
    """The demo copy: Yab with its own bundle id, so its worlds have none of
    the real Yab's access, and a YAB_PROBE of its own if opened by hand."""
    target = Wd.APP
    built = Path(app) if app else None
    tmp = None
    if not built:
        tmp = Path(tempfile.mkdtemp(prefix="yab-demo-build-"))
        tree = tmp / "tree"
        print("Building Yab from HEAD in %s (about 5 minutes)…" % tree, flush=True)
        subprocess.run(["git", "-C", str(REPO), "worktree", "add", "--detach", str(tree), "HEAD"], check=True)
        try:
            subprocess.run(["./build.sh", "release", "prod"], cwd=tree, check=True)
            built = tree / "build/pane.app"
            staged = tmp / "pane.app"
            shutil.copytree(built, staged, symlinks=True)
            built = staged
        finally:
            subprocess.run(["git", "-C", str(REPO), "worktree", "remove", "--force", str(tree)], capture_output=True)
    if not built.exists():
        raise SystemExit("No app at %s" % built)
    for world in [world_name(n) for n in ORDER]:
        Wd.quit_world(world)
    if target.exists():
        shutil.rmtree(target)
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(built, target, symlinks=True)
    info_path = target / "Contents/Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    info["CFBundleIdentifier"] = Wd.BUNDLE
    info["LSEnvironment"] = {"YAB_PROBE": "demo", "YAB_HISTORY": "own", "YAB_RECORDING": "1"}
    info.pop("YabFeed", None)
    info_path.write_bytes(plistlib.dumps(info))
    entitlements = Path(tempfile.mkstemp(suffix=".plist")[1])
    raw = subprocess.run(["codesign", "-d", "--entitlements", ":-", str(built)], capture_output=True).stdout
    entitlements.write_bytes(raw if raw.strip() else (REPO / "yab.entitlements").read_bytes())
    identities = subprocess.run(["security", "find-identity", "-v", "-p", "codesigning"], capture_output=True, text=True).stdout
    identity = next((line.split('"')[1] for line in identities.splitlines() if "Developer ID Application" in line), "-")
    subprocess.run(["codesign", "--force", "--deep", "--options", "runtime", "--entitlements", str(entitlements),
                    "--sign", identity, str(target)], check=True)
    if tmp:
        shutil.rmtree(tmp, ignore_errors=True)
    version = info.get("CFBundleShortVersionString", "?"), info.get("CFBundleVersion", "?")
    print("Installed %s (%s, build %s), signed %s." % (target, version[0], version[1], identity))


def check(names):
    """Each scene built out of sight, its world asked what it holds, a
    picture of its window kept: what a take would start from."""
    out_dir = Wd.CACHE / "check"
    out_dir.mkdir(parents=True, exist_ok=True)
    failed = 0
    for name in names:
        world = world_name(name)
        scene = SCENES[name]
        problems = []
        start = time.time()
        try:
            open_scene(name, background=True, quiet=True)
            time.sleep(4)
            tabs = Wd.bench(world, {"do": "tabs"}).get("tabs", [])
            front = next((t for t in tabs if t.get("active")), {})
            want = scene.get("front", {}).get(scene.get("space"))
            if want and want not in front.get("url", "").replace(":8800", "") and name not in ("mail", "welcome", "hello", "update"):
                problems.append("front tab is %s, not %s" % (front.get("url") or front.get("label"), want))
            # Mail opens in a space of its own, which holds one tab.
            if len(tabs) < 6 and name != "mail":
                problems.append("only %d tabs" % len(tabs))
            mail = Wd.bench(world, {"do": "agent-mail-state"})
            if scene.get("mail", True) and not mail.get("accounts"):
                problems.append("no mail account")
            call = Wd.bench(world, {"do": "call", "action": "state"})
            if call.get("badge", "none") == "none":
                problems.append("no meeting on the calendar pin")
            Wd.bench(world, {"do": "winshot", "path": str(out_dir / (name + ".png"))}, timeout=60)
        except (OSError, SystemExit) as error:
            problems.append(str(error))
        finally:
            Wd.quit_world(world)
        failed += bool(problems)
        print("%-10s %s  %.0f s  %s" % (name, "ok  " if not problems else "FAIL", time.time() - start, "; ".join(problems)), flush=True)
    print("\npictures in %s" % out_dir)
    return failed


def launchers():
    """A double-clickable app for each scene beside the demo copy of Yab:
    it shows the take, then builds the world and opens it. They run a copy
    of this folder kept under Application Support (macOS would ask each one
    for the Documents folder otherwise): run this again after changing it."""
    support = Wd.HOME / "Library/Application Support/yab-demo/demos"
    if support.exists():
        shutil.rmtree(support)
    shutil.copytree(HERE, support, ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
    shutil.copy(REPO / "evals/mail/fake_gmail.py", support / "fake_gmail.py")
    folder = Wd.APP.parent
    for old in folder.glob("[0-9][0-9] *.app"):
        shutil.rmtree(old)
    icon = Wd.APP / "Contents/Resources/yab.icns"
    for n, name in enumerate(ORDER, 1):
        scene = SCENES[name]
        steps = "\n".join("%d. %s" % (k, line) for k, line in enumerate(scene["story"], 1))
        quote = lambda text: text.replace("\\", "\\\\").replace('"', '\\"')
        log = Wd.CACHE / ("launch-%s.log" % name)
        command = ("export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH; mkdir -p '%s'; /usr/bin/python3 '%s' %s > '%s' 2>&1"
                   % (Wd.CACHE, support / "demo.py", name, log))
        script = ('set story to "%s"\n'
                  'display dialog story with title "%s" buttons {"Cancel", "Open"} default button "Open" with icon note\n'
                  'do shell script "%s"\n') % (quote(steps), quote(scene["title"]), quote(command))
        app = folder / ("%02d %s.app" % (n, name.capitalize() if name != "pip" else "PiP"))
        subprocess.run(["osacompile", "-o", str(app), "-e", script], check=True, capture_output=True)
        if icon.exists():
            shutil.copy(icon, app / "Contents/Resources/applet.icns")
            subprocess.run(["touch", str(app)])
    print("%d scene apps in %s" % (len(ORDER), folder))


def stop():
    for name in ORDER + ["demo"]:
        world = name if name == "demo" else world_name(name)
        if Wd.quit_world(world):
            print("quit", world)
    Wd.stop_server()
    print("demo sites stopped")


def main():
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("what", nargs="?")
    parser.add_argument("more", nargs="?")
    parser.add_argument("--background", action="store_true")
    parser.add_argument("--size")
    parser.add_argument("--frame", choices=["4:3", "square", "16:9", "screen"])
    parser.add_argument("--pretend", action="store_true")
    parser.add_argument("--stage")
    parser.add_argument("--app")
    parser.add_argument("--terminal", action="store_true")
    parser.add_argument("-h", "--help", action="store_true")
    args = parser.parse_args()
    if args.help:
        print(__doc__)
        return
    if not args.what or args.what == "list":
        return listing()
    if args.what == "install":
        return install(args.app)
    if args.what == "stop":
        return stop()
    if args.what == "launchers":
        return launchers()
    if args.what == "check":
        names = [args.more] if args.more else ORDER
        sys.exit(1 if check(names) else 0)
    if args.what == "sites":
        Wd.ensure_server()
        return print("demo sites and mail are up (log: %s)" % (Wd.CACHE / "server.log"))
    if args.what == "cli" and not args.more and args.terminal:
        world = world_name("cli")
        if not Wd.pid_of(world):
            open_scene("cli")
        return open_terminal(world)
    if args.what not in SCENES:
        raise SystemExit("No scene %r. ./demo lists them." % args.what)
    size = None
    if args.size:
        w, h = args.size.lower().split("x")
        size = (int(w), int(h))
    open_scene(args.what, again=args.more == "again", background=args.background, size=size, pretend=args.pretend, stage=args.stage,
               frame=args.frame)


if __name__ == "__main__":
    main()
