# red-alert-in-linux

Fix for **Red Alert 2 / Yuri's Revenge (CnCNet)** on Linux Wine + Wayland that
**renders only when you move the mouse, runs at ~1 FPS, then freezes**, and
takes forever to sync with other players.

Tested on: Omarchy 4.0.3.1 (Arch-based, Hyprland on Wayland/XWayland),
vanilla Wine 11.17 and Steam Proton Experimental (non-Steam game), hybrid
Intel Iris Plus + NVIDIA MX230, Internet Archive `red-alert-2_202103` dump +
CnCNet client 9.3.3.

## Symptoms

- Game/launcher opens and even connects to a lobby match.
- In-game pixels only repaint under the cursor; the rest stays stale/black.
- After a while the picture stops updating entirely.
- Syncing with other players is very slow; `debug.log` ends with
  `Game loop finished. Average FPS = 1`.
- `debug.log` also shows `Checking hardware region fill capability...Failed!`
  and `SetDisplayMode: 1280x800x16`.

## Root cause

1. The dump ships an old **ts-ddraw** (`ddraw.dll`, 42 KB) forced into
   exclusive fullscreen (`renderer=opengl`, `fullscreen=true`,
   `windowed=false`, `SingleProcAffinity=No` in `ddraw.ini`).
2. Exclusive fullscreen + Wine's built-in DirectDraw (`wined3d`) on XWayland
   stops delivering repaint events, so the backbuffer only updates on
   mouse-move expose events, then stalls. At 1 FPS the netcode's `FrameSync`
   packets stall too, which looks like "slow connect".
3. cnc-ddraw changelogs explicitly mention fixing **low FPS** and **Wine FPS
   limiter** bugs that this setup hits.

Fix: replace ts-ddraw with **cnc-ddraw v7.1**, run it **borderless-windowed**,
**force full redraw**, pin to **one CPU**, and tell Wine to use the native
`ddraw.dll`.

## Quick fix

```bash
# 1. Apply the renderer fix (backs up ddraw.dll/ddraw.ini to Backup/)
./scripts/fix-rendering.sh "/path/to/Red Alert 2"
# If omitted, it auto-detects ~/Downloads/red-alert-2_202103/Red Alert 2

# 2. Launch stably (single-core, vsync off, Intel iGPU)
./scripts/launch-ra2.sh "/path/to/Red Alert 2"

# Variants:
./scripts/launch-ra2.sh --nvidia      # try discrete GPU instead
./scripts/launch-ra2.sh --gamescope   # nested compositor, best isolation on Hyprland
./scripts/launch-ra2.sh --direct      # skip CnCNet launcher (offline/skirmish)
```

Reference config used: `config/ddraw.linux-wayland.ini`. The `ddraw.dll` /
`ddraw.ini` part of the fix is runner-independent: it applies whether you
launch via vanilla Wine or via Steam/Proton.

## Steam (non-Steam game + Proton Experimental)

If you run `CnCNetYRLauncher.exe` as a Steam non-Steam game (this is the
setup this fix was verified against after the Wine run):

1. Steam > Add a Non-Steam Game > Browse to `CnCNetYRLauncher.exe`.
2. Right-click the shortcut > Properties:
   - Target: `"/path/to/Red Alert 2/CnCNetYRLauncher.exe"`
   - Start In: `"/path/to/Red Alert 2"`
   - Compatibility: check "Force the use of a specific Steam Play
     compatibility tool" > **Proton Experimental**.
   - General: uncheck "Enable the Steam Overlay while in-game" (the overlay
     hooks the same DirectDraw path and can reintroduce stalls).
