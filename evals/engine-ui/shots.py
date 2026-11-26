#!/usr/bin/env python3
"""Settings › Engine, ⌘K's engine rows, the site menu's Opens in and the hover
card's foot on the real signed CEF app, light and dark (round 2 of the
engine artifact). Settings by winshot, the rest by ScreenCaptureKit with
menus pressed through Accessibility. Farm only: capture, accessibility, pyobjc.

    evals/engine-ui/job.sh   (builds the app, then runs this)
"""
import argparse
import http.server
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import sys
import threading
import time
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'chromium-tabs'))
sys.path.append(str(Path(__file__).resolve().parents[1] / 'chromium-drm'))
from run import launch_exact, wait_for
from probe_capture import picture
import yab_socket
import ax
from capture_menus import picture_with_menus

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'chromium-extensions'))
from prepared_lifetime import PreparedAppLifetime


class Pages(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        title = {'/pr': 'Pull Request #412', '/video': 'Netflix', '/design': 'Yab design'}.get(self.path, 'Engine fixture')
        body = f'''<!doctype html><meta charset="utf-8"><title>{title}</title>
<style>body{{margin:40px;background:#f4f1ea;color:#222;font:24px system-ui}}</style>
<h1>{title}</h1><p id="engine"></p><script>
document.querySelector('#engine').textContent=navigator.userAgent.includes('Chrome/')?'Chromium':'WebKit';
</script>'''.encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


def run(app, out, port):
    out.mkdir(parents=True, exist_ok=True)
    world = 'engine-ui-' + uuid.uuid4().hex[:8]
    domain = 'dev.serafim.fast.test.' + world
    sock = Path.home() / 'Library/Application Support' / f'Pane ({world})' / 'bench.sock'
    defaults = out / 'defaults.plist'
    # localhost stands in for a protected-video service; two rules of the
    # owner's own, as drawn.
    defaults.write_bytes(plistlib.dumps({'bench': True, 'welcomed': True, 'mail': False, 'hints.noticing': False,
                                        'searchSuggest': False, 'drm.test.domains': ['localhost'],
                                        'site.engine.figma.com': 'chromium', 'site.engine.notion.so': 'webKit',
                                        'ApplePersistenceIgnoreState': True, 'NSQuitAlwaysKeepsWindows': False}))
    subprocess.run(['defaults', 'import', domain, str(defaults)], check=True)
    proc = launch_exact(app, dict(os.environ, YAB_PROBE=world, YAB_HISTORY='own', YAB_ENGINE='chromium',
                                 YAB_AGENT_CLAUDE='/usr/bin/true', YAB_AGENT_CODEX='/nonexistent/chromium'), out)
    ask = yab_socket.kwasker(sock, timeout=45, strict=True, takes_timeout=True,
                            fail=lambda req, reply: RuntimeError(f'{req}: {reply}'))
    lifetime = PreparedAppLifetime(app, proc, sock.parent, ask, out)
    report = {'app': str(app), 'pid': proc.pid, 'checks': {}, 'states': {}, 'pictures': [], 'errors': []}
    checks = report['checks']
    pid = proc.pid
    tabs = {}

    def engine(tab):
        return ask(do='chromium-drm', id=tab, op='site-engine')

    def wait_engine(tab, kind, why):
        def ready():
            s = ask(do='chromium-drm', id=tab)
            report['states']['wait-' + why] = s
            return s if s['engine'] == kind and not s['loading'] else None
        return wait_for(ready, why, 60)

    def front():
        from AppKit import NSRunningApplication, NSApplicationActivateIgnoringOtherApps
        target = NSRunningApplication.runningApplicationWithProcessIdentifier_(pid)
        target.unhide()
        target.activateWithOptions_(NSApplicationActivateIgnoringOtherApps)

    def window_shot(name, menus=False):
        path = out / (name + '.png')
        meta = picture(pid, path, window_id=0)
        if menus:
            meta = picture_with_menus(pid, path, meta)
        report['pictures'].append({'name': name, 'file': path.name, 'capture': meta.get('capture')})
        checks[name + '_sck'] = meta.get('capture') == 'ScreenCaptureKit'
        return path

    def step(name, fn):
        try:
            fn()
        except Exception as error:
            report['errors'].append(f'{name}: {error}')
            try:
                (out / (name + '-failure-ax.txt')).write_text(ax.dump(pid))
            except Exception:
                pass

    def one_appearance(look):
        ask(do='ui', look=look)
        time.sleep(.6)

        def settings():
            ask(wait=90, **{'do': 'ui', 'page': 'engine', 'settings': True})
            ask(wait=90, do='census')
            time.sleep(1.5)
            # A layer render of Settings comes out blank: ScreenCaptureKit
            # takes its window by number.
            windows = ask(do='ui', windows=True).get('windows', [])
            report['states'][f'{look}-windows'] = windows
            found = next(w for w in windows if 'Settings' in str(w.get('kind', '')) or w.get('title') == 'Settings')
            path = out / f'{look}-1-settings-engine.png'
            meta = picture(pid, path, window_id=found['id'])
            report['pictures'].append({'name': path.stem, 'file': path.name, 'capture': meta.get('capture')})
            checks[f'{look}-settings-shot'] = meta.get('capture') == 'ScreenCaptureKit'
            ask(do='ui', settings=False)
            time.sleep(.6)
        step(f'{look}-settings', settings)

        def actions():
            front()
            # The field lists open tabs other than the one in front.
            ask(do='select', id=tabs['other'])
            time.sleep(.4)
            ask(do='ui', newTab=True)
            time.sleep(.6)
            ask(do='ui', typed='Pull Request')
            time.sleep(1.0)
            ask(do='ui', pickOpen=True)
            time.sleep(1.0)
            titles = engine(tabs['pr']).get('actions', [])
            report['states'][f'{look}-actions'] = titles
            checks[f'{look}-actions-rows'] = 'Open in Chromium' in titles and 'Always Open in Chromium' in titles
            window_shot(f'{look}-2-cmdk-actions')
            ask(do='ui', closeField=True)
            time.sleep(.6)
        step(f'{look}-actions', actions)

        def site_menu():
            front()
            tab = tabs['video']
            ask(do='select', id=tab)
            time.sleep(.5)
            ax.cancel_menus(pid)
            ask(do='ui', extensions=True)
            box = wait_for(lambda: ax.popover_box(pid), 'Site Controls did not open', 6)
            time.sleep(.6)
            found = [c for c in ax.controls(pid, box, ('AXMenuButton', 'AXPopUpButton')) if c['frame'][1] > box[1] + box[3] - 60]
            if not found:
                found = [c for c in ax.controls(pid, box) if c['frame'][1] > box[1] + box[3] - 60]
            if not found or not ax.show_menu(max(found, key=lambda c: c['frame'][0])['element']):
                raise RuntimeError('the foot menu did not open')
            wait_for(lambda: ax.item(pid, 'Opens in'), 'foot menu has no Opens in', 5)
            log = report['states'].setdefault(f'{look}-submenu', {})
            if not ax.open_submenu(pid, 'Opens in', 'Auto (WebKit)', log):
                raise RuntimeError('Opens in did not open: ' + str(log))
            time.sleep(.5)
            marks = {i['title']: i['mark'] for i in ax.items(pid) if i['title']}
            report['states'][f'{look}-marks'] = marks
            checks[f'{look}-auto-checked'] = bool(marks.get('Auto (WebKit)')) and not marks.get('Chromium') and 'WebKit' in marks
            window_shot(f'{look}-3-site-menu', menus=True)
            ax.cancel_menus(pid)
            ask(do='ui', extensions=False)
            time.sleep(.5)
        step(f'{look}-site-menu', site_menu)

        def cards():
            front()
            for key, want in (('pr', 'WebKit'), ('video', 'WebKit · Protected video'), ('design', 'Chromium')):
                ask(do='select', id=tabs['other'])
                time.sleep(.3)
                reply = ask(do='glance', id=tabs[key])
                report['states'][f'{look}-card-{key}'] = reply
                foot = engine(tabs[key]).get('foot')
                checks[f'{look}-card-{key}-foot'] = foot == want
                time.sleep(.4)
                window_shot(f'{look}-4-card-{key}')
                ask(do='glance', id=tabs[key], on=False)
                time.sleep(.3)
        step(f'{look}-cards', cards)

    try:
        wait_for(lambda: sock.exists() if proc.poll() is None else False, 'Missing bench socket', 60)
        ask(do='ui', welcome=False, sidebar=True)
        for element, _ in ax.walk(ax.app(pid)):
            if ax.value(element, 'AXRole') == 'AXButton' and ax.value(element, 'AXTitle') in ('Don’t Reopen', "Don't Reopen"):
                ax.press(element)
                break
        # Auto with memory tight: the pull request opens in WebKit.
        # The window's first tab may already hold a page built before memory
        # got tight: it takes a page of its own first.
        tabs['other'] = ask(do='usage-open', url=f'http://127.0.0.1:{port}/other')['id']
        wait_engine(tabs['other'], 'chromium', 'the first tab did not open in Chromium')
        ask(do='pressure', level=2)
        tabs['pr'] = ask(do='usage-open', url=f'http://127.0.0.1:{port}/pr')['id']
        wait_engine(tabs['pr'], 'webKit', 'Auto did not spare memory with WebKit')
        ask(do='pressure', level=0)
        tabs['video'] = ask(do='usage-open', url=f'http://localhost:{port}/video')['id']
        wait_engine(tabs['video'], 'webKit', 'the protected stand-in did not open in WebKit')
        tabs['design'] = ask(do='usage-open', url=f'http://127.0.0.1:{port}/design')['id']
        wait_engine(tabs['design'], 'chromium', 'the default tab did not open in Chromium')
        for look in ('light', 'dark'):
            one_appearance(look)
        report['ok'] = bool(checks) and all(checks.values()) and not report['errors']
    finally:
        lifetime.finish(report, result_key='ok')
        subprocess.run(['defaults', 'delete', domain], capture_output=True)
    print(json.dumps({'checks': checks, 'errors': report['errors']}, indent=1, default=str))
    if not report['ok']:
        raise SystemExit('Engine UI pictures incomplete')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Pages)
    threading.Thread(target=server.serve_forever, daemon=True).start()

    def deadline(*_):
        raise TimeoutError('Engine UI pictures exceeded 600 seconds')

    signal.signal(signal.SIGALRM, deadline)
    signal.alarm(600)
    try:
        run(args.app, args.out, server.server_port)
    finally:
        signal.alarm(0)
        server.shutdown()
