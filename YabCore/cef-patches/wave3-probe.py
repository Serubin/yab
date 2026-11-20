#!/usr/bin/env python3
"""Own CEF wave 3 native hook proof; run only in a farm display job.

Checks, against a real YabCore helper and ScreenCaptureKit pictures of its
remote layer: native audible state (WebAudio, no DOM polling), delegated
focus with native text-input state (UTF-16 ranges, caret geometry, password
privacy), and native download provenance (user gesture versus script). With
--baseline it records what an SDK without the hooks reports instead.
"""
import argparse
import http.server
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import traceback
import threading
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tests'))
from run import stop, wait_socket

PAGE = '''<!doctype html><html><head><title>Wave 3</title><style>
html,body{margin:0;background:#12783c;color:white;font:24px system-ui}
input{position:absolute;left:30px;width:300px;height:40px;font:22px system-ui}
#text{top:90px}#secret{top:160px}a{position:absolute;left:30px;top:230px;color:white}
select{position:absolute;left:30px;top:290px;width:200px;height:36px;font:20px system-ui}
</style></head><body><input id="text" aria-label="Text"><input id="secret" type="password" aria-label="Secret">
<a id="save" href="/file.bin" download="wave3.bin">Download</a>
<select id="pick"><option>Alpha</option><option>Beta</option><optgroup label="More"><option>Gamma</option><option disabled>Delta</option></optgroup></select>
<script>document.querySelector('#pick').addEventListener('change',e=>document.documentElement.dataset.changed=e.target.value)</script></body></html>'''
PLAY = '''(()=>{globalThis.ctx=new AudioContext();const o=ctx.createOscillator(),g=ctx.createGain();
g.gain.value=.03;o.frequency.value=440;o.connect(g).connect(ctx.destination);o.start();globalThis.osc=o;return ctx.state})()'''
QUIET = "(osc.stop(), ctx.close().then(()=>'closed'))"


HITS = {}