3. Set Launch Options exactly:
   ```text
   WINEDLLOVERRIDES="ddraw=n,b" PROTON_USE_WINED3D=1 taskset -c 0 %command%
   ```
   - `WINEDLLOVERRIDES="ddraw=n,b"` loads this repo's cnc-ddraw instead of
     Proton's built-in ddraw (the Proton equivalent of the `wine reg` step).
   - `PROTON_USE_WINED3D=1` keeps DirectDraw on wined3d (DXVK does not handle
     this game's ddraw path).
   - `taskset -c 0` pins the pre-multi-core engine + spawner to one CPU,
     matching `singlecpu=true` in `ddraw.ini`.
4. Run `./scripts/fix-rendering.sh "/path/to/Red Alert 2"` first if you have
   not already: the game-dir files are shared regardless of runner.

Each non-Steam shortcut gets its own prefix under
`~/.steam/steam/steamapps/compatdata/<id>/pfx`; no manual prefix setup is
needed. Verify with `debug.log`: `Game loop finished. Average FPS = 50-60`,
not 1.

## What the fix changes (`ddraw.ini`)

| Setting | Before (broken) | After | Why |
|---|---|---|---|
| `ddraw.dll` | ts-ddraw (42 KB) | cnc-ddraw v7.1 (402 KB) | Fixes Wine FPS-limiter / low-FPS bugs |
| `fullscreen` + `windowed` | `false` + `false` (exclusive) | `true` + `true` (borderless) | Exclusive mode stalls repaints on XWayland |
| `border` | `true` | `false` | True borderless window |
| `maintas` | `false` | `true` | Keep aspect when stretched |
| `renderer` | `opengl` (forced, stale ts-ddraw) | `opengl` (cnc-ddraw) | Tested Wine/XWayland path; `gdi` is fallback |
| `minfps` | `0` | `-2` | Force full redraw; fixes mouse-move-only painting |
| `singlecpu` | `No` / unset | `true` | Pre-multi-core engine freezes/desyncs otherwise |
| `nonexclusive` | `true` | `true` (kept) | Don't grab exclusive mode |
| Wine override | none | `ddraw = native,builtin` | Actually load cnc-ddraw instead of Wine built-in |

`RA2MD.ini [Video]` is left alone (`Video.Windowed=False`,
`BorderlessWindowedClient=False`) so cnc-ddraw owns windowing.

## Slow connection / desync note

Most of the "slow connect" is the 1 FPS stall: every client must exchange
`FrameSync` packets each frame, so one stalled renderer holds the whole room.
After this fix, if sync is still slow:

- In the CnCNet client use a nearby tunnel (lowest ping), keep `PortPool`
  reachable (default UDP 16665); UPnP or a manual UDP port-forward helps.
- Keep `singlecpu=true` + launch via `taskset -c 0` (this repo's launcher).
- Close Discord overlay / screen recorders that hook DirectDraw.

## If it still fails

| Problem | Try |
|---|---|
| Black screen with `renderer=opengl` | `renderer=gdi` in `ddraw.ini` (slower, very stable) |
| Tearing | `vsync=true` (adds input lag) |
| Game too fast / flicker | `maxgameticks=60` (then 30/25/20/15) |
| Crash on start | `resolutions=1`, delete `Screenshots/`, run `--direct` once |
| Window focus/Alt-Tab weirdness | `noactivateapp=true` |
| Still stale frames on Hyprland | `--gamescope`, plus window rule below |

Hyprland (optional, reduces blur/tearing hooks on the game window):

```ini
windowrulev2 = noblur, class:^(.*ra2.*|.*gamemd.*|.*CnCNet.*)$, title:.*
windowrulev2 = fullscreenstate 0 2, class:^(.*ra2.*|.*gamemd.*)$, title:.*
```

## Restore

```bash
GAME_DIR="/path/to/Red Alert 2"
cp --remove-destination "$GAME_DIR/Backup/ddraw.pre-fix.dll.bak" "$GAME_DIR/ddraw.dll"
cp --remove-destination "$GAME_DIR/Backup/ddraw.pre-fix.ini.bak" "$GAME_DIR/ddraw.ini"
wine reg delete 'HKEY_CURRENT_USER\Software\Wine\DllOverrides' /v ddraw /f
```

## Layout

```text
config/ddraw.linux-wayland.ini  tuned cnc-ddraw config for Wine/Wayland
scripts/fix-rendering.sh        download cnc-ddraw, backup, apply config, set wine override
scripts/launch-ra2.sh           stable launch: taskset, GPU choice, gamescope, direct mode
```

Upstream: cnc-ddraw <https://github.com/FunkyFr3sh/cnc-ddraw>, CnCNet
<https://cncnet.org>. This repo only ships config + scripts, not the game.
