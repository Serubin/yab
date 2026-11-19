#!/bin/bash
# Builds Yab the way CONTRIBUTING.md tells an outsider to, on a farm Mac,
# and times each step:
#   - a fresh copy of the tracked files, without the farm's own scripts
#     (mini, farm, adhd, runs, scripts/remote), as an outside clone may be
#   - a fresh HOME: no SwiftPM cache, no farm state, no signing keychain
#     in the search list, no ~/.config/yab
#   - YAB_* and farm variables cleared
#
#   ./farm exec --name "Contributor build" -- bash scripts/oss/clean-build-check.sh
#
# Writes steps.tsv (step, seconds, exit code) and one log per step to
# $YAB_FARM_OUT (or a new temporary folder), and prints the table and the
# test summary at the end, so `./farm log JOB` holds the result. Don't
# `./farm fetch` it: the clean checkout and its .build are in there too.
#
# YAB_OSS_STEPS picks steps (comma separated): build, lint, mailcore, test,
# cef. Default: all.
set -uo pipefail

SRC="$(cd "$(dirname "$0")/../.." && pwd -P)"
OUT="${YAB_FARM_OUT:-$(mktemp -d "${TMPDIR:-/tmp}/yab-oss-check.XXXXXX")}"
STAMP="$(date +%Y%m%d%H%M%S)"
WORK="$OUT/clean-$STAMP"
mkdir -p "$WORK/home" "$WORK/src"

# Tracked files only (what a clone has), minus the farm.
if git -C "$SRC" rev-parse --git-dir >/dev/null 2>&1; then
  git -C "$SRC" ls-files -z \
    | grep -zvE '^(mini|farm|adhd|runs|scripts/remote/)' \
    | (cd "$SRC" && rsync -a --from0 --files-from=- ./ "$WORK/src/")
else
  rsync -a --exclude .build --exclude build --exclude /mini --exclude /farm \
    --exclude /adhd --exclude /runs --exclude /scripts/remote "$SRC/" "$WORK/src/"
fi
# git is part of a clone: the linters diff against it.
git -C "$WORK/src" init -q
git -C "$WORK/src" add -A
git -C "$WORK/src" -c user.name=check -c user.email=check@localhost commit -qm clean

STEPS=",${YAB_OSS_STEPS:-build,lint,mailcore,test,cef},"
want() { case "$STEPS" in *",$1,"*) return 0 ;; *) return 1 ;; esac; }
for name in $(env | sed -n 's/^\(YAB_[A-Za-z0-9_]*\)=.*/\1/p'); do
  [ "$name" = YAB_FARM_OUT ] || unset "$name"
done
unset CLAUDE_CODE_SESSION_ID CODEX_THREAD_ID
export HOME="$WORK/home"
export YAB_SIGN_IDENTITY=-
cd "$WORK/src" || exit 1

{
  echo "host: $(scutil --get LocalHostName 2>/dev/null || hostname -s)"
  echo "macOS: $(sw_vers -productVersion)"
  xcodebuild -version | tr '\n' ' '; echo
  swift --version 2>&1 | head -1
  echo "cores: $(sysctl -n hw.perflevel0.physicalcpu 2>/dev/null) performance, $(sysctl -n hw.ncpu) total"
} > "$OUT/machine.txt"

printf 'step\tseconds\texit\n' > "$OUT/steps.tsv"
step() {
  local label="$1" start rc
  shift
  echo "== $label: $*"
  start=$(date +%s)
  "$@" > "$OUT/$label.log" 2>&1
  rc=$?
  printf '%s\t%s\t%s\n' "$label" "$(( $(date +%s) - start ))" "$rc" >> "$OUT/steps.tsv"
  tail -5 "$OUT/$label.log"
  return $rc
}

if want build; then
  step swift-build swift build
  step build-app ./build.sh
  step codesign codesign -dv "build/pane Dev.app"
fi
if want lint; then
  step parse-check scripts/swift-parse-check --base HEAD
  step design-check ./design-check --base HEAD
fi
want mailcore && step mailcore-tests swift test --filter MailCoreTests
# The whole suite as CI runs it; tests that need a test screen skip
# themselves (TestScreen.available).
want test && step swift-test swift test

if want cef; then
# Optional: Chromium tabs on the stock CEF distribution (the release uses a
# patched SDK). Fetch CEF, build YabCore, assemble the app with it.
step cef-fetch bash scripts/cef/fetch.sh
CEF_DIR="$(tail -1 "$OUT/cef-fetch.log")"
export YABCORE_BUILD_DIR="$WORK/yabcore"
step yabcore-build env YAB_CEF_DIR="$CEF_DIR" YAB_FARM_OUT="$WORK/yabcore-out" bash YabCore/build.sh
CORE_APP="$(tail -1 "$OUT/yabcore-build.log")"
step build-app-cef env YAB_CEF=1 YAB_UNIVERSAL=0 YAB_CEF_DIR="$CEF_DIR" \
  YAB_CEF_HELPER="$CORE_APP/Contents/MacOS/YabCore" ./build.sh
fi

if [ -f "$OUT/swift-test.log" ]; then
  echo "== swift test summary"
  echo "passed: $(grep -c '✔ Test' "$OUT/swift-test.log"), failed: $(grep -c '✘ Test' "$OUT/swift-test.log"), skipped: $(grep -c ' skipped' "$OUT/swift-test.log")"
  grep -E '✘ (Test|Suite)|Test run with|error:' "$OUT/swift-test.log" | tail -60
fi
for log in cef-fetch yabcore-build build-app-cef; do
  [ -f "$OUT/$log.log" ] && { echo "== $log (tail)"; tail -15 "$OUT/$log.log"; }
done
echo
cat "$OUT/machine.txt"
column -t "$OUT/steps.tsv"
echo "out: $OUT"
