#!/usr/bin/env python3
"""Memory and energy of Yab beside Chrome, at 20/50/200 tabs, clean or with
extensions, and Yab's A/B variants (YAB_ flags) in one job on one Mac.

    python3 -u evals/memory/night.py --app "build/Pane Dev.app" --out DIR \
        [--browsers yab,chrome] [--profiles clean,adblock,passwords-fresh] [--tabs 20,50,200] \
        [--variant base] [--variant name:YAB_X=1,YAB_Y=2] [--rounds 3] [--quiet 30] [--soak 0]

A GUI probe: run it through the farm as a display job (Chrome needs
`--needs chrome`). Every (round, profile, tabs) step launches each browser
(and each Yab variant) fresh, interleaved A,B,A,B so a busy Mac weighs on
both, opens the tabs behind the first one (pages served from here, a mix of
four weights: plain, article, heavy DOM, an app with timers and a JS heap),
waits for them to load and for WebKit to put hidden pages down (--settle),
then measures for --quiet seconds with nobody touching it:

  mb        phys_footprint of the browser and every process it is
            responsible for (Activity Monitor's Memory), and by kind
  cpu       % of one core over the quiet window, same processes
  wakes     package-idle + interrupt wakeups per second, same processes
  procs     how many processes

--soak SECONDS adds a leak run per Yab variant: 20 tabs, every 20 s one tab
navigates, one opens and one closes, a switch; the app's own footprint and
the total each minute, and the slope per hour over the last two thirds.

Prints each row as "NIGHT-ROW {json}" and writes DIR/rows.jsonl.
"""
import argparse
import json
import os
import platform
import random
import statistics
import subprocess
import sys
import threading
import time
import urllib.parse
import http.server
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'evals/stand'))
import stand  # noqa: E402

lowram = stand.lowram

# The stand launches Yab with YAB_HANGS, a watchdog that pings the main
# thread every 20 ms: fifty wakeups a second Chrome doesn't pay. Not here.
_launch = stand.probe_app.launch


# A variant's settings ("@key=value"): written to the world's defaults
# before Yab starts, for the test-only knobs that are settings.
SETTINGS = {}


def _launch_quiet(app, env, *a, **kw):
    settings = {k[1:]: v for k, v in env.items() if k.startswith('@')}
    settings.update(SETTINGS)
    env = {k: v for k, v in env.items() if k != 'YAB_HANGS' and not k.startswith('@')}
    for key, value in settings.items():
        kind = '-int' if value.lstrip('-').isdigit() else '-string'
        subprocess.run(['defaults', 'write', 'dev.serafim.fast.test.' + env['YAB_PROBE'], key, kind, value], check=True)
    return _launch(app, env, *a, **kw)


stand.probe_app.launch = _launch_quiet

APP_PAGE = """<!doctype html><meta charset=utf-8><title>App %(n)d</title><link rel="icon" href="/favicon.ico">
<body style="font:14px system-ui;margin:20px"><h1>App %(n)d</h1><p id=clock></p><ul id=feed></ul>
<script>
window.heap = Array.from({length: 60000}, (_, i) => ({i, s: 'item ' + i + ' of %(n)d'}));
const feed = document.getElementById('feed');
for (let i = 0; i < 300; i++) { const li = document.createElement('li'); li.textContent = 'row ' + i; feed.appendChild(li); }
setInterval(() => { document.getElementById('clock').textContent = new Date().toISOString();
  feed.children[(Math.random() * 300) | 0].textContent = Math.random().toFixed(5); }, 1000);
setInterval(() => fetch('/ping?' + Date.now(), {cache: 'no-store'}).catch(() => {}), 15000);
</script>"""
BATCH_WAIT = 60  # seconds a batch of ten tabs may take to load (20 for --real)
KINDS = ('plain', 'article', 'heavy', 'app')
# --kinds plain,video: a muted video playing on a loop, as a news site's.
VIDEO_PAGE = """<!doctype html><meta charset=utf-8><title>Video %(n)d</title><link rel="icon" href="/favicon.ico">
<body style="font:14px system-ui;margin:20px"><h1>Video %(n)d</h1>
<video src="/clip.mp4" autoplay muted loop playsinline width=640 height=360></video><p>A clip that plays by itself.</p>"""
CLIP = Path(__file__).resolve().parent / 'clip.mp4'
# --real: public pages that change little from day to day, 24 sites; tab n
# gets REAL[n % 24] with ?n so no two tabs are the same document.
REAL = [
    'https://en.wikipedia.org/wiki/Web_browser', 'https://developer.mozilla.org/en-US/docs/Web/JavaScript',
    'https://github.com/WebKit/WebKit', 'https://news.ycombinator.com/', 'https://www.bbc.com/news',
    'https://www.apple.com/macbook-pro/', 'https://docs.python.org/3/library/asyncio.html', 'https://stackoverflow.com/questions',
    'https://www.theverge.com/', 'https://www.nytimes.com/', 'https://www.reddit.com/r/programming/',
    'https://www.youtube.com/', 'https://www.figma.com/', 'https://vercel.com/', 'https://linear.app/',
    'https://www.notion.com/', 'https://webkit.org/blog/', 'https://www.amazon.com/', 'https://medium.com/',
    'https://www.cnn.com/', 'https://arstechnica.com/', 'https://www.wired.com/', 'https://stripe.com/',
    'https://www.imdb.com/',
]


