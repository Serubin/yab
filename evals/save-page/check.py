#!/usr/bin/env python3
"""save_page end to end (docs/agent-asks.md): asks from ⌘J's chat on real
pages, a stand-in Claude (stand_in.py) calling save_page through Yab's own
MCP server, and the files that come out opened and read:

- "save this page as pdf": Letter pages, more than one, the article's words;
- "export this table to excel" on a page with three tables: the list comes
  back for the agent to ask which; "all of them": one workbook, a sheet a
  table, numbers as numbers, the header bold;
- "the second one as csv": that table's rows, UTF-8 with its mark;
- "both articles in one pdf, reader": an outline entry each, both articles'
  words, none of the ad's;
- "both as markdown": one file, both titles, a rule between;
- every file a card under the answer: the chat's step keeps the file, and
  a picture of the column (winshot) in --out.

    ./farm exec --display --name "Save page" -- \\
        bash evals/qa-batch/run.sh evals/save-page/check.py
"""
import argparse, http.server, json, os, re, shutil, subprocess, sys, tempfile, threading, time, zipfile
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import yab_socket  # noqa: E402
import probe_app  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--app", required=True)
parser.add_argument("--out", default=None)
OPTS = parser.parse_args()
# A farm job's own folder when there is one, so ./farm fetch brings it home.
OUT = os.path.join(os.environ["YAB_FARM_OUT"], "save-page") if os.environ.get("YAB_FARM_OUT") else OPTS.out or os.path.join(tempfile.mkdtemp(prefix="yab-save-page-"), "save-page")
os.makedirs(OUT, exist_ok=True)
WORLD = "savepage" + os.environ.get("SLOT", "x")[-6:]
FOLDER = os.path.expanduser(f"~/Library/Application Support/Pane ({WORLD})")
SUITE = f"dev.serafim.fast.test.{WORLD}"
FAILS = []
ask = yab_socket.asker(os.path.join(FOLDER, "bench.sock"))
wait_for = yab_socket.wait_for

ONE = "The harbor lights at Calder Point were rebuilt in 1911 by a crew of nine."
TWO = "Marrow Hill's orchard keeps forty kinds of pear, most of them older than the town."
AD = "BUY NOW LIMITED OFFER"


def article(title, fact):
    paragraphs = "".join(f"<p>{fact} Paragraph {i} goes on about the place, its people and the weather that shaped them, "
                         f"long enough to fill a line or two on paper and then some more words after that.</p>" for i in range(1, 70))
    return (f"<!doctype html><meta charset=utf-8><title>{title}</title>"
            f"<nav><a href='/'>Home</a> <a href='/about'>About</a></nav>"
            f"<div class='ad-banner'>{AD}</div>"
            f"<article><h1>{title}</h1>{paragraphs}</article>"
            f"<aside class='related'>Related: other stories</aside><footer>© Fixture</footer>")


PRICES = """<!doctype html><meta charset=utf-8><title>Fixture pricing</title><h1>Fixture pricing</h1>
<table><caption>Prices by plan</caption><tr><th>Plan</th><th>Seats</th><th>Price</th></tr>
<tr><td>Free</td><td>1</td><td>0</td></tr><tr><td>Team</td><td>10</td><td>1,200</td></tr><tr><td>Business</td><td>50</td><td>$4,800</td></tr></table>
<h2>Feature comparison</h2>
<table><tr><th>Feature</th><th>Free</th><th>Team</th></tr><tr><td>Sync, "fast"</td><td>No</td><td>Yes</td></tr>
<tr><td>Agents</td><td>1</td><td>5</td></tr><tr><td>Zip codes</td><td>02139</td><td>10001</td></tr></table>
<div role="grid" aria-label="Limits"><div role="row"><span role="columnheader">Limit</span><span role="columnheader">Value</span></div>
<div role="row"><span role="gridcell">Tabs</span><span role="gridcell">500</span></div>
<div role="row"><span role="gridcell">Spaces</span><span role="gridcell">12</span></div></div>"""

PAGES = {"/article-one": article("Calder Point lights", ONE), "/article-two": article("Marrow Hill orchard", TWO), "/prices": PRICES}


