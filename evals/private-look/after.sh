#!/bin/bash
# The candidate: build, the private window tests, then the same shots.
set -euo pipefail
cd "$(dirname "$0")/../.."
out=${YAB_FARM_OUT:?run through farm}
mkdir -p "$out"
./build.sh 2>&1 | tee "$out/build.log"
YAB_PROBE="private-look-tests-${YAB_FARM_JOB}" YAB_HISTORY=own \
    swift test --scratch-path .build/dev-optimized -c debug -Xswiftc -O --filter 'PrivateNormalWindowTests' \
    2>&1 | tee "$out/tests.log"
python3 -u evals/private-look/shots.py --app "build/Pane Dev.app" --out "$out/shots"