def serve(real=False):
    notes = stand.Notes()
    base = stand.serve(notes)  # plain, article, heavy

    class Pages(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            url = urllib.parse.urlparse(self.path)
            if url.path.startswith('/ping'):
                self.send_response(204)
                self.end_headers()
                return
            parts = url.path.strip('/').split('/')
            if url.path == '/clip.mp4':
                # With byte ranges: AVFoundation asks for nothing else.
                clip = CLIP.read_bytes()
                first, last = 0, len(clip) - 1
                asked = self.headers.get('Range', '')
                if asked.startswith('bytes='):
                    a, _, b = asked[6:].partition('-')
                    first = int(a or 0)
                    last = min(int(b), last) if b else last
                    self.send_response(206)
                    self.send_header('Content-Range', f'bytes {first}-{last}/{len(clip)}')
                else:
                    self.send_response(200)
                self.send_header('Content-Type', 'video/mp4')
                self.send_header('Accept-Ranges', 'bytes')
                self.send_header('Content-Length', str(last - first + 1))
                self.end_headers()
                self.wfile.write(clip[first:last + 1])
                return
            if len(parts) == 2 and parts[0] in ('app', 'video') and parts[1].isdigit():
                data = ((APP_PAGE if parts[0] == 'app' else VIDEO_PAGE) % {'n': int(parts[1])}).encode()
                self.send_response(200)
                self.send_header('Content-Type', 'text/html; charset=utf-8')
                self.send_header('Cache-Control', 'no-store')
                self.send_header('Content-Length', str(len(data)))
                self.end_headers()
                self.wfile.write(data)
                return
            if url.path == '/favicon.ico':
                self.send_response(200)
                self.send_header('Content-Type', 'image/png')
                self.send_header('Content-Length', str(len(stand.ICON)))
                self.end_headers()
                self.wfile.write(stand.ICON)
                return
            self.send_error(404)

        def log_message(self, *args):
            pass

    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Pages)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    app_base = f'http://127.0.0.1:{server.server_port}'

    def url(n):
        if real:
            page = REAL[n % len(REAL)]
            return page + ('&' if '?' in page else '?') + f'n={n}'
        kind = KINDS[n % len(KINDS)]
        return f'{app_base}/{kind}/{n}' if kind in ('app', 'video') else f'{base}/p/{kind}/{n}'
    return url


def counters(root):
    """{pid: (cpu s, wakeups, footprint MB, kind, born)} for the family."""
    out = {}
    for pid, kind in stand.family(root):
        ri = lowram.Rusage()
        if lowram.lib.proc_pid_rusage(pid, 2, lowram.ctypes.byref(ri)) != 0:
            continue
        out[pid] = ((ri.user_time + ri.system_time) * lowram.TICK_NS / 1e9, ri.pkg_idle_wkups + ri.interrupt_wkups,
                    ri.phys_footprint / 2**20, kind, ri.proc_start_abstime)
    return out


