"""Builds a demo world: Mira's browser, as it is the moment it's built.

A world is a YAB_PROBE world ("Pane (demo-<scene>)" under Application
Support, settings suite net.serubin.pane.test.demo-<scene>), run by the demo
copy of Yab (`./demo install`), whose bundle id is its own so it has no
access the real Yab was given: no calendar, contacts or Messages.

Building one: quit it if it runs, wipe its folder and settings, write the
files Yab reads at launch (spaces, tabs, history, bookmarks, downloads,
memory, the notebook, routines, the new tab's rows, icons, a home of its
own for the file picker), write its settings, open it, and then, through
its bench socket, what only the running app can make: keychain items
(passwords, 2FA keys, cards, addresses), the two mail accounts (work and
personal) on the made-up Gmail, replies written ahead, the day's meetings.
"""
import json
import os
import plistlib
import shutil
import signal
import socket
import sqlite3
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import persona as P  # noqa: E402

HOME = Path.home()
CACHE = HOME / "Library/Caches/yab-demo"
APP = Path(os.environ.get("YAB_DEMO_APP", str(HOME / "Applications/Yab Demo/Yab.app")))
BUNDLE = "net.serubin.pane.demo"
MAIL = "http://127.0.0.1:8795"
STATE = CACHE / "state.json"


def folder(world):
    return HOME / "Library/Application Support" / ("Pane (%s)" % world)


def suite(world):
    return "net.serubin.pane.test." + world


def say(text):
    print(text, flush=True)


# ---------------------------------------------------------------- the running app

def pid_of(world):
    lock = folder(world) / "yab.lock"
    try:
        pid = int(lock.read_text().strip().split()[0])
    except (OSError, ValueError, IndexError):
        return None
    try:
        os.kill(pid, 0)
    except OSError:
        return None
    command = subprocess.run(["ps", "-p", str(pid), "-o", "comm="], capture_output=True, text=True).stdout.strip()
    return pid if command.endswith("/MacOS/pane") or command == "pane" else None


def quit_world(world):
    """Quit this world's Yab, if it runs: only its own process."""
    pid = pid_of(world)
    if not pid:
        return False
    os.kill(pid, signal.SIGTERM)
    for _ in range(50):
        time.sleep(0.1)
        try:
            os.kill(pid, 0)
        except OSError:
            return True
    os.kill(pid, signal.SIGKILL)
    time.sleep(0.3)
    return True


def bench(world, request, timeout=30):
    """One request on the world's socket, its answer as a dict."""
    path = str(folder(world) / "bench.sock")
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(timeout)
        s.connect(path)
        s.sendall((json.dumps(request) + "\n").encode())
        data = b""
        while not data.endswith(b"\n"):
            chunk = s.recv(65536)
            if not chunk:
                break
            data += chunk
    try:
        return json.loads(data or b"{}")
    except ValueError:
        return {"raw": data.decode("utf-8", "replace")}


def wait_for_socket(world, seconds=40):
    path = folder(world) / "bench.sock"
    end = time.time() + seconds
    while time.time() < end:
        if path.exists():
            try:
                bench(world, {"do": "tabs"}, timeout=5)
                return True
            except OSError:
                pass
        time.sleep(0.3)
    return False


# ---------------------------------------------------------------- the sites server

def server_up():
    try:
        urllib.request.urlopen(MAIL + "/fake/state", timeout=1).read()
        return True
    except OSError:
        return False


def ensure_server():
    """The sites and the mail, started once and left running (./demo stop ends them)."""
    if server_up():
        return
    CACHE.mkdir(parents=True, exist_ok=True)
    log = open(CACHE / "server.log", "ab")
    process = subprocess.Popen([sys.executable, str(HERE / "server.py")], stdout=log, stderr=log,
                               stdin=subprocess.DEVNULL, start_new_session=True)
    (CACHE / "server.pid").write_text(str(process.pid))
    for _ in range(50):
        if server_up():
            return
        time.sleep(0.2)
    raise SystemExit("The demo sites didn't start: see %s" % (CACHE / "server.log"))


def stop_server():
    try:
        pid = int((CACHE / "server.pid").read_text())
        os.kill(pid, signal.SIGTERM)
    except (OSError, ValueError):
        pass


def reset_mail():
    request = urllib.request.Request(MAIL + "/__demo/reset", data=b"{}", headers={"Content-Type": "application/json"})
    return json.loads(urllib.request.urlopen(request, timeout=5).read())


# ---------------------------------------------------------------- icons

def host_of(url):
    return (urllib.parse.urlsplit(url).hostname or "").lower()


