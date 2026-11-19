#!/usr/bin/env python3
"""Inspect input delivery on an exact existing helper, without rebuilding it."""
import argparse
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

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tests'))
from run import Fixture, wait_socket, stop

parser = argparse.ArgumentParser()
parser.add_argument('--app', type=Path, required=True)
parser.add_argument('--host', type=Path)
args = parser.parse_args()
out = Path(os.environ['YAB_FARM_OUT'])
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
threading.Thread(target=server.serve_forever, daemon=True).start()
process = peer = reader = host = None
events = []
sequence = 0
report = {'app': str(args.app), 'stages': [], 'profiles': []}

try:
    with tempfile.TemporaryDirectory(prefix='yci-', dir='/tmp') as temporary, (out / 'helper.log').open('w') as log:
        directory = Path(temporary)
        os.chmod(directory, 0o700)
        endpoint = directory / 'core.sock'
        process = subprocess.Popen([str(args.app / 'Contents/MacOS/PaneCore'),
            f'--socket={endpoint}', f'--data-root={directory / "data"}',
            '--no-sandbox', '--use-mock-keychain', '--no-default-browser-check'],
            stdout=log, stderr=log, start_new_session=True)
        try:
            wait_socket(endpoint, process)
            if args.host:
                host = subprocess.Popen([str(args.host), str(out)], stdout=log, stderr=log,
                                        start_new_session=True)
                end = time.monotonic() + 15
                while not (out / 'host-window.json').exists():
                    if host.poll() is not None or time.monotonic() > end:
                        raise RuntimeError('Layer host did not start')
                    time.sleep(.05)
            peer = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            peer.settimeout(25)
            peer.connect(str(endpoint))
            reader = peer.makefile('rb')

            def request(method, params=None):
                global sequence
                sequence += 1
                identifier = str(sequence)
                peer.sendall((json.dumps({'v': 1, 'id': identifier, 'method': method,
                                         'params': params or {}}) + '\n').encode())
                while True:
                    line = reader.readline()
                    if not line:
                        raise RuntimeError('Helper disconnected')
                    message = json.loads(line)
                    if 'event' in message:
                        events.append(message)
                        continue
                    assert message['id'] == identifier
                    if 'error' in message:
                        raise RuntimeError(message['error'])
                    return message['result']

            def evaluate(tab, expression):
                return request('script.evaluate', {'tab': tab, 'world': 'input-diagnostic',
                    'function': 'function(args){return (' + expression + ')}', 'arguments': {}})

            report['hello'] = request('hello')
            tabs = []
            for index in range(3):
                profile = 'diag-' + str(index)
                private = index == 2
                request('profile.open', {'profile': profile, 'private': private})
                report['profiles'].append({'profile': profile, 'private': private})
                tab = request('tab.create', {'profile': profile,
                    'url': f'http://127.0.0.1:{server.server_port}/' + ('b' if index == 1 else 'a')})['tab']
                end = time.monotonic() + 25
                while True:
                    state = request('tab.state', {'tab': tab})
                    if state['hasDocument'] and state['devToolsReady'] and not state['loading']:
                        break
                    if time.monotonic() > end:
                        raise RuntimeError('Document not ready')
                    time.sleep(.05)
                tabs.append(tab)

            tab = tabs[0]
            if host:
                # Match the failed full eval, including its independent AppKit
                # host and switching displayed contexts before input delivery.
                for index, target in enumerate(tabs[:2]):
                    end = time.monotonic() + 20
                    while True:
                        layers = [e['params'] for e in events if e['event'] == 'layer.changed'
                                  and e['params'].get('tab') == target and e['params'].get('contextId')]
                        if layers:
                            break
                        if time.monotonic() > end:
                            raise RuntimeError('No layer context')
                        request('tab.state', {'tab': target})
                        time.sleep(.05)
                    token = 'diagnostic-' + str(index)
                    pending = out / 'host-state.pending'
                    pending.write_text(json.dumps({'contextId': layers[-1]['contextId'],
                        'width': 800, 'height': 600, 'token': token}))
                    pending.replace(out / 'host-state.json')
                    while not (out / (token + '.json')).exists():
                        if time.monotonic() > end:
                            raise RuntimeError('Host did not capture the context')
                        time.sleep(.05)
                    report.setdefault('hostCaptures', []).append(
                        json.loads((out / (token + '.json')).read_text()))
            evaluate(tab, '''(()=>{globalThis.inputEvents=[];
              for(const kind of ['mousedown','mouseup','keydown','keyup','beforeinput','input','focus','blur'])
                document.addEventListener(kind,e=>inputEvents.push({kind,key:e.key??null,
                  data:e.data??null,x:e.clientX??null,y:e.clientY??null,target:e.target.tagName,time:e.timeStamp}),true);
              return true})()''')

            def record(stage):
                time.sleep(.2)
                value = evaluate(tab, '''({hasFocus:document.hasFocus(),now:performance.now(),
                  visibility:document.visibilityState,
                  active:document.activeElement?.tagName,value:document.querySelector('input').value,
                  rectangle:document.querySelector('input').getBoundingClientRect().toJSON(),
                  events:inputEvents})''')
                state = request('tab.state', {'tab': tab})
                report['stages'].append({'stage': stage, 'document': value,
                                         'producer': state.get('producer')})

            def send(kind, **fields):
                request('input.send', {'tab': tab, 'kind': kind, **fields})

            record('initial')
            # Preserve the unchanged full E2E's burst ordering before paced
            # observations can accidentally hide an asynchronous focus race.
            send('mouseDown', x=100, y=110)
            send('mouseUp', x=100, y=110)
            send('keyDown', keyCode=0, characters='a', unmodified='a')
            send('keyUp', keyCode=0, characters='a', unmodified='a')
            send('text', text='日本語')
            record('burst-mouse-key-text')
            # The following stages are cumulative diagnostics, not fixes.
            send('mouseDown', x=100, y=110)
            send('mouseUp', x=100, y=110)
            record('mouse')
            send('keyDown', keyCode=0, characters='a', unmodified='a')
            send('keyUp', keyCode=0, characters='a', unmodified='a')
            record('key')
            send('text', text='日本語')
            record('committed-text')
            evaluate(tab, "(document.querySelector('input').focus(),true)")
            record('script-focus')
            send('keyDown', keyCode=0, characters='a', unmodified='a')
            send('keyUp', keyCode=0, characters='a', unmodified='a')
            send('text', text='日本語')
            record('input-after-script-focus')
            request('shutdown')
            process.wait(timeout=20)
            report['helperExit'] = process.returncode
        finally:
            stop(host)
            if reader:
                reader.close()
            if peer:
                peer.close()
            stop(process)
except Exception as error:
    report['error'] = str(error)
    raise
finally:
    server.shutdown()
    (out / 'input-diagnostic.json').write_text(json.dumps(report, indent=2, ensure_ascii=False) + '\n')
    (out / 'input-events.json').write_text(json.dumps(events, indent=2) + '\n')
    print(json.dumps(report, indent=2, ensure_ascii=False))
