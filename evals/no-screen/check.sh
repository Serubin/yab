#!/bin/bash
# Crash #34: yab with no window server (Codex's sandbox, a seatbelt without the
# window server) says a line and leaves with 69, no crash report; a normal
# launch opens the browser. Needs Codex CLI and a display: run on the farm with
# ./farm exec --display --host adhd --pin "Codex CLI" -- evals/no-screen/check.sh
set -o pipefail
cd "$(dirname "$0")/../.."
./build.sh 2>&1 | tee /tmp/crash34-build-$$.log | tail -5 || exit 1
APP=$(ls -dt build/*.app | head -1); BIN="$APP/Contents/MacOS/pane"
echo "== app $APP on $(hostname -s)"
CODEX=$(command -v codex || ls /opt/homebrew/bin/codex ~/.local/bin/codex 2>/dev/null | head -1)
REPORTS=~/Library/Logs/DiagnosticReports
touch /tmp/crash34-mark-$$
fail=0
check() { # label, expected exit, command...
  label=$1; want=$2; shift 2
  out=$("$@" 2>&1); code=$?
  echo "-- $label: exit $code"; echo "$out" | sed 's/^/   /' | head -4
  [ "$code" = "$want" ] || { echo "   FAIL (wanted $want)"; fail=1; }
}
WORLD=crash34-$$
export YAB_PROBE=$WORLD FAST_PROBE=$WORLD
[ -n "$CODEX" ] && check "codex sandbox, no word" 69 "$CODEX" sandbox -- "$BIN"
[ -n "$CODEX" ] && check "codex sandbox, -v" 69 "$CODEX" sandbox -- "$BIN" -v
[ -n "$CODEX" ] && check "codex sandbox, yab help" 0 "$CODEX" sandbox -- "$BIN" help
check "seatbelt without window server" 69 sandbox-exec -p '(version 1)(allow default)(deny mach-lookup (global-name "com.apple.windowserver.active") (global-name "com.apple.coreservices.launchservicesd"))' "$BIN"
sleep 3
new=$(find "$REPORTS" -newer /tmp/crash34-mark-$$ -name 'yab*' 2>/dev/null)
if [ -n "$new" ]; then echo "FAIL new crash reports: $new"; fail=1; else echo "-- no new yab crash reports"; fi
echo "== normal launch"
"$BIN" >/tmp/crash34-run-$$.log 2>&1 &
pid=$!
sleep 12
if kill -0 $pid 2>/dev/null; then
  wins=$(swift -e 'import CoreGraphics; let p = Int(CommandLine.arguments[1])!; let l = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as! [[String: Any]]; print(l.filter { ($0["kCGWindowOwnerPID"] as? Int) == p && ($0["kCGWindowLayer"] as? Int) == 0 && (($0["kCGWindowBounds"] as? [String: Double])?["Width"] ?? 0) > 300 }.count)' $pid 2>/dev/null)
  echo "-- alive after 12 s, pid $pid, normal-layer windows: $wins"
  [ "${wins:-0}" -ge 1 ] || { echo "   FAIL no browser window"; fail=1; }
  kill $pid; sleep 2; kill -9 $pid 2>/dev/null
else
  wait $pid; echo "FAIL exited early with $?"; tail -20 /tmp/crash34-run-$$.log; fail=1
fi
defaults delete dev.serafim.fast.test.$WORLD >/dev/null 2>&1
echo "== result: $([ $fail = 0 ] && echo PASS || echo FAIL)"
exit $fail
