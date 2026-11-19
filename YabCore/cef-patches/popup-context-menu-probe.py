#!/usr/bin/env python3
"""A right click in an extension's action popup, then the popup closes.

Crash reports 1100, 1101, 1136, 1316, 1538, 1539: YabCore's main thread in
ChromeWebContentsViewDelegateViewsMac::IsMenuRunning() reading freed memory
(0xcdcdcdcdcdcdcdcd, PartitionAlloc's freed byte) right after
WebContentsImpl::ShowContextMenu. An action popup has no CefBrowser, so CEF
never asks YabCore's RunContextMenu: Chrome runs a native NSMenu in a nested
loop inside ChromeWebContentsViewDelegateCef::ShowContextMenu. YabCore's wire
is a common-modes run loop source, so popup.close (Yab dismissing its popover)
is served inside that loop; the popup's WebContents goes, the menu is cancelled
with it, and CEF then calls IsMenuRunning() on its destroyed delegate.
CEF patch 0105 returns when the delegate is gone.

Run in a farm job with --display (the menu is real AppKit UI), from the
worktree root, on an app built with YabCore on the pinned SDK:
  python3 -u YabCore/cef-patches/popup-context-menu-probe.py --app APP --host HOST
Exit 0: YabCore survived and still answers. Exit 1: it crashed (reproduced).
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

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tests'))
from run import wait_socket

PAGE = b'<!doctype html><title>Popup owner</title><body style="background:#bc3543;margin:0;height:600px">owner'
MENUS_JS = """ObjC.import('CoreGraphics');
const rows = ObjC.castRefToObject($.CGWindowListCopyWindowInfo($.kCGWindowListOptionAll, 0)), out = [];
for (let i = 0; i < rows.count; i++) {
  const w = rows.objectAtIndex(i), b = w.objectForKey('kCGWindowBounds');
  if (ObjC.unwrap(w.objectForKey('kCGWindowOwnerPID')) === PID)
    out.push({layer: ObjC.unwrap(w.objectForKey('kCGWindowLayer')), number: ObjC.unwrap(w.objectForKey('kCGWindowNumber')),
              onScreen: !!ObjC.unwrap(w.objectForKey('kCGWindowIsOnscreen')), alpha: ObjC.unwrap(w.objectForKey('kCGWindowAlpha')),
              bounds: [ObjC.unwrap(b.objectForKey('X')), ObjC.unwrap(b.objectForKey('Y')), ObjC.unwrap(b.objectForKey('Width')), ObjC.unwrap(b.objectForKey('Height'))]});
}
JSON.stringify(out);"""


class Fixture(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(PAGE)))
        self.end_headers()
        self.wfile.write(PAGE)

    def log_message(self, *_):
        pass


def windows(pid):
    try:
        done = subprocess.run(['/usr/bin/osascript', '-l', 'JavaScript', '-e', MENUS_JS.replace('PID', str(pid))],
                              capture_output=True, text=True, timeout=10)
        if done.returncode:
            return [{'error': done.stderr[-400:]}]
        return json.loads(done.stdout or '[]')
    except Exception as error:
        return [{'error': repr(error)}]


def menus(pid):
    # kCGPopUpMenuWindowLevel is 101.
    return [w for w in windows(pid) if w.get('layer') == 101 and w.get('onScreen')]


def main_thread(pid, out, name):
    # The menu's nested tracking loop, as the main thread's stack shows it.
    path = out / (name + '.sample.txt')
    subprocess.run(['/usr/bin/sample', str(pid), '1', '-file', str(path)], capture_output=True, timeout=30)
    text = path.read_text(errors='replace') if path.exists() else ''
    return {'popUpContextMenu': '_popUpContextMenu:withEvent:forView:' in text and 'NSMenuTrackingSession' in text}


def crash_reports(since, pid):
    # Only this run's helper: other jobs' YabCore copies crash on the same Mac.
    folder = Path.home() / 'Library/Logs/DiagnosticReports'
    found = []
    for path in folder.glob('YabCore*.ips'):
        if path.stat().st_mtime < since:
            continue
        text = path.read_text(errors='replace')
        try:
            if json.loads(text[text.index('\n{') + 1:]).get('pid') == pid:
                found.append(str(path))
        except ValueError:
            pass
    return sorted(found)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--host', type=Path, required=True)
    args = parser.parse_args()
    out = Path(os.environ['YAB_FARM_OUT']) / 'popup-context-menu'
    out.mkdir(parents=True, exist_ok=True)
    report = {'checks': [], 'app': str(args.app), 'machine': os.uname().nodename}
    events = []
    started = time.time()
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f'http://127.0.0.1:{server.server_port}'
    helper = host = peer = None
    seq = 0
    code = 2
    try:
        with tempfile.TemporaryDirectory(prefix='ycm-', dir='/tmp') as temporary, (out / 'helper.log').open('w') as log:
            directory = Path(temporary)
            os.chmod(directory, 0o700)
            endpoint = directory / 'core.sock'
            env = dict(os.environ)
            env.pop('YAB_CEF_EXTENSION_WINDOWS', None)
            helper = subprocess.Popen([str(args.app / 'Contents/MacOS/PaneCore'), f'--socket={endpoint}',
                f'--data-root={directory / "data"}', '--no-sandbox', '--use-mock-keychain',
                '--no-default-browser-check'], stdout=log, stderr=log, start_new_session=True, env=env)
            wait_socket(endpoint, helper)
            host = subprocess.Popen([str(args.host), str(out)], stdout=log, stderr=log, start_new_session=True)
            if Path('./stage').exists():
                placement = subprocess.run(['./stage', 'put', str(host.pid), '4'], capture_output=True, text=True, timeout=20)
                report['placement'] = {'exit': placement.returncode, 'stdout': placement.stdout[-500:], 'stderr': placement.stderr[-500:]}
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
                        raise ConnectionError('YabCore disconnected during ' + method)
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

            report['hello'] = request('hello')
            request('profile.open', {'profile': 'popup'})
            manage = request('extension.open', {'profile': 'popup'})['tab']
            eventually('management tab', lambda: request('tab.state', {'tab': manage})['url'] == 'chrome://extensions/' and
                       request('tab.state', {'tab': manage})['devToolsReady'])
            fixture = directory / 'fixture'
            shutil.copytree(Path(__file__).resolve().parents[1] / 'tests/external-action', fixture)
            request('extension.load', {'tab': manage, 'path': str(fixture)})
            rows = eventually('extension installed', lambda: [r for r in request('extension.list', {'tab': manage})
                              if r['name'] == 'Yab External Action'])
            extension = rows[0]['id']
            owner = request('tab.create', {'profile': 'popup', 'url': base + '/'})['tab']
            eventually('owner ready', lambda: (lambda s: s['hasDocument'] and not s['loading'] and
                       s['url'].startswith(base))(request('tab.state', {'tab': owner})), pump=owner)
            eventually('real key host', lambda: (lambda v: v if v.get('key') and v.get('active') else None)(
                       json.loads((out / 'host-window.json').read_text())) if (out / 'host-window.json').exists() else None)
            request('tab.focus', {'tab': owner, 'focused': True})
            mark = len(events)
            opened = request('extension.action.open', {'tab': owner, 'extension': extension,
                             'anchor': {'x': 100, 'y': 100, 'width': 24, 'height': 24}}, allow_error=True)
            check('action popup opens', 'error' not in opened and opened.get('opened'), opened)
            shown = eventually('popup.layer shown', lambda: next((e['params'] for e in events[mark:]
                               if e['event'] == 'popup.layer' and e['params'].get('contextId') and
                               float(e['params'].get('pixelWidth', 0)) >= 200 * float(e['params'].get('scale', 1))), None), 20, pump=owner)
            report['popup'] = shown
            token = shown['token']
            request('popup.focus', {'tab': owner, 'token': token, 'focused': True}, allow_error=True)
            # The popup page has loaded once its layer is shown; let its button lay out.
            time.sleep(1)
            report['windowsBefore'] = windows(helper.pid)
            for kind in ('mouseMove', 'rightDown', 'rightUp'):
                pressed = request('popup.input', {'tab': owner, 'token': token, 'kind': kind, 'x': 140, 'y': 70}, allow_error=True)
                check('popup input ' + kind, 'error' not in pressed, pressed)
            # Chrome builds the menu after reading the clipboard; its NSMenu
            # then tracks in a nested loop on YabCore's main thread, under
            # the ShowContextMenu message (window lists can't see it from a job).
            tracking = {}
            for attempt in range(4):
                request('tab.state', {'tab': owner})
                tracking = main_thread(helper.pid, out, 'after-click-%d' % attempt)
                if tracking['popUpContextMenu']:
                    break
            report['mainThreadAfterClick'] = tracking
            report['windowsAfterClick'] = windows(helper.pid)
            check('Chrome runs a native context menu for the popup (no CefBrowser, no RunContextMenu)',
                  tracking['popUpContextMenu'], tracking)
            # Yab dismissing its popover: served inside the menu's nested loop.
            try:
                report['close'] = request('popup.close', {'tab': owner, 'token': token}, allow_error=True)
                end = time.monotonic() + 6
                while time.monotonic() < end and helper.poll() is None:
                    request('tab.state', {'tab': owner})
                    time.sleep(.2)
                report['menusAfterClose'] = main_thread(helper.pid, out, 'after-close')['popUpContextMenu'] if helper.poll() is None else False
                report['ownerAfterClose'] = request('tab.state', {'tab': owner})
            except (ConnectionError, OSError) as error:
                report['disconnect'] = repr(error)
            time.sleep(1)
            report['helperExit'] = helper.poll()
            survived = report['helperExit'] is None and 'disconnect' not in report
            report['survived'] = survived
            if survived:
                check('YabCore still answers after the popup closed under its menu', report.get('ownerAfterClose'))
                check('the menu went with the popup', not report['menusAfterClose'], report['menusAfterClose'])
                request('shutdown', allow_error=True)
                helper.wait(timeout=20)
                code = 0
            else:
                code = 1
    except Exception as error:
        report['error'] = repr(error) + ' ' + traceback.format_exc()[-1500:]
        code = 2 if code == 2 else code
    finally:
        if peer:
            peer.close()
        for process in (host, helper):
            if process and process.poll() is None:
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                    process.wait(timeout=10)
                except Exception:
                    pass
        server.shutdown()
        server.server_close()
        time.sleep(3)  # ReportCrash writes the .ips shortly after the exit.
        reports = crash_reports(started, helper.pid if helper else -1)
        report['crashReports'] = reports
        for path in reports:
            shutil.copy(path, out / Path(path).name)
        report['events'] = [e for e in events if e['event'].startswith('popup.') or e['event'] == 'menu.open']
        report['exitCode'] = code
        (out / 'result.json').write_text(json.dumps(report, indent=2) + '\n')
        print(json.dumps({k: report.get(k) for k in ('survived', 'helperExit', 'mainThreadAfterClick', 'menusAfterClose',
                                                      'disconnect', 'crashReports', 'error', 'exitCode')}, indent=2), flush=True)
        for path in reports:
            text = Path(path).read_text(errors='replace')
            body = json.loads(text[text.index('\n{') + 1:])
            thread = body['threads'][body.get('faultingThread', 0)]
            names = {i: image.get('name') for i, image in enumerate(body.get('usedImages', []))}
            print('crash', body.get('exception'), flush=True)
            for frame in thread['frames'][:8]:
                print('  ', names.get(frame.get('imageIndex')), hex(frame.get('imageOffset', 0)), frame.get('symbol', ''), flush=True)
    sys.exit(code)


if __name__ == '__main__':
    main()
