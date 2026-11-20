#!/usr/bin/env python3
"""Local-only protocol + cross-process pixel acceptance. No external accounts."""
import argparse
import http.server
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import sys
import signal
import time


class Fixture(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/icon.svg':
            data = b'<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32"><path fill="green" d="M0 0h32v32H0z"/></svg>'
            self.send_response(200)
            self.send_header('Content-Type', 'image/svg+xml')
        else:
            page = 'B' if self.path.startswith('/b') else 'A'
            color = '#bc3543' if page == 'B' else '#12783c'
            data = f'''<!doctype html><html><head><title>YabCore {page}</title>
<meta name="theme-color" content="{color}"><link rel="icon" href="/icon.svg">
<style>html,body{{margin:0;background:{color};color:white;font:24px system-ui}}body{{height:2000px}}h1{{margin:20px}}input{{position:absolute;top:90px;left:30px;width:250px;height:40px;font:20px system-ui}}</style></head>
<body><h1>YabCore {page}</h1><input aria-label="Protocol input"><script>
globalThis.wheels=0;document.documentElement.dataset.wheels='0';addEventListener('wheel',e=>{{document.documentElement.dataset.wheels=String(++wheels);document.documentElement.dataset.wheelX=String(e.clientX);document.documentElement.dataset.wheelY=String(e.clientY)}});
</script></body></html>'''.encode()
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *_):
        pass


def wait_socket(path, process):
    end = time.monotonic() + 30
    while time.monotonic() < end:
        if process.poll() is not None:
            raise RuntimeError(f'YabCore exited before socket: {process.returncode}')
        if path.exists():
            return
        time.sleep(.05)
    raise RuntimeError('YabCore socket not ready')


def stop(process):
    if process and process.poll() is None:
        process.send_signal(signal.SIGTERM)
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.send_signal(signal.SIGKILL)
            process.wait(timeout=10)


