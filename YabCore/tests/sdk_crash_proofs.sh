#!/bin/bash
# The crash fixes of CEF 0103 to 0110, each probe on two SDKs: the one 0.46.27
# ships (official-35b0c5db4b75, OLD_SDK), where it must crash, and the pinned
# one, where it must not. YabCore of this tree on both; the permission probe
# also with 2b26972ae's YabCore, which has no YabCore-side guard, so that
# 0103 alone is what keeps it up. Farm only, a display Mac, not main:
#   ./farm exec --display --name "..." -- bash YabCore/tests/sdk_crash_proofs.sh [PROOF...]
# PROOF: permission (0103), restore (0105), moved (0106), menu (0107),
# snapshot (0108), drive (0110); none runs them all.
set -uo pipefail
cd "$(dirname "$0")/../.."
: "${YAB_FARM_OUT:?run through the farm}"
[[ "${YAB_FARM_HOST:-}" != main ]] || { echo 'not on main' >&2; exit 2; }
ROOT="$YAB_FARM_OUT"
OLD_SDK="${OLD_SDK:-official-35b0c5db4b75}"
read -r NEW_SDK DIST HOST SOURCE < <(python3 -c 'import json; d=json.load(open("scripts/cef/release-sdk.json")); s=d["source"]; print(d["sdkKey"], d["distribution"], s["host"], s["path"])')

sdk_dir() { # key -> SDK folder on this Mac, copied from the pin's host when missing
  local dir="$HOME/.local/state/yab-spike-cef/owncef-sdk/$1/$DIST"
  if [ ! -f "$dir/yab-owncef.json" ]; then
    mkdir -p "$dir"
    bash YabCore/cef-patches/fetch-native-artifact.sh "$dir/" "$HOST:${SOURCE/$NEW_SDK/$1}/" >&2 || return 1
  fi
  echo "$dir"
}
core() { # tree label sdk-key -> YabCore helper of that tree built on that SDK
  local tree="$1" label="$2" sdk
  sdk="$(sdk_dir "$3")" || return 1
  mkdir -p "$ROOT/core-$label"
  ( cd "$tree" && YAB_FARM_OUT="$ROOT/core-$label" YAB_CEF_DIR="$sdk" YAB_CEF_API_VERSION=999999 \
      YABCORE_BUILD_DIR="$HOME/.local/state/yab-spike-cef/crash-proof-core-$label-$3" bash YabCore/build.sh ) \
    > "$ROOT/core-$label.log" 2>&1 || { tail -30 "$ROOT/core-$label.log" >&2; return 1; }
  local app; app="$(cat "$ROOT/core-$label/app-path.txt")"
  dwarfdump --uuid "$app/Contents/Frameworks/Chromium Embedded Framework.framework/Chromium Embedded Framework" | head -1 >&2
  echo "$app/Contents/MacOS/PaneCore"
}

OLD="$(core "$PWD" old "$OLD_SDK")" || exit 1
NEW="$(core "$PWD" new "$NEW_SDK")" || exit 1
proofs=("$@")
[[ ${#proofs[@]} -gt 0 ]] || proofs=(permission restore moved menu snapshot drive)
results=()
# side expected command...: runs the probe in its own $YAB_FARM_OUT; "crash"
# wants it to fail (or to report the crash), "clean" to pass.
side() {
  local name="$1" want="$2"; shift 2
  local out="$ROOT/$name"; mkdir -p "$out"
  echo "== $name (wants $want)"
  YAB_FARM_OUT="$out" "$@" > "$out/run.log" 2>&1
  local code=$?
  tail -15 "$out/run.log"
  local got=clean; [ "$code" = 0 ] || got=crash
  results+=("$name: wanted $want, exit $code")
  [ "$got" = "$want" ]
}
status=0
for proof in "${proofs[@]}"; do
  case "$proof" in
    permission)
      base="$ROOT/base-tree"; mkdir -p "$base"
      git archive 2b26972ae YabCore scripts/cef | tar -x -C "$base"
      BASE_OLD="$(core "$base" base-old "$OLD_SDK")" && BASE_NEW="$(core "$base" base-new "$NEW_SDK")" || { status=1; continue; }
      for element in geolocation usermedia; do
        side "permission-$element-before" clean python3 -u YabCore/tests/permission_element.py "$BASE_OLD" --element "$element" --expect crash || status=1
        side "permission-$element-0103" clean python3 -u YabCore/tests/permission_element.py "$BASE_NEW" --element "$element" --expect clean || status=1
        side "permission-$element-this" clean python3 -u YabCore/tests/permission_element.py "$NEW" --element "$element" --expect clean || status=1
      done ;;
    restore)
      side restore-before clean python3 -u YabCore/tests/hosted_window_restore.py "$OLD" --expect-crash || status=1
      side restore-after clean python3 -u YabCore/tests/hosted_window_restore.py "$NEW" || status=1 ;;
    moved)
      # This tree's YabCore already starts children from yab.app.old ("aside"
      # passes); without 0106 the sandbox of a renderer started after the move
      # still reads the old path ("moved" fails).
      side moved-before crash python3 -u YabCore/tests/bundle_moved.py "$OLD" || status=1
      side moved-after clean python3 -u YabCore/tests/bundle_moved.py "$NEW" || status=1 ;;
    menu)
      lockf -k -s "${YAB_BUILD_LOCK:-/tmp/yab-build.lock}" clang++ -std=c++20 -fobjc-arc -framework Cocoa -framework QuartzCore \
        YabCore/tests/external_action_host.mm -o "$ROOT/external-action-host" || { status=1; continue; }
      side menu-before crash python3 -u YabCore/cef-patches/popup-context-menu-probe.py --app "${OLD%/Contents/MacOS/PaneCore}" --host "$ROOT/external-action-host" || status=1
      side menu-after clean python3 -u YabCore/cef-patches/popup-context-menu-probe.py --app "${NEW%/Contents/MacOS/PaneCore}" --host "$ROOT/external-action-host" || status=1 ;;
    snapshot)
      side snapshot-before crash python3 -u YabCore/tests/snapshot_renderer_gone.py "$OLD" --rounds 60 || status=1
      side snapshot-after clean python3 -u YabCore/tests/snapshot_renderer_gone.py "$NEW" --rounds 60 || status=1 ;;
    drive)
      side drive-before crash env YAB_PRESS_ANYWAY=1 python3 -u YabCore/tests/pdf_save_to_drive.py "$OLD" || status=1
      side drive-after clean env YAB_PRESS_ANYWAY=1 python3 -u YabCore/tests/pdf_save_to_drive.py "$NEW" || status=1 ;;
    *) echo "unknown proof $proof" >&2; status=2 ;;
  esac
done
printf '%s\n' "${results[@]}"
exit "$status"
