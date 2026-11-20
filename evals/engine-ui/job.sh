#!/bin/bash
# Farm only. Settings › Engine (round 2): build the real signed app with CEF,
# run the engine rule tests, then pictures of the page, ⌘K's rows, the site
# menu and the hover card in light and dark. No account, no release.
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p "$YAB_FARM_OUT/core"
CORE_APP="$(YAB_FARM_OUT="$YAB_FARM_OUT/core" bash YabCore/build.sh)"
YAB_CEF=1 YAB_UNIVERSAL=0 YAB_CEF_HELPER="$CORE_APP/Contents/MacOS/PaneCore" ./build.sh
ARTIFACT="$YAB_FARM_OUT/$YAB_TASK_NAME.app"
ditto 'build/yab Dev.app' "$ARTIFACT"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$ARTIFACT/Contents/Info.plist")" = "$YAB_TASK_NAME"
codesign --verify --deep --strict "$ARTIFACT"
export DRM_TEST_FILTER='EngineRulesTests|SiteEngineTests|TabEngineTests'
TEST_STATUS=0
bash evals/chromium-drm/tests.sh || TEST_STATUS=$?
printf '%s\n' "$TEST_STATUS" > "$YAB_FARM_OUT/tests-exit.txt"
if ! python3 -c 'from PIL import Image' >/dev/null 2>&1; then
  python3 -m pip install --disable-pip-version-check --target "$YAB_FARM_OUT/python" Pillow
  export PYTHONPATH="$YAB_FARM_OUT/python${PYTHONPATH:+:$PYTHONPATH}"
fi
if ! python3 -c 'import ScreenCaptureKit' >/dev/null 2>&1; then
  BRIDGE_VERSION="$(python3 -c 'import objc; print(objc.__version__)')"
  python3 -m pip install --disable-pip-version-check --no-deps --target "$YAB_FARM_OUT/python" "pyobjc-framework-ScreenCaptureKit==$BRIDGE_VERSION"
  export PYTHONPATH="$YAB_FARM_OUT/python${PYTHONPATH:+:$PYTHONPATH}"
fi
PROBE_STATUS=0
python3 -u evals/engine-ui/shots.py --app "$ARTIFACT" --out "$YAB_FARM_OUT/shots" || PROBE_STATUS=$?
if (( TEST_STATUS != 0 )); then exit "$TEST_STATUS"; fi
exit "$PROBE_STATUS"
