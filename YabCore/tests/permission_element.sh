#!/bin/bash
# A permission element clicked and every question answered yes, against the
# pinned release SDK (permission_element.py). YAB_PERM_EXPECT=crash for the
# YabCore of 2b26972ae (reports 623-1550; farm 490082aa on m2), clean since.
set -uo pipefail
cd "$(dirname "$0")/../.."
: "${YAB_FARM_OUT:?}"
export YAB_CEF_DIR="${YAB_CEF_DIR:-$(python3 -c 'import json,os; d=json.load(open("scripts/cef/release-sdk.json")); print(os.path.expanduser("~/.local/state/yab-spike-cef/owncef-sdk/")+d["sdkKey"]+"/"+d["distribution"])')}"
rsync -a --exclude .rsync-partial "$YAB_CEF_DIR/" "$YAB_FARM_OUT/sdk/" || exit 1
export YAB_CEF_DIR="$YAB_FARM_OUT/sdk"
export YABCORE_BUILD_DIR="$YAB_FARM_OUT/core-build"
export YAB_CEF_API_VERSION=999999
bash YabCore/build.sh 2>&1 | tee "$YAB_FARM_OUT/core-build.log" | tail -5 || exit 1
APP="$(cat "$YAB_FARM_OUT/app-path.txt" 2>/dev/null || tail -1 "$YAB_FARM_OUT/core-build.log")"
HELPER="$APP/Contents/MacOS/PaneCore"
test -x "$HELPER" || { echo "no helper at $HELPER" >&2; exit 1; }
status=0
for element in geolocation usermedia; do
  python3 -u YabCore/tests/permission_element.py "$HELPER" --element "$element" --expect "${YAB_PERM_EXPECT:-crash}" || status=1
done
exit $status
