#!/usr/bin/env python3
"""watch_page end to end (docs/agent-asks.md, wave 1): a shop page on this
Mac whose price the eval changes, a watch set through a real `yab mcp` as an
agent sets it, Yab reading the page on its own (the clock forced by
agent-watch-page-tick), and what the person sees:

- the tool answers in one line and the tab's row says "Watching: under $200";
- above the line nothing is said; under it, one notification in words
  ("Sony WH-1000XM6 is $189, under the $200 you asked for"), the watch over
  and its row showing "$189"; read again, nothing more is said;
- a page already under the line: no watch, "It holds already";
- a check that stops reading the page: misses counted, a wake owed once at
  the third; written again through the tool, it reads again; stopped
  through the tool, gone.

Build, then on the farm:

  ./farm exec --display --name "Watch a page" -- bash -c 'set -o pipefail; ./build.sh 2>&1 | tee build.log && python3 evals/watch-page/run.py'

Pictures (row before, row after) and results land in $YAB_FARM_OUT/watch-page."""
import http.server, json, os, subprocess, sys, threading, time, uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'evals'))
import yab_socket  # noqa: E402
from probe_app import launch  # noqa: E402

OUT = Path(os.environ.get('YAB_FARM_OUT') or os.environ.get('OUT') or '/tmp') / 'watch-page'
OUT.mkdir(parents=True, exist_ok=True)
FAILS = []


def check(what, ok, detail=''):
    print(('✓ ' if ok else '✗ ') + what + ('' if ok else f': {str(detail)[:600]}'), flush=True)
    if not ok: FAILS.append(what)


PAGES = {'/sony': 249.99, '/kettle': 39.0, '/lamp': 120.0}
MOVED = set()


class Shop(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split('?')[0]
        if path not in PAGES:
            self.send_response(404); self.end_headers(); return
        name = {'/sony': 'Sony WH-1000XM6', '/kettle': 'Kettle', '/lamp': 'Desk Lamp'}[path]
        price = f'Price: ${PAGES[path]:,.2f}' if path not in MOVED else 'This item is no longer listed. See similar items.'
        body = (f'<!doctype html><meta charset="utf-8"><title>{name}</title><h1>{name}</h1>'
                f'<p class="price">{price}</p><button>Add to cart</button>').encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Shop)
threading.Thread(target=server.serve_forever, daemon=True).start()
BASE = f'http://127.0.0.1:{server.server_address[1]}'

CHECK = r"""
const m = text.match(/Price:\s*\$([\d,.]+)/);
if (!m) return null;
const p = number(m[1]);
return { value: '$' + p.toFixed(2).replace(/\.00$/, ''), holds: p < 200 };
"""

world = 'watchpage-' + uuid.uuid4().hex[:8]
domain = 'dev.serafim.fast.test.' + world
for key in ('bench', 'welcomed'):
    subprocess.run(['defaults', 'write', domain, key, '-bool', 'true'], check=True)
