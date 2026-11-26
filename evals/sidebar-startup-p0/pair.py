#!/usr/bin/env python3
"""Pristine-main/candidate startup proof using only existing bench commands.

Native state is read before every action/render. The input app is recorded,
then probe_app makes its explicitly derived, isolated signed copy. This is
development A/B proof, not an unchanged shipping-signature acceptance run.
"""
import argparse
import hashlib
import http.server
import json
import os
from pathlib import Path
import plistlib
import socket
import subprocess
import sys
import threading
import time
import traceback
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'evals'))
from probe_app import launch


class FocusContractBlocked(RuntimeError):
    pass


def require_focus_contract(out, context, record=True):
    """Active proof cannot override the worker's explicit keep-focus flag."""
    flag = os.environ.get('YAB_FARM_KEEP_FOCUS')
    result = {'environment_flag': flag, 'blocked': flag == '1', 'context': context,
              'host': os.environ.get('WHERE'), 'setup_blocked_exit': 78}
    if record or result['blocked']:
        out = Path(out); out.mkdir(parents=True, exist_ok=True)
        (out / 'focus-contract.json').write_text(json.dumps(result, indent=2) + '\n')
    if result['blocked']:
        raise FocusContractBlocked('Active proof requires focus; worker YAB_FARM_KEEP_FOCUS=1')
    return result


def run_with_focus_guard(main):
    try: return main()
    except FocusContractBlocked as error:
        print('SETUP_BLOCKED ' + str(error), flush=True)
        return 78


class Page(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        index = self.path.strip('/') or '0'
        body = (f'<!doctype html><meta charset=utf-8><title>Restored page {index}</title>'
                '<style>body{margin:0;background:#eaf0f9;color:#162441;font:24px -apple-system}'
                'main{padding:80px 60px;min-height:1400px;background:linear-gradient(135deg,#eaf0f9,#d5e7ee)}'
                'button{font:inherit}</style>'
                f'<main><h1>Restored page {index}</h1><p>Sidebar startup fixture</p>'
                '<button onclick="this.textContent=++window.presses">Page press counter</button>'
                '<script>window.presses=0</script></main>').encode()
        self.send_response(200); self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *_): pass


def identity(app):
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    binary = app / 'Contents/MacOS' / info['CFBundleExecutable']
    return {'path': str(app), 'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
            'version': info.get('CFBundleShortVersionString'), 'build': info.get('CFBundleVersion'),
            'name': info.get('CFBundleDisplayName', info.get('CFBundleName'))}


def hidden_startup_ghost(report):
    """Require the specific hidden-at-rest / actually drawn-at-zero defect.

    Restore-count or hit-test failures alone cannot qualify a baseline.
    The media still needs human review; this is the native-state predicate.
    """
    if not report.get('initial_hidden'): return False
    steps = {row['step']: row['data'] for row in report.get('steps', [])}
    for phase in ['launch', 'relaunch']:
        for observation in ['first untouched native state', 'untouched resting native state']:
            state = steps.get(phase + ': ' + observation, {})
            column = state.get('column', {})
            placement = column.get('placement')
            layer = column.get('host', {}).get('layer', {})
            frames = ([placement.get('model', []), placement.get('presentation', [])] if placement is not None else
                      [layer.get('frame', []), layer.get('shown_frame', [])])
            if not (column.get('out') is False and column.get('shown') is False and
                    all(len(f) == 4 and f[2] > 0 and f[3] > 0 and abs(f[0]) < .5 for f in frames)):
                return False
    return True


