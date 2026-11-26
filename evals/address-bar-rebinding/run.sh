#!/bin/bash
# Verify the unchanged default and record custom keys in Settings, then relaunch.
set -euo pipefail
cd "$(dirname "$0")/../.."
: "${YAB_FARM_OUT:?run through the display-enabled farm}"
./build.sh 2>&1 | tee "$YAB_FARM_OUT/build.log"
python3 -u evals/address-bar-rebinding/check.py --app "build/Pane Dev.app"
