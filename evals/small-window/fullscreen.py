#!/usr/bin/env python3
"""Small Window over another app's full-screen Space (register 533).

Run against an already prepared app, with no build in this eval:
    ./farm exec --display --needs accessibility,pointer --name "Small Window fullscreen" -- \
        python3 evals/small-window/fullscreen.py --app "build/Pane Dev.app"

An isolated Yab probe receives a localhost URL through LaunchServices. Fresh,
owned TextEdit instances hold full-screen windows on every attached display.
CGWindowList must show the Small Window above TextEdit on the same display,
with TextEdit still full screen and Yab's desktop window absent throughout
the sampled opening. TextEdit is the foreground app before the link; Yab's
Small Window must become key afterward, without leaving TextEdit's Space.

Check with the main window minimized and with it left on its desktop Space.
Single-screen scenarios run only on a host with exactly one display and print
SKIP elsewhere. On multiple displays, repeat with every display occupied,
opening on each display. The eval never changes system display configuration
or Spaces settings.
Evidence goes to $YAB_FARM_OUT/small-window-fullscreen unless --out is given.
No screen capture permission is needed: CGWindowList supplies placement and
stacking evidence, and winshot draws the probe's own window under blackout.
"""
import argparse
from http.server import BaseHTTPRequestHandler
import json
import os
from pathlib import Path
import subprocess
import sys
import threading
import time
import uuid

import AppKit
import ApplicationServices as AX
import Quartz

EVALS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(EVALS))
import yab_socket  # noqa: E402
from probe_app import launch  # noqa: E402

TEXTEDIT = Path('/System/Applications/TextEdit.app')
POINTER = EVALS / 'window-tiling/pointer.py'
TASK = 'Small Window fullscreen'


def wait(test, label, seconds=15):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        value = test()
        if value:
            return value
        # AppKit's screen and activation notifications need a running loop.
        AppKit.NSRunLoop.currentRunLoop().runUntilDate_(
            AppKit.NSDate.dateWithTimeIntervalSinceNow_(.1))
    raise TimeoutError(label)


def stable(test, label, seconds=15):
    since, previous = None, None

    def settled():
        nonlocal since, previous
        value = test()
        if not value or value != previous:
            since = time.monotonic() if value else None
        previous = value
        return value if since is not None and time.monotonic() - since >= 1 else None

    return wait(settled, label, seconds)


def attribute(element, name):
    error, value = AX.AXUIElementCopyAttributeValue(element, name, None)
    return value if error == 0 else None


def set_attribute(element, name, value):
    error = AX.AXUIElementSetAttributeValue(element, name, value)
    if error != 0:
        raise RuntimeError(f'{name}: Accessibility error {error}')


def same(a, b):
    return len(a) == len(b) == 4 and all(abs(x - y) <= 2 for x, y in zip(a, b))


def inside(a, b):
    return (len(a) == len(b) == 4 and a[0] >= b[0] - 2 and a[1] >= b[1] - 2
            and a[0] + a[2] <= b[0] + b[2] + 2 and a[1] + a[3] <= b[1] + b[3] + 2)


def on_display(rows, screen):
    x, y, width, height = screen
    return [w for w in rows if w['alpha'] > 0 and w['frame'][0] < x + width
            and w['frame'][1] < y + height and w['frame'][0] + w['frame'][2] > x
            and w['frame'][1] + w['frame'][3] > y]


def space_losses(samples, fixtures, main_number):
    losses = []
    for index, sample in enumerate(samples):
        for fixture in fixtures:
            rows = on_display(sample['windows'], fixture['screen'])
            same_window = any(w['number'] == fixture['number'] and w['pid'] == fixture['pid']
                              and same(w['frame'], fixture['screen']) for w in rows)
            desktop = any(w['number'] == main_number for w in rows)
            if not same_window or desktop:
                losses.append({'sample': index, 'display': fixture['screen'],
                               'full_screen_missing': not same_window, 'main_visible': desktop})
    return losses


def focused_pid():
    app = attribute(AX.AXUIElementCreateSystemWide(), 'AXFocusedApplication')
    if app is None:
        return None
    error, pid = AX.AXUIElementGetPid(app, None)
    return int(pid) if error == 0 else None