def icon_for(host):
    """A 64 pt PNG for a host: a made-up site's own, else the site's real
    icon, fetched once into the cache."""
    sites = {"localhost": "tern-dev"}
    if host.endswith(".localtest.me"):
        sites[host] = host.split(".")[0]
    name = sites.get(host)
    if name:
        own = HERE / "sites" / name / "favicon.png"
        return own if own.exists() else None
    cached = CACHE / "icons" / (host + ".png")
    if cached.exists():
        return cached if cached.stat().st_size > 0 else None
    cached.parent.mkdir(parents=True, exist_ok=True)
    try:
        url = "https://www.google.com/s2/favicons?sz=64&domain=" + urllib.parse.quote(host)
        data = urllib.request.urlopen(url, timeout=6).read()
        cached.write_bytes(data if data[:8] == b"\x89PNG\r\n\x1a\n" else b"")
    except OSError:
        cached.write_bytes(b"")
    return cached if cached.stat().st_size > 0 else None


# ---------------------------------------------------------------- the files

def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=1))


def diary_key(url):
    parts = urllib.parse.urlsplit(url)
    host = (parts.hostname or "").lower()
    host = host[4:] if host.startswith("www.") else host
    path = parts.path or "/"
    if len(path) > 1 and path.endswith("/"):
        path = path[:-1]
    query = "&".join(q for q in parts.query.split("&") if q and not q.split("=")[0].lower().startswith("utm_"))
    return host + path + ("?" + query if query else "")


def history_key(url):
    parts = urllib.parse.urlsplit(url)
    host = (parts.hostname or "").lower()
    host = host[4:] if host.startswith("www.") else host
    path = parts.path.lower().rstrip("/")
    return host + path


def write_history(root, now):
    """diary.sqlite (the history page, agents, habits) and history.json (the field)."""
    seen = P.visits(now)
    db = sqlite3.connect(root / "diary.sqlite")
    db.executescript("""
        PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v TEXT);
        CREATE TABLE IF NOT EXISTS visits(id INTEGER PRIMARY KEY, key TEXT NOT NULL, at REAL NOT NULL);
        CREATE INDEX IF NOT EXISTS visits_at ON visits(at);
        CREATE INDEX IF NOT EXISTS visits_key ON visits(key);
        CREATE TABLE IF NOT EXISTS pages(
          key TEXT PRIMARY KEY, url TEXT NOT NULL, title TEXT NOT NULL DEFAULT '', host TEXT NOT NULL,
          count INTEGER NOT NULL DEFAULT 0, last REAL NOT NULL, read REAL);
        CREATE INDEX IF NOT EXISTS pages_host ON pages(host);
        CREATE TABLE IF NOT EXISTS looks(key TEXT PRIMARY KEY, image TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS looks_image ON looks(image);
        CREATE VIRTUAL TABLE IF NOT EXISTS words USING fts5(
          key UNINDEXED, kind UNINDEXED, title, body, tokenize='unicode61 remove_diacritics 2');
    """)
    db.execute("INSERT OR REPLACE INTO meta VALUES('version','2')")
    db.execute("INSERT OR REPLACE INTO meta VALUES('seeded','1')")
    pages = {}
    for url, title, at in seen:
        key = diary_key(url)
        host = key.split("/")[0].split("?")[0]
        db.execute("INSERT INTO visits(key, at) VALUES(?, ?)", (key, at))
        page = pages.setdefault(key, {"url": url, "title": title, "host": host, "count": 0, "last": 0})
        page["count"] += 1
        page["last"] = max(page["last"], at)
    for key, page in pages.items():
        db.execute("INSERT OR REPLACE INTO pages(key, url, title, host, count, last, read) VALUES(?,?,?,?,?,?,NULL)",
                   (key, page["url"], page["title"], page["host"], page["count"], page["last"]))
        db.execute("INSERT INTO words(key, kind, title, body) VALUES(?, 0, ?, ?)", (key, page["title"], key))
    db.commit()
    db.close()
    field = {}
    for url, title, at in seen:
        key = history_key(url)
        entry = field.setdefault(key, {"url": url, "key": key, "title": title, "count": 0, "last": 0})
        entry["count"] += 1
        entry["last"] = max(entry["last"], P.apple(at))
    typed = {"daybook.localtest.me", "news.ycombinator.com", "theverge.com", "linear.app/tern/view/my-issues"}
    for key, entry in field.items():
        if key in typed:
            entry["typed"] = max(1, entry["count"] // 3)
    write_json(root / "history.json", sorted(field.values(), key=lambda e: -e["last"]))
    return pages


def write_tabs(root, now, scene):
    rows = P.tabs(now)
    for space_id, extra in scene.get("tabs", {}).items():
        rows[space_id] = rows[space_id] + [P.tab(url, title, now - 60 * n) for n, (url, title) in enumerate(extra, 1)]
    for space_id, entries in rows.items():
        active = 0
        want = scene.get("front", {}).get(space_id)
        for n, entry in enumerate(entries):
            if want and want in entry["url"].replace(":8800", ""):
                active = n
                break
        else:
            # Today's first tab, past the pins and kept ones.
            active = next((n for n, e in enumerate(entries) if not e.get("pin") and not e.get("kept")), 0)
        name = "session.json" if space_id == P.PERSONAL else "session-%s.json" % space_id
        write_json(root / name, {"tabs": entries, "active": active})
    spaces = []
    for space in P.SPACES:
        spaces.append({"id": space["id"], "name": space["name"], "icon": space["icon"], "ownSignIns": False,
                       "paint": {"swatch": "custom", "color": space["color"], "grain": True, "grainAmount": 0.35}})
    write_json(root / "spaces.json", spaces)
    return rows


def write_icons(root, hosts):
    icons = root / "icons"
    icons.mkdir(parents=True, exist_ok=True)
    for host in sorted(hosts):
        source = icon_for(host)
        if source:
            shutil.copyfile(source, icons / (host + ".png"))


def write_memory(root, now):
    memory = root / "memory"
    for path, text in P.memory(now).items():
        target = memory / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)
    (memory / ".layout").write_text("2")