class Page(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = PAGES.get(self.path)
        self.send_response(200 if body else 404)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        self.wfile.write((body or "gone").encode())

    def log_message(self, *_):
        pass


def check(what, ok, detail=""):
    print(("✓ " if ok else "✗ ") + what + ("" if ok else f": {str(detail)[:700]}"), flush=True)
    if not ok: FAILS.append(what)


def shot(name):
    time.sleep(1.2)
    path = os.path.join(OUT, name + ".png")
    ask({"do": "winshot", "path": path})
    print("  picture", path, flush=True)


def said_since(mark):
    """The tool answers the stand-in logged after mark."""
    lines = open(LOG).read().splitlines()
    return [json.loads(line.split(" ", 2)[2]) for line in lines if line.split(" ", 2)[1:2] == ["SAID"] and float(line.split(" ", 1)[0]) >= mark]


def saved(said):
    found = re.search(r"Saved: (/.+?)(?: \([^()]*\))?$", said, re.M)
    return found.group(1) if found else ""


def pdf(path):
    got = subprocess.run(["xcrun", "swift", os.path.join(HERE, "pdfinfo.swift"), path], capture_output=True, text=True, timeout=180)
    try: return json.loads(got.stdout)
    except ValueError: return {"error": got.stderr[-500:]}


def chat_items(session):
    try: return json.load(open(os.path.join(FOLDER, "chats", session + ".json"))).get("items", [])
    except (OSError, ValueError): return []


def until_over(session, seconds=120):
    end = time.monotonic() + seconds
    got = {}
    while time.monotonic() < end:
        got = ask({"do": "agent-wait", "session": session, "seconds": 5}, timeout=25)
        if got.get("state") not in ("running", "starting", "waiting", None): break
    return got


def on(path, words, name):
    """Ask in the page's chat on the tab at path; the answer's tool words."""
    tab = next(t for t in ask({"do": "tabs"})["tabs"] if t.get("url", "").endswith(path))
    ask({"do": "select", "id": tab["id"]})
    time.sleep(1.0)
    ask({"do": "agent-page-ask", "how": "chat"})
    time.sleep(1.0)
    mark = time.time()
    sent = ask({"do": "agent-page-ask", "how": "chat", "words": words})
    session = sent.get("session", "")
    check(f"{name}: the ask starts", session, sent)
    got = until_over(session)
    check(f"{name}: done", got.get("state") == "done", got)
    said = " ".join(said_since(mark))
    print(f"  {name}: {said[:300]!r}", flush=True)
    # The chat is written to disk a moment after the turn ends.
    def kept():
        return [i.get("extra", {}).get("file") for i in chat_items(session) if (i.get("extra") or {}).get("file")]
    files = wait_for(kept, 8) or []
    shot(name)
    return said, files


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Page)
threading.Thread(target=server.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{server.server_address[1]}"
LOG = os.path.join(OUT, "claude.log"); open(LOG, "w").close()
subprocess.run(["defaults", "delete", SUITE], stderr=subprocess.DEVNULL)
for key in ("bench", "welcomed", "spaces"):
    subprocess.run(["defaults", "write", SUITE, key, "-bool", "true"])
subprocess.run(["defaults", "write", SUITE, "agents.asking", "bypass"])
shutil.rmtree(os.path.join(FOLDER, "chats"), ignore_errors=True)
fixture = shutil.copy2(os.path.join(HERE, "stand_in.py"), os.path.join(OUT, "stand_in.py"))
os.chmod(fixture, 0o755)
env = {"YAB_PROBE": WORLD, "YAB_HISTORY": "own", "YAB_AGENT_CLAUDE": fixture, "SAVE_PAGE_LOG": LOG}
app = probe_app.launch(OPTS.app, env, OUT, task_name="Save page", extra_env_names=("SAVE_PAGE_LOG",))
try:
    wait_for(lambda: ask({"do": "census"}).get("pid"), 30)
    ask({"do": "flood", "urls": [BASE + p for p in PAGES]})
    wait_for(lambda: len([t for t in ask({"do": "tabs"})["tabs"] if BASE in t.get("url", "")]) == 3, 20)
    time.sleep(2)

    # 1. One page as a PDF.
    said, files = on("/article-one", "save this page as pdf", "1-pdf")
    path = saved(said)
    check("pdf: a file", path and os.path.exists(path), said)
    if path and os.path.exists(path):
        info = pdf(path)
        check("pdf: Letter pages", info.get("width") == 612 and info.get("height") == 792, {k: info.get(k) for k in ("width", "height", "error")})
        check("pdf: several pages, not one long one", info.get("pages", 0) >= 3, info.get("pages"))
        check("pdf: the article's words", "Calder Point" in info.get("text", ""), info.get("text", "")[:300])
    check("pdf: the chat keeps the file for its card", path in files, files)

    # 2. Tables: the list, then all of them as a workbook.
    said, _ = on("/prices", "export this table to excel", "2-tables-asked")
    check("excel: three tables listed to ask which", "has 3 tables" in said and "Prices by plan" in said and "Feature comparison" in said and "Limits" in said, said)
    said, files = on("/prices", "all of them", "3-excel")
    path = saved(said)
    check("excel: a workbook", path.endswith(".xlsx") and os.path.exists(path), said)
    if path and os.path.exists(path):
        try:
            with zipfile.ZipFile(path) as book:
                bad = book.testzip()
                workbook = book.read("xl/workbook.xml").decode()
                names = re.findall(r'<sheet name="([^"]+)"', workbook)
                first = book.read("xl/worksheets/sheet1.xml").decode()
                second = book.read("xl/worksheets/sheet2.xml").decode()
            check("excel: a sound zip", bad is None, bad)
            check("excel: a sheet a table, named", names == ["Prices by plan", "Feature comparison", "Limits"], names)
            check("excel: numbers as numbers", "<v>1200</v>" in first and "<v>10</v>" in first, first[:600])
            check("excel: a currency stays as the page wrote it", "$4,800" in first, first[:900])
            check("excel: a leading zero stays text", "02139" in second and "<v>2139</v>" not in second, second[:900])
            check("excel: the header bold", 's="1" t="inlineStr"><is><t xml:space="preserve">Plan' in first, first[:400])
        except (zipfile.BadZipFile, KeyError) as error:
            check("excel: opens as a workbook", False, error)
        # Quick Look draws it, as the card's thumb and a click will.
        look = subprocess.run(["qlmanage", "-t", "-s", "400", "-o", OUT, path], capture_output=True, text=True, timeout=60)
        check("excel: Quick Look reads it", os.path.exists(os.path.join(OUT, os.path.basename(path) + ".png")), look.stdout[-300:] + look.stderr[-300:])
    check("excel: the chat keeps the file for its card", path in files, files)

    # 3. One table as CSV.
    said, files = on("/prices", "the second one as csv", "4-csv")
    path = saved(said)
    check("csv: a file", path.endswith(".csv") and os.path.exists(path), said)
    if path and os.path.exists(path):
        raw = open(path, "rb").read()
        text = raw[3:].decode("utf-8")
        check("csv: UTF-8 with its mark, for Excel", raw[:3] == b"\xef\xbb\xbf", raw[:10])
        check("csv: the second table, quoted where it must be", text.splitlines()[:2] == ["Feature,Free,Team", '"Sync, ""fast""",No,Yes'], text[:300])
        check("csv: named for the table", "Feature comparison" in os.path.basename(path), path)

    # 4. Both articles, reading form, one PDF.
    said, files = on("/article-one", "both articles as one book pdf, no ads", "5-book")
    path = saved(said)
    check("book: a file", path.endswith(".pdf") and os.path.exists(path), said)
    if path and os.path.exists(path):
        info = pdf(path)
        text = info.get("text", "")
        check("book: an outline entry an article", info.get("outline") == ["Calder Point lights", "Marrow Hill orchard"], info.get("outline"))
        check("book: both articles' words", ONE[:30] in text and TWO[:30] in text, text[:300])
        check("book: no ad, no menu", AD not in text and "Related: other stories" not in text, [w for w in (AD, "Related") if w in text])
        check("book: Letter pages", info.get("width") == 612, info.get("width"))
        check("book: named as asked", os.path.basename(path).startswith("Flight reading"), path)

    # 5. Both as Markdown.
    said, files = on("/article-two", "both as markdown", "6-markdown")
    path = saved(said)
    check("markdown: a file", path.endswith(".md") and os.path.exists(path), said)
    if path and os.path.exists(path):
        text = open(path, encoding="utf-8").read()
        check("markdown: both titles, a rule between", "# Calder Point lights" in text and "# Marrow Hill orchard" in text and "\n---\n" in text, text[:300])
finally:
    app.terminate()
    server.shutdown()

print(f"\n{len(FAILS)} failed" if FAILS else "\nall passed", flush=True)
sys.exit(1 if FAILS else 0)
