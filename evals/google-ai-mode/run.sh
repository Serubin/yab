#!/bin/bash
# Build the app and run run.py on it, on a display-enabled farm job:
#   ./farm exec --display --name "AI Mode Google" --estimate 1500 -- \
#     bash evals/google-ai-mode/run.sh "AI Mode Google" [--runs 3] [--only yab,plain-safari]
set -euo pipefail
cd "$(dirname "$0")/../.."
task_name="${1:-AI Mode Google}"
shift || true
export YAB_TASK_NAME="$task_name"
evidence="$(dirname "${APP:?run through the display-enabled farm}")"
./build.sh 2>&1 | tee "$evidence/build.log"
ditto "build/Pane Dev.app" "$evidence/$task_name.app"
python3 evals/google-ai-mode/run.py --app "$evidence/$task_name.app" --task "$task_name" "$@"
