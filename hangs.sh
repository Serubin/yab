#!/bin/bash
# Where the main thread stops, while bringing things over from another
# browser, the moment the whole Mac seemed to freeze.
#
#   ./hangs.sh                    everything from the default browser
#   ./hangs.sh Chrome             from that one instead
#   ./hangs.sh Dia tabs,history   only those parts
#
# A fresh world of its own, "yab (hangs)", so nothing the browser you use
# holds is touched: its settings, its tabs, its history. Passwords go into
# the keychain under that world's own label, "yab (hangs)", and nowhere
# else; leave "passwords" out to keep the keychain out of it altogether.
#
# The run opens the welcome, goes to the chapter about the old browser,
# presses the button as a person would, waits for it all to settle, and
# quits. A watchdog asks the main thread for a moment every 20 ms; every
# answer that took 100 ms or more is a stall, written down with the phase
# the import was in. The report at the end is worst first.
set -euo pipefail

cd "$(dirname "$0")"
FROM="${1:-}"
ONLY="${2:-}"
WORLD=hangs

swift build 2>&1 | grep -E "error:|Compiling|Build complete" | grep -v "^Compiling" || true
[ -x .build/debug/Fast ] || { echo "no build"; exit 1; }

# The same wipe as ./fresh.sh, for this world: a first launch every time.
rm -rf "$HOME/Library/Application Support/Pane ($WORLD)"
defaults delete "net.serubin.pane.test.$WORLD" 2>/dev/null || true

DIR="$HOME/Library/Application Support/Pane ($WORLD)"
LOG="$DIR/hangs.log"
SAMPLE="$(mktemp -t yab-hangs).txt"
echo "bringing from ${FROM:-the default browser}${ONLY:+ ($ONLY)}, macOS may ask for its keychain key"
# Stalls are drawing as much as code, and drawing waits on the window
# server, which every other app shares. A busy Mac makes every number
# bigger: compare runs made at about the same load.
echo "load now: $(sysctl -n vm.loadavg | tr -d '{}' | awk '{print $1}'), window server at $(ps -Ao %cpu,comm | awk '/WindowServer$/ {print $1}')% CPU"
env YAB_PROBE=$WORLD YAB_HANGS=1 YAB_BRING="${FROM:-default}" ${ONLY:+YAB_BRING_ONLY="$ONLY"} \
  .build/debug/Fast 2>&1 | grep -E "phase|done|STALL|brought|stalls|  [a-z]|no browser|watching" &
RUN=$!

# The whole run, sampled: where the main thread's time went, so a stall
# named by phase can also be named by function.
sleep 1
PID=$(pgrep -n -f "[.]build/debug/Fast" || true)
# In front, the way a person sees it: a window behind others isn't drawn,
# and what isn't drawn can't stall.
# NSRunningApplication through JXA, not System Events: no Apple event, so no
# "wants access to control" dialog left over the screen.
[ -n "$PID" ] && osascript -l JavaScript -e "ObjC.import('AppKit'); \$.NSRunningApplication.runningApplicationWithProcessIdentifier($PID).activateWithOptions(\$.NSApplicationActivateIgnoringOtherApps)" >/dev/null 2>&1 || true
[ -n "$PID" ] && sample "$PID" 12 1 -file "$SAMPLE" >/dev/null 2>&1 || true
wait $RUN || true

if [ -s "$SAMPLE" ]; then
  echo
  echo "main thread, busiest frames of yab's own (samples of 1 ms):"
  /usr/bin/python3 - "$SAMPLE" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
main = text.split("Thread_")[1]
seen = {}
for line in main.split("\n"):
    m = re.match(r"\s*[+!:| ]*(\d+) (.+?)  \(in (\S+)\)", line)
    if not m: continue
    frame, module, count = m.group(2)[:100], m.group(3), int(m.group(1))
    if module == "yab" and "main" not in frame:
        seen[frame] = max(seen.get(frame, 0), count)
    if "layoutIfNeeded" in frame or "CA::Transaction::commit" in frame:
        seen["(layout and drawing)"] = max(seen.get("(layout and drawing)", 0), count)
for frame, count in sorted(seen.items(), key=lambda x: -x[1])[:15]:
    print(f"  {count:6d}  {frame}")
PY
  cp "$SAMPLE" "$DIR/sample.txt" 2>/dev/null || true
  echo "full sample: $DIR/sample.txt"
fi
echo "full log: $LOG"
