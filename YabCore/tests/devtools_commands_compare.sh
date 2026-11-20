#!/bin/bash
# Reopen this investigation's exact compiled before/after artifacts.
set -euo pipefail
cd "$(dirname "$0")/../.."
: "${YAB_FARM_OUT:?}"
for variant in before after; do
  if [ "$variant" = before ]; then
    JOB=fb3e295b29d14733; COPY=cef-zip-baseline
  else
    JOB=60109d5317674c65; COPY=cef-zip-app
  fi
  APP="/Users/m1/.local/state/yab-farm/work/fast-apps/farm-$JOB/out/DevTools crash guard.app"
  if [ ! -x "$APP/Contents/MacOS/PaneCore" ]; then
    APP="$YAB_FARM_OUT/$variant.app"
    mkdir -p "$APP"
    rsync -a -e 'ssh -o BatchMode=yes -o ConnectTimeout=20' "m4:/tmp/$COPY/" "$APP/"
  fi
  mkdir -p "$YAB_FARM_OUT/$variant"
  shasum -a 256 "$APP/Contents/MacOS/PaneCore" > "$YAB_FARM_OUT/$variant/helper-sha256.txt"
  if [ "$variant" = before ]; then
    YAB_FARM_OUT="$YAB_FARM_OUT/$variant" python3 YabCore/tests/devtools_accelerator.py "$APP/Contents/MacOS/PaneCore" --expect-crash
  else
    YAB_FARM_OUT="$YAB_FARM_OUT/$variant" python3 YabCore/tests/devtools_accelerator.py "$APP/Contents/MacOS/PaneCore"
  fi
done
