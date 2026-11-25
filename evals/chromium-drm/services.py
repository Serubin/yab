#!/usr/bin/env python3
"""Owner-run Spotify/Netflix playback acceptance in an already signed-in probe.

Never logs credentials, URLs, page text or media sources. Never signs in or
presses Play. The owner controls both in the existing isolated app window.
"""
import argparse
import json
from pathlib import Path
import sys
import time
import uuid
from urllib.parse import urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import yab_socket

HOSTS = {'spotify': {'open.spotify.com'}, 'netflix': {'netflix.com', 'www.netflix.com'}}
MEDIA = '''return Array.from(document.querySelectorAll('audio,video'), (m,index)=>({
index,time:m.currentTime,paused:m.paused,ended:m.ended,ready:m.readyState,error:m.error?.code??null
}));'''


def playback_advanced(before, after, seconds):
    """Require a continuing, healthy media element, not an ad/UI progress bar."""
    for first in before:
        for last in after:
            if (first['index'] == last['index'] and not first['paused'] and not last['paused']
                    and not first['ended'] and not last['ended'] and first['error'] is None
                    and last['error'] is None and first['ready'] >= 2 and last['ready'] >= 2
                    and last['time'] - first['time'] >= min(.5, seconds / 2)):
                return True
    return False


def run(args):
    args.out.mkdir(parents=True, exist_ok=True)
    report = {'service': args.service, 'checks': {}, 'scope': 'Owner-started real-service HTML media playback; no FairPlay/key-system assertion.'}
    checks = report['checks']
    original = None
    tab_id = args.tab
    original_host = None

    def ask(**request):
        reply = yab_socket.exchange(args.socket, dict(do='chromium-drm', id=tab_id, **request), timeout=45, strict=True)
        if 'error' in reply:
            raise RuntimeError('Bench operation failed; check the selected signed-in probe tab.')
        return reply

    def state():
        result = ask()
        host = (urlsplit(result.get('url', '')).hostname or '').lower().rstrip('.')
        if host not in HOSTS[args.service]:
            raise RuntimeError('Selected tab left the playback host. Return to the service player and rerun.')
        if original_host is not None and host != original_host:
            raise RuntimeError('Playback hostname changed. Restore the original host choice before rerunning.')
        if not result.get('tab', '').lower().startswith(tab_id.lower()):
            raise RuntimeError('Tab identity changed.')
        return result

    def ready(engine):
        until = time.monotonic() + args.timeout
        while time.monotonic() < until:
            current = state()
            if current['engine'] == engine and not current['loading'] and (engine != 'chromium' or current['context'] > 0):
                return
            time.sleep(.25)
        raise RuntimeError('Engine switch did not finish within the timeout.')

    try:
        initial = state()
        tab_id = initial['tab']
        original_host = (urlsplit(initial['url']).hostname or '').lower().rstrip('.')
        report['host'] = urlsplit(initial['url']).hostname
        original = ask(op='site-engine')['choice']
        report['original_choice'] = original
        input('Keep this service tab open. Press Enter to switch it to Chromium (playback will stop). ')
        ask(op='site-engine', choice='chromium')
        ready('chromium')
        checks['chromium_before'] = True
        input('Chromium is loaded. Press Enter to switch the same signed-in tab to Recommended (WebKit). ')
        ask(op='site-engine', choice='recommended')
        ready('webKit')
        checks['same_tab_after_switch'] = state()['tab'] == tab_id
        input('In Yab, start a Spotify track or Netflix title yourself. Wait until it plays, then press Enter here. ')
        before = ask(op='script', body=MEDIA)['value']
        time.sleep(args.seconds)
        after = ask(op='script', body=MEDIA)['value']
        checks['playing_advances'] = playback_advanced(before, after, args.seconds)
        checks['webkit_after_playback'] = state()['engine'] == 'webKit'
        if args.capture_pid:
            from probe_capture import picture
            capture = picture(args.capture_pid, args.out / 'service-playing.png', window_id=state()['window'])
            checks['screen_capture'] = capture.get('capture') == 'ScreenCaptureKit'
        if not checks['playing_advances']:
            raise RuntimeError('No healthy HTML media element advanced. Playback remains unverified; inspect the service manually.')
        report['ok'] = all(checks.values())
    except (Exception, KeyboardInterrupt) as error:
        report['ok'] = False
        report['failure'] = str(error) if isinstance(error, RuntimeError) else type(error).__name__
    finally:
        if original is not None:
            try:
                state()  # Never restore a preference onto a different host/tab.
                ask(op='site-engine', choice=original)
                report['restored_choice'] = original
            except Exception:
                report['restore_failed'] = True
                report['ok'] = False
        (args.out / 'summary.json').write_text(json.dumps(report, indent=2) + '\n')
    print(('PASS' if report.get('ok') else 'UNVERIFIED') + ': ' + str(args.out / 'summary.json'))
    if report.get('restore_failed'):
        print('Preference restoration failed. Restore the original host choice with the site-engine bench command.')
    return 0 if report.get('ok') else 1


def tab_reference(value):
    if len(value) == 8 and all(c in '0123456789abcdefABCDEF' for c in value):
        return value.lower()
    return str(uuid.UUID(value))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--socket', type=Path, required=True, help='Existing isolated probe bench.sock, not the daily profile')
    parser.add_argument('--tab', required=True, type=tab_reference, help='UUID or 8-character bench ID of the already signed-in service tab')
    parser.add_argument('--service', choices=HOSTS, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--seconds', type=float, default=5)
    parser.add_argument('--timeout', type=float, default=90)
    parser.add_argument('--capture-pid', type=int, help='Opt-in screenshot of this exact app PID; may include account UI')
    args = parser.parse_args()
    if args.seconds < 2 or args.timeout <= 0:
        parser.error('--seconds must be at least 2 and --timeout positive')
    if args.socket.parent.name == 'Pane' or not args.socket.parent.name.startswith('Pane ('):
        parser.error('Use an isolated YAB_PROBE world socket')
    return run(args)


if __name__ == '__main__':
    raise SystemExit(main())
