#!/usr/bin/env python3
"""Seal a patched minimal CEF distribution into a release archive and pin it.

usage: package_patched.py --distrib DIR --out DIR --src CHROMIUM_SRC --cef-version V
                          --gn-args FILE --release-repo OWNER/REPO --manifest PATH
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from patched_receipt import series  # noqa: E402

FRAMEWORK = 'Release/Chromium Embedded Framework.framework/Chromium Embedded Framework'


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['--distrib', '--out', '--src', '--gn-args', '--manifest']:
        parser.add_argument(name, type=Path, required=True)
    for name in ['--cef-version', '--release-repo']:
        parser.add_argument(name, required=True)
    args = parser.parse_args()

    folders = [p for p in args.distrib.iterdir() if p.name.endswith('_macosarm64_minimal')]
    if len(folders) != 1:
        sys.exit('package: expected one *_macosarm64_minimal folder in ' + str(args.distrib))
    folder = folders[0]
    if folder.name != f'cef_binary_{args.cef_version}_macosarm64_minimal':
        sys.exit(f'package: built {folder.name}, expected CEF {args.cef_version}')
    framework = folder / FRAMEWORK
    if not framework.is_file():
        sys.exit('package: framework missing; did cefclient build?')
    if 'CEF_YAB_EXTERNAL_ACTION_VERSION' not in (folder / 'include/cef_browser.h').read_text():
        sys.exit('package: include/cef_browser.h lacks the Yab API; patches missing')

    # Pin what was compiled, which can differ from the checkout if it moved during the build.
    applied = {e['name']: e['sha256'] for e in
               json.loads((args.src / '.yab-owncef-patches.json').read_text())['patches']}
    if applied != series():
        sys.exit('package: YabCore/cef-patches changed since the build applied it; rebuild')

    gn_args = args.gn_args.read_text().splitlines()
    framework_sha = sha256(framework)
    receipt = {'schema': 1, 'cefVersion': args.cef_version, 'gnArgs': gn_args,
               'frameworkSha256': framework_sha, 'patches': applied}
    (folder / 'yab-owncef.json').write_text(json.dumps(receipt, indent=2) + '\n')

    args.out.mkdir(parents=True, exist_ok=True)
    key = framework_sha[:12]
    archive = args.out / f'cef-yab-patched-{key}_macosarm64_minimal.tar.bz2'
    subprocess.run(['tar', '-cjf', str(archive), '--no-mac-metadata', '--no-xattrs',
                    '--uid', '0', '--gid', '0', '--uname', '', '--gname', '',
                    '-C', str(folder.parent),
                    '-s', f',^{folder.name},cef-yab-patched-{key},', folder.name],
                   check=True, env={**os.environ, 'COPYFILE_DISABLE': '1'})
    tag = 'cef-patched-' + key
    manifest = {'schema': 1, 'cefVersion': args.cef_version,
                'archive': archive.name, 'sha256': sha256(archive),
                'url': f'https://github.com/{args.release_repo}/releases/download/{tag}/{archive.name}',
                'frameworkSha256': framework_sha, 'patches': applied}
    args.manifest.write_text(json.dumps(manifest, indent=2) + '\n')
    print(f'package: {archive} ({archive.stat().st_size // 2**20} MB)')
    print(f'package: wrote {args.manifest}. Create the release first, then commit it:')
    print(f'  gh release create {tag} --repo {args.release_repo} --prerelease '
          f'--title "Patched CEF {key}" --notes "CEF {args.cef_version}, '
          f'{len(applied)} Yab patches, proprietary codecs off." "{archive}"')


if __name__ == '__main__':
    main()
