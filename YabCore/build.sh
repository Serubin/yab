#!/bin/bash
# Run through ./farm. Only the CEF wrapper and YabCore are compiled.
set -euo pipefail
cd "$(dirname "$0")/.."
WORK="${YABCORE_BUILD_DIR:-$HOME/.local/state/yab-spike-cef/yabcore-v2}"
if [ -n "${YAB_CEF_API_VERSION:-}" ]; then
  [[ "$YAB_CEF_API_VERSION" =~ ^([0-9]{5}|999999)$ ]] || { echo 'YAB_CEF_API_VERSION must be a five-digit stable API or 999999' >&2; exit 2; }
  # Keep stable/experimental wrapper object caches separate.
  WORK="$WORK/api-$YAB_CEF_API_VERSION"
fi
mkdir -p "$WORK"
# Share the farm's compiler lock and give back a display place while compiling.
# The cache lock also protects CMake and task-name/signature updates from two jobs.
if [ "${YABCORE_BUILD_LOCK_HELD:-}" != 1 ]; then
  exec lockf -k -s "${YAB_BUILD_LOCK:-/tmp/yab-build.lock}" lockf -k "$WORK/build.lock" \
    env YABCORE_BUILD_LOCK_HELD=1 bash "$0" "$@"
fi
CEF_ROOT="${YAB_CEF_DIR:-$(bash scripts/cef/fetch.sh)}"
CMAKE="$(command -v cmake || true)"
if [ -z "$CMAKE" ]; then
  CMAKE="$WORK/tools/cmake/data/bin/cmake"
  if [ ! -x "$CMAKE" ]; then
    python3 -m pip install --disable-pip-version-check --target "$WORK/tools" cmake >&2
  fi
fi
# CMake records absolute source paths. Farm snapshots can occupy different
# lanes, so keep only our native sources at a stable, mutex-protected path.
mkdir -p "$WORK/source/src"
# Trees of every age take turns in this folder, so a file keeps no time of its
# own tree: a changed file is written now and an unchanged one is left alone.
# With the tree's times kept (rsync -a, cp -p), make took a source older than
# the object another tree had built and linked that object: adhd 11-06, job
# 2bfe4d97, transport.mm.o without Transport::Metrics.
cmp -s YabCore/CMakeLists.txt "$WORK/source/CMakeLists.txt" || cp YabCore/CMakeLists.txt "$WORK/source/CMakeLists.txt"
rsync -rl --checksum --delete YabCore/src/ "$WORK/source/src/"
# A build folder from before can hold such an object already: its sources
# are stamped now once, so each of its objects is compiled again one time.
if [ ! -f "$WORK/source/.times-written" ]; then
  find "$WORK/source" -type f -exec touch {} +
  touch "$WORK/source/.times-written"
fi
YABCORE_CMAKE_ARGS=(-S "$WORK/source" -B "$WORK/build" -G 'Unix Makefiles' -DCMAKE_BUILD_TYPE=Release
  -DPROJECT_ARCH=arm64 -DUSE_SANDBOX=ON -DCEF_ROOT="$CEF_ROOT")
if [ -n "${YAB_CEF_API_VERSION:-}" ]; then
  if [ "$YAB_CEF_API_VERSION" = 999999 ]; then
    # The pinned SDK selects experimental API by default. Its api_version
    # CMake option accepts only five-digit stable versions.
    YABCORE_CMAKE_ARGS+=(-U api_version)
  else
    YABCORE_CMAKE_ARGS+=("-Dapi_version=$YAB_CEF_API_VERSION")
  fi
fi
# These are build-only inputs; production helper never reads plan/environment.
POLICY_BINDING="$WORK/parent-policy-build-input.json"
python3 - "$POLICY_BINDING" <<'PYPOLICYBEFORE'
import importlib.util,json,os,sys
from pathlib import Path
path=Path('YabCore/cef-patches/candidate_parent_policy.py')
spec=importlib.util.spec_from_file_location('build_parent_policy',path);module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
value=module.build_inputs(os.environ.get('YABCORE_PARENT_POLICY_PLAN'),os.environ.get('YABCORE_PARENT_POLICY_HEADER'))
Path(sys.argv[1]).write_text(json.dumps(value,sort_keys=True)+'\n')
PYPOLICYBEFORE
if [ -n "${YABCORE_PARENT_POLICY_HEADER:-}" ]; then
  YABCORE_CMAKE_ARGS+=("-DYABCORE_PARENT_POLICY_HEADER=$YABCORE_PARENT_POLICY_HEADER")
else
  YABCORE_CMAKE_ARGS+=(-U YABCORE_PARENT_POLICY_HEADER)
fi
"$CMAKE" "${YABCORE_CMAKE_ARGS[@]}" >&2
"$CMAKE" --build "$WORK/build" --target YabCore -j 4 >&2
python3 - "$POLICY_BINDING" <<'PYPOLICYAFTER'
import importlib.util,json,os,sys
from pathlib import Path
path=Path('YabCore/cef-patches/candidate_parent_policy.py')
spec=importlib.util.spec_from_file_location('build_parent_policy',path);module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
assert json.loads(Path(sys.argv[1]).read_text())==module.build_inputs(os.environ.get('YABCORE_PARENT_POLICY_PLAN'),os.environ.get('YABCORE_PARENT_POLICY_HEADER')), 'Precompile input changed during actual helper compilation'
PYPOLICYAFTER
APP="$WORK/build/Release/PaneCore.app"
# Remove only the three known dangling links produced by the old CEF sample
# macro. Never delete a directory or any valid framework resource.
python3 - "$APP" <<'PYLINKS'
from pathlib import Path
import os, sys
root = Path(sys.argv[1]) / 'Contents/Frameworks/Chromium Embedded Framework.framework/Versions/A'
for relative, expected in [('Resources/Resources', 'Versions/A/Resources'), ('Libraries/Libraries', 'Versions/A/Libraries'), ('A', 'A')]:
    link = root / relative
    if link.is_symlink() and os.readlink(link) == expected:
        link.unlink()
PYLINKS
LABEL="${YAB_TASK_NAME:-Page core}"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $LABEL" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $LABEL" "$APP/Contents/Info.plist" 2>/dev/null || /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $LABEL" "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP" >&2
ACTUAL="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$APP/Contents/Info.plist")"
test "$ACTUAL" = "$LABEL"
# The visible artifact and bundle metadata share the task name; executable and
# bundle identifiers stay stable. ditto replaces only this job's fresh output.
DEST="${YAB_FARM_OUT:-$WORK}/$LABEL.app"
ditto "$APP" "$DEST"
if [ "${YAB_FARM_OUT:-$WORK}" != "$WORK" ]; then
  cp -p "$POLICY_BINDING" "${YAB_FARM_OUT:-$WORK}/parent-policy-build-input.json"
fi
printf '%s\n' "$DEST" > "${YAB_FARM_OUT:-$WORK}/app-path.txt"
printf '%s\n' "$DEST"