subprocess.run(['defaults', 'write', domain, 'look', '-string', 'light'], check=True)
# The column, where the row has room for its words.
subprocess.run(['defaults', 'write', domain, 'sidebar', '-bool', 'true'], check=True)
support = yab_socket.support(world)
sock = support / 'bench.sock'
env = dict(os.environ, YAB_PROBE=world, YAB_HISTORY='own')
app = launch(ROOT / 'build/Pane Dev.app', env, OUT, task_name='Watch a page')
ask = yab_socket.asker(sock)
client = None
try:
    yab_socket.wait_for(lambda: sock.exists(), 60)
    time.sleep(3)
    sony = ask({'do': 'open', 'url': BASE + '/sony', 'plain': True})['id']
    yab_socket.wait_for(lambda: 'Sony' in json.dumps(ask({'do': 'tabs'})), 20)
    time.sleep(1)

    # A real `yab mcp`, as Claude Code runs it.
    client = subprocess.Popen([str(app.binary), 'mcp', '--socket', str(sock)], env=env, text=True,
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    calls = [0]

    def mcp(method, params):
        calls[0] += 1
        client.stdin.write(json.dumps({'jsonrpc': '2.0', 'id': calls[0], 'method': method, 'params': params}) + '\n')
        client.stdin.flush()
        while True:
            line = client.stdout.readline()
            if not line:
                raise RuntimeError('yab mcp exited')
            message = json.loads(line)
            if message.get('id') == calls[0]:
                return message

    def tool(arguments):
        got = mcp('tools/call', {'name': 'watch_page', 'arguments': arguments})
        result = got.get('result') or {}
        words = ' '.join(part.get('text', '') for part in result.get('content') or [])
        return words, result.get('isError') is True or 'error' in got

    def pages():
        return ask({'do': 'agent-watch-pages'})

    def words(tab):
        return ask({'do': 'agent-watch-pages', 'id': tab}).get('words', '')

    def tick():
        return ask({'do': 'agent-watch-page-tick'}, timeout=90)

    mcp('initialize', {'protocolVersion': '2025-06-18', 'capabilities': {}, 'clientInfo': {'name': 'claude-code', 'version': 'eval'}})
    listed = mcp('tools/list', {}).get('result', {}).get('tools', [])
    check('yab mcp lists watch_page', any(t['name'] == 'watch_page' for t in listed))

    said, failed = tool({'tab': sony[:8].lower(), 'name': 'Sony WH-1000XM6', 'until': 'under $200', 'check': CHECK,
                         'tell': 'Sony WH-1000XM6 is {value}, under the $200 you asked for'})
    print('watch_page:', said, flush=True)
    check('watch_page sets the watch and says so in a line', not failed and said.startswith('Watching Sony WH-1000XM6') and '$249.99' in said, said)
    active = [w for w in pages()['watches'] if w['active']]
    check('one watch, on the page, read once', len(active) == 1 and active[0]['url'] == BASE + '/sony' and active[0]['value'] == '$249.99', active)
    watch_id = active[0]['watch'] if active else ''
    check('the row says "Watching: under $200"', words(sony) == 'Watching: under $200', words(sony))
    ask({'do': 'select', 'id': sony})
    time.sleep(1.5)
    ask({'do': 'winshot', 'path': str(OUT / 'row-watching.png')})

    got = tick()
    check('above the line: nothing said, still watching', got['told'] == [] and any(w['active'] for w in got['watches']), got)

    PAGES['/sony'] = 189.0
    got = tick()
    told = got['told']
    check('under the line: one notification in words',
          len(told) == 1 and told[0]['body'] == 'Sony WH-1000XM6 is $189, under the $200 you asked for' and told[0]['title'] == 'Sony WH-1000XM6', told)
    over = [w for w in got['watches'] if w['watch'] == watch_id]
    check('the watch is over', len(over) == 1 and not over[0]['active'], over)
    check('its row shows what it found', words(sony) == '$189', words(sony))
    ask({'do': 'select', 'id': sony})
    time.sleep(1.5)
    ask({'do': 'winshot', 'path': str(OUT / 'row-held.png')})
    got = tick()
    check('read again: nothing more is said', len(got['told']) == 1, got['told'])
    said, failed = tool({})
    check('the agent lists no watches left', 'No watches' in said, said)

    # Already under the line: no watch.
    kettle = ask({'do': 'open', 'url': BASE + '/kettle', 'plain': True})['id']
    time.sleep(2)
    said, failed = tool({'tab': kettle[:8].lower(), 'name': 'Kettle', 'until': 'under $200', 'check': CHECK})
    check('a page already under the line: no watch, "It holds already"',
          'It holds already' in said and not any(w['active'] for w in pages()['watches']), said)

    # A check that reads nothing on the page at once comes back to fix.
    said, failed = tool({'url': BASE + '/lamp', 'name': 'Desk Lamp', 'until': 'in stock', 'check': "return /In stock/.test(text) ? { value: 'In stock', holds: true } : null;"})
    check('a check that reads nothing comes back as an error', failed and 'found nothing' in said, said)

    # A page that changes under the check: three misses owe one wake.
    said, failed = tool({'url': BASE + '/lamp', 'name': 'Desk Lamp', 'until': 'under $100', 'check': CHECK.replace('200', '100')})
    lamp = next((w for w in pages()['watches'] if w['active'] and w['name'] == 'Desk Lamp'), None)
    check('a watch by url, no tab', not failed and lamp is not None, said)
    MOVED.add('/lamp')
    for _ in range(3):
        got = tick()
    lamp = next((w for w in got['watches'] if w['watch'] == (lamp or {}).get('watch')), None)
    check('three misses: counted, a wake owed once, nothing said', lamp and lamp['misses'] == 3 and lamp['woke'] and len(got['told']) == 1, lamp)
    got = tick()
    lamp = next((w for w in got['watches'] if w['watch'] == (lamp or {}).get('watch')), None)
    check('a fourth miss wakes nothing more', lamp and lamp['misses'] == 4 and lamp['woke'], lamp)
    said, failed = tool({'watch': lamp['watch'] if lamp else '', 'check': "return { value: /no longer listed/.test(text) ? 'Gone' : 'Listed', holds: false };"})
    lamp = next((w for w in pages()['watches'] if w['watch'] == (lamp or {}).get('watch')), None)
    check('written again: reads again, misses cleared', not failed and lamp and lamp['misses'] == 0 and not lamp['woke'] and lamp['value'] == 'Gone', (said, lamp))
    said, failed = tool({'stop': lamp['watch'] if lamp else ''})
    check('stopped through the tool: gone', 'Stopped watching Desk Lamp' in said and not any(w['watch'] == (lamp or {}).get('watch') for w in pages()['watches']), said)
    (OUT / 'result.json').write_text(json.dumps({'fails': FAILS, 'watches': pages()}, indent=2))
finally:
    if client:
        client.stdin.close()
        client.wait(timeout=15)
    app.terminate()
    server.shutdown()

print('FAILED: ' + ', '.join(FAILS) if FAILS else 'all passed', flush=True)
sys.exit(1 if FAILS else 0)
