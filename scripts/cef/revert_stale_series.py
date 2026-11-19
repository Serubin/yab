#!/usr/bin/env python3
"""Reverse a previously applied Yab patch series when the repo's series moved on.

usage: revert_stale_series.py --src CHROMIUM_SRC --snapshot DIR
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from patched_receipt import PATCHES, series  # noqa: E402

LEDGER = '.yab-owncef-patches.json'


def git_apply(src, patch, *flags):
    return subprocess.run(['git', '-C', str(src), 'apply', *flags, str(patch)],
                          capture_output=True, text=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--src', type=Path, required=True)
    parser.add_argument('--snapshot', type=Path, required=True)
    args = parser.parse_args()
    ledger = args.src / LEDGER
    current = [{'name': n, 'sha256': h} for n, h in series().items()]
    if not ledger.exists():
        args.snapshot.mkdir(parents=True, exist_ok=True)
    else:
        applied = json.loads(ledger.read_text())['patches']
        if current[:len(applied)] == applied:
            print(f'series: {len(applied)} applied patches are still current')
        else:
            print(f'series: reversing {len(applied)} stale patches', file=sys.stderr)
            for entry in reversed(applied):
                patch = args.snapshot / entry['name']
                if not patch.is_file() or hashlib.sha256(patch.read_bytes()).hexdigest() != entry['sha256']:
                    sys.exit(f'series: no exact snapshot of applied {entry["name"]}; '
                             'delete the build root and start over')
                for flags in (('--reverse', '--check'), ('--reverse',)):
                    result = git_apply(args.src, patch, *flags)
                    if result.returncode:
                        sys.exit(f'series: could not reverse {entry["name"]}: {result.stderr.strip()}')
                # Shrink the ledger as we go so an interrupted revert resumes cleanly.
                applied.pop()
                ledger.write_text(json.dumps({'schema': 1, 'patches': applied}, indent=2) + '\n')
            ledger.unlink()
            shutil.rmtree(args.snapshot)
            args.snapshot.mkdir(parents=True)
    # apply-series.py only extends a series; this exact copy is what lets a later change reverse it.
    for entry in current:
        shutil.copy2(PATCHES / entry['name'], args.snapshot / entry['name'])


if __name__ == '__main__':
    main()
