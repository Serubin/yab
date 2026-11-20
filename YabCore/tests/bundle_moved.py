#!/usr/bin/env python3
"""YabCore and its bundle after Update.Swap set that bundle aside.

Update.Swap renames the running yab.app to yab.app.old and puts the new build
at yab.app, while Yab runs. Two cases, both on the bundle set aside, with the
old path left empty here:
  moved  YabCore was running; the tabs it opens next need renderers.
  aside  YabCore starts from yab.app.old (the app relaunching it after a swap).
A renderer started from yab.app.old CHECKed in BundleFromPath at startup:
CEF takes the first path component ending in .app for the main bundle, and
that is the helper's own (#1505). Passes when every tab loads and answers.
--expect-failure: the baseline must fail to load the later tabs.
"""
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time

assert os.environ.get('YAB_FARM_WORKER') == '1', 'Run through ./farm'
helper = Path(sys.argv[1])
expect_failure = '--expect-failure' in sys.argv[2:]
out = Path(os.environ['YAB_FARM_OUT'])
app = helper.parents[2]
aside = app.with_name(app.name + '.old')
assert app.suffix == '.app' and not aside.exists(), (app, aside)
# Sandboxed by default, as Yab runs it.
unsandboxed = '--no-sandbox' in sys.argv[2:]
label = ('baseline' if expect_failure else 'fixed') + ('-unsandboxed' if unsandboxed else '')


def scenario(case):
    report = {'case': case, 'app': str(app)}
    with tempfile.TemporaryDirectory(prefix='yc-moved-', dir='/tmp') as temporary:
        endpoint = Path(temporary) / 'core.sock'
        log_path = out / ('moved-%s-%s.log' % (case, label))
        moved = False
        if case == 'aside':
            app.rename(aside); moved = True
        executable = (aside if moved else app) / 'Contents/MacOS/PaneCore'
        with log_path.open('w') as log:
            process = subprocess.Popen([str(executable), '--socket=' + str(endpoint),
                '--data-root=' + temporary + '/data', '--use-mock-keychain'] + (['--no-sandbox'] if unsandboxed else []),
                stdout=log, stderr=log)
            try:
                deadline = time.monotonic() + 30
                while not endpoint.exists():
                    assert process.poll() is None and time.monotonic() < deadline, 'Helper did not start'
                    time.sleep(.1)
                with socket.socket(socket.AF_UNIX) as sock:
                    sock.connect(str(endpoint)); sock.settimeout(20)
                    stream = sock.makefile('rb')
                    def call(method, **params):
                        call.serial += 1
                        request = str(call.serial)
                        sock.sendall((json.dumps(dict(v=1, id=request, method=method, params=params)) + '\n').encode())
                        while True:
                            raw = stream.readline()
                            assert raw, 'Helper exited during ' + method
                            value = json.loads(raw)
                            if value.get('id') == request:
                                assert 'error' not in value, value
                                return value.get('result')
                    call.serial = 0
                    def open_tab(title):
                        tab = call('tab.create', profile='moved', url='data:text/html,<title>%s</title>' % title)['tab']
                        call('tab.resize', tab=tab, width=800, height=600, scale=1)
                        return tab
                    def loads(tab, title, seconds):
                        deadline = time.monotonic() + seconds
                        while time.monotonic() < deadline:
                            if call('tab.state', tab=tab).get('devToolsReady'):
                                try:
                                    if call('script.evaluate', tab=tab, world='moved-test',
                                            function='function(){return document.title}') == title:
                                        return True
                                except AssertionError:
                                    pass
                            time.sleep(.2)
                        return False
                    call('hello'); call('profile.open', profile='moved', private=True)
                    first = open_tab('First')
                    report['firstLoads'] = loads(first, 'First', 20)
                    if case == 'moved':
                        assert report['firstLoads'], 'The first tab never loaded'
                        app.rename(aside); moved = True
                    # Three more: Chrome may hand the first of them a spare
                    # renderer started earlier; the later ones need new ones.
                    later = [open_tab('Later %d' % index) for index in range(3)]
                    report['laterLoad'] = [loads(tab, 'Later %d' % index, 20) for index, tab in enumerate(later)]
                    report['firstStillAnswers'] = loads(first, 'First', 5)
                    report['alive'] = process.poll() is None
            except (OSError, AssertionError) as error:
                report['error'] = str(error)
            finally:
                if process.poll() is None:
                    process.terminate()
                    try: process.wait(timeout=20)
                    except subprocess.TimeoutExpired: process.kill(); process.wait()
                report['exit'] = process.returncode
                if moved: aside.rename(app)
        text = log_path.read_text(errors='replace')
        report['children'] = [line.split(' -> ')[-1][-90:] for line in text.splitlines() if line.startswith('YabCore child renderer')][-4:]
    report['ok'] = bool(report.get('firstLoads') and all(report.get('laterLoad', [False]))
                        and report.get('firstStillAnswers') and report.get('alive'))
    return report


reports = [scenario('moved'), scenario('aside')]
(out / ('moved-%s.json' % label)).write_text(json.dumps(reports, indent=2))
print(json.dumps(reports, indent=2), flush=True)
for report in reports:
    if expect_failure:
        print(('PASS' if not report['ok'] else 'FAIL') + ': baseline, %s: tabs %s' % (
            report['case'], 'fail to load' if not report['ok'] else 'load'), flush=True)
    else:
        print(('PASS' if report['ok'] else 'FAIL') + ': %s: every tab loads from yab.app.old' % report['case'], flush=True)
ok = all((not report['ok']) if expect_failure else report['ok'] for report in reports)
sys.exit(0 if ok else 1)
