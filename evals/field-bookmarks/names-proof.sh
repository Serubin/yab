#!/bin/bash
set -euo pipefail
out=${YAB_FARM_OUT:?}
curl -fL 'https://8hauzhgbhxiipn9a.public.blob.vercel-storage.com/releases/yab-0.46.7-202611030445.zip' -o "$out/before.zip"
mkdir "$out/published"
ditto -xk "$out/before.zip" "$out/published"
before=$(find "$out/published" -path '*/Contents/MacOS/yab' -type f | head -1)
codesign --verify --deep --strict "${before%/Contents/MacOS/yab}"
python3 evals/golden/saved_page_names.py --app "${before%/Contents/MacOS/yab}" --out "$out/before" --before --keep-signature
bash evals/field-bookmarks/names-after.sh