def windows(on_screen=True):
    option = Quartz.kCGWindowListOptionOnScreenOnly if on_screen else Quartz.kCGWindowListOptionAll
    rows = Quartz.CGWindowListCopyWindowInfo(option, Quartz.kCGNullWindowID) or []
    result = []
    for row in rows:
        bounds = row.get('kCGWindowBounds', {})
        result.append({'number': int(row['kCGWindowNumber']), 'pid': int(row['kCGWindowOwnerPID']),
                       'layer': int(row.get('kCGWindowLayer', 0)),
                       'alpha': float(row.get('kCGWindowAlpha', 1)),
                       'frame': [float(bounds.get(k, 0)) for k in ('X', 'Y', 'Width', 'Height')]})
    return result


def screen_frames():
    screens = list(AppKit.NSScreen.screens())
    if not screens:
        return []
    top = screens[0].frame().origin.y + screens[0].frame().size.height
    return [[float(r.origin.x), float(top - r.origin.y - r.size.height),
             float(r.size.width), float(r.size.height)] for r in (s.frame() for s in screens)]


class TextEdit:
    def __init__(self, path, screen):
        self.path, self.screen = path, screen
        self.apps = []
        self.app = self.window = None
        self.number = None

    def start(self):
        self.path.write_text('Small Window full-screen fixture.\n')
        running = AppKit.NSRunningApplication.runningApplicationsWithBundleIdentifier_
        before = {int(app.processIdentifier()) for app in running('com.apple.TextEdit')}
        subprocess.run(['open', '-n', '-a', str(TEXTEDIT), str(self.path)], check=True, timeout=15)

        def owned_document():
            for app in running('com.apple.TextEdit'):
                pid = int(app.processIdentifier())
                if pid in before:
                    continue
                element = AX.AXUIElementCreateApplication(pid)
                for window in attribute(element, 'AXWindows') or []:
                    if self.path.stem in str(attribute(window, 'AXTitle') or ''):
                        return app, window
            return None

        self.app, self.window = wait(owned_document, 'new TextEdit process with the owned document')
        self.apps = [self.app]
        self.pid = int(self.app.processIdentifier())

    def front(self):
        if not self.app.activateWithOptions_(AppKit.NSApplicationActivateIgnoringOtherApps):
            raise RuntimeError('TextEdit activation was refused')
        error = AX.AXUIElementPerformAction(self.window, 'AXRaise')
        if error != 0:
            raise RuntimeError(f'TextEdit AXRaise: {error}')
        wait(lambda: focused_pid() == self.pid, 'owned TextEdit has keyboard focus')

    def listed(self):
        return next((w for w in windows() if w['pid'] == self.pid and w['layer'] == 0
                     and w['alpha'] > 0 and same(w['frame'], self.screen)), None)

    def fullscreen(self, on):
        self.front()
        if bool(attribute(self.window, 'AXFullScreen')) == on:
            if on:
                self.number = stable(self.listed, 'existing full-screen TextEdit settled')['number']
            return
        if on:
            x, y, width, height = self.screen
            set_attribute(self.window, 'AXSize', AX.AXValueCreate(
                AX.kAXValueCGSizeType, Quartz.CGSizeMake(min(700, width - 80), min(500, height - 80))))
            set_attribute(self.window, 'AXPosition', AX.AXValueCreate(
                AX.kAXValueCGPointType, Quartz.CGPointMake(x + 40, y + 40)))
        set_attribute(self.window, 'AXFullScreen', on)
        wait(lambda: attribute(self.window, 'AXFullScreen') == on, f'TextEdit full screen = {on}')
        if on:
            self.number = stable(self.listed, 'TextEdit covers its target display')['number']
        else:
            # Space transitions continue after AXFullScreen changes.
            stable(lambda: not self.listed(), 'TextEdit left full screen')

    def close(self):
        for app in self.apps:
            if not app.isTerminated():
                app.terminate()
                end = time.monotonic() + 5
                while not app.isTerminated() and time.monotonic() < end:
                    time.sleep(.1)
                if not app.isTerminated():
                    app.forceTerminate()


class Trace:
    def __init__(self, pids):
        self.pids = pids
        self.samples, self.errors = [], []
        self.stop = threading.Event()
        self.thread = threading.Thread(target=self.run, daemon=True)

    def sample(self):
        self.samples.append({'time': time.monotonic(),
                             'focused_pid': focused_pid(),
                             'windows': [w for w in windows() if w['pid'] in self.pids]})

    def run(self):
        try:
            while not self.stop.wait(.05):
                self.sample()
        except Exception as error:
            self.errors.append(repr(error))


