#!/bin/bash
# Compile untouched main sources for the same native F12 regression.
set -euo pipefail
cd "$(dirname "$0")/../.."
: "${YAB_FARM_OUT:?}" "${1:?base commit}"
ROOT="$PWD"
SDK="$(python3 -c 'import json,os; d=json.load(open("scripts/cef/release-sdk.json")); print(os.path.expanduser("~/.local/state/yab-spike-cef/owncef-sdk/")+d["sdkKey"]+"/"+d["distribution"])')"
rsync -a --exclude .rsync-partial "$SDK/" "$YAB_FARM_OUT/sdk/"
mkdir -p "$YAB_FARM_OUT/baseline-source"
git archive "$1" YabCore scripts/cef | tar -x -C "$YAB_FARM_OUT/baseline-source"
export YAB_CEF_DIR="$YAB_FARM_OUT/sdk"
export YABCORE_BUILD_DIR="$YAB_FARM_OUT/baseline-build"
export YAB_CEF_API_VERSION=999999
cd "$YAB_FARM_OUT/baseline-source"
bash YabCore/build.sh > "$YAB_FARM_OUT/core-app.txt"
cd "$ROOT"
python3 YabCore/tests/devtools_accelerator.py "$(cat "$YAB_FARM_OUT/core-app.txt")/Contents/MacOS/PaneCore" --expect-crash
