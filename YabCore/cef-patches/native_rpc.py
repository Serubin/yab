"""Bounded native boundary probes against the helper inside a signed app."""
from pathlib import Path
import json
import os
import socket
import subprocess
import sys
import tempfile
import time
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tests'))
from run import wait_socket
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'evals/chromium-extensions'))
from prepared_lifetime import PreparedHelperLifetime

def report_capture_refusal(out):
    # Keep the actual nested SCK error in the farm log. Its existing refusal
    # tracker must see a declined TCC, rather than a later missing-JSON error.
    try:
        with (Path(out) / 'helper.log').open('rb') as log:
            log.seek(0, os.SEEK_END); log.seek(max(0, log.tell() - 65536))
            lines = log.read().decode('utf-8', errors='replace').splitlines()
        for line in reversed(lines):
            if 'SCStreamErrorDomain Code=-3801' in line or 'declined TCCs' in line:
                print(line[:1600], file=sys.stderr, flush=True)
                return
    except OSError:
        pass

class NativeRPC:
    def __init__(self, app, out, extra_args=(), *, sandboxed=False):
        self.out = Path(out); self.out.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(prefix='yn-', dir='/tmp')
        self.directory = Path(self.temporary.name); os.chmod(self.directory, 0o700)
        self.log = (self.out / 'helper.log').open('w')
        endpoint = self.directory / 'core.sock'
        env = dict(os.environ, YAB_CEF_TRACE_CDP='1'); env.pop('YAB_CEF_EXTENSION_WINDOWS', None)
        self.process = subprocess.Popen([str(Path(app) / 'Contents/MacOS/PaneCore'), f'--socket={endpoint}',
            f'--data-root={self.directory / "data"}', *(() if sandboxed else ('--no-sandbox',)), '--use-mock-keychain',
            '--no-default-browser-check', *extra_args], env=env, stdout=self.log, stderr=self.log, start_new_session=True)
        self.lifetime = PreparedHelperLifetime(Path(app).resolve(), self.process, self.directory / 'data', self.out)
        self.buffer = b''; self.sequence = 0; self.responses = {}; self.events = []; self.history = []
        self.lifetime.shutdown = lambda: self.call('shutdown')
        try:
            wait_socket(endpoint, self.process)
            self.socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            self.socket.settimeout(30); self.socket.connect(str(endpoint))
            self.hello = self.call('hello')
        except BaseException:
            self.close()
            raise
    def send(self, method, params=None):
        self.sequence += 1; token = str(self.sequence)
        self.socket.sendall((json.dumps({'v': 1, 'id': token, 'method': method, 'params': params or {}}) + '\n').encode())
        return token
    def pump(self, timeout=30):
        end = time.monotonic() + timeout
        while b'\n' not in self.buffer:
            self.socket.settimeout(max(.05, end - time.monotonic()))
            data = self.socket.recv(65536)
            if not data: raise RuntimeError('Native helper disconnected')
            self.buffer += data
        line, self.buffer = self.buffer.split(b'\n', 1); row = json.loads(line); self.history.append(row)
        if 'event' in row: self.events.append(row)
        else: self.responses[row['id']] = row
        return row
    def result(self, token, timeout=180, allow_error=False):
        end = time.monotonic() + timeout
        while token not in self.responses:
            if time.monotonic() >= end: raise TimeoutError('Native request ' + token)
            self.pump(end - time.monotonic())
        row = self.responses.pop(token)
        if 'error' in row:
            if allow_error: return {'error': row['error']}
            raise RuntimeError(row['error'])
        return row.get('result')
    def call(self, method, params=None, allow_error=False, timeout=30):
        return self.result(self.send(method, params), timeout, allow_error)
    def event(self, predicate, mark=0, timeout=30):
        end = time.monotonic() + timeout
        while True:
            for row in self.events[mark:]:
                if predicate(row): return row['params']
            if time.monotonic() >= end: raise TimeoutError('Native event')
            self.pump(end - time.monotonic())
    def eventually(self, label, action, timeout=30):
        end = time.monotonic() + timeout
        while True:
            value = action()
            if value: return value
            if time.monotonic() >= end: raise TimeoutError(label)
            time.sleep(.1)
    def ready(self, tab):
        def state():
            value = self.call('tab.state', {'tab': tab})
            return value if value['hasDocument'] and not value['loading'] and value['devToolsReady'] else None
        return self.eventually('Native document ready', state)
    def contexts(self, tab):
        self.call('scripts.frames', {'tab': tab})
        return self.call('scripts.status', {'tab': tab})['contexts']
    def js(self, tab, body, argument=None, frame=None, gesture=False):
        context = frame or self.eventually('Native main script context', lambda: next((c for c in self.contexts(tab)
                            if c['main'] and c['default']), None))
        return self.call('scripts.evaluate', {'tab': tab, 'frame': context['token'], 'world': '',
            'function': 'async function(arg){' + body + '}', 'arguments': argument, 'userGesture': gesture})
    def shutdown(self):
        if not self.lifetime.quit():
            raise RuntimeError('Original native helper shutdown failed: ' + repr(self.lifetime.receipt))
    def close(self):
        report = {'ok': True, 'checks': {}}
        natural = False
        try:
            natural = self.lifetime.finish(report)
        finally:
            (self.out / 'wire.json').write_text(json.dumps(self.history, indent=2) + '\n')
            peer = getattr(self, 'socket', None)
            if peer is not None: peer.close()
            self.log.close()
            report_capture_refusal(self.out)
            deadline = time.monotonic() + 5
            while True:
                try: self.temporary.cleanup(); break
                except OSError:
                    if time.monotonic() >= deadline: raise
                    time.sleep(.1)
        if not natural:
            raise RuntimeError('Original helper/children did not naturally shut down; exact cleanup receipts retained')