def quiet(root, seconds):
    a = counters(root)
    time.sleep(seconds)
    b = counters(root)
    same = [p for p in b if p in a and a[p][4] == b[p][4]]
    cpu = sum(b[p][0] - a[p][0] for p in same)
    wakes = sum(b[p][1] - a[p][1] for p in same)
    kinds, counts = {}, {}
    for v in b.values():
        kinds[v[3]] = kinds.get(v[3], 0) + v[2]
        counts[v[3]] = counts.get(v[3], 0) + 1
    wakes_by = {}
    cpu_by = {}
    for p in same:
        wakes_by[b[p][3]] = wakes_by.get(b[p][3], 0) + (b[p][1] - a[p][1]) / seconds
        cpu_by[b[p][3]] = cpu_by.get(b[p][3], 0) + (b[p][0] - a[p][0]) / seconds * 100
    others = [p for p in b if b[p][3] == 'other']
    names = lowram.sh('ps', '-o', 'pid=,rss=,comm=', '-p', ','.join(map(str, others))).strip().splitlines() if others else []
    busiest = sorted(((round((b[p][0] - a[p][0]) / seconds * 100, 1), b[p][3], p) for p in same), reverse=True)[:12]
    return {'mb': round(sum(v[2] for v in b.values())), 'cpu_pct': round(cpu / seconds * 100, 2),
            'wakes_s': round(wakes / seconds, 1), 'procs': len(b), 'by_kind_mb': {k: round(v) for k, v in kinds.items()},
            'by_kind_n': counts, 'busiest': busiest, 'wakes_by_kind': {k: round(v, 1) for k, v in wakes_by.items()},
            'cpu_by_kind': {k: round(v, 2) for k, v in cpu_by.items()}, 'other_names': [n.strip()[-90:] for n in names]}


def sleep_wake(run, count):
    """Puts `count` hidden tabs to sleep one by one, then brings each back
    to the front: how long each took and what memory came back."""
    ids = run.ids()[1:count + 1]
    before = sum(v[2] for v in counters(run.pid).values())
    slept = []
    for ident in ids:
        t0 = time.monotonic()
        try:
            run.yab.ask(timeout=30, do='sleep', id=ident)
        except Exception:
            pass
        slept.append(round((time.monotonic() - t0) * 1000))
    time.sleep(5)
    after = sum(v[2] for v in counters(run.pid).values())
    woke = []
    for ident in ids:
        t0 = time.monotonic()
        run.yab.select(ident)
        while time.monotonic() - t0 < 20 and run.yab.ask(do='census').get('loading', 0):
            time.sleep(0.05)
        woke.append(round((time.monotonic() - t0) * 1000))
    run.front_first()
    return {'slept_ms': slept, 'freed_mb': round(before - after), 'freed_per_tab_mb': round((before - after) / max(1, len(ids)), 1),
            'woke_ms': woke}


def categories(pids):
    """`footprint` of these processes, dirty MB by category, summed."""
    totals = {}
    for pid in pids:
        text = subprocess.run(['footprint', '-p', str(pid)], capture_output=True, text=True).stdout
        for line in text.splitlines():
            parts = line.split()
            # "  75 MB        0 B      1968 KB          7    WebKit Malloc"
            if len(parts) >= 8 and parts[1] in ('B', 'KB', 'MB', 'GB'):
                try:
                    dirty = float(parts[0]) * {'B': 1 / 1024, 'KB': 1, 'MB': 1024, 'GB': 1024 * 1024}[parts[1]] / 1024
                except (ValueError, KeyError):
                    continue
                name = ' '.join(parts[7:])
                totals[name] = totals.get(name, 0) + dirty
    return sorted(((k, round(v)) for k, v in totals.items()), key=lambda kv: -kv[1])[:12]


def footprints(run, count):
    """Where the memory is: Yab's own process, and its N biggest page
    processes, by `footprint` category."""
    app = categories([run.pid])
    print('== footprint of the app (dirty MB): ' + ', '.join(f'{k} {v}' for k, v in app), flush=True)
    try:
        report = run.yab.ask(do='processes')
    except Exception as e:
        print('footprint: no processes', e, flush=True)
        return
    rows = sorted(report.get('processes', []), key=lambda r: -r.get('mb', 0))
    pids = [r['pid'] for r in rows[:count] if r.get('pid')]
    pages = categories(pids)
    print(f'== footprint of {len(pids)} page processes (dirty MB): ' + ', '.join(f'{k} {v}' for k, v in pages), flush=True)
    try:
        print('== stills', json.dumps(run.yab.ask(do='stills'))[:400], flush=True)
    except Exception:
        pass


