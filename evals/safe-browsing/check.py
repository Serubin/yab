#!/usr/bin/env python3
"""Local feed and real navigation evidence in separate off/on profiles."""
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import plistlib
import socket
import subprocess
import sys
import threading
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'evals'))
from probe_app import launch
import probe_capture
import probe_ocr


def main():
    out = Path(os.environ['YAB_FARM_OUT']) / 'safe-browsing'
    out.mkdir(parents=True, exist_ok=True)
    requests = []
    results = []
    app_path = ROOT / 'build/Pane Dev.app'
    info = plistlib.loads((app_path / 'Contents/Info.plist').read_bytes())
    task_name = os.environ['YAB_TASK_NAME']
    assert info['CFBundleName'] == info['CFBundleDisplayName'] == task_name
    (out / 'app-name.json').write_text(json.dumps({key: info[key] for key in
        ('CFBundleName', 'CFBundleDisplayName', 'CFBundleIdentifier', 'CFBundleExecutable')}, indent=2))

    class Site(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            requests.append(self.path)
            if self.path == '/lists/phishing.json':
                body = json.dumps({'updated': time.time(), 'hashes': [
                    hashlib.sha256(b'127.0.0.1').hexdigest()]}).encode()
                mime = 'application/json'
            elif self.path.startswith('/pay'):
                body = b'<html><title>Local navigation fixture</title><body>Local navigation fixture</body></html>'
                mime = 'text/html'
            else:
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header('Content-Type', mime)
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    server = ThreadingHTTPServer(('127.0.0.1', 0), Site)
    base = f'http://127.0.0.1:{server.server_port}'
    threading.Thread(target=server.serve_forever, daemon=True).start()

    def wait(test, description):
        deadline = time.monotonic() + 40
        while time.monotonic() < deadline:
            value = test()
            if value:
                return value
            time.sleep(.2)
        raise TimeoutError(description)

    def expect(value, description):
        results.append({'passed': bool(value), 'description': description})
        print(('PASS ' if value else 'FAIL ') + description, flush=True)
        if not value:
            raise AssertionError(description)

    def shot(app, name, expected, window_id=None):
        path = out / (name + '.png')
        # cacheDisplay can omit SwiftUI's light appearance. Capture the
        # owned window instead, and refuse blank pictures before passing.
        if os.environ.get('WHERE') in ('aws-1', 'aws-2'):
            helper = Path.home() / '.local/state/yab-farm/capture-tools/capture-window'
            if not helper.is_file():
                helper = out / 'capture-window'
                subprocess.run(['swiftc', '-O', str(ROOT / 'evals/probe_capture.swift'),
                                '-o', str(helper)], check=True)
            captured = subprocess.run([str(helper), str(app.pid), str(path),
                                       str(window_id or 0)], check=True,
                                      capture_output=True, text=True, timeout=15)
            path.with_suffix('.json').write_text(captured.stdout)
        else:
            probe_capture.picture(app.pid, path, window_id=window_id)
        words = '\n'.join(probe_ocr.words(str(path)))
        path.with_suffix('.txt').write_text(words)
        expect(expected.lower() in words.lower(), name + ': expected text is visible')

    try:
        for enabled in (False, True):
            phase = 'on' if enabled else 'off'
            world = 'safe-browsing-' + phase + '-' + uuid.uuid4().hex[:8]
            domain = 'dev.serafim.fast.test.' + world
            support = Path.home() / 'Library/Application Support' / f'Pane ({world})'
            sock = support / 'bench.sock'
            for key in ('bench', 'welcomed'):
                subprocess.run(['defaults', 'write', domain, key, '-bool', 'true'], check=True)
            if enabled:
                subprocess.run(['defaults', 'write', domain, 'safe.browsing', '-bool', 'true'], check=True)

            def ask(**request):
                with socket.socket(socket.AF_UNIX) as connection:
                    connection.settimeout(30)
                    connection.connect(str(sock))
                    connection.sendall((json.dumps(request) + '\n').encode())
                    data = b''
                    while b'\n' not in data:
                        chunk = connection.recv(65536)
                        if not chunk:
                            raise RuntimeError('bench closed')
                        data += chunk
                reply = json.loads(data.split(b'\n', 1)[0])
                if reply.get('error'):
                    raise RuntimeError(f'{request}: {reply}')
                return reply

            start = len(requests)
            app = launch(app_path, dict(os.environ, YAB_PROBE=world,
                         YAB_HISTORY='own', YAB_FEED=base + '/appcast.json'), out,
                         task_name=task_name)
            try:
                wait(lambda: sock.exists(), 'probe socket')
                if enabled:
                    wait(lambda: (support / 'phishing-hashes.json').exists(), 'downloaded local list')
                    expect('/lists/phishing.json' in requests[start:], 'Opting in downloads the whole local list')
                ask(do='ui', page='privacy', settings=True, spot='safe-browsing', look='light')
                time.sleep(2)
                windows = ask(do='ui', windows=True)['windows']
                settings = next(w for w in windows if 'Settings' in w['kind'] or w['title'] == 'Settings')
                shot(app, f'settings-{phase}', 'Warn before phishing sites', settings['id'])
                ask(do='ui', settings=False)
                tab = ask(do='open', url=base + '/pay-' + phase, fresh=True)
                ask(do='select', id=tab['id'])
                if enabled:
                    time.sleep(3)
                    expect('/pay-on' not in requests[start:], 'On: the listed navigation never reaches the server')
                else:
                    wait(lambda: '/pay-off' in requests[start:], 'off navigation reaches fixture')
                    expect('/lists/phishing.json' not in requests[start:], 'Default off: no list request')
                    expect('/pay-off' in requests[start:], 'Default off: the same host loads normally')
                time.sleep(1)
                shot(app, f'navigation-{phase}', 'is on a phishing list' if enabled else 'Local navigation fixture')
                for look in ('light', 'dark') if enabled else ():
                    ask(do='ui', look=look)
                    time.sleep(1)
                    shot(app, f'warning-{look}', 'is on a phishing list')
                before_reload = requests.count('/pay-' + phase)
                ask(do='chord', id=tab['id'], keys='cmd+r')
                if enabled:
                    time.sleep(1)
                    expect(requests.count('/pay-on') == 0, 'Reload does not bypass the warning')
                else:
                    wait(lambda: requests.count('/pay-off') > before_reload, 'native reload reaches fixture')
                    expect(True, 'Default off: native Command-R reloads the page')
                (out / f'tab-{phase}.json').write_text(json.dumps(ask(do='tabs'), indent=2))
            finally:
                app.terminate()
                app.wait()
    finally:
        server.shutdown()
        (out / 'summary.json').write_text(json.dumps({'host': os.environ.get('WHERE'),
            'checks': results, 'requests': requests}, indent=2))


if __name__ == '__main__':
    main()
