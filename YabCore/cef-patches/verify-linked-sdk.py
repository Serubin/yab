#!/usr/bin/env python3
"""Read-only provenance checks on the exact source SDK and signed Yab app."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess


def uuid(binary):
    result = subprocess.check_output(['dwarfdump', '--uuid', str(binary)], text=True)
    values = re.findall(r'^UUID: ([0-9A-Fa-f-]+) \(arm64\)', result, re.M)
    assert len(values) == 1, (str(binary), result)
    return values[0].upper()


def signing(path):
    subprocess.run(['codesign', '--verify', '--strict', str(path)], check=True)
    result = subprocess.run(['codesign', '-dvv', str(path)], check=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True).stdout
    assert 'TeamIdentifier=25UG4QYN9F' in result, (str(path), result)
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--sdk', type=Path, required=True)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--core-app', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    manifest = json.loads((args.sdk / 'yab-owncef.json').read_text())
    source = args.sdk / 'Release/Chromium Embedded Framework.framework/Chromium Embedded Framework'
    digest = hashlib.sha256()
    with source.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    assert digest.hexdigest() == manifest['frameworkSha256'], 'SDK changed after acceptance started'
    embedded = args.app / 'Contents/Frameworks/Chromium Embedded Framework.framework'
    helper = args.app / 'Contents/MacOS/PaneCore'
    source_helper = args.core_app / 'Contents/MacOS/PaneCore'
    source_uuid, embedded_uuid = uuid(source), uuid(embedded / 'Chromium Embedded Framework')
    assert source_uuid == embedded_uuid, 'Signed app has a different CEF framework'
    helper_uuid, source_helper_uuid = uuid(helper), uuid(source_helper)
    assert helper_uuid == source_helper_uuid, 'Signed app has a different YabCore helper'
    signatures = {name: signing(path) for name, path in
                  [('app', args.app), ('framework', embedded), ('helper', helper)]}
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(args.app)], check=True)
    args.out.write_text(json.dumps({
        'sdk': str(args.sdk), 'app': str(args.app), 'coreApp': str(args.core_app),
        'sdkFrameworkSha256': digest.hexdigest(), 'frameworkUuid': source_uuid,
        'helperUuid': helper_uuid, 'signingTeam': '25UG4QYN9F',
        'signatures': signatures,
        'scope': 'matching SDK/hash and Mach-O UUIDs after signing; runtime proof is separate',
    }, indent=2) + '\n')
    print('PASS source SDK, embedded framework, helper and signing provenance')


if __name__ == '__main__':
    main()
