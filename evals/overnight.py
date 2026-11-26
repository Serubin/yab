#!/usr/bin/env python3
"""Remote farm batches with durable stage results and explicit coverage gaps.

./farm exec --host adhd --display --estimate 9000 -- python3 evals/overnight.py profiles
./farm exec --host renderer-2 --display --estimate 5400 -- python3 evals/overnight.py native
All output is kept beside this job's APP, outside the reusable checkout lane.
"""
import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import socket
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
PROFILES = tuple(json.loads((ROOT / 'evals/usage/scenarios/catalog.json').read_text())['profiles'])


def save(path, value):
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(value, indent=2, ensure_ascii=False) + '\n')
    temporary.replace(path)


def notices(log):
    return [line[:500] for line in log.splitlines()
            if re.search(r'\b(skip(?:ped)?|unsupported|gated|gap|inconclusive)\b', line, re.I)
            and not re.search(r'\b0 (?:skip(?:ped)?|gap)', line, re.I)][-100:]


def run_stage(out, state, name, command, timeout=1800, env=None):
    # Recheck physical prerequisites between stages, not just at dispatch.
    from farm import guard
    guard(True)
    row = {'name': name, 'command': list(map(str, command)), 'status': 'running',
           'started': time.time(), 'log': str(out / (name + '.log'))}
    state['stages'].append(row)
    state['status'] = 'running'
    save(out / 'status.json', state)
    print('START ' + name, flush=True)
    with open(row['log'], 'w') as log:
        child = subprocess.Popen(row['command'], cwd=ROOT, env=env or os.environ,
                                 stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        row['pid'] = child.pid
        save(out / 'status.json', state)
        try:
            code = child.wait(timeout=timeout)
            row.update(returncode=code, status='passed' if code == 0 else 'failed')
        except subprocess.TimeoutExpired:
            # Allow the harness's finally blocks to close its own test app.
            os.killpg(child.pid, signal.SIGINT)
            try:
                child.wait(timeout=30)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL)
                child.wait()
            row.update(status='timeout', returncode=124)
        finally:
            row['ended'] = time.time()
            row['seconds'] = row['ended'] - row['started']
            row['notices'] = notices(Path(row['log']).read_text(errors='replace'))
            # A caller may append stages after main() completed. Never keep
            # its old successful summary while a later regression has failed.
            state['status'] = ('stages_completed_with_failures'
                               if any(s['status'] != 'passed' for s in state['stages'])
                               else 'stages_passed_pending_coverage_review')
            save(out / 'status.json', state)
    print('END %s: %s (%.1fs)' % (name, row['status'], row['seconds']), flush=True)
    if row['status'] == 'timeout':
        raise RuntimeError('stage timed out; inspect owned test processes before continuing: ' + name)
    return row['returncode'] == 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('track', choices=('profiles', 'native', 'mail-sections', 'regressions'))
    parser.add_argument('--session-minutes', type=float, default=10)
    args = parser.parse_args()
    if not 0 < args.session_minutes <= 60:
        parser.error('session-minutes must be in (0, 60]')
    # This entrypoint cannot accidentally build/test on the user's current Mac.
    if (sys.platform != 'darwin' or os.environ.get('YAB_FARM_WORKER') != '1'
            or os.environ.get('WHERE') not in ('adhd', 'renderer-2', 'main')):
        parser.error('run through ./farm exec --display --host adhd or renderer-2')
    sys.path.insert(0, str(ROOT / 'scripts/remote'))
    app = Path(os.environ['APP'])
    out = app.parent / 'overnight'
    out.mkdir(exist_ok=False)
    state = {'schema': 1, 'track': args.track, 'host': socket.gethostname(),
             'source_snapshot': (app.parent / 'snapshot').read_text().strip(),
             'started': time.time(), 'status': 'running', 'stages': [],
             'performance_acceptance': 'pending review of quiet-host and per-run quality evidence',
             'coverage_gaps': ['signed-in third-party professional workflows',
                               'real Gmail OAuth and live provider delivery',
                               'physical input and full visual acceptance',
                               'OS sleep/wake, screen sharing, extensions and real agent CLIs']}
    save(out / 'status.json', state)
    py = sys.executable
    provenance = out / 'build-manifest.json'
    env = dict(os.environ, PYTHONUNBUFFERED='1')
    stage = lambda name, command, **kw: run_stage(out, state, name, command, env=env, **kw)
    try:
        if not stage('source-archive', ['git', 'archive', '--format=tar.gz',
                                      '--output=' + str(out / 'source.tar.gz'),
                                      state['source_snapshot']], timeout=300):
            raise RuntimeError('could not preserve the frozen source snapshot')
        if not stage('build', [py, 'evals/usage/build_manifest.py', '--shipping-optimization',
                               '--out', provenance], timeout=3600):
            raise RuntimeError('build failed; no candidate app is accepted')
        if app.exists():
            raise RuntimeError('refusing to overwrite an existing app in this job slot')
        shutil.copytree(ROOT / 'build/Pane Dev.app', app, symlinks=True)
        state['app'] = str(app)
        state['binary_sha256'] = json.loads(provenance.read_text())['binary_sha256']
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        binary = app / 'Contents/MacOS' / info['CFBundleExecutable']
        if args.track == 'profiles':
            common = ['--app', str(app), '--provenance', str(provenance)]
            functional = ['--functional-only'] if os.environ['WHERE'] == 'renderer-2' else []
            if functional:
                state['performance_acceptance'] = 'functional only; renderer-2 shares production rendering'
            stage('usage-contracts', [py, '-m', 'unittest', 'discover', '-s', 'evals/usage', '-p', 'test_*.py', '-v'])
            stage('profiles-smoke-faults', [py, 'evals/usage/suite.py', *common, *functional, '--faults',
                                          '--out', out / 'smoke'], timeout=3600)
            # One independent stage per profile: a failure cannot hide the other seven.
            for profile in PROFILES:
                stage('session-' + profile, [py, 'evals/usage/run.py', '--launch', *common, *functional,
                      '--scenario', profile, '--mode', 'session', '--minutes', str(args.session_minutes),
                      '--out', out / ('session-' + profile)], timeout=int(args.session_minutes * 60 + 900))
            stage('public-sites', [py, 'evals/usage/real.py', *common, '--out', out / 'public-sites'], timeout=3600)
            if functional:
                state['coverage_gaps'].append('quiet-host Mail timing; renderer-2 is functional only')
            else:
                env['MAIL_WORLD'] = 'night-time-' + os.environ['SLOT']
                stage('mail-timing', [py, 'evals/mail/time.py', '--app', app, '--front',
                                      '--out', out / 'mail-timing.json'], timeout=3600)
        elif args.track == 'regressions':
            state['performance_acceptance'] = 'functional regressions only; no timing acceptance'
            stage('targeted-swift', ['swift', 'test', '--filter',
                  'BenchKeyEventTests|NoEmptyTabTests|SafariImportTests|MailSnippetTests|MailRichTests'], timeout=1800)
            stage('headless-contracts', [py, '-m', 'unittest', 'discover', '-s', 'evals/headless', '-p', 'test_*.py', '-v'])
            env.update(MAIL_WORLD='night-snippets-' + os.environ['SLOT'][-16:], MAIL_FRONT='1',
                       YAB_STAGE='/nonexistent-night-test-stage')
            stage('mail-snippets', [py, 'evals/mail/check.py', '--app', app, '--only', 'snippets'], timeout=900)
            env['MAIL_WORLD']='night-attachments-' + os.environ['SLOT'][-16:]
            stage('mail-attachments', [py, 'evals/mail/check.py', '--app', app, '--only', 'attachments'], timeout=900)
            stage('headless-start-seen', [py, 'evals/headless/check.py', '--bin', binary,
                                        '--only', 'hidden-start,seen', '--out', out / 'headless'], timeout=300)
        elif args.track == 'mail-sections':
            state['performance_acceptance'] = 'functional Mail fixtures only; no timing acceptance'
            stage('headless-contracts', [py, '-m', 'unittest', 'discover', '-s', 'evals/headless', '-p', 'test_*.py', '-v'])
            for section in ('memory', 'calendar', 'splits', 'filters', 'labels', 'reads', 'notify',
                            'followup', 'cleanup', 'rich', 'attach', 'attachments', 'motion', 'speed'):
                env.update(MAIL_WORLD='night-' + os.environ['SLOT'][-16:] + '-' + section,
                           MAIL_MEMORY_WORLD='night-memory-' + os.environ['SLOT'][-16:],
                           MAIL_MEMORY_RESULTS=str(out / 'mail-memory.json'),
                           YAB_STAGE='/nonexistent-night-test-stage')
                stage('mail-' + section, [py, 'evals/mail/check.py', '--app', app, '--only', section], timeout=1200)
        else:
            state['performance_acceptance'] = 'functional only; quiet-host performance acceptance requires separate evidence'
            stage('swift-tests', ['swift', 'test'], timeout=3600)
            stage('design-check', ['./design-check'])
            stage('usage-contracts', [py, '-m', 'unittest', 'discover', '-s', 'evals/usage', '-p', 'test_*.py', '-v'])
            stage('overnight-contracts', [py, '-m', 'unittest', 'discover', '-s', 'evals', '-p', 'test_overnight.py', '-v'])
            stage('headless-contracts', [py, '-m', 'unittest', 'discover', '-s', 'evals/headless', '-p', 'test_*.py', '-v'])
            stage('fake-gmail-contracts', [py, 'evals/mail/fake_selftest.py'])
            env.update(MAIL_WORLD='night-mail-' + os.environ['SLOT'],
                       MAIL_MEMORY_WORLD='night-memory-' + os.environ['SLOT'],
                       MAIL_MEMORY_RESULTS=str(out / 'mail-memory.json'), MAIL_FRONT='1',
                       MAIL_SHOTS=str(out / 'mail-shots'),
                       YAB_STAGE='/nonexistent-night-test-stage')
            stage('mail-full', [py, 'evals/mail/check.py', '--app', app], timeout=5400)
            stage('browser-tools-native', ['evals/browse/check'], timeout=3600)
            stage('spaces', [py, 'evals/browse/spaces.py', '--bin', binary])
            stage('headless', [py, 'evals/headless/check.py', '--bin', binary, '--out', out / 'headless'], timeout=3600)
            stage('hint-keys', [py, 'evals/hint-keys.py'])
            stage('multi-window', [py, 'evals/multi-window-actions.py', '--bin', binary, '--out', out])
        state['status'] = 'completed_with_failures' if any(s['status'] != 'passed' for s in state['stages']) else 'completed_pending_coverage_review'
    except Exception as error:
        state.update(status='blocked', error=str(error))
        print('BLOCKED: ' + str(error), flush=True)
    finally:
        # Existing harnesses put extra screenshots in the lane. Preserve evidence
        # before another farm job can reuse it.
        for name in ('native-evidence', 'mail-shots', 'mail-check-shots'):
            source = ROOT / '.build' / name
            if source.is_dir():
                shutil.copytree(source, out / name, dirs_exist_ok=True)
        state['ended'] = time.time()
        save(out / 'status.json', state)
        print(json.dumps({'evidence': str(out), 'status': state['status']}), flush=True)
    return int(state['status'] != 'completed_pending_coverage_review')


if __name__ == '__main__':
    raise SystemExit(main())