def write_files(root, now):
    """The world's own home for the file picker, and its downloads."""
    import files
    made = files.make()
    home = root / "Home"
    downloads = root / "Downloads"
    entries = []
    for place, name, source, minutes, page, title in files.PLACES:
        target = (downloads if place == "Downloads" else home / place) / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(made[source], target)
        when = now - minutes * 60
        os.utime(target, (when, when))
        if place == "Downloads":
            entries.append({"name": name, "from": host_of(page), "path": str(target), "date": P.apple(when),
                            "page": page, "pageTitle": title})
    write_json(root / "downloads.json", sorted(entries, key=lambda e: -e["date"]))


def settings(scene, now):
    """The world's settings suite, before launch."""
    space = scene.get("space", P.WORK)
    color = next(s["color"] for s in P.SPACES if s["id"] == space)
    values = {
        "welcomed": True, "bench": True, "spaces": True, "sidebar": True, "look": "light",
        "space.current": space, "window.00000000-0000-0000-0000-000000000002.space": space,
        "backdrop": "color", "backdrop.swatch": "custom", "backdrop.color": color,
        "backdrop.grain": True, "backdrop.grain.amount": 0.35,
        "agents.watch": False, "agents.watched": now, "agents.forget": True, "agents.asking": "auto",
        "codes.texts": False, "codes.mail": True,
        "dev.offer": False, "devSites": {"localhost:5173": True},
        "hints.dismissed": ["setup.memory", "setup.watch", "setup.cli"],
        "tabs.tidy": 12, "player.shown": True, "float.leave": True,
        "mail.undo": 10, "mail.agents": True,
    }
    values.update(scene.get("prefs", {}))
    return values


def write_settings(world, values):
    subprocess.run(["defaults", "delete", suite(world)], capture_output=True)
    plist = CACHE / ("%s.plist" % world)
    plist.parent.mkdir(parents=True, exist_ok=True)
    clean = {}
    for key, value in values.items():
        if isinstance(value, float) and key in ("agents.watched",):
            import datetime as dt
            value = dt.datetime.fromtimestamp(value, dt.timezone.utc).replace(tzinfo=None)
        clean[key] = value
    with open(plist, "wb") as f:
        plistlib.dump(clean, f)
    subprocess.run(["defaults", "import", suite(world), str(plist)], check=True)


def screen_frame():
    """The main screen's visible frame, as AppKit counts it."""
    script = ("ObjC.import('AppKit'); var f = $.NSScreen.mainScreen.visibleFrame; var s = $.NSScreen.mainScreen.frame;"
              "[f.origin.x, f.origin.y, f.size.width, f.size.height, s.size.width, s.size.height].join(' ')")
    out = subprocess.run(["osascript", "-l", "JavaScript", "-e", script], capture_output=True, text=True).stdout.split()
    try:
        return [float(v) for v in out]
    except ValueError:
        return [0, 0, 1440, 875, 1440, 900]


FRAMES = {"4:3": (1200, 900), "square": (900, 900), "16:9": (1440, 810)}


