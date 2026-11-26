#!/bin/bash
set -euo pipefail
out=${YAB_FARM_OUT:?}
# Xcode 27's metadata exporter needs the same absolute source spelling in
# swiftconstvalues and sources.list. Keep this packaging-only workaround in
# a disposable runner rather than altering another task's build.sh.
python3 - "$out/build-names.sh" <<'PY'
from pathlib import Path
import shlex
import sys
root = Path.cwd().resolve()
source = (root / 'build.sh').read_text()
source = source.replace('cd "$(dirname "$0")"', 'cd ' + shlex.quote(str(root)), 1)
source = source.replace('  Sources/Fast/SystemIntents.swift "$INTENTS/bridge.swift" -o',
                        '  "$PWD/Sources/Fast/SystemIntents.swift" "$PWD/$INTENTS/bridge.swift" -o')
Path(sys.argv[1]).write_text(source)
PY
YAB_APP_CACHE=0 bash "$out/build-names.sh" 2>&1 | tee "$out/build.log"
app="build/Pane Dev.app"
ditto "$app" "$out/${YAB_TASK_NAME:?}.app"
app="$out/$YAB_TASK_NAME.app"
codesign --verify --deep --strict "$app"
ditto -c -k --keepParent "$app" "$out/candidate.zip"
swift test --scratch-path .build/dev-optimized -c debug -Xswiftc -O --filter 'SavedPageRankingTests|BookmarkSuggestionsTests|SearchSuggestionsTests|RecentTabSuggestionsTests|FieldSpaceURLTests|FieldPlacePriorityTests' 2>&1 | tee "$out/tests.log"
if [ "${1:-}" != --build-only ]; then
  python3 evals/golden/saved_page_names.py --app "$app" --out "$out/after" --keep-signature
fi