def sample_app(pid, path):
    """`sample` of Yab's own process at rest: its heaviest stacks, printed."""
    subprocess.run(['sample', str(pid), '8', '-file', str(path)], capture_output=True)
    text = path.read_text(errors='replace') if path.exists() else ''
    graph = text.split('Call graph:')[-1].split('Total number in stack')[0].splitlines()
    print(f'== sample {pid}', flush=True)
    for line in [l for l in graph if l.strip()][:80]:
        print('   ' + line[:200], flush=True)
    # The leaves where it spent its time, summed.
    tops = text.split('Sort by top of stack')[-1].splitlines()[:25] if 'Sort by top of stack' in text else []
    for line in tops:
        print('   top ' + line[:160], flush=True)


def sample_busy(busiest, n, out, tag):
    """`sample` of the n busiest processes at rest (any kind: Yab, a page,
    an extension's background page), side by side for 6 s; each one's
    heaviest leaves and the head of its call graph printed."""
    picks = [(pct, kind, pid) for pct, kind, pid in busiest if pct > 0][:n]
    procs = []
    for pct, kind, pid in picks:
        path = out / f'busy-{tag}-{pid}.txt'
        procs.append((pct, kind, pid, path, subprocess.Popen(['sample', str(pid), '6', '-mayDie', '-file', str(path)],
                                                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)))
    for pct, kind, pid, path, proc in procs:
        proc.wait()
        text = path.read_text(errors='replace') if path.exists() else ''
        print(f'== busy {tag} pid {pid} {kind} {pct}% ({len(text)} bytes)', flush=True)
        graph = text.split('Call graph:')[-1].split('Total number in stack')[0].splitlines()
        for line in [l for l in graph if l.strip()][:60]:
            print('   ' + line[:220], flush=True)
        tops = text.split('Sort by top of stack')[-1].splitlines()[:30] if 'Sort by top of stack' in text else []
        for line in tops:
            print('   top ' + line[:180], flush=True)


def loadavg():
    return float(lowram.sysctl('vm.loadavg').strip('{} ').split()[0])


class YabRun:
    def __init__(self, app, profile, spec, out, env):
        stand.EXTRA_ENV.clear()
        stand.EXTRA_ENV.update(env)
        self.yab = stand.Yab(app, profile, spec, out)
        self.pid = self.yab.pid
        stand.stage(self.yab.proc.pid)
        self.loaded = self.yab.extensions(spec['extensions']) if spec['extensions'] else []

    def open(self, urls):
        for i in range(0, len(urls), 10):
            self.yab.ask(do='flood', urls=urls[i:i + 10], asleep=False)
            self.settle(BATCH_WAIT)

    def settle(self, limit):
        end = time.monotonic() + limit
        while time.monotonic() < end:
            if self.yab.ask(do='census').get('loading', 1) == 0:
                return True
            time.sleep(0.5)
        return False

    def census(self):
        return self.yab.ask(do='census')

    def front_first(self):
        tabs = self.yab.tabs()
        if tabs:
            self.yab.select(tabs[0]['id'])

    def ids(self):
        return [t['id'] for t in self.yab.tabs()]

    def select(self, ident):
        self.yab.select(ident)

    def go(self, ident, url):
        self.yab.ask(do='go', id=ident, url=url)

    def quit(self):
        try:
            self.yab.proc.terminate()
            self.yab.proc.wait(20)
        except Exception:
            pass
        try:
            os.kill(self.pid, 15)
        except OSError:
            pass
        time.sleep(3)


class PipeChrome(stand.Chrome):
    """The stand's Chrome, always spawned on a DevTools pipe as it is with
    extensions: opened by LaunchServices it never opened its DevTools port
    on m4 (2026-10-13)."""

    def __init__(self, profile, out, extensions=()):
        self.browser = lowram.Chrome(lowram.CHROME, profile=str(stand.STATE / 'chrome' / profile))
        self.spawned = None
        self.loaded = {}
        self.pid = self.start_with(list(extensions), out)
        self.cdp = self.browser.cdp
        self.sessions = {}
        self.active = None
        self.pings = []
        self.pinging = True