def run(app, out):
    out.mkdir(parents=True, exist_ok=True)
    world = 'small-fs-' + uuid.uuid4().hex[:10]
    domain = 'dev.serafim.fast.test.' + world
    report = {'world': world, 'checks': [], 'skips': [], 'cases': [], 'passed': False,
              'limits': ['Isolated profile and localhost page, not reporter-profile acceptance.',
                         'Space continuity is checked by window identity, AXFullScreen and the '
                         'on-screen list sampled about every 50 ms, not private Space APIs.',
                         'Transitions shorter than the sampling interval may be missed.']}
    proc, server = None, None
    fixtures = []

    def check(name, ok, required=True, **detail):
        report['checks'].append({'name': name, 'passed': bool(ok), **detail})
        print(('PASS ' if ok else 'FAIL ') + name, flush=True)
        if not ok and required:
            raise AssertionError(name)
        return bool(ok)

    def skip(name, reason):
        report['skips'].append({'name': name, 'reason': reason})
        print('SKIP ' + name + ': ' + reason, flush=True)

    def scenario(name, minimized, target):
        case = {'name': name, 'minimized': minimized, 'display': target, 'passed': False,
                'phase': 'setup', 'failures': []}
        report['cases'].append(case)
        trace = None

        def accept(label, ok, **detail):
            if not check(name + ': ' + label, ok, required=False, **detail):
                case['failures'].append(label)

        try:
            ask(do='float', action='app', how='unmini')
            ask(do='front')
            x, y, width, height = fixtures[target].screen
            ask(do='window', frame=[x + 60, y + 60, min(900, width - 120), min(640, height - 120)])
            main = ask(do='window')
            if minimized:
                ask(do='float', action='app', how='mini')
            wait(lambda: ask(do='window')['mini'] == minimized, 'main window minimized state')
            for fixture in fixtures:
                fixture.fullscreen(True)
            source = fixtures[target]
            x, y, width, height = source.screen
            subprocess.run([sys.executable, str(POINTER), 'move', str(x + width / 2), str(y + height / 2)],
                           check=True, timeout=15, capture_output=True)
            source.front()
            stable(lambda: focused_pid() == source.pid and all(f.listed() for f in fixtures),
                   'TextEdit focused and all full-screen displays settled')
            case['before'] = {'main': ask(do='window'), 'links': ask(do='links'), 'windows': windows(),
                              'textedit': [{'pid': f.pid, 'number': f.number, 'screen': f.screen,
                                            'full': bool(attribute(f.window, 'AXFullScreen'))} for f in fixtures]}
            onscreen = {w['number'] for w in case['before']['windows']}
            check(name + ': main window is off the active Space', main['number'] not in onscreen,
                  main=case['before']['main'])
            check(name + ': main window still exists on its desktop',
                  any(w['number'] == main['number'] for w in windows(False))
                  and case['before']['main']['mini'] == minimized
                  and (minimized or case['before']['links']['browserWindow']))
            check(name + ': every display has another app in full screen',
                  all(f.listed() and attribute(f.window, 'AXFullScreen') for f in fixtures))

            case['phase'] = 'opening'
            trace = Trace({proc.pid, *(f.pid for f in fixtures)})
            trace.sample()
            trace.thread.start()
            url = yab_socket.url(server, '/' + name)
            # Target the launch-owned copy, never the installed user's Yab.
            subprocess.run(['open', '-a', str(Path(proc.binary).parents[2]), url], check=True, timeout=15)
            link = wait(lambda: next((w for w in ask(do='links')['windows'] if w['url'] == url), None),
                        'external URL reaches Small Window')
            wait(lambda: ask(do='eval', id=link['id'], js='location.href === ' + json.dumps(url)
                             + ' && document.readyState === "complete"').get('value') is True,
                 'Small Window loads the external page')
            wait(lambda: any(w['number'] == link['number'] for w in windows()), 'Small Window is on screen')
            time.sleep(2)
            case['phase'] = 'acceptance'
            case['links'] = ask(do='links')
            case['small'] = ask(do='window', small=True)
            case['main_after'] = ask(do='window')
            case['spaces'] = ask(do='ui', spaces=True)
            case['after'] = windows()
            current = next((w for w in case['links']['windows'] if w['id'] == link['id']), {})
            listed = next((w for w in case['after'] if w['number'] == link['number']), None)
            accept('Small Window is visible, key and on the active Space',
                  current.get('visible') and current.get('key') and current.get('space') and listed is not None,
                  link=current)
            accept('Small Window is on the requested display',
                  listed is not None and inside(listed['frame'], source.screen), frame=listed)
            # CGWindowList is front to back. Compare only windows intersecting
            # this display, and report a missing source separately from order.
            local = on_display(case['after'], source.screen)
            positions = {w['number']: i for i, w in enumerate(local)}
            source_present = source.number in positions
            accept('same full-screen TextEdit window remains on the requested display', source_present)
            if source_present and listed is not None:
                accept('Small Window stacks above the same full-screen TextEdit window',
                       link['number'] in positions and positions[link['number']] < positions[source.number],
                       order=positions)
            accept('all TextEdit windows remain full screen on screen',
                  all(attribute(f.window, 'AXFullScreen') and f.listed()
                      and f.listed()['number'] == f.number for f in fixtures))
            accept('no Yab window entered full screen', not case['links']['fullScreen'])
            accept('main window kept its minimized state', case['main_after']['mini'] == minimized
                  and (minimized or case['links']['browserWindow']))
            small = case['small']
            accept('full-screen overlay has no green button',
                  len(small['lights']) == 2 or small['green'].get('hidden') is True,
                  lights=small['lights'], green=small['green'])
            shot = out / (name + '.png')
            ask(do='winshot', window=link['number'], path=str(shot))
            accept('Small Window evidence was written', shot.exists() and shot.stat().st_size > 0)
            case['picture'] = str(shot)
        except Exception as error:
            case['error'] = repr(error)
            check_name = name + ': ' + case['phase']
            report['checks'].append({'name': check_name, 'passed': False, 'error': repr(error)})
            print('FAIL ' + check_name + ': ' + str(error), flush=True)
        finally:
            # Save failure state before cleanup switches any Spaces itself.
            case['failure_windows'] = windows()
            case['fixture_state'] = [{'pid': f.pid, 'number': f.number, 'screen': f.screen,
                                      'full': bool(attribute(f.window, 'AXFullScreen'))} for f in fixtures]
            if trace:
                trace.stop.set()
                trace.thread.join(timeout=5)
                case['trace'] = str(out / (name + '-trace.json'))
                Path(case['trace']).write_text(json.dumps({'samples': trace.samples, 'errors': trace.errors}, indent=2) + '\n')
                losses = space_losses(trace.samples, case['before']['textedit'], main['number'])
                continuous = not trace.errors and not trace.thread.is_alive() and len(trace.samples) >= 2 and not losses
                accept('no sampled departure from the full-screen Spaces', continuous,
                       samples=len(trace.samples), losses=losses)
                case['diagnosis'] = ('Yab desktop exposed' if any(loss['main_visible'] for loss in losses)
                                     else 'full-screen window disappeared from its display' if losses
                                     else 'sampling failed' if not continuous
                                     else 'full-screen Spaces stayed visible')
            else:
                case['diagnosis'] = 'fixture setup failed before opening a link'
            try:
                for _ in range(5):
                    if not ask(do='links')['windows']:
                        break
                    ask(do='link-close')
                for fixture in reversed(fixtures):
                    fixture.fullscreen(False)
            except Exception as error:
                case['cleanup_error'] = repr(error)
                report['checks'].append({'name': name + ': restored fixture windows', 'passed': False,
                                         'error': repr(error)})
                print('FAIL ' + name + ': restored fixture windows: ' + str(error), flush=True)
            case['passed'] = not case['failures'] and 'error' not in case and 'cleanup_error' not in case

    class Page(BaseHTTPRequestHandler):
        def do_GET(self):
            body = b'<!doctype html><title>Small Window full screen</title><h1>External link fixture</h1>'
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            try:
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                pass

        def log_message(self, *_):
            pass

    try:
        check('Accessibility is available', AX.AXIsProcessTrusted())
        check('eval runs on a display-enabled farm worker', os.environ.get('YAB_FARM_WORKER') == '1')
        check('real windows are not operated on the user Mac',
              os.environ.get('WHERE') != 'main' and os.environ.get('YAB_FARM_HOST') != 'main')
        screens = screen_frames()
        report['screens'] = screens
        check('at least one display is attached', bool(screens))
        for key in ('bench', 'welcomed', 'links.small'):
            subprocess.run(['defaults', 'write', domain, key, '-bool', 'true'], check=True)
        server = yab_socket.serve(Page)
        proc = launch(app, dict(os.environ, YAB_PROBE=world, YAB_HISTORY='own', YAB_AGENTS='none'),
                      out, task_name=os.environ.get('YAB_TASK_NAME', TASK))
        wait(lambda: yab_socket.socket_path(world).exists() and proc.poll() is None, 'probe bench socket', 45)
        ask = yab_socket.kwasker(yab_socket.socket_path(world), timeout=10, strict=True,
                               fail=lambda request, reply: RuntimeError((request, reply)))
        ask(do='open', url=yab_socket.url(server, '/main'), plain=True)
        ask(do='ui', welcome=False, closeField=True)
        ask(do='front')
        for index, screen in enumerate(screens):
            fixture = TextEdit(out / f'{world}-display-{index + 1}.txt', screen)
            fixtures.append(fixture)
            fixture.start()
        if len(screens) == 1:
            scenario('single-screen-minimized', True, 0)
            scenario('single-screen-main-other-space', False, 0)
            skip('multiple screens', 'Only one display is attached.')
        else:
            for target in range(len(screens)):
                scenario(f'multi-screen-{target + 1}-minimized', True, target)
                scenario(f'multi-screen-{target + 1}-main-other-space', False, target)
        report['passed'] = bool(report['cases']) and all(c['passed'] for c in report['cases'])
    except Exception as error:
        report['passed'] = False
        report['error'] = repr(error)
        print('FAIL setup: ' + str(error), flush=True)
    finally:
        for fixture in reversed(fixtures):
            try:
                fixture.close()
            except Exception as error:
                report.setdefault('cleanup_errors', []).append(repr(error))
        if proc:
            try:
                proc.terminate()
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait(timeout=5)
            except Exception as error:
                report.setdefault('cleanup_errors', []).append(repr(error))
        if server:
            server.shutdown()
            server.server_close()
        if report.get('cleanup_errors'):
            report['passed'] = False
            print('FAIL cleanup: ' + repr(report['cleanup_errors']), flush=True)
        (out / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(('PASS ' if report['passed'] else 'FAIL ') + 'Small Window full-screen eval', flush=True)
    return 0 if report['passed'] else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True, help='Already built Yab app bundle')
    parser.add_argument('--out', type=Path)
    parser.add_argument('--configuration', choices=('all', 'single', 'multi'), default='all',
                        help='Select scenarios for the attached displays; incompatible scenarios print SKIP')
    args = parser.parse_args()
    output = args.out or Path(os.environ.get('YAB_FARM_OUT', '/tmp')) / 'small-window-fullscreen'
    output = output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    results, skips, original = {}, [], None

    def skip(name, reason):
        skips.append({'name': name, 'reason': reason})
        print('SKIP ' + name + ': ' + reason, flush=True)

    try:
        if (os.environ.get('YAB_FARM_WORKER') != '1'
                or os.environ.get('WHERE') not in ('adhd', 'renderer-2', 'm4', 'aws-1', 'aws-2')
                or os.environ.get('YAB_FARM_HOST') == 'main' or not AX.AXIsProcessTrusted()):
            raise RuntimeError('Run on a remote display worker with Accessibility and pointer capabilities')
        original = screen_frames()
        if not original:
            raise RuntimeError('No display is attached')
        if args.configuration in ('all', 'single'):
            if len(original) == 1:
                results['single'] = run(args.app.resolve(), output / 'single')
            else:
                skip('single-screen scenarios',
                     'Multiple displays are attached; use a host with exactly one display. '
                     'System display configuration is left unchanged.')
        if args.configuration in ('all', 'multi'):
            if len(original) > 1:
                results['multi'] = run(args.app.resolve(), output / 'multi')
            else:
                skip('multiple screens', 'Only one display is attached.')
    except Exception as error:
        results['configuration_error'] = repr(error)
        print('FAIL display configuration: ' + str(error), flush=True)
    passed = all(code == 0 for code in results.values()) if results else None
    (output / 'summary.json').write_text(json.dumps({'passed': passed, 'results': results, 'skips': skips,
                                                   'original_screens': original,
                                                   'final_screens': screen_frames()}, indent=2) + '\n')
    status = 'SKIP ' if passed is None else 'PASS ' if passed else 'FAIL '
    print(status + 'all requested full-screen configurations', flush=True)
    return 1 if passed is False else 0


if __name__ == '__main__':
    sys.exit(main())