class World:
    def __init__(self, app, out, base, count, hidden, glass, flank='left'):
        # Check before profile/default writes or any app launch. The caller
        # records the successful prerequisite in its report below.
        focus = require_focus_contract(out, 'sidebar native active/fullscreen proof', record=False)
        self.app, self.out = app, out
        self.count, self.hidden, self.glass, self.flank = count, hidden, glass, flank
        self.world = 'startup-pair-' + uuid.uuid4().hex[:10]
        self.domain = 'dev.serafim.fast.test.' + self.world
        self.support = Path.home() / 'Library/Application Support' / f'Pane ({self.world})'
        self.sock = self.support / 'bench.sock'
        self.proc = None
        self.out.mkdir(parents=True); self.support.mkdir(parents=True)
        self.report = {'world': self.world, 'app': identity(app), 'count': count, 'initial_hidden': hidden,
            'focus_contract': focus,
            'glass': glass, 'flank': flank, 'steps': [], 'checks': [], 'lifecycle': [],
            'physical_input_verified': False,
            'profile_limitations': 'Matching tab counts, local pages, default extension set. No reporter accounts/extensions, OS/hardware/scale parity.',
            'identity_limit': 'probe_app derives and ad-hoc signs a separate bundle; input and launched hashes are both recorded.'}
        tabs = [{'url': f'{base}/{i}', 'title': f'Restored page {i}', 'id': str(uuid.uuid4()), 'visits': 0}
                for i in range(count)]
        (self.support / 'session.json').write_text(json.dumps({'tabs': tabs, 'active': 0}))
        # Actual app settings: no proactive look/glance or quiet memory
        # passes, and no unrelated While You Browse model work.
        isolation = {'agents.watch': False, 'agents.forget': True,
                     'tidy.titles': False, 'folders.names': False, 'tidy.downloads': False}
        self.report['harness_overrides'] = {'launch_environment': {'YAB_AGENTS': 'none'},
                                            'world_preferences': isolation, 'home': 'inherited unchanged'}
        prefs = {'bench': True, 'welcomed': True, 'sidebar': True, 'sidebar.shut': hidden,
                 'sidebar.width': 240, 'sidebar.flank': flank, 'backdrop': 'color' if glass else 'none',
                 'backdrop.glass': glass, 'backdrop.transparency': .6, 'look': 'light', 'backdrop.swatch': 'coral',
                 **isolation}
        for key, value in prefs.items():
            flag = '-bool' if isinstance(value, bool) else '-float' if isinstance(value, (int, float)) else '-string'
            subprocess.run(['defaults', 'write', self.domain, key, flag,
                str(value).lower() if isinstance(value, bool) else str(value)], check=True)
        # Same app-owned negative preference used by column-live: no localhost
        # Developer Mode question obscures rows; it grants no OS permission.
        subprocess.run(['defaults', 'write', self.domain, 'devSites', '-dict',
                        base.removeprefix('http://'), '-bool', 'false'], check=True)
        self.save()

    def save(self):
        (self.out / 'report.json').write_text(json.dumps(self.report, indent=2, ensure_ascii=False) + '\n')

    def note(self, step, data):
        self.report['steps'].append({'step': step, 'monotonic': time.monotonic(), 'data': data}); self.save()

    def check(self, name, ok, data=None):
        self.report['checks'].append({'name': name, 'ok': bool(ok), 'data': data}); self.save()
        print(('PASS ' if ok else 'APP_FAIL ') + str(self.out.name) + ' ' + name, flush=True)

    def ask(self, **request):
        forced = (request.get('front') is True or request.get('do') == 'front' or
                  request.get('do') == 'float' and request.get('action') == 'app' and
                  request.get('how') in ['front', 'activate', 'away'] or
                  request.get('do') == 'ui' and 'fullscreen' in request)
        if forced:
            require_focus_contract(self.out, 'forced front/activation/fullscreen request')
        request.setdefault('browserWindow', 1)
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.settimeout(30); client.connect(str(self.sock)); client.sendall((json.dumps(request) + '\n').encode())
            body = bytearray()
            while b'\n' not in body:
                data = client.recv(65536)
                if not data: break
                body.extend(data)
        response = json.loads(body.split(b'\n', 1)[0])
        if response.get('error'): raise RuntimeError(response['error'])
        return response

    def column(self, phase):
        state = self.ask(do='sidecol'); self.note(phase, state); return state

    def spawn(self, phase):
        self.sock.unlink(missing_ok=True)
        start = time.monotonic()
        self.proc = launch(self.app, {'YAB_PROBE': self.world, 'YAB_HISTORY': 'own', 'YAB_MEASURE': '1', 'YAB_AGENTS': 'none'},
                           self.out / phase, task_name=os.environ['YAB_TASK_NAME'] + ' ' + self.out.parent.name)
        deadline = time.monotonic() + 60
        while True:
            try:
                state = self.ask(do='sidecol')
                # Read-only readiness. No census, focus, resize, render, menu,
                # edge or preference write can heal the initial layout first.
                if state.get('column', {}).get('window') and any(c.get('known') for c in state.get('columns', [])):
                    break
            except (OSError, json.JSONDecodeError): pass
            except RuntimeError as error:
                if str(error) not in ('no owned window', 'no browser', 'no window'): raise
            if self.proc.poll() is not None or time.monotonic() > deadline:
                raise RuntimeError('owned window did not register within startup deadline')
            time.sleep(.025)
        self.note(phase + ': first untouched native state', state)
        self.report['lifecycle'].append({'phase': phase, 'pid': self.proc.pid, 'identity': self.proc.identity,
                                         'registration_seconds': time.monotonic() - start})
        self.save()
        self.visibility(phase + ': first untouched', state, not self.hidden)
        time.sleep(2.0)
        resting = self.column(phase + ': untouched resting native state')
        self.visibility(phase + ': untouched resting', resting, not self.hidden)
        census = self.ask(do='census'); self.note(phase + ': census after initial observation', census)
        self.check(phase + ': restored tab count', census.get('tabs') == self.count, census)
        self.check(phase + ': actual restore has one awake tab', census.get('tabs', 0) - census.get('asleep', 0) == 1, census)
        self.native_hits(phase + ': untouched hits', not self.hidden)
        self.shot(phase + '-untouched')

    def visibility(self, name, state, shown):
        col = state.get('column', {}); layer = col.get('host', {}).get('layer', {})
        # Newer builds can carry the host with its parent's sublayer
        # transform. Measure the drawing's effective position, with the
        # original host-layer geometry as pristine-main's equivalent.
        placement = col.get('placement')
        frames = ([placement.get('model', []), placement.get('presentation', [])]
                  if placement is not None else [layer.get('frame', []), layer.get('shown_frame', [])])
        self.owned_column = bool(col.get('window') and len(state.get('columns', [])) == 1
                                 and state['columns'][0].get('known'))
        self.check(name + ': unique owned column', self.owned_column, state.get('columns'))
        self.check(name + ': requested state matches native state', col.get('out') == shown and col.get('shown') == shown, col)
        # Left and right hosts are translated opposite ways. Native bounds
        # are full-window, so compare the resting origin to the known 280pt
        # off-edge translation, not full-window visibility or alpha alone.
        expected = 0 if shown else -280 if self.flank == 'left' else 280
        self.check(name + ': model and presentation position', all(len(f) == 4 and abs(f[0] - expected) < .5 for f in frames),
                   {'expected_x': expected, 'frames': frames, 'layer': layer, 'placement': placement})
        if shown:
            chain = col.get('chain', [])
            self.check(name + ': visible ancestry', bool(chain) and all(not v.get('hidden') and v.get('alpha', 0) > .99 for v in chain), chain)

    def native_hits(self, name, shown):
        rows = self.ask(do='rowframes').get('rows', [])
        points = [(18 if self.flank == 'left' else 1160, 60)]
        for row in rows[:2]:
            x, y, width, height = row['frame']; points.append((x + width / 2, y + height / 2))
        hits = []
        for point in points:
            hit = self.ask(do='droptarget', at=point); hits.append({'at': point, **hit})
        self.note(name, hits)
        def in_column(hit):
            chain = hit.get('chain', [])
            # droptarget returns only12 ancestors. A real ColumnCell chain
            # reaches Host at12 and ColumnView just beyond that boundary.
            # Accept the actual row view only in this unique owned column;
            # a generic Host or a PageView never counts as a sidebar hit.
            return any('ColumnView' in v for v in chain) or bool(self.owned_column and chain and
                        chain[0] == 'ColumnCell' and 'ColumnPages' in chain)
        self.check(name + ': native routing agrees with visibility', len(points) >= 2 and
                   all(in_column(h) == shown for h in hits), hits)

    def shot(self, name):
        path = self.out / (name + '.png')
        reply = self.ask(do='winshot', path=str(path), page=True)
        self.note('shot ' + name, reply)
        if not path.is_file() or path.stat().st_size < 10000: raise RuntimeError('missing app-drawn frame')

    def menu(self, title):
        reply = self.ask(do='app-menu', menu='View', press=title); self.note('menu ' + title, reply)
        if not reply.get('pressed'): raise RuntimeError('missing enabled app action ' + title)
        time.sleep(1.2)

    def exercise(self, phase):
        if self.hidden:
            self.menu('Show Sidebar')
            state = self.column(phase + ': actual Show Sidebar')
            self.visibility(phase + ': actual Show Sidebar', state, True)
            self.native_hits(phase + ': actual Show Sidebar hits', True); self.shot(phase + '-shown')
            self.menu('Hide Sidebar')
            self.visibility(phase + ': Hide Sidebar', self.column(phase + ': hidden again'), False)
            # Synthetic Brim edge only; this does not claim physical hover.
            self.ask(do='edge', at=[650, 380], front=True, wait=.15)
            edge = 1 if self.flank == 'left' else 1179
            self.ask(do='edge', at=[edge, 380], front=True, wait=1.1)
            self.visibility(phase + ': synthetic reveal', self.column(phase + ': synthetic reveal'), True)
            self.native_hits(phase + ': revealed hits', True); self.shot(phase + '-revealed')
            self.ask(do='edge', at=[650, 380], front=True, wait=1)
            self.visibility(phase + ': synthetic leave', self.column(phase + ': synthetic leave'), False)
            self.ask(do='edge', **{'let': True})
        if self.count == 128 and phase == 'launch':
            tabs = self.ask(do='tabs')['tabs']
            for tab in tabs[:10]: self.ask(do='select', id=tab['id'])
            self.ask(do='select', id=tabs[0]['id']); time.sleep(1)
            census = self.ask(do='census'); self.note('separately warmed128/10', census)
            self.check('separately warmed fixture ten awake', census['tabs'] - census['asleep'] == 10, census)

    def quit(self, phase):
        proc = self.proc
        requested = time.monotonic()
        try: reply = self.ask(do='quit-ask', yes=True); self.note(phase + ': native Quit confirmation', reply)
        except (OSError, json.JSONDecodeError): pass  # Expected EOF only if owned process actually exits below.
        proc.wait(15)
        self.report['lifecycle'].append({'phase': phase + ': quit', 'pid': proc.pid, 'identity': proc.identity,
            'normal_quit_command': True, 'observed_owned_process_exit': proc.poll() is not None,
            'seconds': time.monotonic() - requested})
        self.proc = None; self.save()

    def run(self):
        try:
            for phase in ('launch', 'relaunch'):
                self.spawn(phase); self.exercise(phase); self.quit(phase)
            self.report['harness_completed'] = True
        except Exception:
            self.report['error'] = traceback.format_exc(); print(self.report['error'], flush=True)
        finally:
            if self.proc and self.proc.poll() is None:
                # Cleanup is distinct from lifecycle success and never repairs
                # a failed Quit/relaunch assertion.
                self.report['forced_cleanup'] = True; self.proc.terminate(); self.proc.wait(15)
            self.report['all_invariants_passed'] = self.report.get('harness_completed', False) and all(c['ok'] for c in self.report['checks'])
            self.save()
        return self.report


