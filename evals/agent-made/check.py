#!/usr/bin/env python3
"""save_file and copy end to end (docs/agent-asks.md, wave 1), in a test
world with a stand-in Claude (stand_in.py) calling them through the real
`yab mcp` Yab gives it:

- files: Team.csv (48 rows) and Talks.ics (4 events) land in the task's
  folder under ~/Downloads/yab, their cards under the answer in the chat
  ("48 rows", "4 events"), and the 14 addresses on the clipboard, the chat
  saying "Copied · 14 addresses" with Copy Again; light and dark;
- link: the page's link with its title, rich (HTML and RTF) and as a
  #:~:text= address to the paragraph;
- thefile: a saved file put on the clipboard as the file;
- outside: a file outside the task's folder is refused, and a name with
  folders in it lands in the task's folder all the same;
- the answer card at the page's foot (⌘J's line): "Copied · 14 addresses",
  Copy Again, and ⌘C putting them back after something else was copied.

Each state is a picture of the window (winshot) in --out.

    ./farm exec --display --name "Save file and copy" -- \\
        bash evals/qa-batch/run.sh evals/agent-made/check.py
"""
import argparse, http.server, json, os, shutil, subprocess, sys, tempfile, threading, time
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import yab_socket  # noqa: E402
import probe_ocr  # noqa: E402
import probe_app  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--app", required=True)
parser.add_argument("--out", default=None)
OPTS = parser.parse_args()
OUT = OPTS.out or os.environ.get("YAB_FARM_OUT") or os.path.join(tempfile.mkdtemp(prefix="yab-made-"), "agent-made")
os.makedirs(OUT, exist_ok=True)
WORLD = "agentmade" + os.environ.get("SLOT", "x")[-6:]
FOLDER = os.path.expanduser(f"~/Library/Application Support/Pane ({WORLD})")
SUITE = f"dev.serafim.fast.test.{WORLD}"
FAILS = []
MARK = 0.0
ask = yab_socket.asker(os.path.join(FOLDER, "bench.sock"))
wait_for = yab_socket.wait_for
EMAILS = "\n".join(f"person{n}@example.com" for n in range(1, 15))
QUOTE = "The Velmora lantern walk starts at 21:40 from the north pier."


class Page(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = (f"<!doctype html><meta charset=utf-8><title>Velmora festival</title><h1>Velmora festival</h1>"
                f"<p>{QUOTE}</p><ul>" + "".join(f"<li>person{n}@example.com</li>" for n in range(1, 15)) + "</ul>")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        self.wfile.write(body.encode())

    def log_message(self, *_):
        pass


def check(what, ok, detail=""):
    print(("✓ " if ok else "✗ ") + what + ("" if ok else f": {str(detail)[:600]}"), flush=True)
    if not ok: FAILS.append(what)


def shot(name):
    time.sleep(1.0)
    path = os.path.join(OUT, name + ".png")
    ask({"do": "winshot", "path": path})
    print("  picture", path, flush=True)
    return path


def words(path, part=None):
    """What a person reads in a picture: "column" its right third, "page"
    the rest."""
    if part:
        width = int(subprocess.run(["sips", "-g", "pixelWidth", path], capture_output=True, text=True).stdout.split()[-1])
        height = int(subprocess.run(["sips", "-g", "pixelHeight", path], capture_output=True, text=True).stdout.split()[-1])
        edge = int(width * 0.6)
        box = (edge, 0, width - edge, height) if part == "column" else (0, 0, edge, height)
        return " ".join(probe_ocr.words(path, box))
    return " ".join(probe_ocr.words(path))


def board(kind):
    """The clipboard's `kind` (public.utf8-plain-text, public.html, …) as
    text, read with AppKit through JXA."""
    script = f"ObjC.import('AppKit'); var s = $.NSPasteboard.generalPasteboard.stringForType('{kind}'); s.isNil() ? '' : s.js"
    return subprocess.run(["osascript", "-l", "JavaScript", "-e", script], capture_output=True, text=True).stdout.rstrip("\n")


def board_types():
    script = "ObjC.import('AppKit'); ObjC.deepUnwrap($.NSPasteboard.generalPasteboard.types).join(',')"
    return subprocess.run(["osascript", "-l", "JavaScript", "-e", script], capture_output=True, text=True).stdout.strip().split(",")


def put_on_board(text):
    subprocess.run(["pbcopy"], input=text, text=True)


def chat_items(session):
    try: return json.load(open(os.path.join(FOLDER, "chats", session + ".json"))).get("items", [])
    except (OSError, ValueError): return []


def until_over(session, seconds=60):
    end = time.monotonic() + seconds
    got = {}
    while time.monotonic() < end:
        got = ask({"do": "agent-wait", "session": session, "seconds": 5}, timeout=25)
        if got.get("state") not in ("running", "starting", "waiting", None): break
    return got


def run(prompt):
    global MARK
    MARK = time.time()
    started = ask({"do": "agent-run", "prompt": prompt, "cli": "claude", "access": "browser"})
    session = started.get("session", "")
    ask({"do": "agent-chat", "action": "show", "session": session})
    got = until_over(session, 60)
    check(f"{prompt.split(':')[0]}: the task ends done", got.get("state") == "done", got)
    return session, got


def extras(session, key):
    return [i["extra"][key] for i in chat_items(session) if (i.get("extra") or {}).get(key)]


def saved(after):
    """The paths save_file answered with since `after`, from the stand-in's log."""
    out = []
    for line in open(LOG).read().splitlines():
        stamp, _, rest = line.partition(" ")
        if float(stamp) >= after and rest.startswith("TOOL save_file Saved: "):
            out.append(rest[len("TOOL save_file Saved: "):].split(" | ")[0].rsplit(" (", 1)[0])
    return out


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Page)
threading.Thread(target=server.serve_forever, daemon=True).start()
URL = f"http://127.0.0.1:{server.server_address[1]}/festival"
LOG = os.path.join(OUT, "claude.log"); open(LOG, "w").close()
subprocess.run(["defaults", "delete", SUITE], stderr=subprocess.DEVNULL)
for key in ("bench", "welcomed", "spaces"):
    subprocess.run(["defaults", "write", SUITE, key, "-bool", "true"])
