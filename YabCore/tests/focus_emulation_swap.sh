#!/bin/bash
# A focused page swapped out of its renderer under YabCore's focus emulation,
# against the pinned release SDK (focus_emulation_swap.py, crash report 1153).
# Exit 0: no renderer crashed.
set -uo pipefail
cd "$(dirname "$0")/../.."
source YabCore/tests/release_core_app.sh || exit 1
python3 -u YabCore/tests/focus_emulation_swap.py "$APP/Contents/MacOS/PaneCore"
