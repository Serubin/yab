#!/bin/bash
# Farm only. Opens in (mockup B): build the real signed app with CEF, run the
# focused native tests, then every state of the panel and menu in light and
# dark with ScreenCaptureKit pictures. No account, no release.
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p "$YAB_FARM_OUT/core"
CORE_APP="$(YAB_FARM_OUT="$YAB_FARM_OUT/core" bash YabCore/build.sh)"
YAB_CEF=1 YAB_UNIVERSAL=0 YAB_CEF_HELPER="$CORE_APP/Contents/MacOS/PaneCore" ./build.sh
ARTIFACT="$YAB_FARM_OUT/$YAB_TASK_NAME.app"
ditto 'build/yab Dev.app' "$ARTIFACT"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$ARTIFACT/Contents/Info.plist")" = "$YAB_TASK_NAME"
codesign --verify --deep --strict "$ARTIFACT"
export DRM_TEST_FILTER='TabEngineTests|SiteEngineTests|ChromiumDRMTests|ChromiumDRMNavigationTests'
TEST_STATUS=0
bash evals/chromium-drm/tests.sh || TEST_STATUS=$?
printf '%s\n' "$TEST_STATUS" > "$YAB_FARM_OUT/native-tests-exit.txt"
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
python3 -u evals/chromium-drm/opens_in.py --app "$ARTIFACT" --out "$YAB_FARM_OUT/opens-in" || PROBE_STATUS=$?
if (( TEST_STATUS != 0 )); then exit "$TEST_STATUS"; fi
exit "$PROBE_STATUS"