class ChromeRun:
    def __init__(self, profile, spec, out):
        self.chrome = PipeChrome(f'night-{profile}', out, spec['extensions'])
        # The sweeper closes every page but these (and a hop goes to localhost).
        self.chrome.keep = ('about:blank', 'http://127.0.0.1:', 'http://localhost:', 'https://')
        self.pid = self.chrome.pid
        stand.stage(self.pid)
        self.loaded = list(getattr(self.chrome, 'loaded', {}) or {})
        self.targets = []

    def open(self, urls):
        for i in range(0, len(urls), 10):
            for u in urls[i:i + 10]:
                self.targets.append(self.chrome.open(u))
            self.settle(BATCH_WAIT)

    def settle(self, limit):
        # Chrome has no census: the batch's pages asked whether they are
        # complete, each answer waited for 3 s at most (a hidden page's
        # answer took up to the call's 30 s, and opening 20 tabs ten minutes).
        end = time.monotonic() + limit
        while time.monotonic() < end:
            pending = 0
            for t in self.targets[-10:]:
                try:
                    session = self.chrome.session(t)
                    got = self.chrome.cdp.call('Runtime.evaluate', {'expression': 'document.readyState', 'returnByValue': True},
                                               session=session, timeout=3)
                    if got.get('result', {}).get('value') != 'complete':
                        pending += 1
                except Exception:
                    pending += 1
            if not pending:
                return True
            time.sleep(0.5)
        return False

    def census(self):
        return {}

    def front_first(self):
        pass

    def ids(self):
        return list(self.targets)

    def select(self, ident):
        self.chrome.select(ident)

    def go(self, ident, url):
        self.chrome.eval(f'location.href = {json.dumps(url)}; 1', ident)

    def quit(self):
        self.chrome.pinging = False
        self.chrome.quit()
        time.sleep(3)


def emit(out, row):
    print('NIGHT-ROW ' + json.dumps(row), flush=True)
    with open(out / 'rows.jsonl', 'a') as f:
        f.write(json.dumps(row) + '\n')


