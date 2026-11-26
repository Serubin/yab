#!/bin/bash
# Reuse the signed candidate; no build in this display job.
set -euo pipefail
out=${YAB_FARM_OUT:?}
# Repeat the published baseline on this same display worker. The archive
# comes from the published release, never from a baseline rebuild.
curl -fL 'https://8hauzhgbhxiipn9a.public.blob.vercel-storage.com/releases/yab-0.46.7-202611030445.zip' -o "$out/before.zip"
mkdir "$out/published"
ditto -x -k "$out/before.zip" "$out/published"
before=$(find "$out/published" -path '*/Contents/MacOS/yab' -type f | head -1)
python3 evals/golden/saved_page_names.py --app "${before%/Contents/MacOS/yab}" --out "$out/before" --before --keep-signature
python3 - "${1:?signed build job}" "$out/candidate.zip" "${2:-}" <<'PY'
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
job = json.loads(subprocess.check_output(['./farm', 'where', sys.argv[1]], text=True))
path = Path.home() / '.local/state/yab-farm/runtime/farm.py'
spec = importlib.util.spec_from_file_location('saved_names_artifact_transport', path)
farm = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = farm
spec.loader.exec_module(farm)
print('Fetching the signed app archive from ' + job['host'], flush=True)
# The farm transport is also the supported artifact reader. Pull only the
# compressed app, instead of transferring a second copy of the build logs.
archive = sys.argv[3] or job['evidence'] + '/out/candidate.zip'
subprocess.run(['./adhd', 'pull', archive, sys.argv[2]],
               env=farm.transport(job, farm.config()), check=True)
PY
mkdir "$out/built"
ditto -x -k "$out/candidate.zip" "$out/built"
app="$out/built/${YAB_TASK_NAME:?}.app"
codesign --verify --deep --strict "$app"
python3 evals/golden/saved_page_names.py --app "$app" --out "$out/after" --keep-signature
