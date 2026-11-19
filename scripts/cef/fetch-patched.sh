#!/bin/bash
# Download the patched CEF SDK pinned in scripts/cef/patched-sdk.json and print its folder.
set -euo pipefail
cd "$(dirname "$0")/../.."
MANIFEST=scripts/cef/patched-sdk.json
[ -f "$MANIFEST" ] || { echo "CEF: no $MANIFEST; build one with scripts/cef/build-patched.sh" >&2; exit 1; }
python3 -I scripts/cef/patched_receipt.py --check "$MANIFEST" >&2
exec /usr/bin/python3 -I - "$MANIFEST" <<'PY'
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request

manifest = json.loads(Path(sys.argv[1]).read_text())
name, sha, url = manifest['archive'], manifest['sha256'], manifest['url']
if Path(name).name != name or not name.endswith('_macosarm64_minimal.tar.bz2'):
    sys.exit('CEF: unexpected archive name')
if urllib.parse.urlsplit(url).scheme != 'https' or not url.endswith('/' + name):
    sys.exit('CEF: archive URL must be https and end in the archive name')
root = Path(os.environ.get('YAB_CEF_CACHE', str(Path.home() / '.local/state/yab-spike-cef'))) / 'patched'
root.mkdir(parents=True, exist_ok=True)
archive, folder = root / name, root / name[:-len('_macosarm64_minimal.tar.bz2')]


def checksum(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


with (root / '.lock').open('a') as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    with tempfile.TemporaryDirectory(prefix='cefpatched-', dir=root) as tmp:
        if not archive.is_file():
            downloaded = Path(tmp) / name
            print('CEF: downloading ' + url, file=sys.stderr)
            with urllib.request.urlopen(url, timeout=300) as response, downloaded.open('wb') as out:
                shutil.copyfileobj(response, out)
            if checksum(downloaded) != sha:
                sys.exit('CEF: patched archive SHA-256 mismatch')
            downloaded.replace(archive)
        if checksum(archive) != sha:
            sys.exit('CEF: cached patched archive SHA-256 mismatch; remove it and retry')
        print('CEF: SHA-256 verified ' + sha, file=sys.stderr)
        stamp, expected = folder / '.verified', sha + '  ' + name + '\n'
        if not stamp.is_file() or stamp.read_text() != expected:
            if folder.exists():
                sys.exit('CEF: unverified extraction already exists: ' + str(folder))
            subprocess.run(['tar', '-xjf', str(archive), '-C', tmp], check=True)
            extracted = Path(tmp) / folder.name
            receipt = json.loads((extracted / 'yab-owncef.json').read_text())
            if receipt.get('patches') != manifest['patches'] or receipt.get('frameworkSha256') != manifest['frameworkSha256']:
                sys.exit('CEF: archive receipt disagrees with the manifest')
            (extracted / '.verified').write_text(expected)
            extracted.replace(folder)
    # The extraction can come back from a CI cache, so its stamp alone isn't proof.
    framework = folder / 'Release/Chromium Embedded Framework.framework/Chromium Embedded Framework'
    if checksum(framework) != manifest['frameworkSha256']:
        sys.exit('CEF: extracted framework SHA-256 mismatch; remove ' + str(folder) + ' and retry')
print(folder)
PY
