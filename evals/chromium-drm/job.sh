#!/bin/bash
# Farm only. CEF integration and a clear-media stand-in, no account or release.
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p "$YAB_FARM_OUT/core"
CORE_APP="$(YAB_FARM_OUT="$YAB_FARM_OUT/core" bash YabCore/build.sh)"
YAB_CEF=1 YAB_UNIVERSAL=0 YAB_CEF_HELPER="$CORE_APP/Contents/MacOS/PaneCore" ./build.sh
ARTIFACT="$YAB_FARM_OUT/$YAB_TASK_NAME.app"
ditto 'build/yab Dev.app' "$ARTIFACT"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$ARTIFACT/Contents/Info.plist")" = "$YAB_TASK_NAME"
codesign --verify --deep --strict "$ARTIFACT"
export DRM_TEST_FILTER="$(python3 scripts/runs/tests_for.py Sources/Fast/SiteEngine.swift Sources/Fast/PageOwnership.swift Sources/Fast/ChromiumDRM.swift Sources/Fast/ChromiumDRMCookies.swift Sources/Fast/ChromiumDRMExtensions.swift Sources/Fast/ChromiumDRMExtensionScripts.swift Sources/Fast/ChromiumDRMExtensionRules.swift Sources/Fast/ChromiumDRMNavigation.swift Sources/Fast/ChromiumProcess.swift Sources/Fast/WebKitBrowser.swift Sources/Fast/ChromiumDRMBench.swift Sources/Fast/ChromiumPage.swift Sources/Fast/Tab.swift Sources/Fast/Bench.swift Tests/FastTests/SiteEngineTests.swift Tests/FastTests/TabEngineTests.swift Tests/FastTests/ChromiumDRMTests.swift Tests/FastTests/ChromiumDRMExtensionTests.swift Tests/FastTests/ChromiumDRMNavigationTests.swift Tests/FastTests/ChromiumPageTests.swift)"
printf '%s\n' "$DRM_TEST_FILTER" > "$YAB_FARM_OUT/selected-tests.txt"
# Preserve the exact assembled app and continue independent runtime acceptance
# after a unit-harness failure. The final job still returns the test failure.
TEST_STATUS=0
bash evals/chromium-drm/tests.sh || TEST_STATUS=$?
printf '%s\n' "$TEST_STATUS" > "$YAB_FARM_OUT/native-tests-exit.txt"
BRIDGE_STATUS=0
python3 -u evals/chromium-drm/native-probe.py --app "$ARTIFACT" --out "$YAB_FARM_OUT/native-bridge" || BRIDGE_STATUS=$?
printf '%s\n' "$BRIDGE_STATUS" > "$YAB_FARM_OUT/native-bridge-exit.txt"
if ! python3 -c 'from PIL import Image' >/dev/null 2>&1; then
  python3 -m pip install --disable-pip-version-check --target "$YAB_FARM_OUT/python" Pillow
  export PYTHONPATH="$YAB_FARM_OUT/python${PYTHONPATH:+:$PYTHONPATH}"
fi
python3 -u evals/chromium-drm/run.py --app "$ARTIFACT" --out "$YAB_FARM_OUT/acceptance"
if (( TEST_STATUS != 0 )); then exit "$TEST_STATUS"; fi
exit "$BRIDGE_STATUS"
