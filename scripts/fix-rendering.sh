#!/usr/bin/env bash
# Fix Red Alert 2 / Yuri's Revenge (CnCNet) rendering on Linux Wine + Wayland.
#
# Symptom it fixes: game connects but pixels only repaint when the mouse moves,
# then freezes (debug.log shows "Average FPS = 1", "hardware region fill Failed").
# Root cause: old ts-ddraw in exclusive fullscreen + stale framebuffer on XWayland.
# Fix: install cnc-ddraw (v7.1+, fixes Wine FPS-limiter bugs) and switch to
# borderless-windowed + forced full redraw + single-CPU affinity.
#
# Usage:
#   ./scripts/fix-rendering.sh ["/path/to/Red Alert 2"]
#   RA2_DIR="/path/to/Red Alert 2" ./scripts/fix-rendering.sh
#
# Env:
#   CNC_DDRAW_VERSION  cnc-ddraw version tag (default 7.1.0.0)
#   CNC_DDRAW_URL      override download URL (for offline/air-gapped use)
#   WINEPREFIX         Wine prefix to set the ddraw override in (default ~/.wine)

set -euo pipefail

GAME_DIR="${1:-${RA2_DIR:-}}"
if [[ -z "$GAME_DIR" ]]; then
  # Common locations: Internet Archive dump + CnCNet installer default
  for candidate in \
    "$HOME/Downloads/red-alert-2_202103/Red Alert 2" \
    "$HOME/Games/RA2" \
    "$HOME/.wine/drive_c/CnCNet" \
  ; do
    if [[ -f "$candidate/gamemd-spawn.exe" ]]; then
      GAME_DIR="$candidate"
      break
    fi
  done
fi

if [[ -z "$GAME_DIR" || ! -f "$GAME_DIR/gamemd-spawn.exe" ]]; then
  echo "error: could not find 'Red Alert 2' game dir (expected gamemd-spawn.exe inside)." >&2
  echo "usage: $0 [\"/path/to/Red Alert 2\"]" >&2
  exit 1
fi

CNC_DDRAW_VERSION="${CNC_DDRAW_VERSION:-7.1.0.0}"
CNC_DDRAW_URL="${CNC_DDRAW_URL:-https://github.com/FunkyFr3sh/cnc-ddraw/releases/download/v${CNC_DDRAW_VERSION}/cnc-ddraw.zip}"
WINEPREFIX="${WINEPREFIX:-$HOME/.wine}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TUNED_INI="$REPO_DIR/config/ddraw.linux-wayland.ini"

echo "Game dir:   $GAME_DIR"
echo "Wineprefix: $WINEPREFIX"
echo "cnc-ddraw:  $CNC_DDRAW_VERSION"

mkdir -p "$GAME_DIR/Backup"
# The Internet Archive dump ships ddraw.dll read-only; make backups without
# preserving the hardlink/read-only bits that block overwriting later.
if [[ -f "$GAME_DIR/ddraw.dll" ]]; then
  cp -v --remove-destination "$GAME_DIR/ddraw.dll" "$GAME_DIR/Backup/ddraw.pre-fix.dll.bak"
fi
if [[ -f "$GAME_DIR/ddraw.ini" ]]; then
  cp -v --remove-destination "$GAME_DIR/ddraw.ini" "$GAME_DIR/Backup/ddraw.pre-fix.ini.bak"
fi

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

echo "Downloading cnc-ddraw v$CNC_DDRAW_VERSION ..."
curl -fL -o "$TMPDIR/cnc-ddraw.zip" "$CNC_DDRAW_URL"
python3 -c "import zipfile; zipfile.ZipFile('$TMPDIR/cnc-ddraw.zip').extractall('$TMPDIR/extracted')"

# Break read-only/hardlink so the copy always succeeds.
if [[ -e "$GAME_DIR/ddraw.dll" ]]; then
  chmod u+w "$GAME_DIR/ddraw.dll" || true
  rm -f "$GAME_DIR/ddraw.dll"
fi
cp -v "$TMPDIR/extracted/ddraw.dll" "$GAME_DIR/ddraw.dll"
if [[ -f "$TMPDIR/extracted/cnc-ddraw config.exe" ]]; then
  cp -v "$TMPDIR/extracted/cnc-ddraw config.exe" "$GAME_DIR/" || true
fi
if [[ -d "$TMPDIR/extracted/Shaders" ]]; then
  mkdir -p "$GAME_DIR/Shaders"
  cp -rv "$TMPDIR/extracted/Shaders/." "$GAME_DIR/Shaders/" | tail -n 2
fi

if [[ -f "$TUNED_INI" ]]; then
  echo "Applying tuned Wayland config ..."
  cp -v "$TUNED_INI" "$GAME_DIR/ddraw.ini"
else
  echo "Tuned config not found in repo; patching stock ddraw.ini in place ..."
  # Borderless-windowed: avoids exclusive-fullscreen repaint stalls on XWayland.
  sed -i -E 's/^(fullscreen\s*=).*/\1true/' "$GAME_DIR/ddraw.ini"
  sed -i -E 's/^(windowed\s*=).*/\1true/' "$GAME_DIR/ddraw.ini"
  sed -i -E 's/^(maintas\s*=).*/\1true/' "$GAME_DIR/ddraw.ini"
  sed -i -E 's/^(border\s*=).*/\1false/' "$GAME_DIR/ddraw.ini"
  # opengl is the tested Wine/XWayland path; gdi is the fallback (see README).
  sed -i -E 's/^(renderer\s*=).*/\1opengl/' "$GAME_DIR/ddraw.ini"
  # Force full redraw: fixes "only repaints when mouse moves" / 1 FPS stall.
  sed -i -E 's/^(minfps\s*=).*/\1-2/' "$GAME_DIR/ddraw.ini"
fi

if command -v wine >/dev/null 2>&1; then
  echo "Setting Wine ddraw override to native,builtin ..."
  export WINEPREFIX
  wine reg add 'HKEY_CURRENT_USER\Software\Wine\DllOverrides' /v ddraw /d native,builtin /f
else
  echo "note: 'wine' not found; skipping wine reg override."
  echo "If you run via Steam/Proton, the WINEDLLOVERRIDES launch option below covers this."
fi

echo
echo "Done. Key settings now in $GAME_DIR/ddraw.ini:"
grep -E '^(renderer|fullscreen|windowed|border|maintas|minfps|vsync|singlecpu|nonexclusive)=' "$GAME_DIR/ddraw.ini" || true
echo
echo "Launch (vanilla Wine): ./scripts/launch-ra2.sh [\"$GAME_DIR\"]"
echo
echo "Launch (Steam non-Steam game + Proton Experimental), Launch Options:"
echo '  WINEDLLOVERRIDES="ddraw=n,b" PROTON_USE_WINED3D=1 taskset -c 0 %command%'
echo "If you get a black screen, see README fallback table (try renderer=gdi)."