def step(args, out, url, browser, variant, env, profile, tabs, rnd):
    spec = dict(stand.PROFILES[profile])
    t0 = time.monotonic()
    run = None
    try:
        run = YabRun(args.app, profile, spec, out, env) if browser == 'yab' else ChromeRun(profile, spec, out)
        time.sleep(8)
        empty = quiet(run.pid, 10)
        opened = time.monotonic()
        run.open([url(rnd * 10000 + i) for i in range(tabs)])
        open_s = time.monotonic() - opened
        ids = run.ids()
        # Each tab sent on to new pages, every other one on another site
        # (127.0.0.1 and localhost are two sites): what back/forward
        # caches and process swaps keep.
        for hop in range(args.hops):
            for k, ident in enumerate(ids):
                target = url(rnd * 10000 + 5000 + hop * 1000 + k)
                if hop % 2 == 0:
                    target = target.replace('127.0.0.1', 'localhost')
                try:
                    run.go(ident, target)
                except Exception:
                    pass
            run.settle(60)
        # A person going through their tabs: each one shown in turn.
        for ident in ids[:args.flick]:
            try:
                run.select(ident)
            except Exception:
                pass
            time.sleep(0.6)
        if browser == 'yab' and run.loaded:
            # One opened late (AdGuard's thank-you page) closed too.
            stand.Yab.close_arrival_pages(run.yab, seconds=0)
        run.front_first()
        time.sleep(args.settle)
        if browser == 'yab' and run.loaded:
            stand.Yab.close_arrival_pages(run.yab, seconds=0)
            run.front_first()
        idle = quiet(run.pid, args.quiet)
        census = run.census()
        if args.collect and browser == 'yab':
            # The same tabs, paired: memory now, then after every page
            # process collected its garbage (Garbage, bench census collect).
            mb = []
            for _ in range(2):
                mb.append(round(sum(v[2] for v in counters(run.pid).values())))
                run.yab.ask(do='census', collect=True)
                time.sleep(15)
            mb.append(round(sum(v[2] for v in counters(run.pid).values())))
            emit(out, {'kind': 'collect', 'browser': browser, 'variant': variant, 'profile': profile, 'tabs': tabs,
                       'round': rnd, 'mb_before': mb[0], 'mb_after_one': mb[1], 'mb_after_two': mb[2]})
        if args.sleepwake and browser == 'yab':
            row_sleep = sleep_wake(run, args.sleepwake)
            emit(out, {'kind': 'sleepwake', 'browser': browser, 'variant': variant, 'profile': profile, 'tabs': tabs,
                       'round': rnd, **row_sleep})
        if args.footprint and browser == 'yab':
            footprints(run, args.footprint)
        if args.sample_busy:
            sample_busy(idle['busiest'], args.sample_busy, out, f'{browser}-{variant}-{profile}-{tabs}-{rnd}')
        if args.sample and browser == 'yab':
            sample_app(run.pid, out / f'sample-{variant}-{profile}-{tabs}-{rnd}.txt')
        row = {'kind': 'idle', 'real': args.real, 'hops': args.hops, 'flick': args.flick, 'browser': browser, 'variant': variant, 'profile': profile, 'tabs': tabs, 'round': rnd,
               'host': platform.node().split('.')[0], 'load': loadavg(), 'open_s': round(open_s, 1),
               'extensions': run.loaded, 'empty': {k: empty[k] for k in ('mb', 'cpu_pct', 'wakes_s', 'procs')},
               **idle, 'census': {k: census.get(k) for k in ('tabs', 'asleep', 'built', 'loading', 'collected')} if census else None}
        if browser == 'yab':
            row['arrival_closed'] = getattr(run.yab, 'arrival_pages', None)
            # The busiest page processes at rest, by the address of their tabs.
            try:
                report = run.yab.ask(do='processes')
                urls = {t['id'][:8].lower(): t.get('url', '') for t in run.yab.tabs()}
                tabs_of = {r['pid']: r.get('tabs') or [] for r in report.get('processes', [])}
                row['busy_pages'] = [[pct, [urls.get(t, t)[:80] for t in tabs_of.get(pid, [])]]
                                     for pct, kind, pid in idle['busiest'] if kind == 'pages']
                if args.processes:
                    row['processes'] = report
            except Exception as e:
                row['processes'] = str(e)
        emit(out, row)
    except (Exception, SystemExit) as e:  # one broken step must not end the night
        emit(out, {'kind': 'error', 'browser': browser, 'variant': variant, 'profile': profile, 'tabs': tabs,
                   'round': rnd, 'error': repr(e)[:400]})
    finally:
        if run:
            run.quit()
    print(f'  step {browser}/{variant} {profile} {tabs} tabs: {time.monotonic() - t0:.0f}s', flush=True)


