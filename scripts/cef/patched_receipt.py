#!/usr/bin/env python3
"""Patch-series receipt for a self-built patched CEF SDK.

usage: patched_receipt.py [--check MANIFEST]
"""
import argparse
import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
PATCHES = ROOT / 'YabCore/cef-patches'


def series():
    # Same selection and order as YabCore/cef-patches/apply-series.py.
    return {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(PATCHES.glob('[0-9][0-9][0-9][0-9]-*.patch'))}


def check(manifest):
    pinned = json.loads(manifest.read_text()).get('patches', {})
    current = series()
    if pinned == current:
        print(f'CEF: patched SDK matches all {len(current)} patches')
        return 0
    for name in sorted(set(pinned) | set(current)):
        if name not in current:
            print(f'  removed since the SDK was built: {name}', file=sys.stderr)
        elif name not in pinned:
            print(f'  added since the SDK was built:   {name}', file=sys.stderr)
        elif pinned[name] != current[name]:
            print(f'  changed since the SDK was built: {name}', file=sys.stderr)
    print('CEF: YabCore/cef-patches no longer matches the patched SDK; rebuild it '
          'with scripts/cef/build-patched.sh and publish a new one', file=sys.stderr)
    return 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', type=Path, metavar='MANIFEST')
    args = parser.parse_args()
    if args.check:
        sys.exit(check(args.check))
    json.dump(series(), sys.stdout, indent=2)
    print()


if __name__ == '__main__':
    main()