def place_window(world, size=None, park=False, frame="4:3"):
    """Where the window opens, the same every take: centered at a frame's
    size (4:3 by default, what a wide export wants), the screen's whole
    visible frame ("screen"), a size asked for, or (park) mostly past the
    screen's edge, for checking a world without covering anyone's work."""
    x, y, w, h, sw, sh = screen_frame()
    want = size or FRAMES.get(frame)
    if want:
        width, height = want
        fit = min(1.0, (w - 32) / width, (h - 32) / height)
        width, height = int(width * fit), int(height * fit)
        x, y, w, h = x + (w - width) / 2, y + (h - height) / 2, width, height
    if park:
        x, w, h = sw - 60, 1440, 900
    frame_words = "%d %d %d %d 0 0 %d %d" % (x, y, w, h, sw, sh)
    subprocess.run(["defaults", "write", BUNDLE, "NSWindow Frame yab (%s)" % world, frame_words], check=True)
    return x, y, w, h


# ---------------------------------------------------------------- building

def build(world, scene, now=None, background=False, size=None, frame=None):
    """The whole world, from nothing, open and seeded."""
    if not APP.exists():
        raise SystemExit("No demo app at %s: run ./demo install first." % APP)
    now = now or time.time()
    ensure_server()
    quit_world(world)
    root = folder(world)
    shutil.rmtree(root, ignore_errors=True)
    root.mkdir(parents=True)
    meeting, events = P.events(now)
    shift = scene.get("meeting_in")
    if shift is not None:
        delta = now + shift * 60 - meeting["start"]
        meeting = dict(meeting, start=meeting["start"] + delta, end=meeting["end"] + delta)
        events = [meeting] + events[1:]
    write_json(STATE, {"built": now, "persona": P.MIRA, "meeting": meeting, "events": events,
                       "night": P.design_night(now), "trip": [str(d) for d in P.trip(now)]})
    reset_mail()
    rows = write_tabs(root, now, scene)
    pages = write_history(root, now)
    write_json(root / "bookmarks.json", P.bookmarks(now))
    write_files(root, now)
    write_json(root / "hints.json", [] if scene.get("no_hints") else P.hints(now))
    write_json(root / "routines.json", P.routines(now))
    write_json(root / "profile.json", P.profile(now))
    answers = [dict(a, at=P.iso(now - 20 * 86400)) for a in P.ANSWERS]
    write_json(root / "answers.json", answers)
    write_memory(root, now)
    if scene.get("know", True):
        write_json(root / "know.json", P.know_report(now))
    hosts = {host_of(e["url"]) for entries in rows.values() for e in entries}
    hosts |= {host_of(page["url"]) for page in pages.values()}
    for item in P.bookmarks(now):
        for child in item.get("children", [item]):
            if child.get("url"):
                hosts.add(host_of(child["url"]))
    hosts |= {"mail.google.com", "figma.com", "flysas.com", "drift.localtest.me", "roundtable.localtest.me"}
    write_icons(root, {h for h in hosts if h})
    for name, text in scene.get("files", {}).items():
        (root / name).parent.mkdir(parents=True, exist_ok=True)
        (root / name).write_text(text)
    write_settings(world, settings(scene, now))
    place_window(world, size=size, park=background, frame=frame or scene.get("frame", "4:3"))
    env = {"YAB_PROBE": world, "YAB_HISTORY": "own", "YAB_RECORDING": "1"}
    env.update(scene.get("env", {}))
    command = ["open", "-n"] + (["-g"] if background else []) + ["-a", str(APP)]
    for key, value in env.items():
        command += ["--env", "%s=%s" % (key, value)]
    subprocess.run(command, check=True)
    if not wait_for_socket(world):
        raise SystemExit("Yab didn't open the world %s (no bench socket)." % world)
    seed(world, scene, meeting, now)
    return root


def seed(world, scene, meeting, now):
    """What only the running app can make."""
    answer = bench(world, {"do": "box", "act": "seed-world", "logins": P.logins(now), "cards": P.cards(now),
                           "addresses": P.addresses(now), "meetingHosts": ["localhost"],
                           "calendarHosts": ["daybook.localtest.me"]})
    if scene.get("mail", True):
        # Work and personal, each its own mailbox on the made-up Gmail.
        for box, account in (("work", P.MIRA["work_email"]), ("personal", P.MIRA["email"])):
            bench(world, {"do": "agent-mail-account", "base": "%s/%s/gmail/v1/users/me/" % (MAIL, box), "account": account})
        bench(world, {"do": "agent-mail-writer-fake", "text": json.dumps(P.REPLIES)})
    minutes = max(1, round((meeting["start"] - time.time()) / 60))
    bench(world, {"do": "call", "action": "meetings",
                  "list": [{"title": meeting["title"], "in": minutes, "for": 30, "link": meeting["link"]}]})
    for request in scene.get("after", []):
        if callable(request):
            request(world)
        else:
            bench(world, request, timeout=60)
    return answer