def soak(args, out, url, variant, env):
    spec = dict(stand.PROFILES['clean'])
    run = YabRun(args.app, 'clean', spec, out, env)
    rng = random.Random(7)
    try:
        run.open([url(i) for i in range(20)])
        run.front_first()
        time.sleep(30)
        start = time.monotonic()
        samples = []
        n = 100
        nxt = 0
        while time.monotonic() - start < args.soak:
            tabs = run.yab.tabs()
            if tabs:
                t = rng.choice(tabs)
                try:
                    run.yab.ask(do='go', id=t['id'], url=url(n))
                except Exception:
                    pass
                n += 1
                run.yab.ask(do='flood', urls=[url(n)], asleep=False)
                n += 1
                tabs = run.yab.tabs()
                if len(tabs) > 20:
                    victim = rng.choice(tabs[1:])
                    try:
                        run.yab.ask(do='sync', action='close', url=victim['url'])
                    except Exception:
                        pass
                run.yab.select(rng.choice(tabs)['id'])
            if time.monotonic() - start >= nxt:
                c = counters(run.pid)
                app = next((v[2] for p, v in c.items() if p == run.pid), 0)
                samples.append({'t': round(time.monotonic() - start), 'app_mb': round(app, 1),
                                'total_mb': round(sum(v[2] for v in c.values())), 'procs': len(c)})
                print(f'  soak {variant} {samples[-1]}', flush=True)
                nxt += 60
            time.sleep(20)

        def slope(key):
            tail = samples[len(samples) // 3:]
            if len(tail) < 3:
                return None
            xs = [s['t'] / 3600 for s in tail]
            ys = [s[key] for s in tail]
            mx, my = statistics.mean(xs), statistics.mean(ys)
            return round(sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / sum((x - mx) ** 2 for x in xs), 1)
        emit(out, {'kind': 'soak', 'browser': 'yab', 'variant': variant, 'seconds': args.soak, 'host': platform.node().split('.')[0],
                   'app_mb_per_h': slope('app_mb'), 'total_mb_per_h': slope('total_mb'), 'samples': samples})
    finally:
        run.quit()


def parse_variant(text):
    name, _, flags = text.partition(':')
    env = {}
    for pair in filter(None, flags.split(',')):
        k, _, v = pair.partition('=')
        env[k] = v
    return name, env


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--app', required=True)
    p.add_argument('--out', required=True)
    p.add_argument('--browsers', default='yab,chrome')
    p.add_argument('--profiles', default='clean')
    p.add_argument('--tabs', default='20,50')
    p.add_argument('--variant', action='append', default=[])
    p.add_argument('--rounds', type=int, default=1)
    p.add_argument('--settle', type=float, default=45)
    p.add_argument('--quiet', type=float, default=30)
    p.add_argument('--soak', type=float, default=0)
    p.add_argument('--processes', action='store_true')
    p.add_argument('--collect', action='store_true', help='Yab: memory before and after collecting garbage now')
    p.add_argument('--sleepwake', type=int, default=0, help='sleep N hidden tabs, then wake each (Yab)')
    p.add_argument('--footprint', type=int, default=0, help='footprint categories of the N biggest page processes')
    p.add_argument('--sample', action='store_true', help='sample Yab at rest after each step')
    p.add_argument('--sample-busy', type=int, default=0, help='sample the N busiest processes at rest after each step')
    p.add_argument('--kinds', default='', help='page mix, of plain,article,heavy,app,video')
    p.add_argument('--real', action='store_true', help='public sites instead of local pages')
    p.add_argument('--hops', type=int, default=0, help='navigations per tab after opening')
    p.add_argument('--flick', type=int, default=0, help='tabs shown in turn before the quiet window')
    args = p.parse_args()
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    if args.sample or args.sample_busy:
        # Yab's own process may be sampled (get-task-allow).
        entitlements = out / 'get-task-allow.plist'
        entitlements.write_text('<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
                                '"http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>'
                                '<key>com.apple.security.get-task-allow</key><true/></dict></plist>')
        stand.probe_app.SIGN_ENTITLEMENTS = str(entitlements)
    global KINDS
    if args.kinds:
        KINDS = tuple(args.kinds.split(','))
    url = serve(args.real)
    global BATCH_WAIT
    BATCH_WAIT = 20 if args.real else 60
    variants = [parse_variant(v) for v in (args.variant or ['base'])]
    print(f'host {platform.node()} load {loadavg()} mem {int(lowram.sysctl("hw.memsize")) >> 30} GB', flush=True)
    for rnd in range(args.rounds):
        for profile in args.profiles.split(','):
            for tabs in [int(t) for t in args.tabs.split(',')]:
                runs = []
                for b in args.browsers.split(','):
                    if b == 'yab':
                        runs += [('yab', name, env) for name, env in variants]
                    else:
                        runs.append(('chrome', 'chrome', {}))
                if rnd % 2:
                    runs.reverse()
                for browser, name, env in runs:
                    step(args, out, url, browser, name, env, profile, tabs, rnd)
    if args.soak:
        for name, env in variants:
            soak(args, out, url, name, env)
    # A compact summary: medians by (browser/variant, profile, tabs).
    rows = [json.loads(l) for l in open(out / 'rows.jsonl') if l.strip()]
    groups = {}
    for r in rows:
        if r.get('kind') == 'idle':
            groups.setdefault((r['variant'], r['profile'], r['tabs']), []).append(r)
    print('\nvariant           profile          tabs     MB   cpu%  wakes/s  procs  (n)')
    for (v, prof, tabs), rs in sorted(groups.items(), key=lambda kv: (kv[0][1], kv[0][2], kv[0][0])):
        med = lambda k: statistics.median(r[k] for r in rs)
        print(f'{v:<17} {prof:<16} {tabs:>4} {med("mb"):>6.0f} {med("cpu_pct"):>6.1f} {med("wakes_s"):>8.0f} {med("procs"):>6.0f}  ({len(rs)})')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
