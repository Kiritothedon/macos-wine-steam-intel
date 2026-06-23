# Developer README (Intel edition)

This file documents implementation details for `run.command`, `uninstall.command`, and the Merlot `.app` bundles in the **Intel-Mac** fork of `macos-wine-steam`.

## How this differs from the Apple Silicon original

| | Apple Silicon original | This Intel fork |
|---|---|---|
| CPU check | requires `arm64` | requires `x86_64` |
| Rosetta | installs Rosetta 2 (needs `sudo`) | not used; `run.command` needs no `sudo` |
| D3D backend (default) | DXMT (`3Shain/dxmt`) | DXVK (`Gcenx/DXVK-macOS`, D3D10/11 → Vulkan → Metal via bundled MoltenVK) |
| D3D backend (opt-in) | Apple GPTK / D3DMetal | Wine builtin WineD3D (`USE_DXVK=0`) |
| Wine flavor | `wine-devel` | `wine-staging` (bundles MoltenVK; configurable) |

Everything else (prefix init, registry tweaks, detached launch, the Merlot
`.app` builder) is unchanged.

## What `run.command` Does

- Checks platform: macOS only, Intel (`x86_64`) only.
- Downloads and extracts Wine:
  - From Gcenx macOS Wine builds, asset `wine-${WINE_FLAVOR}-${WINE_VERSION}-osx64.tar.xz`.
  - `WINE_FLAVOR` defaults to `staging` (also accepts `devel`, `stable`).
  - Extracted into `WINE_ROOT` (defaults to `~/wine-$WINE_VERSION`).
  - These builds bundle `libMoltenVK.dylib` and `winevulkan.dll`, which is what
    makes DXVK work on Intel/AMD GPUs.
- Initializes the Wine prefix at `WINEPREFIX` (defaults to `~/.wine-steam-intel`).
- Creates/updates a symlink next to the scripts pointing at `WINEPREFIX`
  (name from `WINEPREFIX_ALIAS_NAME`, default `WINEPREFIX`).
- Steam installation: downloads `SteamSetup.exe` to `STEAM_SETUP`
  (`/tmp/SteamSetup.exe`), runs it via Wine, deletes it once Steam is detected.
- D3D translation backend (chosen by `USE_DXVK`):
  - Default (`USE_DXVK=1`, DXVK):
    - downloads the DXVK-macOS "builtin" tarball and installs the
      `i386-windows` / `x86_64-windows` dll folders into `DXVK_ROOT` (default `~/DXVK`)
    - enables it via `WINEDLLPATH_PREPEND` (same mechanism the original used for DXMT)
    - **memory auto-tune** (`MERLOT_AUTO_TUNE=1`, default): detects system RAM
      (`sysctl -n hw.memsize`) and GPU VRAM (`system_profiler SPDisplaysDataType`),
      then writes `${WINEPREFIX}/dxvk.conf` and exports `DXVK_CONFIG_FILE` at it.
      It sets `dxgi.maxDeviceMemory` to the detected VRAM, `dxgi.maxSharedMemory`
      to `RAM/4` clamped to 1024–8192 MB, and `d3d9.maxAvailableMemory` to VRAM.
      Skipped if the caller already set `DXVK_CONFIG_FILE`.
    - passes through `DXVK_HUD`, `DXVK_FRAME_RATE`, `DXVK_CONFIG`,
      `DXVK_CONFIG_FILE` when the caller sets them
  - Opt-in (`USE_DXVK=0`, WineD3D):
    - skips the DXVK download and forces Wine's builtin d3d libraries with
      `WINEDLLOVERRIDES=d3d9,d3d10core,d3d11,dxgi=b` (unless the caller already set it)
    - slower, OpenGL-backed, but covers D3D9
- Launch mode:
  - Default (`MERLOT_DETACH=1`) runs Steam with `nohup ... & disown`, logging to
    `MERLOT_STEAM_LOG` (`${TMPDIR:-/tmp}/merlot-steam.log`).
  - `MERLOT_DETACH=0` keeps the foreground behavior.
- Wine logging: defaults `WINEDEBUG` to `-all,err+all` unless already set.
- Registry values written inside the prefix (unchanged from upstream):
  - `HKCU\Software\Wine\Mac Driver\RetinaMode` from `WINE_RETINA_MODE` (`0`/`1`)
  - Disables Windows mouse acceleration (`MouseSpeed`/`MouseThreshold1`/`MouseThreshold2` = 0)
  - Optional `HKCU\Software\Wine\DirectInput\MouseWarpOverride` from `WINE_MOUSE_WARP_OVERRIDE`

## Configuration (Environment Variables)

Defaults are the values in `run.command`.