class Fixture(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path in ('/h1', '/h2', '/h3'):
            HITS[self.path] = HITS.get(self.path, 0) + 1
            data = ('<!doctype html><title>History %s</title><body style="background:#12783c;color:#fff;font:24px system-ui">'
                    'history %s</body>' % (self.path[1:], self.path[1:])).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.send_header('Cache-Control', 'no-store')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        if self.path.startswith('/file'):
            data = b'yab wave 3 download\n' * 64
            self.send_response(200)
            self.send_header('Content-Type', 'application/octet-stream')
            self.send_header('Content-Disposition', 'attachment; filename="wave3.bin"')
        else:
            data = PAGE.encode()
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *_):
        pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--host', type=Path, required=True)
    parser.add_argument('--baseline', action='store_true')
    args = parser.parse_args()
    out = Path(os.environ['YAB_FARM_OUT'])
    out.mkdir(parents=True, exist_ok=True)
    expect = not args.baseline
    report = {'expectHooks': expect, 'captures': [], 'checks': []}
    events = []
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f'http://127.0.0.1:{server.server_port}'
    process = host = peer = reader = None
    sequence = 0
    try:
        with tempfile.TemporaryDirectory(prefix='yc3-', dir='/tmp') as temporary, (out / 'helper.log').open('w') as log:
            directory = Path(temporary)
            os.chmod(directory, 0o700)
            endpoint = directory / 'core.sock'
            process = subprocess.Popen([str(args.app / 'Contents/MacOS/PaneCore'),
                f'--socket={endpoint}', f'--data-root={directory / "data"}',
                '--no-sandbox', '--use-mock-keychain', '--no-default-browser-check',
                '--autoplay-policy=no-user-gesture-required'],
                stdout=log, stderr=log, start_new_session=True)
            wait_socket(endpoint, process)
            host = subprocess.Popen([str(args.host), str(out)], stdout=log, stderr=log,
                                    start_new_session=True)
            peer = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            peer.settimeout(25)
            peer.connect(str(endpoint))
            reader = peer.makefile('rb')

            def pump(message):
                if 'event' in message:
                    events.append(message)
                    return True
                return False

            def request(method, params=None, allow_error=False):
                nonlocal sequence
                sequence += 1
                identifier = str(sequence)
                peer.sendall((json.dumps({'v': 1, 'id': identifier, 'method': method,
                                         'params': params or {}}) + '\n').encode())
                while True:
                    line = reader.readline()
                    if not line:
                        raise RuntimeError('Helper disconnected')
                    message = json.loads(line)
                    if pump(message):
                        continue
                    assert message['id'] == identifier
                    if 'error' in message:
                        if allow_error:
                            return {'error': message['error']}
                        raise RuntimeError(method + ': ' + json.dumps(message['error']))
                    return message['result']

            def evaluate(tab, expression):
                return request('script.evaluate', {'tab': tab, 'world': 'wave3-proof',
                    'function': 'function(args){return (' + expression + ')}', 'arguments': {}})

            pumped = {'tab': None}

            def eventually(label, action, timeout=25):
                end = time.monotonic() + timeout
                while True:
                    # Events are read from the socket only inside request(); poll
                    # with a cheap request so event-only conditions can ever become true.
                    if pumped['tab']:
                        request('tab.state', {'tab': pumped['tab']}, allow_error=True)
                    value = action()
                    if value:
                        return value
                    if time.monotonic() > end:
                        raise RuntimeError('Timed out: ' + label)
                    time.sleep(.05)

            def check(name, value, detail=None):
                report['checks'].append({'check': name, 'passed': bool(value), 'detail': detail})
                assert value, (name, detail)

            def state_events(tab, key):
                return [e['params'][key] for e in events if e['event'] == 'page.state'
                        and e['params'].get('tab') == tab and key in e['params']]

            def text_states(tab):
                return [e['params'] for e in events if e['event'] == 'page.textInput'
                        and e['params'].get('tab') == tab]

            def capture(tab, token):
                def frame():
                    request('tab.state', {'tab': tab})
                    frames = [e['params'] for e in events if e['event'] == 'layer.changed'
                              and e['params'].get('tab') == tab and e['params'].get('contextId')]
                    return frames[-1] if frames else None
                layer = eventually('surface callback', frame)
                pending = out / 'host-state.pending'
                pending.write_text(json.dumps({'contextId': layer['contextId'],
                    'width': 800, 'height': 600, 'token': token}))
                pending.replace(out / 'host-state.json')
                image = eventually('host capture', lambda: json.loads((out / (token + '.json')).read_text())
                                   if (out / (token + '.json')).exists() else None)
                assert image['own'] == 'ScreenCaptureKit', image
                assert image['green'] > image['total'] * .5, image
                report['captures'].append({'token': token, 'pixels': image})

            def section_failed(name, error):
                report.setdefault('failedSections', {})[name] = repr(error) + ' ' + traceback.format_exc()[-1500:]
                print('SECTION FAILED', name, repr(error)[:400], flush=True)

            hello = request('hello')
            report['hello'] = hello
            hooks = hello.get('nativeHooks', {})
            if expect:
                check('hooks advertised', all(hooks.get(k) for k in
                      ('nativeAudible', 'downloadProvenance', 'externalFocus', 'nativeTextInput',
                       'backgroundColor', 'resizeAck', 'selectMenu', 'nativeDiscard',
                       'extensionConsent', 'nativePrint', 'extensionPopups')), hooks)
            request('profile.open', {'profile': 'wave3', 'private': False})
            tab = request('tab.create', {'profile': 'wave3', 'url': base + '/'})['tab']
            pumped['tab'] = tab
            eventually('document ready', lambda: (lambda s: s['hasDocument'] and s['devToolsReady']
                       and not s['loading'])(request('tab.state', {'tab': tab})))
            capture(tab, 'loaded')

            try:
                # Page background color and resize acknowledgement (patch 0009).
                if expect and hooks.get('backgroundColor'):
                    eventually('page background color', lambda: '#12783c' in state_events(tab, 'backgroundColor'))
                    check('page CSS background reported', request('tab.state', {'tab': tab})['backgroundColor'] == '#12783c')
                if expect and hooks.get('resizeAck'):
                    for serial, (w, h) in enumerate([(640, 480), (900, 700), (640, 480), (800, 600)], start=1):
                        reply = request('tab.resize', {'tab': tab, 'width': w, 'height': h, 'scale': 1, 'serial': str(serial)})
                        check('resize acknowledgement armed', reply.get('resizeAck') is True, reply)
                        ack = eventually('resize ack ' + str(serial), lambda: next((e['params'] for e in events
                            if e['event'] == 'tab.resized' and e['params'].get('serial') == str(serial)), None), 10)
                        viewport = evaluate(tab, '[innerWidth, innerHeight]')
                        report.setdefault('resizeAcks', []).append({'ack': ack, 'viewport': viewport})
                        check('ack at requested size', ack['width'] == w and ack['height'] == h and
                              abs(ack['pixelWidth'] / ack['scale'] - w) < 1, ack)
                        check('renderer viewport at requested size', viewport == [w, h], viewport)
                    capture(tab, 'resized-back')

            except Exception as error:
                section_failed('resize', error)
            try:
                # Client-drawn <select> (patches 0005, 0010).
                if expect and hooks.get('selectMenu'):
                    for kind in ('mouseDown', 'mouseUp'):
                        request('input.send', {'tab': tab, 'kind': kind, 'x': 80, 'y': 308})
                    menu = eventually('select.open', lambda: next((e['params'] for e in events
                                      if e['event'] == 'select.open'), None), 10)
                    report['selectMenu'] = menu
                    labels = [i['label'].strip() for i in menu['items']]
                    check('select items and geometry', labels[:2] == ['Alpha', 'Beta'] and 'Gamma' in labels and
                          menu['x'] == 30 and menu['y'] == 290 and menu['height'] == 36, menu)
                    types = {i['label']: i['type'] for i in menu['items']}
                    check('optgroup reported as group', types.get('More') == 'group', types)
                    check('disabled option reported', any(i['label'].strip() == 'Delta' and not i['enabled'] for i in menu['items']), menu)
                    producer = request('tab.state', {'tab': tab})['producer']
                    check('no Chromium menu window on screen', producer.get('onScreen') is False, producer)
                    pick = labels.index('Gamma')
                    request('select.reply', {'tab': tab, 'token': menu['token'], 'index': pick})
                    eventually('select change', lambda: evaluate(tab, 'document.documentElement.dataset.changed') == 'Gamma')
                    stale = request('select.reply', {'tab': tab, 'token': menu['token'], 'index': 0}, allow_error=True)
                    check('duplicate reply refused', 'error' in stale, stale)
                    check('selection kept after stale reply', evaluate(tab, 'document.querySelector("#pick").value') == 'Gamma')
                    # Withdrawal: removing the element closes the client's menu.
                    for kind in ('mouseDown', 'mouseUp'):
                        request('input.send', {'tab': tab, 'kind': kind, 'x': 80, 'y': 308})
                    second = eventually('second select.open', lambda: next((e['params'] for e in events
                                        if e['event'] == 'select.open' and e['params']['token'] != menu['token']), None), 10)
                    evaluate(tab, '(document.querySelector("#pick").remove(), true)')
                    eventually('select.closed', lambda: any(e['event'] == 'select.closed' and
                               e['params'].get('token') == second['token'] for e in events), 10)
                    check('withdrawn select reported', True)

            except Exception as error:
                section_failed('select', error)
            try:
                # Audible: WebAudio is invisible to DOM media polling.
                report['play'] = evaluate(tab, PLAY)
                if expect:
                    eventually('native audible true', lambda: True in state_events(tab, 'audible'), 15)
                    check('audible true from native WebContents', request('tab.state', {'tab': tab})['audible'] is True)
                else:
                    time.sleep(3)
                evaluate(tab, QUIET)
                if expect:
                    eventually('native audible false', lambda: state_events(tab, 'audible')[-1:] == [False], 15)
                    check('audible false after WebAudio stops', request('tab.state', {'tab': tab})['audible'] is False)
                report['audibleEvents'] = state_events(tab, 'audible')

            except Exception as error:
                section_failed('audible', error)
            try:
                # Focus: delegated key status reaches the page without activating
                # the helper application or ordering its producer window in.
                before = evaluate(tab, '({hasFocus:document.hasFocus(),active:document.activeElement.tagName})')
                report['focusBefore'] = before
                focused = request('tab.focus', {'tab': tab, 'focused': True}, allow_error=True)
                report['focusReply'] = focused
                if expect:
                    check('tab.focus accepted', focused.get('focused') is True, focused)
                    eventually('document focus', lambda: evaluate(tab, 'document.hasFocus()') is True)
                    producer = request('tab.state', {'tab': tab})['producer']
                    check('producer stays inactive and off screen', not producer['appActive'] and
                          producer.get('onScreen') is False and not producer['visible'], producer)
                # Real AppKit click and keys into the text field.
                for kind in ('mouseDown', 'mouseUp'):
                    request('input.send', {'tab': tab, 'kind': kind, 'x': 60, 'y': 110})
                eventually('text field focused', lambda: evaluate(tab, 'document.activeElement.id') == 'text')
                for ch, code in (('a', 0), ('b', 11)):
                    for kind in ('keyDown', 'keyUp'):
                        request('input.send', {'tab': tab, 'kind': kind, 'keyCode': code,
                                               'characters': ch, 'unmodified': ch})
                request('input.send', {'tab': tab, 'kind': 'text', 'text': '😀日本'})
                eventually('typed value', lambda: evaluate(tab, 'document.querySelector("#text").value') == 'ab😀日本')
                report['focusAfterTyping'] = evaluate(tab, '({hasFocus:document.hasFocus(),active:document.activeElement.id,'
                                                  'caret:document.activeElement.selectionStart})')
                if expect:
                    check('document has focus while typing', report['focusAfterTyping']['hasFocus'] is True,
                          report['focusAfterTyping'])
                    # 'ab' + U+1F600 (two UTF-16 units) + two CJK units = 6.
                    def caret_state():
                        rows = [s for s in text_states(tab) if s.get('editable') and s.get('focusToken') != '0']
                        last = rows[-1] if rows else None
                        return last if last and last['selection'].get('valid') and last['selection']['end'] == 6 else None
                    text = eventually('native UTF-16 text state', caret_state)
                    report['textState'] = text
                    check('native text state UTF-16 caret', text['selection']['start'] == 6, text['selection'])
                    check('surrounding text present for a normal field',
                          text.get('hasSurrounding') is True and 'ab' in text.get('surrounding', ''), text)
                    check('caret geometry in root-page coordinates', text.get('coordinateSpace') == 'rootPage' and
                          ('caretBounds' in text or 'selectionBounds' in text), text)
                    via_wire = request('tab.textInput', {'tab': tab})
                    check('tab.textInput returns cached state', via_wire['available'] and
                          via_wire['state'] and via_wire['state']['focusToken'] == text['focusToken'], via_wire)
                capture(tab, 'typed')
            except Exception as error:
                section_failed('focus', error)
            try:
                # Password field: native state must withhold its text.
                for kind in ('mouseDown', 'mouseUp'):
                    request('input.send', {'tab': tab, 'kind': kind, 'x': 60, 'y': 180})
                eventually('password focused', lambda: evaluate(tab, 'document.activeElement.id') == 'secret')
                request('input.send', {'tab': tab, 'kind': 'text', 'text': 'hunter2'})
                eventually('password typed', lambda: evaluate(tab, 'document.querySelector("#secret").value') == 'hunter2')
                if expect:
                    secure = eventually('secure text state', lambda: next((s for s in reversed(text_states(tab))
                                        if s.get('secure')), None))
                    report['secureState'] = secure
                    check('password text withheld', 'surrounding' not in secure and
                          not secure.get('hasSurrounding'), secure)
                    check('no state leaks the password', all('hunter2' not in json.dumps(s) for s in text_states(tab)))
                    request('tab.focus', {'tab': tab, 'focused': False})
                    eventually('focus released', lambda: evaluate(tab, 'document.hasFocus()') is False)
                    check('focus release reaches the page', True)

            except Exception as error:
                section_failed('password', error)
            if args.baseline:
                # The wave-1 reference predates the download wire; record only.
                report['downloadBaseline'] = 'download wire absent in reference helper'
                request('tab.close', {'tab': tab})
                request('shutdown')
                process.wait(timeout=20)
                report['helperExit'] = process.returncode
                report['passed'] = True
                return
            def ready_tab(target, url_suffix=None):
                def done():
                    s = request('tab.state', {'tab': target})
                    ok = s['hasDocument'] and s['devToolsReady'] and not s['loading']
                    return s if ok and (url_suffix is None or s['url'].endswith(url_suffix)) else None
                return eventually('tab ready ' + str(url_suffix), done)

            try:
                # Native discard, restore and freeze (patch 0012): history stays in
                # the engine and only the selected entry loads again.
                if hooks.get('nativeDiscard'):
                    hist = request('tab.create', {'profile': 'wave3', 'url': base + '/h1'})['tab']
                    ready_tab(hist, '/h1')
                    for path in ('/h2', '/h3'):
                        request('tab.navigate', {'tab': hist, 'url': base + path})
                        ready_tab(hist, path)
                    request('tab.back', {'tab': hist})
                    ready_tab(hist, '/h2')
                    state = request('tab.state', {'tab': hist})
                    check('history has back and forward before discard', state.get('canGoBack') and state.get('canGoForward'), state)
                    request('tab.visible', {'tab': hist, 'visible': False})
                    before_hits = dict(HITS)
                    refused = request('tab.discard', {'tab': hist}, allow_error=True)
                    report['discard'] = refused
                    check('page discarded', refused.get('discarded') is True, refused)
                    check('state reports discarded', request('tab.state', {'tab': hist}).get('discarded') is True)
                    check('discard did not reload history', HITS == before_hits, [HITS, before_hits])
                    request('tab.visible', {'tab': hist, 'visible': True})
                    ready_tab(hist, '/h2')
                    # Restoring is asynchronous: wait for the engine to leave the discarded state.
                    print('DISCARD events', json.dumps(state_events(hist, 'discarded')), json.dumps(request('tab.state', {'tab': hist}).get('discarded')), flush=True)
                    eventually('discard cleared', lambda: request('tab.state', {'tab': hist}).get('discarded') is False)
                    restored = request('tab.state', {'tab': hist})
                    check('selected entry restored', restored['url'].endswith('/h2') and restored.get('discarded') is False, restored)
                    check('only the selected entry loaded again', HITS['/h2'] == before_hits['/h2'] + 1 and
                          HITS['/h1'] == before_hits['/h1'] and HITS['/h3'] == before_hits['/h3'], [HITS, before_hits])
                    check('history still native after restore', restored.get('canGoBack') and restored.get('canGoForward'), restored)
                    visible_discard = request('tab.discard', {'tab': hist}, allow_error=True)
                    check('visible page refuses discard', visible_discard.get('discarded') is False, visible_discard)
                    request('tab.visible', {'tab': hist, 'visible': False})
                    frozen = request('tab.freeze', {'tab': hist, 'frozen': True})
                    check('hidden page accepts freeze', frozen.get('accepted') is True and frozen.get('frozen') is True, frozen)
                    check('freeze lifted', request('tab.freeze', {'tab': hist, 'frozen': False}).get('frozen') is False)
                    request('tab.freeze', {'tab': hist, 'frozen': True})
                    request('tab.visible', {'tab': hist, 'visible': True})
                    check('showing a page unfreezes it', request('tab.state', {'tab': hist}).get('frozen') is False)
                    refused_freeze = request('tab.freeze', {'tab': hist, 'frozen': True})
                    check('visible page refuses freeze', refused_freeze.get('accepted') is False, refused_freeze)
                    request('tab.close', {'tab': hist})

            except Exception as error:
                section_failed('discard', error)
            def suspended_print_diagnostic(ptab, asked):
                evaluate(ptab, '(setTimeout(()=>print(),50),true)')
                second = eventually('second print.request', lambda: next((e['params'] for e in events
                    if e['event'] == 'print.request' and e['params'].get('tab') == ptab and
                    e['params']['request'] != asked['request']), None), 15)
                during = request('page.printPDF', {'tab': ptab}, allow_error=True)
                report['printPDFWhileSuspended'] = during if 'error' in during else 'stream'
                report['secondRequestAfterPDF'] = request('print.finish', {'tab': ptab, 'request': second['request']})
                print('PRINT', json.dumps({k: report.get(k) for k in ('printPDFBaseline', 'printPDFAfterFinish', 'printPDFWhileSuspended', 'secondRequestAfterPDF')})[:700], flush=True)

            try:
                # Page-initiated print (patch 0014): window.print is suspended until
                # the client finishes the native request; afterprint then fires.
                if hooks.get('nativePrint'):
                    ptab = request('tab.create', {'profile': 'wave3', 'url': base + '/h1'})['tab']
                    ready_tab(ptab, '/h1')
                    # printToPDF without any pending request: records whether the engine can print at all.
                    baseline_pdf = request('page.printPDF', {'tab': ptab}, allow_error=True)
                    report['printPDFBaseline'] = baseline_pdf if 'error' in baseline_pdf else 'stream'
                    if 'stream' in baseline_pdf:
                        request('page.pdf.close', {'tab': ptab, 'stream': baseline_pdf['stream']}, allow_error=True)
                    evaluate(ptab, '(addEventListener("afterprint",()=>{window.__after=(window.__after||0)+1}),true)')
                    evaluate(ptab, '(setTimeout(()=>print(),50),true)')
                    asked = eventually('print.request', lambda: next((e['params'] for e in events
                                       if e['event'] == 'print.request' and e['params'].get('tab') == ptab), None), 15)
                    report['printRequest'] = asked
                    check('print request is scripted for the main frame', asked.get('scripted') is True and
                          asked.get('mainFrame') is True and asked.get('url', '').startswith(base), asked)
                    done = request('print.finish', {'tab': ptab, 'request': asked['request']})
                    check('print finished once', done.get('finished') is True, done)
                    eventually('afterprint', lambda: evaluate(ptab, 'window.__after') == 1, 15)
                    check('afterprint fired after the client finished', True)
                    again = request('print.finish', {'tab': ptab, 'request': asked['request']})
                    check('stale print finish refused', again.get('finished') is False, again)
                    # The client renders its preview after finishing: printToPDF works then.
                    after_pdf = request('page.printPDF', {'tab': ptab}, allow_error=True)
                    report['printPDFAfterFinish'] = after_pdf if 'error' in after_pdf else 'stream'
                    check('printToPDF works after the request finished', 'stream' in after_pdf, after_pdf)
                    request('page.pdf.close', {'tab': ptab, 'stream': after_pdf['stream']}, allow_error=True)
                    # This unsupported order can leave Blink inside printing and
                    # abort a source renderer. Keep it as an explicit diagnostic,
                    # outside acceptance of the finish-then-PDF contract above.
                    if os.environ.get('YAB_OWNCEF_SUSPENDED_PRINT_DIAGNOSTIC') == '1':
                        suspended_print_diagnostic(ptab, asked)
                    print('PRINT', json.dumps({k: report.get(k) for k in ('printPDFBaseline', 'printPDFAfterFinish')})[:700], flush=True)
                    request('tab.close', {'tab': ptab})

            except Exception as error:
                section_failed('print', error)

            try:
                # Extension consent and Chrome-created tab metadata (patches 0011,
                # 0013): the uninstall dialog goes to the client, never a window.
                if hooks.get('extensionConsent'):
                    extension = Path(temporary) / 'consent-ext'
                    extension.mkdir()
                    (extension / 'manifest.json').write_text(json.dumps({
                        'manifest_version': 3, 'name': 'Wave3 Consent', 'version': '1.0.0',
                        'permissions': ['tabs'], 'background': {'service_worker': 'bg.js'}}))
                    (extension / 'bg.js').write_text("chrome.runtime.onInstalled.addListener(()=>chrome.tabs.create("
                        "{url:%s,active:false,index:0}))" % json.dumps(base + '/h1'))
                    profile_tab = request('extension.open', {'profile': 'wave3'})['tab']
                    ready_tab(profile_tab, 'chrome://extensions/')
                    request('extension.load', {'tab': profile_tab, 'path': str(extension)})
                    def listed():
                        rows = request('extension.list', {'tab': profile_tab})
                        return next((r for r in rows if r['name'] == 'Wave3 Consent'), None)
                    row = eventually('extension installed', listed)
                    created = eventually('extension tab metadata', lambda: next((e['params'] for e in events
                                         if e['event'] == 'tab.extensionCreated'), None), 20)
                    report['extensionTab'] = created
                    report['chromeCreatedTabs'] = [e['params'] for e in events if e['event'] == 'tab.created']
                    check('chrome.tabs.create metadata', created.get('active') is False and created.get('index') == 0 and
                          created.get('extensionId') == row['id'], created)
                    def uninstall():
                        request('script.document', {'tab': profile_tab, 'userGesture': True, 'expression':
                            "(globalThis.__u=null,chrome.management.uninstall(%s,{showConfirmDialog:true},()=>"
                            "{globalThis.__u=chrome.runtime.lastError?.message??'ok'}),true)" % json.dumps(row['id'])})
                        return eventually('extension.consent', lambda: next((e['params'] for e in events
                            if e['event'] == 'extension.consent' and e['params'].get('request') not in seen), None), 15)
                    seen = set()
                    ask = uninstall()
                    seen.add(ask['request'])
                    report['consentRequest'] = ask
                    check('uninstall consent identifies the request', ask.get('operation') == 'uninstall' and
                          ask.get('extensionId') == row['id'] and ask.get('displayName') == 'Wave3 Consent' and
                          ask.get('profile') == 'wave3', ask)
                    wrong = request('extension.consent.reply', {'request': ask['request'], 'extension': row['id'],
                                    'profile': 'other', 'accept': True}, allow_error=True)
                    check('cross-profile answer refused', 'error' in wrong, wrong)
                    request('extension.consent.reply', {'request': ask['request'], 'extension': row['id'],
                            'profile': 'wave3', 'accept': False})
                    eventually('cancel reported to Chrome', lambda: request('script.document', {'tab': profile_tab,
                               'expression': 'globalThis.__u'}) not in (None, ''))
                    check('canceled uninstall keeps the extension', listed() is not None)
                    stale = request('extension.consent.reply', {'request': ask['request'], 'extension': row['id'],
                                    'profile': 'wave3', 'accept': True}, allow_error=True)
                    check('answered request cannot be answered again', 'error' in stale, stale)
                    ask = uninstall()
                    seen.add(ask['request'])
                    request('extension.consent.reply', {'request': ask['request'], 'extension': row['id'],
                            'profile': 'wave3', 'accept': True})
                    eventually('extension removed', lambda: listed() is None)
                    check('accepted uninstall removes the extension', True)
                    request('tab.close', {'tab': profile_tab})
                    report['chromeCreatedGeometry'] = {e['params']['tab']: request('tab.state',
                        {'tab': e['params']['tab']}, allow_error=True)
                        for e in events if e['event'] == 'tab.created'}

            except Exception as error:
                section_failed('consent', error)
            try:
                # Downloads: provenance comes from Chromium's DownloadItem.
                def opened(count):
                    rows = [e['params'] for e in events if e['event'] == 'download.open'
                            and e['params'].get('tab') == tab]
                    return rows if len(rows) >= count else None
                for kind in ('mouseDown', 'mouseUp'):
                    request('input.send', {'tab': tab, 'kind': kind, 'x': 50, 'y': 242})
                first = eventually('gesture download', lambda: opened(1))[0]
                report['gestureDownload'] = first
                target = out / 'wave3-gesture.bin'
                request('download.destination', {'tab': tab, 'download': first['download'], 'path': str(target)})
                def finished(token):
                    rows = [e['params'] for e in events if e['event'] == 'download.updated'
                            and e['params'].get('download') == token and e['params'].get('complete')]
                    if not rows:
                        request('tab.state', {'tab': tab})
                    return rows[-1] if rows else None
                eventually('gesture download complete', lambda: finished(first['download']))
                check('downloaded bytes exact', target.read_bytes() == b'yab wave 3 download\n' * 64)
                time.sleep(6)  # the click above leaves transient user activation for 5 s
                evaluate(tab, '(location.href="/file-script.bin", true)')
                second = eventually('script download', lambda: opened(2))[1]
                report['scriptDownload'] = second
                request('download.cancel', {'tab': tab, 'download': second['download']})
                if expect:
                    check('gesture download provenance', first.get('provenance') == 'native' and
                          first.get('userGesture') is True and first.get('initiator') == base, first)
                    check('script download has no gesture', second.get('provenance') == 'native' and
                          second.get('userGesture') is False and second.get('initiator') == base, second)
                    check('tab URL recorded', first.get('tabURL', '').startswith(base), first)
                else:
                    check('baseline reports provenance unavailable',
                          first.get('provenance') in (None, 'unavailable'), first)
            except Exception as error:
                section_failed('downloads', error)
            request('tab.close', {'tab': tab})
            request('shutdown')
            process.wait(timeout=20)
            report['helperExit'] = process.returncode
            assert process.returncode == 0, process.returncode
            assert not report.get('failedSections'), report.get('failedSections')
            report['passed'] = True
    except Exception as error:
        report['error'] = repr(error)
        raise
    finally:
        stop(host)
        if reader:
            reader.close()
        if peer:
            peer.close()
        stop(process)
        server.shutdown()
        report['events'] = [e for e in events if e['event'] in ('page.textInput', 'download.open', 'download.updated',
                                                                'layer.changed', 'tab.resized', 'print.request', 'print.withdrawn')
                            or (e['event'] == 'page.state' and ('audible' in e['params']))]
        (out / 'wave3-proof.json').write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
