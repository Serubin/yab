#!/usr/bin/env python3
"""Native Chrome tab metadata and browser-bound adopted page acceptance.

Run inside a signed real app built on the exact wave SDK, through farm with
release-signing,capture,pointer. Each IPC operation and observation is bounded.
The original popup queries its owning site's tab and toggles a per-site value
through Chrome storage. SCK captures before/after prove AppKit input reaches it.
"""
import argparse
from contextlib import ExitStack
import http.server
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time
import traceback

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tests'))
from run import wait_socket
from probe_lifetime import PreparedHelperLifetime, NativeHostLifetime, finish_helper, finish_host

HITS = {}
PAGE = b'<!doctype html><title>Page owner</title><body style="background:#bc3543;margin:0;height:100vh">owner'


class Fixture(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        HITS[self.path] = HITS.get(self.path, 0) + 1
        page = PAGE if self.path == '/' else b'<!doctype html><title>Native child</title><style>html,body{margin:0;background:#219653;height:100vh}</style><body>native child'
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(page)))
        self.end_headers()
        self.wfile.write(page)

    def log_message(self, *_):
        pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--host', type=Path, required=True)
    parser.add_argument("--baseline", action="store_true")
    args = parser.parse_args()
    out = Path(os.environ['YAB_FARM_OUT'])
    out.mkdir(parents=True, exist_ok=True)
    report = {'checks': []}
    events = []
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f'http://127.0.0.1:{server.server_port}'
    process = host = peer = None
    seq = 0
    try:
        with tempfile.TemporaryDirectory(prefix='yp-', dir='/tmp') as temporary, (out / 'helper.log').open('w') as log, ExitStack() as cleanup:
            directory = Path(temporary)
            os.chmod(directory, 0o700)
            endpoint = directory / 'core.sock'
            env = dict(os.environ)
            env.pop('YAB_CEF_EXTENSION_WINDOWS', None)
            process = subprocess.Popen([str(args.app / 'Contents/MacOS/PaneCore'), f'--socket={endpoint}',
                f'--data-root={directory / "data"}', '--no-sandbox', '--use-mock-keychain',
                '--no-default-browser-check'], stdout=log, stderr=log, start_new_session=True, env=env)
            helper_lifetime = PreparedHelperLifetime(args.app.resolve(), process, directory / 'data', out)
            cleanup.callback(finish_helper, helper_lifetime, report)
            wait_socket(endpoint, process)
            host = subprocess.Popen([str(args.host), str(out)], stdout=log, stderr=log, start_new_session=True)
            host_lifetime = NativeHostLifetime(host, args.host, out)
            cleanup.callback(finish_host, host_lifetime, report)
            placement = subprocess.run(['./stage', 'put', str(host.pid), '4'],
                                       capture_output=True, text=True, timeout=20)
            report['placement'] = {'exit': placement.returncode, 'stdout': placement.stdout,
                                   'stderr': placement.stderr}
            peer = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            peer.settimeout(15)
            peer.connect(str(endpoint))
            reader = peer.makefile('rb')

            def request(method, params=None, allow_error=False):
                nonlocal seq
                seq += 1
                ident = str(seq)
                peer.sendall((json.dumps({'v': 1, 'id': ident, 'method': method, 'params': params or {}}) + '\n').encode())
                while True:
                    line = reader.readline()
                    if not line:
                        raise RuntimeError('Helper disconnected')
                    message = json.loads(line)
                    if 'event' in message:
                        events.append(message)
                        continue
                    if message.get('id') != ident:
                        raise RuntimeError('Unexpected IPC response: ' + json.dumps(message))
                    if 'error' in message:
                        if allow_error:
                            return {'error': message['error']}
                        raise RuntimeError(method + ': ' + json.dumps(message['error']))
                    return message['result']

            helper_lifetime.shutdown = lambda: request('shutdown')

            def eventually(label, action, timeout=30, pump=None):
                end = time.monotonic() + timeout
                while True:
                    if pump:
                        request('tab.state', {'tab': pump}, allow_error=True)
                    value = action()
                    if value:
                        return value
                    if time.monotonic() > end:
                        raise RuntimeError('Timed out: ' + label)
                    time.sleep(.1)

            def check(name, value, detail=None):
                report['checks'].append({'check': name, 'passed': bool(value), 'detail': detail})
                assert value, (name, detail)

            foreground = eventually('real key host', lambda: (lambda value: value if value.get('key') and value.get('active') else None)(
                          json.loads((out / 'host-window.json').read_text())) if (out / 'host-window.json').exists() else None)
            report['foreground'] = foreground
            import shutil
            hello = request('hello')
            report['hello'] = hello
            check('native tab model advertised', hello['nativeHooks'].get('nativeTabModel'), hello)
            check('native page endpoint advertised', hello['nativeHooks'].get('nativeExternalPages'), hello)
            request('profile.open', {'profile': 'popup'})
            manage = request('extension.open', {'profile': 'popup'})['tab']
            eventually('management tab', lambda: request('tab.state', {'tab': manage})['devToolsReady'])
            fixture = directory / 'fixture'
            shutil.copytree(Path(__file__).resolve().parents[1] / 'tests/external-action', fixture)
            manifest = json.loads((fixture / 'manifest.json').read_text())
            manifest['options_ui'] = {'page': 'options.html', 'open_in_tab': True}
            (fixture / 'manifest.json').write_text(json.dumps(manifest))
            (fixture / 'options.html').write_text('<!doctype html><title>Native metadata options</title>options')
            request('extension.load', {'tab': manage, 'path': str(fixture)})
            extension = eventually('extension installed', lambda: next((r for r in request('extension.list', {'tab': manage})
                                   if r['name'] == 'Yab External Action'), None))
            options = request('tab.create', {'profile': 'popup', 'url': extension['optionsURL']})['tab']
            owner = request('tab.create', {'profile': 'popup', 'url': base + '/'})['tab']
            def ready(tab):
                return (lambda s: s['hasDocument'] and not s['loading'] and s['devToolsReady'])(request('tab.state', {'tab': tab}))
            eventually('owner loaded', lambda: ready(owner), pump=owner)
            eventually('options loaded', lambda: ready(options), pump=options)
            def js(tab, body, argument=None):
                context = eventually('default script context', lambda: next((c for c in request('scripts.status', {'tab': tab})['contexts']
                                     if c['main'] and c['default']), None), pump=tab)
                return request('scripts.evaluate', {'tab': tab, 'frame': context['token'], 'world': '',
                               'function': 'async function(arg){' + body + '}', 'arguments': argument})
            native_owner = js(options, 'return (await chrome.tabs.query({})).find(t=>t.url===arg)', base + '/')
            check('exact native owner identified by URL', native_owner and native_owner.get('id') is not None, native_owner)
            request('tab.focus', {'tab': owner, 'focused': True})
            owner_state = request('tab.state', {'tab': owner})
            mark = len(events)
            created = js(options, 'return await chrome.tabs.create(arg)', {'url': base + '/child',
                         'active': False, 'index': 0, 'openerTabId': native_owner['id'], 'windowId': native_owner['windowId']})
            report['created'] = created
            check('native create preserves background/index/opener', created.get('active') is False and
                  created.get('index') == 0 and created.get('openerTabId') == native_owner['id'], created)
            fresh = js(options, 'return await chrome.tabs.get(arg)', created['id'])
            check('fresh native get preserves background/index/opener', fresh.get('active') is False and
                  fresh.get('index') == 0 and fresh.get('openerTabId') == native_owner['id'], fresh)
            created_event = eventually('early tab.created', lambda: next((e['params'] for e in events[mark:]
                                        if e['event'] == 'tab.created' and e['params'].get('opener') == owner and isinstance(e['params'].get('source'), dict) and e['params']['source'].get('native')), None), pump=owner)
            report['createdEvent'] = created_event
            check('early event has the native owner and background state', created_event.get('opener') == owner and
                  created_event.get('foreground') is False and isinstance(created_event.get('source'), dict) and created_event['source'].get('native'), created_event)
            child = created_event['tab']
            early = request('tab.state', {'tab': child})
            report['earlyState'] = early
            check('native page is bound before adoption', early.get('nativePage', {}).get('bound') and
                  early['nativePage'].get('token') and early['nativePage'].get('windowNumber'), early)
            request('tab.adopt', {'tab': child, 'profile': 'popup', 'private': False})
            eventually('adopted document ready', lambda: ready(child), pump=child)
            marker = js(child, 'globalThis.originalMarker=crypto.randomUUID();return originalMarker')
            request('tab.focus', {'tab': owner, 'focused': False})
            request('tab.focus', {'tab': child, 'focused': True})
            selected = js(options, 'return await chrome.tabs.get(arg)', created['id'])
            check('native activation follows external focus', selected.get('active') is True, selected)
            for target, native_id in [(owner, native_owner['id']), (child, created['id'])]:
                actions = request('ext.actions.state', {'tab': manage, 'page': target, 'extensions': [extension['id']]})
                report.setdefault('actionStates', []).append(actions)
                rows = actions.get('actions', [])
                check('action state keeps exact native tab in a multi-page logical window',
                    len(rows) == 1 and not rows[0].get('error') and rows[0].get('action') is True and
                    rows[0].get('tabId') == native_id and actions.get('windowId') == created['windowId'], actions)
            child_state = request('tab.state', {'tab': child})
            report['childState'] = child_state
            check('adopted page has its own producer', child_state['nativeWindow'] != owner_state['nativeWindow'] and
                  child_state['nativePage']['browserId'] != 0, child_state)
            from PIL import Image
            captures = []
            for index, (width, height) in enumerate([(640, 420), (1000, 720), (640, 420), (1000, 720), (640, 420)]):
                request('tab.resize', {'tab': child, 'width': width, 'height': height, 'scale': 2, 'serial': str(index)})
                def exact():
                    state = request('tab.state', {'tab': child})
                    page = state.get('nativePage') or {}
                    return state if page.get('rendererBound') and page.get('frameMatchesGeometry') and abs(page.get('pageWidth', 0)-width)<1 and abs(page.get('pageHeight', 0)-height)<1 else None
                state = eventually('exact native page size', exact, 20, pump=child)
                native = state['nativePage']; report.setdefault('resizeStates', []).append(native)
                check('native dimensions remain under the GPU limit', native['pixelWidth'] <= 16384 and native['pixelHeight'] <= 16384, native)
                check('same native document survives resize', js(child, 'return originalMarker') == marker)
                if index in (0, 1, 4):
                    name = f'page-{index}'
                    statefile = out / 'host-state.pending'
                    statefile.write_text(json.dumps({'token': name, 'contextId': native['contextId'], 'width': width,
                                                    'height': height, 'pageX': native['pageX'], 'pageY': native['pageY']}))
                    statefile.replace(out / 'host-state.json')
                    pixels = eventually('native page SCK', lambda: json.loads((out / (name + '.json')).read_text())
                                        if (out / (name + '.json')).exists() else None, 35, pump=child)
                    capture = json.loads((out / (name + '.capture.json')).read_text())
                    check('real page is green without exposed backing', capture['on_screen'] is True and
                          pixels['own'] == 'ScreenCaptureKit' and pixels['green'] > pixels['total']*.85 and
                          pixels['magenta'] == 0, pixels)
                    captures.append(name + '.png')
            report['captures'] = captures
            check('no document reload during adoption/resize', HITS.get('/child') == 1, HITS)
            request('tab.visible', {'tab': child, 'visible': False})
            hidden = request('tab.focus', {'tab': child, 'focused': True}, allow_error=True)
            check('hidden page refuses native focus', 'error' in hidden, hidden)
            request('tab.visible', {'tab': child, 'visible': True})
            request('tab.focus', {'tab': child, 'focused': True})
            state = request('tab.state', {'tab': child})
            check('independent producer remains concealed', state['producer']['onScreen'] is False and not state['producer']['key'], state['producer'])
            if not helper_lifetime.quit(): raise RuntimeError('Original helper shutdown failed')
            check('helper exits cleanly', process.returncode == 0, process.returncode)
            report['passed'] = True
    except Exception as error:
        report['error'] = repr(error) + ' ' + traceback.format_exc()[-2200:]
        raise
    finally:
        if peer: peer.close()
        server.shutdown()
        server.server_close()
        report['events'] = [e for e in events if e['event'] in ('tab.created', 'layer', 'tab.resized')]
        report['hits'] = HITS
        (out / 'page-proof.json').write_text(json.dumps(report, indent=2) + '\n')

if __name__ == '__main__': main()
