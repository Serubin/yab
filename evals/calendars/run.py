#!/usr/bin/env python3
"""Calendar pins in a test world (docs/meetings-on-tabs.md): a pinned
calendar with nothing connected says "No calendar connected" with Connect,
which opens Settings › Mail; with a Google account whose consent gave the
calendar list, the pin's Today lists every calendar it shows, a meeting in
two of them once, the other calendar's name beside its own; without the
list, the primary alone, and the list never asked for.

    python3 evals/calendars/run.py --app "build/Pane Dev.app"
"""
import argparse, json, os, socket, subprocess, sys, time, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "mail"))
sys.path.insert(0, os.path.join(HERE, ".."))
from fake_gmail import FakeGmail  # noqa: E402
import yab_socket  # noqa: E402

WORLD = "calendars-" + os.environ.get("SLOT", "x")[-8:]
FOLDER = os.path.expanduser(f"~/Library/Application Support/Pane ({WORLD})")
SOCK = os.path.join(FOLDER, "bench.sock")
ME = "mira@ternlabs.com"
TEAM = "c_team@group.calendar.google.com"
FAILS = []
ask = yab_socket.asker(SOCK, timeout=60)


def check(what, ok, detail=""):
    print(("✓ " if ok else "✗ ") + what + ("" if ok else f": {detail}"), flush=True)
    if not ok:
        FAILS.append(what)


def glance(tab, **more):
    return ask({"do": "glance", "id": tab, **more})


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True)
    parser.add_argument("--exe", default="yab")
    opts = parser.parse_args()

    fake = FakeGmail(me=ME)
    fake.add("hello", "Dan <dan@ternlabs.com>", "Hello", "Hi.", ["INBOX"])
    now = int(time.time())
    fake.calendars = [{"id": ME, "summary": ME, "primary": True, "selected": True},
                      {"id": TEAM, "summary": "Team", "selected": True},
                      {"id": "c_off@group.calendar.google.com", "summary": "Unticked", "selected": False}]
    fake.calendar = [dict(summary="Design sync", start=now + 1200, end=now + 3000, uid="sync@fake"),
                     dict(summary="Design sync", start=now + 1200, end=now + 3000, uid="sync@fake", calendar=TEAM),
                     dict(summary="Launch review", start=now + 2400, end=now + 4200, uid="launch@fake", calendar=TEAM),
                     dict(summary="Hidden one", start=now + 2400, end=now + 4200, uid="off@fake", calendar="c_off@group.calendar.google.com")]
    port = fake.start(0)
    base = f"http://127.0.0.1:{port}/gmail/v1/users/me/"

    suite = f"dev.serafim.fast.test.{WORLD}"
    subprocess.run(["defaults", "delete", suite], stderr=subprocess.DEVNULL)
    for key in ("bench", "welcomed"):
        subprocess.run(["defaults", "write", suite, key, "-bool", "true"])
    subprocess.run(["rm", "-rf", os.path.join(FOLDER, "mail"), os.path.join(FOLDER, "session.json")])
    page = os.path.join(FOLDER, "calendar.html")
    os.makedirs(FOLDER, exist_ok=True)
    with open(page, "w") as f:
        f.write("<title>Calendar</title><body style='font:15px -apple-system'>A calendar</body>")
    # Served over http, so the page has a host the bench can count as a calendar's.
    with socket.socket() as free:
        free.bind(("127.0.0.1", 0))
        web = free.getsockname()[1]
    server = subprocess.Popen([sys.executable, "-m", "http.server", str(web), "--bind", "127.0.0.1", "--directory", FOLDER],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    proc = subprocess.Popen([os.path.join(opts.app, "Contents/MacOS", opts.exe)],
                            env={**os.environ, "YAB_PROBE": WORLD, "YAB_HISTORY": "own"},
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        ask({"do": "probe"})
        stage = os.environ.get("YAB_STAGE") or os.path.join(HERE, "..", "..", "stage")
        if os.path.exists(stage):
            subprocess.run([stage, "put", str(proc.pid), "1"], capture_output=True)
        tab = ask({"do": "open", "url": f"http://127.0.0.1:{web}/calendar.html"})["id"]
        time.sleep(2)
        ask({"do": "call", "action": "calendar", "id": tab})
        time.sleep(1)

        # Nothing connected: the tab's own card, saying so, with Connect.
        card = glance(tab)
        print("  empty:", json.dumps(card), flush=True)
        if card.get("items") is not None:
            print("  the Mac's calendars are let in for this world: the empty card can't show here")
        else:
            check("empty pin: No calendar connected", card.get("now") == "No calendar connected", card)
            check("empty pin: Connect", card.get("button") == "Connect", card)
            # Mail on, as a person who reaches Settings › Mail has it (off, Connect asks
            # the Mac for its calendars instead, which a test world can't answer).
            ask({"do": "agent-mail-settings", "on": True})
            pressed = glance(tab, press=True)
            time.sleep(1)
            check("Connect opens Settings › Mail", glance(tab).get("settings") == "mail", pressed)
            glance(tab, on=False)

        # A Google account whose consent gave the calendar list.
        ask({"do": "agent-mail-account", "base": base, "account": ME, "calendars": True})
        got = yab_socket.wait_for(lambda: (lambda c: c if len(c.get("items") or []) >= 2 else None)(glance(tab)), 30, 1)
        items = (got or glance(tab)).get("items") or []
        titles = [i["title"] for i in items]
        print("  listed:", titles, flush=True)
        check("every ticked calendar, a meeting in two once", sorted(titles) == ["Design sync", "Launch review (Team)"], titles)
        calls = json.loads(urllib.request.urlopen(f"http://127.0.0.1:{port}/fake/calls").read())["calls"]
        check("the list was asked, the unticked calendar not read", "GET calendar/calendarList" in calls
              and not any("c_off" in c for c in calls), [c for c in calls if "calendar" in c])
        glance(tab, on=False)

        # Connected again without the list: the primary alone, the list never asked.
        ask({"do": "agent-mail-account", "remove": True, "account": ME})
        time.sleep(1)
        left = glance(tab)
        check("the last account gone: its meetings with it", not (left.get("items") or []), left)
        glance(tab, on=False)
        before = len(json.loads(urllib.request.urlopen(f"http://127.0.0.1:{port}/fake/calls").read())["calls"])
        ask({"do": "agent-mail-account", "base": base, "account": ME, "calendars": False})
        got = yab_socket.wait_for(lambda: (lambda c: c if (c.get("items") or []) else None)(glance(tab)), 30, 1)
        titles = [i["title"] for i in (got or {}).get("items") or []]
        print("  primary only:", titles, flush=True)
        check("without the list: the primary alone", titles == ["Design sync"], titles)
        calls = json.loads(urllib.request.urlopen(f"http://127.0.0.1:{port}/fake/calls").read())["calls"][before:]
        check("without the list: the list never asked", "GET calendar/calendarList" not in calls, [c for c in calls if "calendar" in c])
        # Its row in Settings › Mail offers the list, at a press (drawn, to look at).
        ask({"do": "ui", "page": "mail", "settings": True})
        time.sleep(2)
        shot = ask({"do": "winshot", "settings": True, "path": os.path.abspath("calendars-settings-mail.png")})
        print("  settings:", shot.get("path") or shot, flush=True)
    finally:
        proc.terminate()
        server.terminate()
    print("FAILED: " + ", ".join(FAILS) if FAILS else "all passed")
    sys.exit(1 if FAILS else 0)


if __name__ == "__main__":
    main()