- `WINE_VERSION` — Wine build version (default `11.10`). Must exist as a
  `wine-${WINE_FLAVOR}-${WINE_VERSION}-osx64.tar.xz` asset in
  [Gcenx macOS Wine builds](https://github.com/Gcenx/macOS_Wine_builds/releases).
  Gcenx prunes old releases, so this default needs bumping over time.
- `WINE_FLAVOR` — `staging` (default), `devel`, or `stable`.
- `USE_DXVK` — `1` (default) uses DXVK; `0` uses Wine builtin WineD3D.
- `DXVK_RELEASE` — DXVK-macOS release tag (default `v1.10.3-20230507-repack`).
  Must exist in [Gcenx/DXVK-macOS](https://github.com/Gcenx/DXVK-macOS/releases)
  as `dxvk-macOS-async-${DXVK_RELEASE}-builtin.tar.gz`.
- `MERLOT_AUTO_TUNE` — `1` (default) auto-generates `${WINEPREFIX}/dxvk.conf`
  from detected RAM/VRAM; `0` leaves DXVK memory at its defaults.
- `DXVK_MAX_DEVICE_MEMORY` / `DXVK_MAX_SHARED_MEMORY` — manual overrides in MB
  for the auto-tuned values (empty = derive from hardware).
- `WINE_ROOT` — where Wine is extracted (default `~/wine-$WINE_VERSION`).
- `WINEPREFIX` — Steam prefix (default `~/.wine-steam-intel`).
- `DXVK_ROOT` — where DXVK dll folders live (default `~/DXVK`).
- `WINEPREFIX_ALIAS_NAME` — symlink name next to `run.command` (default `WINEPREFIX`).
- `WINE_RETINA_MODE` — `1` enable, `0` disable (default `0`).
- `WINE_MOUSE_WARP_OVERRIDE` — empty (default) keeps Wine default; `force|enable|disable`.
- `MERLOT_DETACH` — `1` (default) detaches Steam from Terminal; `0` foreground.
- `MERLOT_STEAM_LOG` — detached-mode Steam log path.
- `STEAM_CEF_DISABLE_GPU` — `1` (default) launches Steam with
  `-cef-disable-gpu -cef-disable-gpu-compositing` to fix the black-window CEF
  rendering bug on macOS Wine; `0` launches without them.
- `STEAM_LAUNCH_ARGS` — extra arguments appended to the Steam launch (advanced).

Passed through to DXVK when set (e.g. from a game config):
- `DXVK_FRAME_RATE` — frame-rate cap, e.g. `60` (`0` = uncapped).
- `DXVK_HUD` — overlay, e.g. `fps` or `full`.
- `DXVK_CONFIG` / `DXVK_CONFIG_FILE` — advanced DXVK tuning.

Example overrides:

```bash
WINEPREFIX="$HOME/Games/SteamPrefix" WINE_RETINA_MODE=1 ./run.command
```

WineD3D fallback (no DXVK; covers D3D9):

```bash
USE_DXVK=0 ./run.command
```

## What `uninstall.command` Removes

Targets derived from environment variables (defaults are the values in `uninstall.command`):

- `STEAM_SETUP`
- `WINEPREFIX_ALIAS_NAME` (symlink next to the scripts)
- `/Applications/Merlot Apps` (hardcoded, removed via `sudo`)
- `WINEPREFIX`
- `DXVK_ROOT`
- `WINE_ROOT`

Notes:

- Asks for confirmation per item and shows progress as `[X/N]`.
- Uses the same `WINE_VERSION`/`WINE_ROOT`/`WINEPREFIX`/`DXVK_ROOT` values you
  used with `run.command` to uninstall the correct locations.

## Notes

- If Wine/DXVK/Steam are already present, `run.command` skips those steps.
- `SCRIPT_DIR` can be overridden via environment variable. When run inside the
  `.app` bundle, the launcher sets it to the directory containing the `.app` so
  the `WINEPREFIX` alias symlink lands next to the app bundle inside `Merlot Apps/`.
  Alias creation is best-effort; if `SCRIPT_DIR` is not writable it is skipped.

## Merlot App Bundles

`install_merlot.command` assembles `Merlot Apps/` in a temporary directory, then installs it into `/Applications/Merlot Apps`. This builder is unchanged from upstream.

### Structure

```
Merlot Apps/
  <APP_NAME>.app/
    Contents/
      Info.plist               # App metadata (Spotlight, Finder, Dock)
      MacOS/
        MerlotLauncher         # Shared launcher for all generated apps
      Resources/
        merlot.env             # Runtime env generated from merlot_configs/*.conf
        run.command            # Copied from repo root at install time
        AppIcon.icns           # Icon for that app
```

### How it works

1. `install_merlot.command` reads each `merlot_configs/*.conf` and generates one `.app` bundle per config.
2. It asks for `sudo`, replaces `/Applications/Merlot Apps`, and copies the freshly generated folder there.
3. Each bundle uses the shared `app/merlot/MerlotLauncher`, generated `Info.plist`, copied `run.command`, and an app-local `merlot.env`.
4. `MerlotLauncher` opens Terminal and runs the embedded `run.command` with the environment overrides listed in that app's `merlot.env`.
5. The launcher exports `SCRIPT_DIR` pointing to the directory containing the `.app`, so the shared `WINEPREFIX` alias symlink lands in `/Applications/Merlot Apps/`.

### Install

```bash
./install_merlot.command
```

To install only one config:

```bash
./install_merlot.command binding-of-isaac
```

To create a new config, copy the template:

```bash
cp merlot_configs/template.conf.example merlot_configs/my-game.conf
```

### Source files

- `app/merlot/MerlotLauncher` - shared launcher script for generated apps
- `app/merlot/AppIcon.icns` - app icon
- `merlot_configs/*.conf` - per-game launcher metadata and `run.command` environment overrides
- `merlot_configs/template.conf.example` - starting point for new game configs; not built by the script
- `install_merlot.command` - assembles and installs the `Merlot Apps/` folder
