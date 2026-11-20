#!/bin/bash
# A renderer started after Update.Swap set the running bundle aside
# (bundle_moved.py): the 0.46.26 helper (2b26972ae), then this tree's.
set -uo pipefail
cd "$(dirname "$0")/../.."
: "${YAB_FARM_OUT:?}"
BASE=2b26972ae
SDK="$(python3 -c 'import json,os; d=json.load(open("scripts/cef/release-sdk.json")); print(os.path.expanduser("~/.local/state/yab-spike-cef/owncef-sdk/")+os.environ.get("YAB_MOVED_SDK", d["sdkKey"])+"/"+d["distribution"])')"
rsync -a --exclude .rsync-partial "$SDK/" "$YAB_FARM_OUT/sdk/" || exit 1
export YAB_CEF_DIR="$YAB_FARM_OUT/sdk" YAB_CEF_API_VERSION=999999
helper() { # tree variant -> helper path
  ( cd "$1" && YAB_FARM_OUT="$YAB_FARM_OUT/$2" YABCORE_BUILD_DIR="$YAB_FARM_OUT/build-$2" bash YabCore/build.sh ) \
    > "$YAB_FARM_OUT/$2-build.log" 2>&1 || { tail -20 "$YAB_FARM_OUT/$2-build.log" >&2; return 1; }
  echo "$(cat "$YAB_FARM_OUT/$2/app-path.txt" 2>/dev/null || tail -1 "$YAB_FARM_OUT/$2-build.log")/Contents/MacOS/PaneCore"
}
mkdir -p "$YAB_FARM_OUT/base-tree" "$YAB_FARM_OUT/before" "$YAB_FARM_OUT/after"
git archive "$BASE" YabCore scripts/cef | tar -x -C "$YAB_FARM_OUT/base-tree"
status=0
if [ "${YAB_MOVED_ONLY:-}" != after ]; then
  BEFORE="$(helper "$YAB_FARM_OUT/base-tree" before)" || exit 1
  python3 -u YabCore/tests/bundle_moved.py "$BEFORE" --expect-failure || status=1
fi
AFTER="$(helper "$PWD" after)" || exit 1
python3 -u YabCore/tests/bundle_moved.py "$AFTER" || status=1
exit $status
