#!/bin/bash
# Equivalent two-tree optimized A/B, with full compiler logs kept visible.
set -euo pipefail
cd "$(dirname "$0")/../.."
: "${YAB_FARM_OUT:?run through farm}"
python3 evals/sidebar-startup-p0/pair.py --focus-preflight "$YAB_FARM_OUT"
base=64fc763b1b7cf66855419eb455c55184a1a14d4c
mkdir -p "$YAB_FARM_OUT/apps"
git diff "$base" -- Sources > "$YAB_FARM_OUT/product.patch"
git rev-parse HEAD > "$YAB_FARM_OUT/source-head.txt"
shasum -a 256 Sources/Fast/Peek.swift > "$YAB_FARM_OUT/candidate-source.sha256"
./build.sh 2>&1 | tee "$YAB_FARM_OUT/candidate-build.log"
ditto 'build/Pane Dev.app' "$YAB_FARM_OUT/apps/candidate.app"
bash scripts/runs/rev_app.sh "$base" "$YAB_FARM_OUT/apps/base.app" 2>&1 | tee "$YAB_FARM_OUT/base-build.log"
python3 -u evals/sidebar-startup-p0/pair.py --base-app "$YAB_FARM_OUT/apps/base.app" --app "$YAB_FARM_OUT/apps/candidate.app" --out "$YAB_FARM_OUT/proof"
