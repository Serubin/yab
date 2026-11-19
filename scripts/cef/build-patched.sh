#!/bin/bash
# Build CEF 156 with YabCore/cef-patches into a minimal macOS arm64 distribution.
# usage: YAB_CEF_RELEASE_REPO=owner/repo [YAB_CEF_BUILD_ROOT=/path] bash scripts/cef/build-patched.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO="$PWD"

CEF_BRANCH=8078
CEF_COMMIT=4fa4ab516dacf6c49fc7e6e70d2b7ebce29fa35f
CEF_VERSION='156.0.14+g4fa4ab5+chromium-156.0.8078.48'
# Codecs stay off so the published SDK carries no H.264/AAC decoders.
export GN_DEFINES='proprietary_codecs=false ffmpeg_branding=Chromium symbol_level=0 is_official_build=false dcheck_always_on=false treat_warnings_as_errors=false use_remoteexec=false'
export CEF_ENABLE_ARM64=1

RELEASE_REPO="${YAB_CEF_RELEASE_REPO:?set YAB_CEF_RELEASE_REPO to the owner/repo that hosts the SDK release}"
ROOT="${YAB_CEF_BUILD_ROOT:-$HOME/.local/state/yab-cef-build}"
SRC="$ROOT/chromium/src"
OUT="out/Release_GN_arm64"
DISTRIB="$ROOT/distrib"
mkdir -p "$ROOT"
log() { printf '\n== %s\n' "$*" >&2; }

[ "$(uname -m)" = arm64 ] || { echo 'build-patched: needs an Apple silicon Mac' >&2; exit 1; }
case "$(xcode-select -p)" in */Xcode*.app/Contents/Developer) ;;
  *) echo 'build-patched: select full Xcode (sudo xcode-select -s /Applications/Xcode.app)' >&2; exit 1 ;; esac
# ANGLE compiles Metal shaders, and Xcode ships that compiler as a separate download.
xcrun metal --version >/dev/null 2>&1 \
  || { echo 'build-patched: no Metal toolchain; run: xcodebuild -downloadComponent MetalToolchain' >&2; exit 1; }

if [ ! -f "$ROOT/.configured" ]; then
  if [ ! -d "$SRC/cef" ]; then
    free_gb=$(( $(df -k "$ROOT" | awk 'NR==2 {print $4}') / 1024 / 1024 ))
    [ "$free_gb" -ge 110 ] || { echo "build-patched: $ROOT has ${free_gb} GB free; needs 110 GB" >&2; exit 1; }
  fi
  log 'checkout: depot_tools, CEF and Chromium without history (hours)'
  mkdir -p "$ROOT/automate"
  curl -fsSL "https://raw.githubusercontent.com/chromiumembedded/cef/$CEF_COMMIT/tools/automate/automate-git.py" \
    -o "$ROOT/automate/automate.py"
  python3 "$ROOT/automate/automate.py" --download-dir="$ROOT" \
    --branch="$CEF_BRANCH" --checkout="$CEF_COMMIT" --no-chromium-history \
    --arm64-build --no-debug-build --no-build --no-distrib
  # The script ran before the checkout existed; now prove it was that commit's own.
  cmp -s "$ROOT/automate/automate.py" "$SRC/cef/tools/automate/automate-git.py" \
    || { echo 'build-patched: downloaded automate script differs from the pinned CEF commit' >&2; exit 1; }
  export PATH="$ROOT/depot_tools:$PATH" DEPOT_TOOLS_UPDATE=0
  log 'configure: CEF stock patches and GN projects'
  (cd "$SRC/cef/tools" && python3 gclient_hook.py)
  touch "$ROOT/.configured"
fi
export PATH="$ROOT/depot_tools:$PATH" DEPOT_TOOLS_UPDATE=0

log 'patches: YabCore/cef-patches'
python3 scripts/cef/revert_stale_series.py --src "$SRC" --snapshot "$ROOT/applied-patches"
python3 YabCore/cef-patches/apply-series.py --src "$SRC" --patches YabCore/cef-patches --check >/dev/null
python3 YabCore/cef-patches/apply-series.py --src "$SRC" --patches YabCore/cef-patches

# gclient_hook.py would re-run CEF's stock patcher over ours, so take its two later steps directly.
log 'regenerate: C API translation and GN files'
(cd "$SRC/cef/tools" && python3 version_manager.py -u)
(cd "$SRC" && gn gen "$OUT")
(cd "$SRC" && gn args "$OUT" --list --short) > "$ROOT/gn-args-resolved.txt"
for want in 'proprietary_codecs = false' 'ffmpeg_branding = "Chromium"' 'is_official_build = false' 'dcheck_always_on = false'; do
  grep -qxF "$want" "$ROOT/gn-args-resolved.txt" || { echo "build-patched: GN resolved without: $want" >&2; exit 1; }
done
# The receipt is public, and only overrides are free of machine-local paths.
(cd "$SRC" && gn args "$OUT" --list --short --overrides-only) > "$ROOT/gn-args.txt"

log 'build: cefclient (the framework is copied from its bundle)'
# One job per core swaps on a 24 GB Mac; YAB_CEF_JOBS caps it.
(cd "$SRC" && autoninja ${YAB_CEF_JOBS:+-j "$YAB_CEF_JOBS"} -C "$OUT" cefclient)

log 'distrib: minimal arm64'
rm -rf "$DISTRIB"
(cd "$SRC/cef/tools" && python3 make_distrib.py --output-dir="$DISTRIB" --ninja-build \
  --arm64-build --minimal --no-docs --no-symbols --no-archive --allow-partial)

log 'package'
python3 scripts/cef/package_patched.py --distrib "$DISTRIB" --out "$ROOT/release" --src "$SRC" \
  --cef-version "$CEF_VERSION" --gn-args "$ROOT/gn-args.txt" --release-repo "$RELEASE_REPO" \
  --manifest "$REPO/scripts/cef/patched-sdk.json"
