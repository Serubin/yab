#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
: "${YAB_FARM_OUT:?}"
clang++ -std=c++20 YabCore/tests/devtools_commands_test.cc -o "$YAB_FARM_OUT/devtools-commands-test"
"$YAB_FARM_OUT/devtools-commands-test"
export YAB_CEF_DIR="$(python3 -c 'import json,os; d=json.load(open("scripts/cef/release-sdk.json")); print(os.path.expanduser("~/.local/state/yab-spike-cef/owncef-sdk/")+d["sdkKey"]+"/"+d["distribution"])')"
# A new worker's transferred SDK may contain rsync's staging directory;
# codesign rejects that extra framework content. Keep proof inputs isolated.
rsync -a --exclude .rsync-partial "$YAB_CEF_DIR/" "$YAB_FARM_OUT/sdk/"
export YAB_CEF_DIR="$YAB_FARM_OUT/sdk"
export YABCORE_BUILD_DIR="$YAB_FARM_OUT/core-build"
export YAB_CEF_API_VERSION=999999
bash YabCore/build.sh > "$YAB_FARM_OUT/core-app.txt"
python3 YabCore/tests/devtools_accelerator.py "$(cat "$YAB_FARM_OUT/core-app.txt")/Contents/MacOS/PaneCore"
