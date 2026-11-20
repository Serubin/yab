#!/usr/bin/env python3
"""Does an unnavigated (url "") tab get a DevTools domain and a document?

Yab creates every tab with an empty URL and navigates later; navigation waits
for Runtime.enable (the DRM hook). Prints one JSON line per sampled state.
"""
import argparse
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tests'))
from run import stop, wait_socket


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--label', default='')
    args = parser.parse_args()
    out = Path(os.environ['YAB_FARM_OUT'])
    out.mkdir(parents=True, exist_ok=True)
    report = {'label': args.label, 'samples': []}
    events = []
    seq = 0
    process = peer = None
    try:
        with tempfile.TemporaryDirectory(prefix='yb-', dir='/tmp') as temporary, (out / 'helper.log').open('w') as log:
            directory = Path(temporary)
            os.chmod(directory, 0o700)
            endpoint = directory / 'core.sock'
            env = dict(os.environ, YAB_CEF_TRACE_CDP='1')
            process = subprocess.Popen([str(args.app / 'Contents/MacOS/PaneCore'), f'--socket={endpoint}',
                f'--data-root={directory / "data"}', '--no-sandbox', '--use-mock-keychain',
                '--no-default-browser-check'], stdout=log, stderr=log, start_new_session=True, env=env)
            wait_socket(endpoint, process)
            peer = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            peer.settimeout(40)
            peer.connect(str(endpoint))
            reader = peer.makefile('rb')

            def request(method, params=None):
                nonlocal seq
                seq += 1
                ident = str(seq)
                peer.sendall((json.dumps({'v': 1, 'id': ident, 'method': method, 'params': params or {}}) + '\n').encode())
                while True:
                    message = json.loads(reader.readline())
                    if 'event' in message:
                        events.append(message)
                        continue
                    return message.get('result') if 'error' not in message else {'error': message['error']}

            request('hello')
            request('profile.open', {'profile': 'boot'})
            tab = request('tab.create', {'profile': 'boot', 'url': ''})['tab']
            start = time.monotonic()

            def sample(tag):
                s = request('tab.state', {'tab': tab})
                row = {'tag': tag, 't': round(time.monotonic() - start, 1)}
                for key in ('hasDocument', 'devToolsReady', 'rendererPID', 'url', 'loading'):
                    row[key] = s.get(key)
                row['producer'] = s.get('producer')
                report['samples'].append(row)
                print(json.dumps(row), flush=True)
                return s
            for _ in range(8):
                sample('blank')
                time.sleep(1)
            started = time.monotonic()
            nav = request('tab.navigate', {'tab': tab, 'url': 'about:blank#second'})
            report['navigate'] = nav
            report['navigateSeconds'] = round(time.monotonic() - started, 1)
            print(json.dumps({'navigate': nav, 'seconds': report['navigateSeconds']}), flush=True)
            for _ in range(4):
                sample('after-navigate')
                time.sleep(1)
            request('shutdown')
    finally:
        if peer:
            peer.close()
        stop(process)
        report['events'] = [e['event'] for e in events][:60]
        (out / 'bootstrap.json').write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
