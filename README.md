# Run Windows Steam games on Intel Mac (Wine + DXVK)

**Intel-Mac edition** of [ByMedion/macos-wine-steam](https://github.com/ByMedion/macos-wine-steam).
The original targets Apple Silicon (Rosetta + DXMT/GPTK). Those pieces are
Apple-Silicon-only, so this fork swaps them for the Intel-native path:

- **No Rosetta.** The Wine build is x86_64 and runs natively on Intel, so
  `run.command` never needs your password.
- **DXVK + MoltenVK** (DirectX 10/11 → Vulkan → Metal) replaces DXMT/GPTK.
  MoltenVK ships inside the Wine build, so AMD/Intel GPUs (e.g. Radeon Pro 570X)
  are supported.

For developer details, see the [Developer README](README_DEV.md).

## References & Credits

- Original project (Apple Silicon):
  [ByMedion/macos-wine-steam](https://github.com/ByMedion/macos-wine-steam)
- Wine builds used by this project:
  [Gcenx/macOS_Wine_builds](https://github.com/Gcenx/macOS_Wine_builds)
- DXVK for macOS:
  [Gcenx/DXVK-macOS](https://github.com/Gcenx/DXVK-macOS)

## Requirements

- An **Intel** Mac (`x86_64`). On Apple Silicon, use the original project instead.
- macOS 11 or newer (tested target: macOS 15 Sequoia on Intel).
- A Metal-capable GPU. AMD GPUs like the **Radeon Pro 570X** work well.
- ~8 GB free disk space and a working internet connection for the first run.

## Download

1. Click the green `Code` button, then `Download ZIP`.
2. Unzip the downloaded ZIP file (double-click it).

## Install / Run

### Simple: Spotlight-friendly launchers with game presets

#### Install:

1. In Finder, locate the unzipped folder.
2. Double-click `install_merlot.command`.
3. If macOS blocks it, right-click `install_merlot.command` -> `Open` -> confirm `Open`.
4. It installs `Merlot Apps` into `/Applications` (asks for your macOS password
   only to copy into `/Applications`).

#### Run:

1. Open one of the apps in `/Applications/Merlot Apps`, or find it in Spotlight:
   - `Steam (Merlot).app` to launch Steam without game-specific presets.
   - A game launcher, for example `Binding of Isaac (Merlot).app`, to use settings optimized for that game.
2. If macOS blocks it, right-click the app -> `Open` -> confirm `Open`.
3. After Steam launches, the Terminal window prints the Steam log path and can be closed. Steam stays running in the background. (Set `MERLOT_DETACH=0` if you prefer the old foreground behavior where closing Terminal kills Steam.)

`Merlot Apps` includes `Steam (Merlot).app` plus ready-made launchers for supported games in this repository.

**Optional advanced setup:**<br>
You can add your own config in `merlot_configs/` and run `install_merlot.command` again to create another launcher. See the [Developer README](README_DEV.md).

**What to expect:**
- The first launch can take a while because it downloads Wine, DXVK, and the Steam installer.
- At the end, Steam should launch inside Wine.
- Unlike the Apple Silicon version, **no Rosetta install and no password are needed to run** — only the one-time `/Applications` copy during install asks for a password.

### Advanced: Generic Steam launcher

1. In Finder, locate the unzipped folder.
2. Double-click `run.command`.
3. If macOS blocks it, right-click `run.command` -> `Open` -> confirm `Open`.
4. After Steam launches, the Terminal window prints the Steam log path and can be closed. Steam stays running in the background.

If you are familiar with Terminal and bash, you can also customize launch options described in the [Developer README](README_DEV.md).

## Choosing the graphics backend

- **DXVK (default, `USE_DXVK=1`)** — DirectX 10/11 → Vulkan → Metal. Best
  performance for modern games on your AMD GPU.
- **WineD3D (`USE_DXVK=0`)** — Wine's built-in OpenGL translation. Slower, but
  covers **DirectX 9** titles and is a good fallback when a game won't start
  under DXVK.

```bash
USE_DXVK=0 ./run.command      # use WineD3D instead of DXVK
```

## Memory auto-tuning

By default (`MERLOT_AUTO_TUNE=1`) `run.command` detects your Mac's RAM and GPU
VRAM at launch and writes a per-prefix `dxvk.conf` so games see accurate,
hardware-appropriate memory budgets instead of generic defaults:

- `dxgi.maxDeviceMemory` is set to your real VRAM, so games pick texture quality
  to match the GPU (e.g. the full 4 GB on a Radeon Pro 570X).
- `dxgi.maxSharedMemory` is scaled from your system RAM (a quarter of it,
  clamped to 1–8 GB), so low-RAM Macs aren't pushed into swap and high-RAM Macs
  aren't artificially starved.
- A tier is reported on launch: `low (<8 GB)`, `balanced (8–16 GB)`, or
  `high (≥16 GB)`.

It adapts automatically — a 16 GB or 32 GB Mac gets a larger shared-memory
budget without any changes. Override or disable it:

```bash
MERLOT_AUTO_TUNE=0 ./run.command                       # don't generate dxvk.conf
DXVK_MAX_DEVICE_MEMORY=4096 DXVK_MAX_SHARED_MEMORY=4096 ./run.command   # force values (MB)
```

If you set your own `DXVK_CONFIG_FILE`, auto-tuning steps aside and uses your file.

### General performance tips

- DXVK compiles shaders on first play, which causes brief stutter; it smooths
  out as the shader cache fills.
- On 8 GB Macs, quit other apps and prefer 1080p over 4K. Older/2D Steam games
  run great; heavy AAA titles are limited mostly by RAM and GPU, not by Wine.

## Stop

1. In Steam, use the menu: `Steam` -> `Exit`.
2. Wait until Steam fully closes.
3. You can close Terminal at any time (default `MERLOT_DETACH=1` detaches Steam from it).

## Uninstall

If Steam is running, follow the steps in "Stop" first.

1. Double-click `uninstall.command`.
2. If macOS blocks it, right-click `uninstall.command` -> `Open` -> confirm `Open`.
3. It may ask for your macOS password to remove `/Applications/Merlot Apps`.
4. It asks for confirmation per item. Type `y` to remove or `n` to keep it.

## Notes

- **Intel only.** Apple Silicon Macs should use the original project.
- This project does not change macOS system settings.

## What The Scripts Do (Short)

`run.command`:
- Verifies the Mac is Intel (`x86_64`). No Rosetta, no `sudo`.
- Downloads Wine (Gcenx macOS Wine builds, which bundle MoltenVK) and sets up a Steam Wine prefix.
- Downloads and installs Steam into that prefix.
- Downloads DXVK and enables it (or uses Wine's built-in WineD3D when `USE_DXVK=0`).

`uninstall.command`:
- Removes files/directories created by `run.command` (with per-item confirmation).
