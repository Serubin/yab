#!/bin/bash
# Register 1015: the candidate build, focused tests, then the private window
# against the untouched main baseline, with winshots of both windows.
set -euo pipefail
cd "$(dirname "$0")/../.."
base=${1:?pass the main commit this worktree started from}
out=${YAB_FARM_OUT:?run through farm}
mkdir -p "$out"
./build.sh 2>&1 | tee "$out/candidate-build.log"
YAB_PROBE="private-spaces-tests-${YAB_FARM_JOB}" YAB_HISTORY=own \
    swift test --scratch-path .build/dev-optimized -c debug -Xswiftc -O --filter 'PrivateNormalWindowTests' \
    2>&1 | tee "$out/tests.log"
apps="$(dirname "${APP:?run through farm}")/private-spaces"
mkdir -p "$apps"
bash scripts/runs/rev_app.sh "$base" "$apps/base.app" 2>&1 | tee "$out/baseline-build.log"
python3 -u evals/private-spaces/check.py --base-app "$apps/base.app" \
    --app "build/Pane Dev.app" --out "$out/private-spaces"
