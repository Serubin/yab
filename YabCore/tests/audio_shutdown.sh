#!/bin/bash
# Quit with a page playing, audio service in process and out, against the
# pinned release SDK (audio_shutdown.py). Both are expected to exit cleanly;
# YAB_AUDIO_EXPECT=crash for a variant meant to reproduce reports 1230-1418.
set -uo pipefail
cd "$(dirname "$0")/../.."
: "${YAB_FARM_OUT:?}"
export YAB_CEF_DIR="$(python3 -c 'import json,os; d=json.load(open("scripts/cef/release-sdk.json")); print(os.path.expanduser("~/.local/state/yab-spike-cef/owncef-sdk/")+d["sdkKey"]+"/"+d["distribution"])')"
rsync -a --exclude .rsync-partial "$YAB_CEF_DIR/" "$YAB_FARM_OUT/sdk/" || exit 1
export YAB_CEF_DIR="$YAB_FARM_OUT/sdk"
export YABCORE_BUILD_DIR="$YAB_FARM_OUT/core-build"
export YAB_CEF_API_VERSION=999999
bash YabCore/build.sh 2>&1 | tee "$YAB_FARM_OUT/core-build.log" | tail -5 || exit 1
APP="$(cat "$YAB_FARM_OUT/app-path.txt" 2>/dev/null || tail -1 "$YAB_FARM_OUT/core-build.log")"
HELPER="$APP/Contents/MacOS/PaneCore"
test -x "$HELPER" || { echo "no helper at $HELPER" >&2; exit 1; }
status=0
python3 -u YabCore/tests/audio_shutdown.py "$HELPER" --expect "${YAB_AUDIO_EXPECT:-clean}" || status=1
python3 -u YabCore/tests/audio_shutdown.py "$HELPER" --out-of-process --expect clean || status=1
exit $status
