#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
base=${1:?base commit}
out=${YAB_FARM_OUT:?run through farm}
mkdir -p "$out/apps"
./build.sh 2>&1 | tee "$out/build-after.log"
ditto "build/Pane Dev.app" "$out/apps/after.app"
bash scripts/runs/rev_app.sh "$base" "$out/apps/before.app" 2>&1 | tee "$out/build-before.log"
python3 -u evals/golden/new_tab_selection.py --app "$out/apps/after.app" --base-app "$out/apps/before.app"
