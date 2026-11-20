#!/bin/bash
# Minimize and restore every window from an extension against the pinned
# release SDK (hosted_window_restore.py). YAB_RESTORE_EXPECT=crash for the
# baseline meant to reproduce reports 990-1155 (macOS 27.2).
set -uo pipefail
cd "$(dirname "$0")/../.."
: "${YAB_FARM_OUT:?}"
sw_vers
export YAB_CEF_DIR="${YAB_CEF_DIR:-$(python3 -c 'import json,os; d=json.load(open("scripts/cef/release-sdk.json")); print(os.path.expanduser("~/.local/state/yab-spike-cef/owncef-sdk/")+d["sdkKey"]+"/"+d["distribution"])')}"
rsync -a --exclude .rsync-partial "$YAB_CEF_DIR/" "$YAB_FARM_OUT/sdk/" || exit 1
export YAB_CEF_DIR="$YAB_FARM_OUT/sdk"
export YABCORE_BUILD_DIR="$YAB_FARM_OUT/core-build"
export YAB_CEF_API_VERSION=999999
bash YabCore/build.sh 2>&1 | tee "$YAB_FARM_OUT/core-build.log" | tail -5 || exit 1
APP="$(cat "$YAB_FARM_OUT/app-path.txt" 2>/dev/null || tail -1 "$YAB_FARM_OUT/core-build.log")"
HELPER="$APP/Contents/MacOS/PaneCore"
test -x "$HELPER" || { echo "no helper at $HELPER" >&2; exit 1; }
if [ "${YAB_RESTORE_EXPECT:-clean}" = crash ]; then
  python3 -u YabCore/tests/hosted_window_restore.py "$HELPER" --expect-crash
else
  python3 -u YabCore/tests/hosted_window_restore.py "$HELPER"
fi