subprocess.run(["defaults", "write", SUITE, "agents.asking", "bypass"])
# No Developer Mode card over the fixture's page: the answer card is the one looked at.
subprocess.run(["defaults", "write", SUITE, "dev.offer", "-bool", "false"])
shutil.rmtree(os.path.join(FOLDER, "chats"), ignore_errors=True)
fixture = shutil.copy2(os.path.join(HERE, "stand_in.py"), os.path.join(OUT, "stand_in.py"))
os.chmod(fixture, 0o755)
env = {"YAB_PROBE": WORLD, "YAB_HISTORY": "own", "YAB_AGENT_CLAUDE": fixture, "AGENT_MADE_LOG": LOG, "AGENT_MADE_PAGE": URL}
app = probe_app.launch(OPTS.app, env, OUT, task_name="Save file and copy", extra_env_names=("AGENT_MADE_LOG", "AGENT_MADE_PAGE"))
made = []
try:
    wait_for(lambda: ask({"do": "census"}).get("pid"), 30)
    ask({"do": "flood", "urls": [URL]})
    tab = wait_for(lambda: next((t for t in ask({"do": "tabs"})["tabs"] if "festival" in t.get("url", "")), None), 15)
    ask({"do": "select", "id": tab["id"]})
    time.sleep(2)

    # 1. Files and the addresses, in the chat.
    session, got = run("files: make me a sheet of the team and the talks as a calendar, and copy the emails")
    files = saved(MARK)
    made += files
    check("files: the chat's steps hold the files", wait_for(lambda: extras(session, "file") == files, 10), extras(session, "file"))
    check("files: two files saved", len(files) == 2 and [os.path.basename(f) for f in files] == ["Team.csv", "Talks.ics"], files)
    # A test world downloads into its own folder; yours, ~/Downloads/yab.
    downloads = os.path.join(FOLDER, "Downloads", "yab") + "/"
    check("files: in the task's folder under Downloads/yab", files and all(f.startswith(downloads) and os.path.dirname(f) == os.path.dirname(files[0]) for f in files), files)
    if files:
        team = open(files[0]).read()
        check("files: Team.csv as written", team.count("\n") == 49 and team.startswith("name,email,team\n"), team[:200])
        check("files: Talks.ics as written", open(files[1]).read().count("BEGIN:VEVENT") == 4)
    check("copy: the addresses on the clipboard", board("public.utf8-plain-text") == EMAILS, board("public.utf8-plain-text")[:200])
    check("copy: the step says what", wait_for(lambda: extras(session, "copied") == ["14 addresses"], 10), extras(session, "copied"))
    for look in ("light", "dark"):
        ask({"do": "ui", "look": look}); time.sleep(0.8)
        seen = words(shot(f"1-chat-{look}"), "column")
        check(f"chat ({look}): the CSV's card says 48 rows", "Team.csv" in seen and "48 rows" in seen, seen[-600:])
        check(f"chat ({look}): the calendar's card says 4 events", "Talks.ics" in seen and "4 events" in seen, seen[-600:])
        check(f"chat ({look}): Copied · 14 addresses, and Copy Again", "Copied" in seen and "14 addresses" in seen and "Copy Again" in seen, seen[-600:])
    ask({"do": "ui", "look": "light"})

    # 2. A link with its title, to a paragraph.
    session, got = run("link: copy a link to the lantern walk")
    expected = URL + "#:~:text=The%20Velmora%20lantern%20walk,from%20the%20north%20pier."
    check("link: plain text is the paragraph's address", board("public.utf8-plain-text") == expected, board("public.utf8-plain-text"))
    html = board("public.html")
    check("link: rich, its title linked", html == f'<a href="{expected}">Velmora festival</a>', html)
    check("link: RTF too", "public.rtf" in board_types(), board_types())
    check("link: the line says what", wait_for(lambda: extras(session, "copied") == ["Link to the paragraph"], 10) or extras(session, "copied") == ["Link to the paragraph"], extras(session, "copied"))
    seen = words(shot("2-link"), "column")
    check("link: the chat says Copied · Link to the paragraph", "Copied" in seen and "Link to the paragraph" in seen, seen[-400:])

    # 3. A saved file, as the file.
    session, got = run("thefile: save a report and copy it")
    files = saved(MARK)
    made += files
    check("thefile: Report.json saved", files and files[0].endswith("/Report.json"), files)
    url = board("public.file-url")
    check("thefile: the clipboard holds the file", files and url.startswith("file://") and url.rstrip("/").endswith("Report.json"), url)
    seen = words(shot("3-file"), "column")
    check("thefile: its card says 3 items", "3 items" in seen, seen[-400:])

    # 4. Outside the task's folder.
    session, got = run("outside: copy /etc/hosts")
    said = got.get("result") or ""
    check("outside: /etc/hosts refused", "task's folder" in said and "Copied" not in said.split("]")[0], said)
    files = saved(MARK)
    made += files
    check("outside: ../../escape.csv lands in the task's folder", files and files[0].startswith(downloads) and files[0].endswith("/escape.csv"), files)

    # 5. The answer card at the page's foot, and ⌘C copying again.
    ask({"do": "agent-chat", "action": "hide"})
    ask({"do": "select", "id": tab["id"]})
    # ⌘J's line opened on the page first, so the page goes with the words
    # and the answer stays at its foot (agent-basics does the same).
    ask({"do": "agent-page-ask", "how": "line"})
    time.sleep(1.2)
    sent = ask({"do": "agent-page-ask", "how": "line", "words": "emails: copy all the emails on this page"})
    card = sent.get("session", "")
    got = until_over(card, 40)
    check("card: the ask ends done", got.get("state") == "done", got)
    check("card: the addresses on the clipboard", board("public.utf8-plain-text") == EMAILS)
    for look in ("light", "dark"):
        ask({"do": "ui", "look": look}); time.sleep(0.8)
        seen = words(shot(f"5-card-{look}"), "page")
        check(f"card ({look}): Copied · 14 addresses and Copy Again", "Copied" in seen and "14 addresses" in seen and "Copy Again" in seen, seen[-600:])
    ask({"do": "ui", "look": "light"})
    put_on_board("something else")
    ask({"do": "chord", "id": tab["id"], "keys": "cmd+c", "wait": 0.6})
    check("card: ⌘C puts the addresses back", wait_for(lambda: board("public.utf8-plain-text") == EMAILS, 3), board("public.utf8-plain-text")[:80])
    seen = words(shot("5-card-again"), "page")
    check("card: the button says Copied a moment", "Copied" in seen, seen[-400:])

    # 6. The same ask as a task in tabs of its own, the chat put away: the
    # corner's line is the answer's first sentence, no clip id, not cut.
    ask({"do": "agent-chat", "action": "hide"})
    tab_line = ask({"do": "agent-page-ask", "how": "line", "words": "emails: copy every email on this page"})
    until_over(tab_line.get("session", ""), 40)
    time.sleep(0.3)
    seen = words(shot("6-corner"))
    check("corner: the answer's first sentence", "Copied the 14 addresses on this page." in seen, seen[:400])
    check("corner: no clip id", "clip" not in seen.lower(), seen[:400])
finally:
    app.terminate()
    server.shutdown()
    print("files made:", made, flush=True)
    print(open(LOG).read()[-3000:], flush=True)
print(f"evidence in {OUT}")
print("FAIL" if FAILS else "PASS", FAILS)
sys.exit(1 if FAILS else 0)