def wire_checks(executable, directory, out):
    """A separate process proves partial frames, errors and peer-loss cleanup."""
    endpoint = directory / 'wire.sock'
    with (out / 'wire-helper.log').open('w') as log:
        process = subprocess.Popen([str(executable), f'--socket={endpoint}',
                                    f'--data-root={directory / "wire-data"}', '--no-sandbox', '--use-mock-keychain', '--no-default-browser-check'], stdout=log, stderr=log, start_new_session=True)
        try:
            wait_socket(endpoint, process)
            peer = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            peer.settimeout(10)
            peer.connect(str(endpoint))
            reader = peer.makefile('rb')
            peer.sendall(b'{"v":99,"id":"wrong","method":"hello"}\n')
            assert 'error' in json.loads(reader.readline())
            peer.sendall(b'{"v":1,"id":"he')
            peer.sendall(b'llo","method":"hello"}\n{"v":1,"id":"bad","method":"tab.resize","params":{"width":[]}}\n')
            assert json.loads(reader.readline())['id'] == 'hello'
            assert 'error' in json.loads(reader.readline())
            # Accept the documented maximum payload even when its LF and the
            # following request arrive together. Size is per frame, not per read.
            large = {'v': 1, 'id': 'large', 'method': 'unknown', 'params': {'blob': ''}}
            encoded = json.dumps(large, separators=(',', ':')).encode()
            large['params']['blob'] = 'x' * (4 * 1024 * 1024 - len(encoded))
            encoded = json.dumps(large, separators=(',', ':')).encode()
            assert len(encoded) == 4 * 1024 * 1024
            peer.sendall(encoded + b'\n{"v":1,"id":"next","method":"unknown"}\n')
            assert json.loads(reader.readline())['id'] == 'large'
            assert json.loads(reader.readline())['id'] == 'next'
            reader.close()
            peer.close()
            process.wait(timeout=15)
            assert process.returncode == 0, process.returncode
            assert not endpoint.exists(), 'Socket not removed on disconnect'
            (out / 'wire-summary.json').write_text(json.dumps({'passed': ['version-rejection', 'fragmented-and-batched-frames', 'malformed-params', 'maximum-and-coalesced-frames', 'disconnect-shutdown']}, indent=2))
        finally:
            stop(process)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--probe', type=Path, required=True)
    parser.add_argument('--host', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    executable = args.app / 'Contents/MacOS/PaneCore'
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    helper = host = None
    # macOS sockaddr_un is limited to 104 bytes, unlike a farm artifact path.
    with tempfile.TemporaryDirectory(prefix='yc-', dir='/tmp') as temporary:
        directory = Path(temporary)
        os.chmod(directory, 0o700)
        wire_checks(executable, directory, out)
        endpoint = directory / 'core.sock'
        with (out / 'helper.log').open('w') as helper_log, (out / 'host.log').open('w') as host_log, (out / 'probe.log').open('w') as probe_log:
            try:
                helper = subprocess.Popen([str(executable), f'--socket={endpoint}', f'--data-root={directory / "data"}', '--no-sandbox', '--use-mock-keychain', '--no-default-browser-check'], stdout=helper_log, stderr=helper_log, start_new_session=True)
                wait_socket(endpoint, helper)
                host = subprocess.Popen([str(args.host), str(out)], stdout=host_log, stderr=host_log, start_new_session=True)
                meta = out / 'host-window.json'
                end = time.monotonic() + 10
                while not meta.exists() and time.monotonic() < end:
                    time.sleep(.02)
                window = json.loads(meta.read_text())
                sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'evals'))
                from probe_capture import picture
                # This checks that adhd's raised blackout occludes our test host.
                # The pixels asserted by the probe still come from the host's own window.
                occlusion = picture(host.pid, out / 'occlusion-start.png', window_id=window['window'])
                (out / 'occlusion-start.json').write_text(json.dumps(occlusion, indent=2))
                base = f'http://127.0.0.1:{server.server_port}'
                result = subprocess.run([str(args.probe), str(endpoint), base, str(out), str(Path(__file__).parent / 'extension')], stdout=probe_log, stderr=subprocess.STDOUT, timeout=240)
                print((out / 'probe.log').read_text(), flush=True)
                if result.returncode:
                    raise RuntimeError(f'Protocol probe failed: {result.returncode}')
                helper.wait(timeout=20)
                assert helper.returncode == 0, helper.returncode
                assert not endpoint.exists(), 'Socket not cleaned on shutdown'
                # A private request context must not have a disk cache path.
                assert not (directory / 'data/space-private').exists()
                assert (directory / 'data/space-space-a/Preferences').exists(), 'Persistent profile not on disk'
                assert (directory / 'data/space-space-b/Preferences').exists(), 'Second persistent profile not on disk'
                # Start the same helper/data root again to catch CEF silently
                # falling back to an off-the-record context for an invalid path.
                with (out / 'persistence-helper.log').open('w') as persistence_log, (out / 'persistence-probe.log').open('w') as persistence_probe:
                    helper = subprocess.Popen([str(executable), f'--socket={endpoint}', f'--data-root={directory / "data"}', '--no-sandbox', '--use-mock-keychain', '--no-default-browser-check'], stdout=persistence_log, stderr=persistence_log, start_new_session=True)
                    wait_socket(endpoint, helper)
                    persisted = subprocess.run([str(args.probe), str(endpoint), base, str(out), str(Path(__file__).parent / 'extension'), 'persist'], stdout=persistence_probe, stderr=subprocess.STDOUT, timeout=60)
                    if persisted.returncode:
                        raise RuntimeError((out / 'persistence-probe.log').read_text())
                    helper.wait(timeout=20)
                    assert helper.returncode == 0, helper.returncode
                summary = json.loads((out / 'summary.json').read_text())
                summary['passed'].extend(json.loads((out / 'persistence.json').read_text())['passed'])
                summary['passed'].append('clean-shutdown-and-memory-private-profile')
                summary['helper_exit'] = helper.returncode
                summary['app'] = str(args.app)
                summary['host'] = os.uname().nodename
                (out / 'summary.json').write_text(json.dumps(summary, indent=2))
            finally:
                stop(host)
                stop(helper)
                server.shutdown()


if __name__ == '__main__':
    main()
