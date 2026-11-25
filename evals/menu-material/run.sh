#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
base=${1:?main commit required}
out=${YAB_FARM_OUT:?run through farm}
task_python=${YAB_TEST_PYTHON:-$(command -v python3)}
./build.sh 2>&1 | tee "$out/candidate-build.log"
ditto "build/Pane Dev.app" "$out/${YAB_TASK_NAME}.app"
bash scripts/runs/rev_app.sh "$base" "$out/main-base.app" 2>&1 | tee "$out/base-build.log"
"$task_python" -u evals/golden/action_menu_material.py --base-app "$out/main-base.app" --app "$out/${YAB_TASK_NAME}.app" --out "$out/menu-material" 2>&1 | tee "$out/proof.log"
