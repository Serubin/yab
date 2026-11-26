#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
base=${1:?base commit}
out="${YAB_FARM_OUT:?run through farm}"
task_python="${YAB_TEST_PYTHON:-$(command -v python3)}"
./build.sh 2>&1 | tee "$out/candidate-build.log"
"$task_python" -u evals/boost-add/tests.py 2>&1 | tee "$out/menu-tests.log"
bash scripts/runs/rev_app.sh "$base" "$out/main-base.app" 2>&1 | tee "$out/base-build.log"
"$task_python" -u evals/golden/boost_add_menu.py --app 'build/Pane Dev.app' --base-app "$out/main-base.app" --out "$out/proof"
