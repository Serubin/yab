#!/bin/bash
# One display job: main at BASE, then this tree, with visible build logs.
set -euo pipefail
cd "$(dirname "$0")/../.."
base=${1:?base main commit}
out=${YAB_FARM_OUT:?run through farm}
mkdir -p "$out/apps"
app="$out/apps/${YAB_TASK_NAME:?}.app"
shasum -a 256 Sources/Fast/Reader.swift Sources/Fast/Tab.swift Tests/FastTests/ReaderTests.swift evals/golden/reading_mode.py evals/reading-mode/x-article.html > "$out/frozen-inputs.sha256"
python3 -u evals/reading-mode/unit.py 2>&1 | tee "$out/reader-unit.log"
./build.sh 2>&1 | tee "$out/build-after.log"
ditto 'build/Pane Dev.app' "$app"
python3 - "$app/Contents/Info.plist" "$YAB_TASK_NAME" <<'PY'
import plistlib, sys
info = plistlib.load(open(sys.argv[1], 'rb'))
assert info['CFBundleName'] == info['CFBundleDisplayName'] == sys.argv[2]
print('Delivered app:', info['CFBundleDisplayName'], flush=True)
PY
codesign --verify --deep --strict "$app"
bash scripts/runs/rev_app.sh "$base" "$out/apps/base.app" 2>&1 | tee "$out/build-before.log"
python3 -u evals/golden/reading_mode.py --app "$out/apps/base.app" --label before
python3 -u evals/golden/reading_mode.py --app "$app" --label after
python3 - "$out/reading-mode" <<'PY_CHECK'
import json, sys
from pathlib import Path
out = Path(sys.argv[1])
before = json.loads((out / 'before/result.json').read_text())
after = json.loads((out / 'after/result.json').read_text())
for name in ('enter waits for the X Article DOM', 'availability follows delayed article mount', 'alternate article route opens'):
    assert next(c for c in before['checks'] if c['name'] == name)['ok'] is False, name
    assert next(c for c in after['checks'] if c['name'] == name)['ok'] is True, name
assert all(c['ok'] for c in after['checks'])
print('Before/after confirmed: X Article entry and availability fail on main, pass here.')
PY_CHECK
