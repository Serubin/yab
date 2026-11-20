#!/bin/bash
# Page pictures whose renderer goes mid-copy, against the pinned release SDK
# (snapshot_renderer_gone.py). Crashes on an SDK without cef-patches/0106
# (reports 1084-1552); clean with it. YAB_CEF_DIR picks another SDK.
set -uo pipefail
cd "$(dirname "$0")/../.."
: "${YAB_FARM_OUT:?}"
source YabCore/tests/release_core_app.sh || exit 1
python3 -u YabCore/tests/snapshot_renderer_gone.py "$APP/Contents/MacOS/PaneCore" --rounds "${YAB_SNAPSHOT_ROUNDS:-60}"
