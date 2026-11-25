#!/usr/bin/env python3
"""Build both app revisions and run the posted-input comparison on the farm."""
import argparse
import os
from pathlib import Path
import subprocess
import sys


def logged(argv, path):
    with path.open('w') as log:
        with subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True) as process:
            for line in process.stdout:
                sys.stdout.write(line)
                sys.stdout.flush()
                log.write(line)
            if process.wait():
                raise subprocess.CalledProcessError(process.returncode, argv)


def main():
    if os.environ.get('YAB_FARM_WORKER') != '1':
        raise RuntimeError('Run through ./farm exec')
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('base')
    parser.add_argument('--reuse', type=Path, help='Reuse both apps from a completed farm job')
    parser.add_argument('--from-host', choices=('adhd', 'm4', 'renderer-2'),
                        help='Read the saved apps from this farm host')
    args = parser.parse_args()
    if args.from_host and not args.reuse:
        parser.error('--from-host requires --reuse')
    base = args.base
    os.chdir(Path(__file__).resolve().parents[2])
    out = Path(os.environ['YAB_FARM_OUT'])
    apps = args.reuse.resolve() if args.reuse else out / 'apps'
    if args.from_host and args.from_host != os.environ.get('WHERE'):
        apps = out / 'apps'
        apps.mkdir(parents=True, exist_ok=True)
        subprocess.run(['rsync', '-a', '-e', 'ssh -o BatchMode=yes -o ConnectTimeout=15',
                        args.from_host + ':' + str(args.reuse) + '/', str(apps) + '/'], check=True)
    (out / 'base-revision.txt').write_text(base + '\n')
    if args.reuse:
        for name in ('candidate.app', 'base.app'):
            if not (apps / name).is_dir():
                raise FileNotFoundError(apps / name)
        (out / 'reused-apps.txt').write_text((args.from_host or os.environ.get('WHERE', '')) +
                                          ':' + str(args.reuse) + '\n')
    else:
        apps.mkdir(parents=True, exist_ok=True)
        logged(['./build.sh'], out / 'build-candidate.log')
        subprocess.run(['ditto', 'build/Pane Dev.app', str(apps / 'candidate.app')], check=True)
        logged(['bash', 'scripts/runs/rev_app.sh', base, str(apps / 'base.app')], out / 'build-base.log')
    return subprocess.call([sys.executable, '-u', 'evals/horizontal-wheel/check.py',
        '--base-app', str(apps / 'base.app'), '--app', str(apps / 'candidate.app'), '--out', str(out / 'proof')])


if __name__ == '__main__':
    raise SystemExit(main())
