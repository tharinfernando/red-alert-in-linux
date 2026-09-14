#!/usr/bin/env bash
# Stable launcher for Red Alert 2 / Yuri's Revenge (CnCNet) on Linux.
# Wraps Wine with the workarounds this game needs on modern multi-core +
# Wayland/XWayland systems: single-core scheduling, vsync off, Intel iGPU by
# default on hybrid graphics, optional gamescope session.
#
# Usage:
#   ./scripts/launch-ra2.sh ["/path/to/Red Alert 2"] [--nvidia] [--gamescope] [--direct]
#   RA2_DIR="/path/to/Red Alert 2" ./scripts/launch-ra2.sh --gamescope
#
# Flags:
#   --nvidia    use discrete NVIDIA GPU (PRIME offload) instead of Intel iGPU
#   --gamescope run inside gamescope (recommended on Hyprland/Wayland if the
#               window still misbehaves; needs `gamescope` installed)
#   --direct    skip CnCNet launcher, run gamemd-spawn.exe directly (offline/skirmish)
#
# Env:
#   WINEPREFIX  Wine prefix (default ~/.wine)
#   WINE        wine binary (default wine)

set -euo pipefail

GAME_DIR=""
USE_NVIDIA=0
USE_GAMESCOPE=0
DIRECT=0
for arg in "$@"; do
  case "$arg" in
    --nvidia) USE_NVIDIA=1 ;;
    --gamescope) USE_GAMESCOPE=1 ;;
    --direct) DIRECT=1 ;;
    *) GAME_DIR="$arg" ;;
  esac
done

if [[ -z "$GAME_DIR" ]]; then
  GAME_DIR="${RA2_DIR:-}"
fi
if [[ -z "$GAME_DIR" ]]; then
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

if [[ -z "$GAME_DIR" || ! -d "$GAME_DIR" ]]; then
  echo "error: game dir not found. Pass it explicitly:" >&2
  echo "  $0 \"/path/to/Red Alert 2\"" >&2
  exit 1
fi

WINE="${WINE:-wine}"
WINEPREFIX="${WINEPREFIX:-$HOME/.wine}"
export WINEPREFIX

# Sanity checks: warn instead of failing so --direct/offline still works.
if [[ ! -f "$GAME_DIR/ddraw.dll" ]]; then
  echo "warn: no ddraw.dll in game dir; run ./scripts/fix-rendering.sh first." >&2
fi
if [[ "$(grep -E '^renderer=' "$GAME_DIR/ddraw.ini" 2>/dev/null || echo none)" != "renderer=opengl" ]]; then
  echo "warn: ddraw.ini renderer is not opengl; run ./scripts/fix-rendering.sh first." >&2
fi
if ! command -v taskset >/dev/null 2>&1; then
  echo "warn: taskset not found; single-core pinning disabled." >&2
fi

# Single-core scheduling: the game + spawner predate multi-core and can
# desync/freeze otherwise (cnc-ddraw singlecpu=true covers the renderer;
# taskset covers the rest of the process tree).
TASKSET=()
if command -v taskset >/dev/null 2>&1; then
  TASKSET=(taskset -c 0)
fi

# Hybrid graphics: 2D DirectDraw is happiest on the Intel iGPU. Only offload
# to NVIDIA when explicitly asked.
if [[ "$USE_NVIDIA" -eq 1 ]]; then
  export __NV_PRIME_RENDER_OFFLOAD=1
  export __GLX_VENDOR_LIBRARY_NAME=nvidia
  echo "Using NVIDIA discrete GPU (PRIME offload)."
else
  unset __NV_PRIME_RENDER_OFFLOAD || true
fi
# Let cnc-ddraw own vsync; stop the driver from queueing extra frames.
export __GL_SYNC_TO_VBLANK=0
export vblank_mode=0

cd "$GAME_DIR"
if [[ "$DIRECT" -eq 1 ]]; then
  EXE="gamemd-spawn.exe"
else
  EXE="CnCNetYRLauncher.exe"
fi
if [[ ! -f "$EXE" ]]; then
  echo "error: $EXE not found in $GAME_DIR" >&2
  exit 1
fi

if [[ "$USE_GAMESCOPE" -eq 1 ]]; then
  if ! command -v gamescope >/dev/null 2>&1; then
    echo "error: --gamescope requested but gamescope is not installed." >&2
    exit 1
  fi
  echo "Launching $EXE inside gamescope ..."
  exec gamescope -f -W 1920 -H 1080 -- "${TASKSET[@]}" "$WINE" "$EXE"
else
  echo "Launching $EXE (wineprefix=$WINEPREFIX, single-core) ..."
  exec "${TASKSET[@]}" "$WINE" "$EXE"
fi
