#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
out="${YAB_FARM_OUT:?run through farm}"
base="${1:?base revision}"
swift test --filter 'SelectionDirectTests|SelectionCommandsTests|FieldSelectionRowsTests|GeminiSelectionTests|AgentDockStopTests' 2>&1 | tee "$out/tests.log"
./build.sh 2>&1 | tee "$out/build.log"
python3 -u evals/golden/selection_direct.py --app "build/Pane Dev.app" --out "$out/after"
bash scripts/runs/rev_app.sh "$base" "$out/before.app" 2>&1 | tee "$out/base-build.log"
python3 -u evals/golden/selection_direct.py --app "$out/before.app" --out "$out/before" --baseline