def main():
    assert os.environ.get('YAB_FARM_WORKER') == '1'
    if len(sys.argv) == 3 and sys.argv[1] == '--focus-preflight':
        require_focus_contract(Path(sys.argv[2]), 'startup pair before builds')
        return 0
    parser = argparse.ArgumentParser(); parser.add_argument('--base-app', type=Path, required=True)
    parser.add_argument('--app', type=Path, required=True); parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args(); args.out.mkdir(parents=True, exist_ok=True)
    require_focus_contract(args.out, 'startup pair entry')
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Page)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f'http://127.0.0.1:{server.server_port}'
    results = {}
    for label, app in [('base', args.base_app.resolve()), ('candidate', args.app.resolve())]:
        results[label] = []
        for count, hidden, glass in [(35, True, False), (128, True, True), (35, False, True)]:
            world = World(app, args.out / label / f'{count}-{int(hidden)}-{int(glass)}', base, count, hidden, glass)
            results[label].append(world.run())
    server.shutdown()
    complete = all(r.get('harness_completed') for runs in results.values() for r in runs)
    hidden = [r for r in results['base'] if r['initial_hidden']]
    before_reproduced = bool(hidden) and all(hidden_startup_ghost(r) for r in hidden)
    controls = all(r['all_invariants_passed'] for r in results['base'] if not r['initial_hidden'])
    after = all(r['all_invariants_passed'] for r in results['candidate'])
    summary = {'harness_completed': complete, 'baseline_hidden_reproduced': before_reproduced,
               'baseline_docked_control_passed': controls, 'candidate_passed': after,
               'scope': 'native layer geometry, app-drawn frames, native hit tests, actual menu and normal quit/relaunch; synthetic hover only',
               'results': results, 'passed': complete and before_reproduced and controls and after}
    (args.out / 'summary.json').write_text(json.dumps(summary, indent=2, ensure_ascii=False) + '\n')
    print('STARTUP_PAIR ' + json.dumps({k: v for k, v in summary.items() if k != 'results'}), flush=True)
    return 0 if summary['passed'] else 1


if __name__ == '__main__': sys.exit(run_with_focus_guard(main))
