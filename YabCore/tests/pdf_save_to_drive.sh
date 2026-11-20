#!/bin/bash
# Save to Drive in Chrome's PDF viewer, against the pinned release SDK
# (pdf_save_to_drive.py, crash report 1524). Exit 0: YabCore survived;
# 1 on an SDK without cef-patches/0108.
set -uo pipefail
cd "$(dirname "$0")/../.."
source YabCore/tests/release_core_app.sh || exit 1
python3 -u YabCore/tests/pdf_save_to_drive.py "$APP/Contents/MacOS/PaneCore"
