#!/bin/bash
# Farm only. Reuse an exact signed Opens in app for harness-only proof.
set -euo pipefail
cd "$(dirname "$0")/../.."
python3 - "$1" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys

assert os.environ.get('YAB_FARM_WORKER') == '1', 'Use the shared farm'
out = Path(os.environ['YAB_FARM_OUT'])
source = json.loads(subprocess.check_output(['./farm', 'where', sys.argv[1]], text=True, timeout=90))
def find_app(base):
    return next((path for path in (base / (source['name'] + '.app'), base / 'source' / (source['name'] + '.app'))
                 if path.is_dir()), None)

app = find_app(Path(source['evidence']) / 'out')
if app is None:
    fetched = subprocess.check_output(['./farm', 'fetch', sys.argv[1], str(out / 'source')], text=True, timeout=600)
    app = find_app(Path(fetched.strip().splitlines()[-1]))
if app is None:
    raise RuntimeError('Source job has no retained signed app')
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
assert info['CFBundleName'] == info['CFBundleDisplayName'] == os.environ['YAB_TASK_NAME']
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True, timeout=60)
source['app'] = str(app)
source['sha256'] = {name: hashlib.sha256((app / 'Contents/MacOS' / name).read_bytes()).hexdigest()
                    for name in (info['CFBundleExecutable'], 'PaneCore')}
(out / 'app-source.json').write_text(json.dumps(source, indent=2))
env = dict(os.environ)
if subprocess.run(['python3', '-c', 'from PIL import Image'], capture_output=True, timeout=20).returncode:
    subprocess.run(['python3', '-m', 'pip', 'install', '--disable-pip-version-check', '--target', str(out / 'python'), 'Pillow'],
                   check=True, timeout=120)
    env['PYTHONPATH'] = str(out / 'python') + (os.pathsep + env['PYTHONPATH'] if env.get('PYTHONPATH') else '')
if subprocess.run(['python3', '-c', 'import ScreenCaptureKit'], env=env, capture_output=True, timeout=20).returncode:
    version = subprocess.check_output(['python3', '-c', 'import objc; print(objc.__version__)'], text=True, timeout=20).strip()
    subprocess.run(['python3', '-m', 'pip', 'install', '--disable-pip-version-check', '--no-deps', '--target', str(out / 'python'),
                    'pyobjc-framework-ScreenCaptureKit==' + version], check=True, timeout=120)
    env['PYTHONPATH'] = str(out / 'python') + (os.pathsep + env['PYTHONPATH'] if env.get('PYTHONPATH') else '')
subprocess.run(['python3', '-u', 'evals/chromium-drm/opens_in.py', '--app', str(app), '--out', str(out / 'opens-in')],
               env=env, check=True, timeout=600)
PY
