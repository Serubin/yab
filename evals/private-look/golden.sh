#!/bin/bash
# The candidate built, then the golden private/normal window eval on it.
set -euo pipefail
cd "$(dirname "$0")/../.."
out=${YAB_FARM_OUT:?run through farm}
mkdir -p "$out"
./build.sh 2>&1 | tee "$out/build.log"
python3 -u evals/golden/private_normal_window.py --app "build/Pane Dev.app" --out "$out/golden"
