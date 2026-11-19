#!/usr/bin/env python3
"""Original Chrome action widget on CEF_CTT_NONE, no toolbar fallback.

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
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import traceback

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tests'))
from run import wait_socket
from probe_lifetime import PreparedHelperLifetime, NativeHostLifetime, finish_helper, finish_host
from native_rpc import report_capture_refusal

PAGE = b'<!doctype html><title>Popup owner</title><body style="background:#bc3543;margin:0;height:600px">owner'


class Fixture(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(PAGE)))
        self.end_headers()
        self.wfile.write(PAGE)

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

            hello = request('hello')
            report['hello'] = hello
            request('profile.open', {'profile': 'popup'})
            manage = request('extension.open', {'profile': 'popup'})['tab']
            eventually('management tab', lambda: request('tab.state', {'tab': manage})['url'] == 'chrome://extensions/' and
                       request('tab.state', {'tab': manage})['devToolsReady'])
            source = Path(__file__).resolve().parents[1] / 'tests/external-action'
            fixture = directory / 'fixture'
            shutil.copytree(source, fixture)
            manifest = json.loads((fixture / 'manifest.json').read_text())
            manifest['options_ui'] = {'page': 'options.html', 'open_in_tab': True}
            (fixture / 'manifest.json').write_text(json.dumps(manifest))
            (fixture / 'options.html').write_text('<!doctype html><title>Native action options</title>options')
            request('extension.load', {'tab': manage, 'path': str(fixture)})
            rows = eventually('extension installed', lambda: [r for r in request('extension.list', {'tab': manage})
                              if r['name'] == 'Yab External Action'])
            extension = rows[0]['id']
            report['extension'] = extension
            options = request('tab.create', {'profile': 'popup',
                'url': 'chrome-extension://' + extension + '/options.html'})['tab']
            eventually('options ready', lambda: request('tab.state', {'tab': options})['devToolsReady'], pump=options)
            owner = request('tab.create', {'profile': 'popup', 'url': base + '/'})['tab']
            eventually('owner ready', lambda: (lambda s: s['hasDocument'] and not s['loading'] and
                       s['url'].startswith(base))(request('tab.state', {'tab': owner})), pump=owner)
            state = request('tab.state', {'tab': owner})
            report['producerBefore'] = state
            check('CEF_CTT_NONE owner uses a BrowserView', state['geometry']['views'] and not state['nativeExtensionWindow'], state)
            check('producer is externally hosted', state['producer']['externallyHosted'], state)
            foreground = eventually('real key host', lambda: (lambda value: value if value.get('key') and value.get('active') else None)(
                          json.loads((out / 'host-window.json').read_text())) if (out / 'host-window.json').exists() else None)
            report['foreground'] = foreground
            hidden = request('extension.action.open', {'tab': owner, 'extension': extension}, allow_error=True)
            check('unfocused action is refused', 'error' in hidden, hidden)
            request('tab.focus', {'tab': owner, 'focused': True})
            if not args.baseline:
                def options_js(body, argument=None):
                    context = eventually('native options context', lambda: next((c for c in
                        request('scripts.status', {'tab': options})['contexts'] if c['main'] and c['default']), None), pump=options)
                    return request('scripts.evaluate', {'tab': options, 'frame': context['token'], 'world': '',
                        'function': 'async function(arg){' + body + '}', 'arguments': argument})
                native_owner = options_js('return (await chrome.tabs.query({})).find(t=>t.url===arg)', base + '/')
                # Original extensions may open a foreground welcome page after
                # installation. The next action still belongs to its explicit,
                # externally focused owner, not that asynchronous native child.
                child = options_js('return await chrome.tabs.create(arg)', {'url': base + '/shadow',
                    'active': True, 'windowId': native_owner['windowId'], 'openerTabId': native_owner['id']})
                fresh_owner = options_js('return await chrome.tabs.get(arg)', native_owner['id'])
                report['foregroundChildBeforeAction'] = {'owner': fresh_owner, 'child': child,
                    'producer': request('tab.state', {'tab': owner})}
                check('native foreground child really changed the logical active tab',
                      child.get('active') is True and fresh_owner.get('active') is False,
                      report['foregroundChildBeforeAction'])
            mark = len(events)
            opened = request('extension.action.open', {'tab': owner, 'extension': extension,
                              'anchor': {'x': 100, 'y': 100, 'width': 24, 'height': 24}}, allow_error=True)
            if args.baseline:
                check('baseline lacks the toolbar-free native entry', 'error' in opened, opened)
                report['passed'] = True
                if not helper_lifetime.quit(): raise RuntimeError('Original helper shutdown failed')
                return
            check('native action entry is advertised', hello.get('nativeHooks', {}).get('externalExtensionAction'), hello)
            check('original action opens without a toolbar', 'error' not in opened and opened.get('opened'), opened)
            shown = eventually('popup.layer shown', lambda: next((e['params'] for e in events[mark:]
                               if e['event'] == 'popup.layer' and e['params'].get('contextId') and
                               float(e['params'].get('pixelWidth', 0)) >= 300 * float(e['params'].get('scale', 1)) and
                               float(e['params'].get('pixelHeight', 0)) >= 160 * float(e['params'].get('scale', 1))), None), 20, pump=owner)
            report['popup'] = shown
            context = shown.get('contextId', 0)
            check('CAContext is a lossless unsigned 32-bit JSON value',
                  0 < context <= 0xffffffff and int(context) == context, shown)
            check('popup names its owner tab', shown.get('tab') == owner, shown)
            check('popup names its extension', shown.get('extensionId') == extension, shown)
            check('popup has a token and a compositor context', shown.get('token') and shown.get('contextId') and shown.get('windowNumber'), shown)
            scale = max(float(shown.get('scale') or 1), 1.0)
            width = max(int(float(shown.get('pixelWidth') or 0) / scale), 240)
            height = max(int(float(shown.get('pixelHeight') or 0) / scale), 120)
            pending = out / 'host-state.pending'
            pending.write_text(json.dumps({'contextId': shown['contextId'], 'width': width, 'height': height, 'token': 'popup'}))
            pending.replace(out / 'host-state.json')
            image = eventually('popup capture', lambda: json.loads((out / 'popup.json').read_text())
                               if (out / 'popup.json').exists() else None, pump=owner)
            report['popupPixels'] = image
            capture = json.loads((out / 'popup.capture.json').read_text())
            report['popupCapture'] = capture
            check('real popup host is on screen', capture.get('on_screen') is True, capture)
            check('popup pixels are the popup page in a key host', image['own'] == 'ScreenCaptureKit' and image['green'] > image['total'] * .3 and image['key'] and image['active'], image)
            check('delegated popup focus is accepted', 'error' not in request('popup.focus',
                  {'tab': owner, 'token': shown['token'], 'focused': True}, allow_error=True))
            other = request('popup.input', {'tab': manage, 'token': shown['token'], 'kind': 'mouseMove', 'x': 20, 'y': 20}, allow_error=True)
            check('another tab cannot drive the popup', 'error' in other, other)
            anchor = request('popup.anchor', {'tab': owner, 'token': shown['token'],
                             'anchor': {'x': 120, 'y': 120, 'width': 24, 'height': 24}}, allow_error=True)
            check('native anchor update is accepted', 'error' not in anchor, anchor)
            for kind in ('mouseMove', 'mouseDown', 'mouseUp'):
                click = request('popup.input', {'tab': owner, 'token': shown['token'],
                                'kind': kind, 'x': 140, 'y': 70}, allow_error=True)
                check('popup input ' + kind, 'error' not in click, click)
            # Let the popup's storage promise and renderer commit finish, then
            # capture the same native compositor, never a replacement page.
            from PIL import Image
            def capture_click():
                name = 'popup-clicked-' + str(len(list(out.glob('popup-clicked-*.json'))))
                pending.write_text(json.dumps({'contextId': shown['contextId'], 'width': width, 'height': height, 'token': name}))
                pending.replace(out / 'host-state.json')
                receipt = eventually('click capture', lambda: json.loads((out / (name + '.json')).read_text())
                                     if (out / (name + '.json')).exists() else None, pump=owner)
                picture = Image.open(out / (name + '.png')).convert('RGB')
                pixels = [picture.getpixel((x, y)) for y in range(20, picture.height - 20, 10)
                          for x in range(20, picture.width - 20, 10)]
                blue = sum(b > 130 and b > r * 1.5 and b > g * 1.3 for r, g, b in pixels)
                report['clickedPixels'] = {'receipt': receipt, 'blue': blue, 'total': len(pixels)}
                return receipt['own'] == 'ScreenCaptureKit' and blue > len(pixels) * .3
            eventually('per-site toggle changes original popup pixels', capture_click, 15)
            check('original popup per-site toggle changed pixels', True, report['clickedPixels'])
            state = request('tab.state', {'tab': owner})
            report['producerAfter'] = state['producer']
            check('producer never ordered on screen', not state['producer']['visible'] and
                  not state['producer']['key'] and state['producer']['onScreen'] is False, state['producer'])
            request('popup.close', {'tab': owner, 'token': shown['token']})
            closed = request('popup.input', {'tab': owner, 'token': shown['token'], 'kind': 'mouseMove'}, allow_error=True)
            check('closed token refuses input', 'error' in closed, closed)
            # A second original widget must have a new identity. Navigation
            # retires its captured native owner document before late input.
            mark = len(events)
            request('extension.action.open', {'tab': owner, 'extension': extension})
            second = eventually('second original popup', lambda: next((e['params'] for e in events[mark:]
                                if e['event'] == 'popup.layer' and e['params'].get('contextId')), None), 20, pump=owner)
            check('new widget has a distinct token', second['token'] != shown['token'], second)
            request('tab.navigate', {'tab': owner, 'url': base + '/replacement'})
            eventually('replacement document', lambda: request('tab.state', {'tab': owner})['url'].endswith('/replacement'))
            stale = request('popup.input', {'tab': owner, 'token': second['token'], 'kind': 'mouseMove'}, allow_error=True)
            check('retired native document refuses late input', 'error' in stale, stale)
            if not helper_lifetime.quit(): raise RuntimeError('Original helper shutdown failed')
            report['passed'] = True
    except Exception as error:
        report['error'] = repr(error) + ' ' + traceback.format_exc()[-1500:]
        raise
    finally:
        if peer:
            peer.close()
        report_capture_refusal(out)
        server.shutdown()
        server.server_close()
        report['events'] = [e for e in events if e['event'].startswith('popup.') or e['event'] == 'tab.created']
        (out / 'popup-proof.json').write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
