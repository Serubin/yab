#!/usr/bin/env python3
"""A focused page swapped out of its renderer while YabCore emulates focus.

Crash report 1153 (0.46.13, PaneCore Helper (Renderer)): null dereference at
0x5c0 in blink::FrameSelection::FocusedOrActiveStateChanged <-
FocusController::FocusHasChanged <- InspectorEmulationAgent::disable <-
DevToolsSession::Detach <- WebDevToolsAgentImpl::WillBeDestroyed <-
WebLocalFrameImpl::WillBeDetached <- Frame::Swap <- RenderFrameImpl::Unload.
YabCore turns Emulation.setFocusEmulationEnabled on for a visible page
(scripts.appearance focused). When the page's main frame moves to another
process and its old renderer keeps a proxy (an opener relation keeps the
browsing instance), the old frame is swapped and detached; its DevTools
agent disables focus emulation, the page loses focus, and FocusHasChanged
reaches the detaching frame, whose selection has no document any more.
CEF patch 0107 skips a frame that is no longer attached.

Usage: focus_emulation_swap.py YABCORE_EXECUTABLE [--rounds N]
Exit 0: no renderer crashed. Exit 1: a renderer crashed (reproduced).
"""
import argparse
import http.server
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import traceback

sys.path.insert(0, str(Path(__file__).resolve().parent))
from run import wait_socket

PAGE = (b'<!doctype html><title>Focus</title><body style="margin:0;background:#357">'
        b'<input id=i autofocus value="caret here"><script>document.getElementById("i").focus()</script>')


class Fixture(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Cache-Control', 'no-store')  # never kept in the back/forward cache
        self.send_header('Content-Length', str(len(PAGE)))
        self.end_headers()
        self.wfile.write(PAGE)

    def log_message(self, *_):
        pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('helper', type=Path)
    parser.add_argument('--rounds', type=int, default=6)
    args = parser.parse_args()
    out = Path(os.environ['YAB_FARM_OUT']) / 'focus-emulation-swap'
    out.mkdir(parents=True, exist_ok=True)
    report = {'machine': os.uname().nodename, 'rounds': []}
    started = time.time()
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    port = server.server_port
    helper = peer = None
    code = 2
    seq = 0
    events = []
    try:
        with tempfile.TemporaryDirectory(prefix='ycf-', dir='/tmp') as temporary, (out / 'helper.log').open('w') as log:
            directory = Path(temporary)
            os.chmod(directory, 0o700)
            endpoint = directory / 'core.sock'
            helper = subprocess.Popen([str(args.helper), f'--socket={endpoint}', f'--data-root={directory / "data"}',
                '--no-sandbox', '--use-mock-keychain', '--no-default-browser-check'],
                stdout=log, stderr=log, start_new_session=True)
            wait_socket(endpoint, helper)
            peer = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            peer.settimeout(30)
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
                        raise ConnectionError('YabCore disconnected during ' + method)
                    message = json.loads(line)
                    if 'event' in message:
                        events.append(message)
                        continue
                    if message.get('id') != ident:
                        continue
                    if 'error' in message:
                        if allow_error:
                            return {'error': message['error']}
                        raise RuntimeError(method + ': ' + json.dumps(message['error']))
                    return message['result']

            def ready(tab, prefix, timeout=30):
                end = time.monotonic() + timeout
                while time.monotonic() < end:
                    state = request('tab.state', {'tab': tab})
                    if state.get('devToolsReady') and state.get('hasDocument') and not state.get('loading') and \
                            state.get('url', '').startswith(prefix):
                        return state
                    time.sleep(.1)
                raise RuntimeError('page not ready: ' + json.dumps(state)[:400])

            request('hello')
            request('profile.open', {'profile': 'focus'})
            for round_ in range(args.rounds):
                a = f'http://127.0.0.1:{port}/a{round_}'
                b = f'http://localhost:{port}/b{round_}'
                tab = request('tab.create', {'profile': 'focus', 'url': a})['tab']
                request('tab.visible', {'tab': tab, 'visible': True}, allow_error=True)
                ready(tab, a)
                row = {'round': round_, 'appearance': request('scripts.appearance', {'tab': tab,
                       'appearance': {'scheme': 'light', 'focused': True}}, allow_error=True)}
                mark = len(events)
                # A same-site popup shares the page's renderer and keeps it as opener.
                row['open'] = request('script.document', {'tab': tab, 'userGesture': True,
                    'expression': f'!!window.open("http://127.0.0.1:{port}/popup{round_}", "_blank")'}, allow_error=True)
                time.sleep(1.5)
                row['focusedBefore'] = request('script.document', {'tab': tab,
                    'expression': 'document.hasFocus() + " " + (document.activeElement && document.activeElement.id)'}, allow_error=True)
                # Renderer-initiated, cross-site: the old frame is swapped to a proxy.
                request('script.document', {'tab': tab, 'expression': f'location.href = "{b}"; true'}, allow_error=True)
                try:
                    ready(tab, b)
                except RuntimeError as error:
                    row['navigation'] = repr(error)
                time.sleep(1)
                row['crashes'] = [e['params'] for e in events[mark:] if e['event'] == 'page.crash']
                report['rounds'].append(row)
                if row['crashes']:
                    break
            crashed = any(r['crashes'] for r in report['rounds'])
            report['rendererCrashed'] = crashed
            request('shutdown', allow_error=True)
            helper.wait(timeout=20)
            code = 1 if crashed else 0
    except Exception as error:
        report['error'] = repr(error) + ' ' + traceback.format_exc()[-1500:]
    finally:
        if peer:
            peer.close()
        if helper and helper.poll() is None:
            try:
                os.killpg(helper.pid, signal.SIGTERM)
                helper.wait(timeout=10)
            except Exception:
                pass
        server.shutdown()
        server.server_close()
        time.sleep(3)
        reports = []
        for path in (Path.home() / 'Library/Logs/DiagnosticReports').glob('PaneCore Helper (Renderer)*.ips'):
            if path.stat().st_mtime < started:
                continue
            text = path.read_text(errors='replace')
            body = json.loads(text[text.index('\n{') + 1:])
            if body.get('parentPid') == (helper.pid if helper else -1):
                reports.append(path)
                shutil.copy(path, out / path.name)
        report['crashReports'] = [str(p) for p in reports]
        report['exitCode'] = code
        (out / 'result.json').write_text(json.dumps(report, indent=2) + '\n')
        print(json.dumps({k: report.get(k) for k in ('rendererCrashed', 'crashReports', 'error', 'exitCode')}, indent=2))
        print('rounds', json.dumps(report['rounds'])[:3000], flush=True)
        for path in reports:
            text = path.read_text(errors='replace')
            body = json.loads(text[text.index('\n{') + 1:])
            thread = body['threads'][body.get('faultingThread', 0)]
            names = {i: image.get('name') for i, image in enumerate(body.get('usedImages', []))}
            print('crash', body.get('exception'), flush=True)
            for frame in thread['frames'][:12]:
                print('  ', names.get(frame.get('imageIndex')), hex(frame.get('imageOffset', 0)), frame.get('symbol', ''), flush=True)
    sys.exit(code)


if __name__ == '__main__':
    main()
