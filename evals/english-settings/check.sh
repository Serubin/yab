#!/bin/bash
# Build main and this tree, then capture the same Settings pages in Japanese.
set -euo pipefail
cd "$(dirname "$0")/../.."
base=1cc4138ea63ad9bb03b4778466df305eaaf86caa
bash scripts/runs/rev_app.sh "$base" "$YAB_FARM_OUT/before.app" 2>&1 | tee "$YAB_FARM_OUT/before-build.log"
/usr/bin/swift evals/english-settings/bundle-check.swift "$YAB_FARM_OUT/before.app" --baseline | tee "$YAB_FARM_OUT/before-bundle.log"
python3 -u evals/golden/settings_developer.py --baseline --settings-only --languages ja --app "$YAB_FARM_OUT/before.app" --out "$YAB_FARM_OUT/before"
./build.sh 2>&1 | tee "$YAB_FARM_OUT/after-build.log"
/usr/bin/swift evals/english-settings/bundle-check.swift 'build/Pane Dev.app' | tee "$YAB_FARM_OUT/after-bundle.log"
python3 -u evals/golden/settings_developer.py --settings-only --languages ja --app 'build/Pane Dev.app' --out "$YAB_FARM_OUT/after"
