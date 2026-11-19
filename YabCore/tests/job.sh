#!/bin/bash
# Submit with --display --needs capture, pinned off the user's Mac.
set -euo pipefail
cd "$(dirname "$0")/../.."
bash YabCore/build.sh 2>&1 | tee "$YAB_FARM_OUT/build.log"
APP="$(cat "$YAB_FARM_OUT/app-path.txt")"
test -x "$APP/Contents/MacOS/PaneCore"
lockf -k -s "${YAB_BUILD_LOCK:-/tmp/yab-build.lock}" clang++ -std=c++20 -fobjc-arc -framework Cocoa -framework QuartzCore \
  YabCore/tests/layer_host.mm -o "$YAB_FARM_OUT/layer-host"
swift test --package-path YabCore/Client --scratch-path "$YAB_FARM_OUT/swift" 2>&1 | tee "$YAB_FARM_OUT/swift-tests.log"
SWIFT_BIN="$(swift build --package-path YabCore/Client --scratch-path "$YAB_FARM_OUT/swift" --show-bin-path)"
python3 -u YabCore/tests/run.py --app "$APP" --probe "$SWIFT_BIN/YabCoreProbe" \
  --host "$YAB_FARM_OUT/layer-host" --out "$YAB_FARM_OUT/run"
