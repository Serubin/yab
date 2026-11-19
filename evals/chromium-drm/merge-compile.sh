#!/bin/bash
# Farm only. Compile the merged helper/app unsigned, then the mapped tests.
set -euo pipefail
cd "$(dirname "$0")/../.."
export YAB_FARM_JOB="${YAB_FARM_JOB:-drm-merge-compile}"
mkdir -p "$YAB_FARM_OUT/core"
CORE_APP="$(YAB_FARM_OUT="$YAB_FARM_OUT/core" bash YabCore/build.sh)"
YAB_SIGN_IDENTITY=- YAB_CEF=1 YAB_UNIVERSAL=0 YAB_CEF_HELPER="$CORE_APP/Contents/MacOS/PaneCore" ./build.sh
export DRM_TEST_FILTER="$(python3 scripts/runs/tests_for.py Sources/Fast/ChromiumPage.swift Tests/FastTests/ChromiumPageTests.swift YabCore/Client/Sources/YabCoreClient/Client.swift YabCore/src/core.mm)"
printf '%s\n' "$DRM_TEST_FILTER" > "$YAB_FARM_OUT/selected-tests.txt"
bash evals/chromium-drm/tests.sh
