#!/usr/bin/env python3
"""Opens in (mockup B) on the real signed app: every state, light and dark,
real menus pressed through Accessibility, pictures by ScreenCaptureKit.
Farm only: needs capture, accessibility and pyobjc."""
import argparse
import http.server
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import sys
import threading
import time
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'chromium-tabs'))
sys.path.append(str(Path(__file__).resolve().parent))
from run import launch_exact, wait_for
from probe_capture import picture
import yab_socket
import ax

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'chromium-extensions'))
from prepared_lifetime import PreparedAppLifetime


class Pages(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b'''<!doctype html><meta charset="utf-8"><title>Opens in fixture</title>
<style>body{margin:40px;background:#164b38;color:white;font:24px system-ui}button{font:inherit;padding:12px}</style>
<h1 id="engine"></h1><p>Local stand-in. No service login.</p>
<button onclick="requestProtected()">Request protected playback</button>
<script>
document.querySelector('#engine').textContent=navigator.userAgent.includes('Chrome/')?'Chromium':'WebKit';
function requestProtected(){setTimeout(()=>navigator.requestMediaKeySystemAccess('com.widevine.alpha',
[{initDataTypes:['cenc'],audioCapabilities:[{contentType:'audio/mp4; codecs="mp4a.40.2"'}]}]).catch(()=>{}),300)}
</script>'''
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


def run(app, out, port):
    out.mkdir(parents=True, exist_ok=True)
    world = 'opens-in-' + uuid.uuid4().hex[:8]
    domain = 'dev.serafim.fast.test.' + world
    sock = Path.home() / 'Library/Application Support' / f'Pane ({world})' / 'bench.sock'
    defaults = out / 'defaults.plist'
    # localhost stands in for a service on the DRM list: Recommended means WebKit there.
    defaults.write_bytes(plistlib.dumps({'bench': True, 'welcomed': True, 'mail': False, 'hints.noticing': False,
                                        'searchSuggest': False, 'drm.test.domains': ['localhost'],
                                        # A crashed earlier run must not ask to reopen its windows.
                                        'ApplePersistenceIgnoreState': True, 'NSQuitAlwaysKeepsWindows': False}))
    subprocess.run(['defaults', 'import', domain, str(defaults)], check=True)
    proc = launch_exact(app, dict(os.environ, YAB_PROBE=world, YAB_HISTORY='own', YAB_ENGINE='chromium',
                                 YAB_AGENT_CLAUDE='/usr/bin/true', YAB_AGENT_CODEX='/nonexistent/chromium'), out)
    ask = yab_socket.kwasker(sock, timeout=45, strict=True, takes_timeout=True,
                            fail=lambda req, reply: RuntimeError(f'{req}: {reply}'))
    lifetime = PreparedAppLifetime(app, proc, sock.parent, ask, out)
    report = {'app': str(app), 'pid': proc.pid, 'checks': {}, 'states': {}, 'pictures': [], 'actions': [], 'errors': []}
    checks = report['checks']
    pid = proc.pid
    tabs = {}
    tab_ids = {}

    def engine(tab):
        return ask(do='chromium-drm', id=tab, op='site-engine')

    def wait_engine(tab, kind, why):
        def ready():
            s = ask(do='chromium-drm', id=tab)
            report['states']['wait-' + tab[:8]] = s
            return s if s['engine'] == kind and s['title'] == 'Opens in fixture' and not s['loading'] else None
        return wait_for(ready, why, 60)

    def windows(tab):
        # Popovers sit on the normal layer, menus above it: everything but the browser window itself.
        found = [w for w in ask(do='chromium-drm', id=tab, op='windows')['windows']
                 if w['bounds'].get('Width', 0) > 40 and w['bounds'].get('Height', 0) > 20
                 and w['bounds'].get('Width', 0) < 800]
        report['states']['windows'] = found
        return found

    def shoot(tab, name, only=None):
        """Every small high window (popover, menus), one picture each."""
        taken = []
        for w in windows(tab):
            if only and not only(w):
                continue
            path = out / f"{name}-w{w['number']}.png"
            try:
                meta = picture(pid, path, window_id=w['number'])
                taken.append({'file': path.name, 'bounds': w['bounds'], 'layer': w['layer'], 'capture': meta.get('capture')})
                checks[path.stem + '_sck'] = meta.get('capture') == 'ScreenCaptureKit'
            except Exception as error:
                report['errors'].append(f'{name}: {error}')
        report['pictures'].append({'name': name, 'windows': taken})
        if not taken:
            report['errors'].append(f'{name}: no window to take')
        return taken

    def shoot_panel(tab, name):
        """The panel is a child window of the browser's: a window picture of it comes back as the
        parent drawn small, so take the browser window and cut the panel out of it."""
        from PIL import Image
        box = panel_box(tab)
        if not box:
            report['errors'].append(f'{name}: no panel to take')
            return None
        full = out / (name + '-window.png')
        meta = picture(pid, full, window_id=0)
        frame = meta['frame']
        image = Image.open(full)
        scale = image.width / frame[2]
        pad = 14
        left, top = max(0, int((box[0] - frame[0] - pad) * scale)), max(0, int((box[1] - frame[1] - pad) * scale))
        right = min(image.width, int((box[0] - frame[0] + box[2] + pad) * scale))
        bottom = min(image.height, int((box[1] - frame[1] + box[3] + pad) * scale))
        crop = out / (name + '.png')
        image.crop((left, top, right, bottom)).save(crop)
        report['pictures'].append({'name': name, 'file': crop.name, 'window_file': full.name, 'box': box, 'scale': scale,
                                   'capture': meta.get('capture')})
        checks[name + '_sck'] = meta.get('capture') == 'ScreenCaptureKit'
        return crop

    def shoot_union(tab, name):
        """The panel with its menus open: the browser window picture holds them all (they are its
        child windows), cut around every small window."""
        from PIL import Image, ImageChops
        from capture_menus import picture_with_menus
        observed = windows(tab)
        boxes = [[w['bounds']['X'], w['bounds']['Y'], w['bounds']['Width'], w['bounds']['Height']] for w in observed]
        if not boxes:
            report['errors'].append(f'{name}: no window to take')
            return None
        x0, y0 = min(b[0] for b in boxes), min(b[1] for b in boxes)
        x1, y1 = max(b[0] + b[2] for b in boxes), max(b[1] + b[3] for b in boxes)
        full = out / (name + '-window.png')
        meta = picture(pid, full, window_id=0)
        meta = picture_with_menus(pid, full, meta)
        frame = meta['frame']
        image = Image.open(full)
        scale = image.width / frame[2]
        pad = 14
        crop = out / (name + '.png')
        image.crop((max(0, int((x0 - frame[0] - pad) * scale)), max(0, int((y0 - frame[1] - pad) * scale)),
                    min(image.width, int((x1 - frame[0] + pad) * scale)), min(image.height, int((y1 - frame[1] + pad) * scale)))).save(crop)
        report['pictures'].append({'name': name, 'file': crop.name, 'windows': boxes, 'scale': scale, 'capture': meta.get('capture')})
        checks[name + '_sck'] = meta.get('capture') == 'ScreenCaptureKit'
        # AX and SCK success alone are insufficient: an independent-window
        # frame on adhd omitted every menu while all functional checks passed.
        # Each real menu must change pixels in its own bounds from the image
        # taken immediately before it opened.
        look = name.split('-', 1)[0]
        before = {'2-foot-menu': '1-default', '3-opens-in-submenu': '2-foot-menu',
                  '4-webkit-chosen-menu': '4-webkit-chosen', '6-row-menu': '5-moved-for-video',
                  '7-service-menu': '7-service-panel', '8-chromium-chosen-menu': '8-chromium-chosen'}
        suffix = name[len(look) + 1:]
        baseline = Image.open(out / (look + '-' + before[suffix] + '-window.png')).convert('RGB')
        if baseline.size != image.size:
            baseline = baseline.resize(image.size)
        visibility = []
        for window in observed:
            if window['layer'] <= 0:
                continue
            b = window['bounds']
            rect = (max(0, round((b['X'] - frame[0]) * scale)), max(0, round((b['Y'] - frame[1]) * scale)),
                    min(image.width, round((b['X'] + b['Width'] - frame[0]) * scale)),
                    min(image.height, round((b['Y'] + b['Height'] - frame[1]) * scale)))
            difference = ImageChops.difference(image.convert('RGB').crop(rect), baseline.crop(rect))
            values = list(difference.getdata())
            fraction = sum(max(pixel) > 16 for pixel in values) / max(1, len(values))
            visibility.append({'window': window['number'], 'bounds': b, 'changed_fraction': fraction})
        checks[name + '_menu_pixels'] = bool(visibility) and all(v['changed_fraction'] > .02 for v in visibility)
        report['states'][name + '-menu-pixels'] = visibility
        return crop

    def panel_box(tab):
        return ax.popover_box(pid)

    def open_panel(tab, name):
        from AppKit import NSRunningApplication, NSApplicationActivateIgnoringOtherApps
        target = NSRunningApplication.runningApplicationWithProcessIdentifier_(pid)
        target.unhide()
        target.activateWithOptions_(NSApplicationActivateIgnoringOtherApps)
        ask(do='select', id=tab)
        time.sleep(.4)
        # A native menu selection can finish dismissing its transient popover
        # after the new engine has loaded. Reopen only after that dismissal,
        # retrying presentation rather than assuming a single toggle stuck.
        for attempt in range(3):
            ax.cancel_menus(pid)
            ask(do='ui', extensions=False)
            time.sleep(.6)
            ask(do='ui', extensions=True)
            try:
                box = wait_for(lambda: panel_box(tab), 'Site Controls did not open', 5)
                time.sleep(.6)
                if panel_box(tab):
                    report['states'][name + '-presentation-attempts'] = attempt + 1
                    (out / (name + '-ax.txt')).write_text(ax.dump(pid))
                    return box
            except RuntimeError:
                pass
        report['states'][name + '-windows'] = ask(do='ui', spaces=True)
        raise RuntimeError('Site Controls did not stay open after three presentation attempts')

    def close_panel():
        ax.cancel_menus(pid)
        ask(do='ui', extensions=False)
        time.sleep(.4)

    def more_button(box):
        found = [c for c in ax.controls(pid, box, ('AXMenuButton', 'AXPopUpButton')) if c['frame'][1] > box[1] + box[3] - 60]
        if not found:
            found = [c for c in ax.controls(pid, box) if c['frame'][1] > box[1] + box[3] - 60]
        return max(found, key=lambda c: c['frame'][0]) if found else None

    def press_item(title):
        line = wait_for(lambda: ax.item(pid, title), 'No menu line ' + title, 10)
        if not ax.press(line['element']):
            raise RuntimeError('AXPress refused for ' + title)
        report['actions'].append({'action': 'AXPress', 'title': title, 'frame': line['frame'], 'mark': line['mark']})
        time.sleep(.5)
        return line

    def marks():
        return {i['title']: i['mark'] for i in ax.items(pid) if i['title']}

    def chosen_menu(tab, look, tag, checked):
        """Reopen the real submenu after a pick: its mark must reflect the persisted choice."""
        box = panel_box(tab) or open_panel(tab, f'{look}-{tag}-reopen')
        button = more_button(box)
        if not button or not ax.show_menu(button['element']):
            raise RuntimeError('chosen foot menu did not open')
        wait_for(lambda: ax.item(pid, 'Opens in'), 'foot menu has no Opens in', 5)
        state = engine(tab)
        recommended = 'Auto (' + ('WebKit' if state['recommended'] == 'webKit' else 'Chromium') + ')'
        log = report['states'].setdefault(f'{look}-{tag}-submenu-open', {})
        if not ax.open_submenu(pid, 'Opens in', recommended, log):
            raise RuntimeError('chosen submenu did not open: ' + str(log))
        time.sleep(.4)
        m = marks()
        report['states'][f'{look}-{tag}-marks'] = m
        checks[f'{look}-{tag}-checked'] = bool(m.get(checked)) and all(
            t in m and not m[t] for t in (recommended, 'Chromium', 'WebKit') if t != checked)
        checks[f'{look}-{tag}-same-tab'] = state['tab'] == tab_ids[tab]
        shoot_union(tab, f'{look}-{tag}-menu')
        close_panel()
        return open_panel(tab, f'{look}-{tag}-after-menu')

    def dismiss_menus(box):
        # Closing the popover takes an open menu with it.
        close_panel()

    def step(name, fn):
        try:
            fn()
        except Exception as error:
            report['errors'].append(f'{name}: {error}')
            try:
                (out / (name + '-failure-ax.txt')).write_text(ax.dump(pid))
            except Exception:
                pass

    def one_appearance(look):
        ask(do='ui', look=look)
        time.sleep(.5)
        a, b = tabs['a'], tabs['b']

        def default():
            ask(do='select', id=a)
            s = wait_engine(a, 'chromium', 'default tab not in Chromium')
            state = engine(a)
            checks[f'{look}-default-no-row'] = state.get('row') is None and state['recommended'] == 'chromium'
            box = open_panel(a, f'{look}-1-default')
            shoot_panel(a, f'{look}-1-default')
            checks[f'{look}-default-panel-open'] = box is not None
        step(f'{look}-default', default)

        def foot_menu():
            box = panel_box(a) or open_panel(a, f'{look}-2')
            button = more_button(box)
            if not button:
                raise RuntimeError('no foot button found')
            report['states'][f'{look}-more-button'] = {k: button[k] for k in ('role', 'frame', 'title', 'desc')}
            report['states'][f'{look}-more-actions'] = ax.actions(button['element'])
            if not ax.show_menu(button['element']):
                raise RuntimeError('the foot menu refused to open')
            wait_for(lambda: ax.item(pid, 'Opens in'), 'foot menu has no Opens in', 5)
            time.sleep(.4)
            shoot_union(a, f'{look}-2-foot-menu')
            (out / f'{look}-foot-menu-ax.txt').write_text(ax.dump(pid))
            log = report['states'].setdefault(f'{look}-submenu-open', {})
            if not ax.open_submenu(pid, 'Opens in', 'Auto (Chromium)', log):
                raise RuntimeError('the Opens in submenu did not open: ' + str(log))
            time.sleep(.4)
            report['states'][f'{look}-submenu-marks'] = marks()
            (out / f'{look}-submenu-ax.txt').write_text(ax.dump(pid))
            m = marks()
            checks[f'{look}-submenu-lines'] = all(t in m for t in ('Auto (Chromium)', 'Chromium', 'WebKit'))
            checks[f'{look}-recommended-checked'] = bool(m.get('Auto (Chromium)')) and not m.get('WebKit')
            shoot_union(a, f'{look}-3-opens-in-submenu')
        step(f'{look}-foot', foot_menu)

        def pick_webkit():
            press_item('WebKit')
            wait_engine(a, 'webKit', 'WebKit pick did not reload in WebKit')
            state = engine(a)
            report['states'][f'{look}-webkit-chosen'] = state
            row = state.get('row') or {}
            checks[f'{look}-webkit-row'] = row == {'title': 'Opens in WebKit', 'said': 'Chosen for 127.0.0.1', 'chosen': True}
            checks[f'{look}-webkit-persisted'] = state['choice'] == 'webKit'
            box = panel_box(a) or open_panel(a, f'{look}-4')
            time.sleep(.5)
            shoot_panel(a, f'{look}-4-webkit-chosen')
            (out / f'{look}-4-ax.txt').write_text(ax.dump(pid))
        step(f'{look}-webkit', pick_webkit)
        step(f'{look}-webkit-mark', lambda: chosen_menu(a, look, '4-webkit-chosen', 'WebKit'))

        def cross():
            box = panel_box(a)
            if not box:
                raise RuntimeError('panel closed')
            row = [t for t in ax.texts(pid, box) if t['text'] == 'Opens in WebKit']
            if not row:
                raise RuntimeError('row text not found in the panel')
            y = row[0]['frame'][1] + row[0]['frame'][3] / 2
            buttons = [c for c in ax.controls(pid, box, ('AXButton',)) if abs(c['frame'][1] + c['frame'][3] / 2 - y) < 30
                       and c['frame'][0] > box[0] + box[2] - 80]
            report['states'][f'{look}-cross-candidates'] = [c['frame'] for c in buttons]
            if not buttons:
                raise RuntimeError('no cross button')
            ax.press(buttons[-1]['element'])
            wait_engine(a, 'chromium', 'the cross did not bring Chromium back')
            state = engine(a)
            checks[f'{look}-cross-resets'] = state['choice'] == 'recommended' and state.get('row') is None
            open_panel(a, f'{look}-4-reset')
            shoot_panel(a, f'{look}-4-cross-reset')
        step(f'{look}-cross', cross)

        def moved():
            close_panel()
            ask(do='chromium-drm', id=a, op='script', body='requestProtected(); return true')
            wait_engine(a, 'webKit', 'EME fallback did not load WebKit')
            state = engine(a)
            report['states'][f'{look}-moved'] = state
            row = state.get('row') or {}
            checks[f'{look}-moved-row'] = row == {'title': 'Opens in WebKit', 'said': 'For its protected video', 'chosen': False}
            box = open_panel(a, f'{look}-5-moved')
            shoot_panel(a, f'{look}-5-moved-for-video')
            buttons = [c for c in ax.controls(pid, box, ('AXMenuButton', 'AXPopUpButton', 'AXButton'))
                       if c['desc'] == 'Opens in WebKit']
            report['states'][f'{look}-row-buttons'] = [(c['role'], c['frame'], ax.actions(c['element'])) for c in buttons]
            if not buttons:
                raise RuntimeError('the row is not a button')
            if not ax.show_menu(buttons[0]['element']):
                raise RuntimeError('the row refused to open its menu')
            wait_for(lambda: ax.item(pid, 'Auto (Chromium)'), 'row menu has no lines', 5)
            time.sleep(.6)
            m = marks()
            report['states'][f'{look}-row-menu-marks'] = m
            checks[f'{look}-row-menu-lines'] = all(t in m for t in ('Auto (Chromium)', 'Chromium', 'WebKit'))
            shoot_union(a, f'{look}-6-row-menu')
            # Recommended again: back to the window's engine, tried afresh.
            press_item('Auto (Chromium)')
            wait_engine(a, 'chromium', 'Recommended did not bring Chromium back')
            checks[f'{look}-recommended-after-move'] = engine(a).get('row') is None
        step(f'{look}-moved', moved)

        def service_host():
            close_panel()
            ask(do='select', id=b)
            wait_engine(b, 'webKit', 'service-like host did not open in WebKit')
            state = engine(b)
            checks[f'{look}-service-recommended-webkit'] = state['recommended'] == 'webKit' and state.get('row') is None
            box = open_panel(b, f'{look}-7-service')
            shoot_panel(b, f'{look}-7-service-panel')
            button = more_button(box)
            if not button or not ax.show_menu(button['element']):
                raise RuntimeError('foot menu did not open')
            wait_for(lambda: ax.item(pid, 'Opens in'), 'foot menu has no Opens in', 5)
            time.sleep(.4)
            log = report['states'].setdefault(f'{look}-service-submenu-open', {})
            if not ax.open_submenu(pid, 'Opens in', 'Auto (WebKit)', log):
                raise RuntimeError('the Opens in submenu did not open: ' + str(log))
            time.sleep(.4)
            m = marks()
            report['states'][f'{look}-service-marks'] = m
            checks[f'{look}-service-menu'] = bool(m.get('Auto (WebKit)')) and not m.get('Chromium')
            shoot_union(b, f'{look}-7-service-menu')
            press_item('Chromium')
            wait_engine(b, 'chromium', 'Chromium pick did not reload in Chromium')
            state = engine(b)
            report['states'][f'{look}-service-chromium'] = state
            row = state.get('row') or {}
            checks[f'{look}-chromium-row'] = row == {'title': 'Opens in Chromium', 'said': 'Chosen for localhost', 'chosen': True}
            open_panel(b, f'{look}-8-chromium')
            shoot_panel(b, f'{look}-8-chromium-chosen')
            chosen_menu(b, look, '8-chromium-chosen', 'Chromium')
        step(f'{look}-service', service_host)

        def reset():
            dismiss_menus(None)
            close_panel()
            ask(do='chromium-drm', id=b, op='site-engine', choice='recommended')
            wait_engine(b, 'webKit', 'reset did not bring WebKit back')
            ask(do='chromium-drm', id=a, op='site-engine', choice='recommended')
        step(f'{look}-reset', reset)

    try:
        wait_for(lambda: sock.exists() if proc.poll() is None else False, 'Missing bench socket', 60)
        ask(do='ui', welcome=False, sidebar=True)
        # macOS's "reopen windows?" alert, if a crash left one: Don't Reopen.
        for element, _ in ax.walk(ax.app(pid)):
            if ax.value(element, 'AXRole') == 'AXButton' and ax.value(element, 'AXTitle') in ('Don\u2019t Reopen', "Don't Reopen"):
                ax.press(element)
                report['states']['reopen_alert'] = 'dismissed'
                break
        tabs['a'] = ask(do='usage-open', url=f'http://127.0.0.1:{port}/eme')['id']
        wait_engine(tabs['a'], 'chromium', 'first tab not in Chromium at the start')
        tabs['b'] = ask(do='usage-open', url=f'http://localhost:{port}/eme')['id']
        wait_engine(tabs['b'], 'webKit', 'service-like tab not in WebKit at the start')
        for tab in tabs.values():
            tab_ids[tab] = engine(tab)['tab']
        report['states']['initial-tab-ids'] = tab_ids
        for look in ('light', 'dark'):
            one_appearance(look)
        report['ok'] = bool(checks) and all(checks.values()) and not report['errors']
    finally:
        lifetime.finish(report, result_key='ok')
        subprocess.run(['defaults', 'delete', domain], capture_output=True)
    if not report['ok']:
        raise SystemExit('Opens in acceptance failed: ' + json.dumps({'checks': {k: v for k, v in checks.items() if not v},
                                                                       'errors': report['errors']}, default=str))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Pages)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    def deadline(*_):
        raise TimeoutError('Opens in runtime exceeded 540 seconds')

    signal.signal(signal.SIGALRM, deadline)
    signal.alarm(540)
    try:
        run(args.app, args.out, server.server_port)
    finally:
        signal.alarm(0)
        server.shutdown()
