# Sourced by the crash probes from the worktree root: builds YabCore against
# the pinned release SDK (or YAB_CEF_DIR) into $YAB_FARM_OUT and sets APP.
: "${YAB_FARM_OUT:?}"
if [ -z "${YAB_CEF_DIR:-}" ]; then
  KEY="$(python3 -c 'import json; print(json.load(open("scripts/cef/release-sdk.json"))["sdkKey"])')"
  DIST="$(python3 -c 'import json; print(json.load(open("scripts/cef/release-sdk.json"))["distribution"])')"
  export YAB_CEF_DIR="$HOME/.local/state/yab-spike-cef/owncef-sdk/$KEY/$DIST"
  if [ ! -f "$YAB_CEF_DIR/yab-owncef.json" ]; then
    SOURCE="$(python3 -c 'import json; s=json.load(open("scripts/cef/release-sdk.json"))["source"]; print(s["host"]+":"+s["path"])')"
    mkdir -p "$YAB_CEF_DIR"
    bash YabCore/cef-patches/fetch-native-artifact.sh "$YAB_CEF_DIR/" "$SOURCE/" || return 1
  fi
fi
export YAB_CEF_API_VERSION=999999
export YABCORE_BUILD_DIR="${YABCORE_BUILD_DIR:-$HOME/.local/state/yab-spike-cef/crash-probe-core-$(basename "$(dirname "$YAB_CEF_DIR")")}"
bash YabCore/build.sh > "$YAB_FARM_OUT/core-build.log" 2>&1 || { tail -40 "$YAB_FARM_OUT/core-build.log"; return 1; }
APP="$(cat "$YAB_FARM_OUT/app-path.txt")"
test -x "$APP/Contents/MacOS/PaneCore" || { echo "no YabCore in $APP" >&2; return 1; }
echo "CEF $(dwarfdump --uuid "$APP/Contents/Frameworks/Chromium Embedded Framework.framework/Chromium Embedded Framework" | head -1)"
