#!/usr/bin/env bash
set -euo pipefail

# Intel-Mac edition of macos-wine-steam.
#
# Differences from the Apple Silicon original:
#   - Requires an Intel (x86_64) Mac. The Wine build runs natively, so there is
#     NO Rosetta step and run.command never needs sudo.
#   - DirectX is translated with DXVK (D3D10/D3D11 -> Vulkan -> Metal via the
#     MoltenVK that ships inside the Wine build) instead of DXMT/GPTK, which are
#     Apple-Silicon-only. Set USE_DXVK=0 to fall back to Wine's built-in
#     WineD3D (OpenGL) path, which also covers D3D9 but is slower.

SCRIPT_DIR="${SCRIPT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}"

WINE_VERSION="${WINE_VERSION:-11.10}"
# Gcenx publishes "staging" and "devel" osx64 builds; both bundle MoltenVK.
# Staging is the gaming-recommended flavor.
WINE_FLAVOR="${WINE_FLAVOR:-staging}"

WINE_ROOT="${WINE_ROOT:-$HOME/wine-${WINE_VERSION}}"
case "${WINE_FLAVOR}" in
  staging) WINE_APP_NAME="Wine Staging.app" ;;
  devel)   WINE_APP_NAME="Wine Devel.app" ;;
  stable)  WINE_APP_NAME="Wine Stable.app" ;;
  *) printf "Error: WINE_FLAVOR must be staging|devel|stable\n" >&2; exit 1 ;;
esac
WINE_APP="${WINE_ROOT}/${WINE_APP_NAME}"
WINE_BIN="${WINE_APP}/Contents/Resources/wine/bin/wine"

WINEPREFIX="${WINEPREFIX:-$HOME/.wine-steam-intel}"
STEAM_SETUP="/tmp/SteamSetup.exe"

# DXVK (DirectX -> Vulkan) backend. The macOS "builtin" variant ships
# i386-windows / x86_64-windows dll folders, just like DXMT did, so it slots
# into WINEDLLPATH_PREPEND. It provides d3d10core + d3d11; dxgi/d3d9 come from
# Wine's builtin libraries.
USE_DXVK="${USE_DXVK:-1}"                # 1=DXVK (default), 0=Wine builtin WineD3D
DXVK_RELEASE="${DXVK_RELEASE:-v1.10.3-20230507-repack}"
DXVK_DIR_NAME="dxvk-macOS-async-${DXVK_RELEASE}-builtin"
DXVK_ROOT="${DXVK_ROOT:-$HOME/DXVK}"

# Auto-tune DXVK memory reporting to this Mac's actual RAM/VRAM (1=on default).
# When on, run.command detects system memory and GPU VRAM and writes a per-prefix
# dxvk.conf so games see accurate, hardware-appropriate memory budgets.
MERLOT_AUTO_TUNE="${MERLOT_AUTO_TUNE:-1}"
# Optional manual overrides in MB. Empty = derive from detected hardware.
DXVK_MAX_DEVICE_MEMORY="${DXVK_MAX_DEVICE_MEMORY:-}"
DXVK_MAX_SHARED_MEMORY="${DXVK_MAX_SHARED_MEMORY:-}"

WINEPREFIX_ALIAS_NAME="${WINEPREFIX_ALIAS_NAME:-WINEPREFIX}"
WINE_RETINA_MODE="${WINE_RETINA_MODE:-0}" # 1=enable RetinaMode, 0=disable RetinaMode (Default)
# 1=detach Steam from the Terminal after launch so closing the window doesn't kill it (Default).
# 0=keep the original foreground behavior (Terminal window must stay open).
MERLOT_DETACH="${MERLOT_DETACH:-1}"
MERLOT_STEAM_LOG="${MERLOT_STEAM_LOG:-${TMPDIR:-/tmp}/merlot-steam.log}"
# Steam's CEF UI (login/library chrome) renders as a BLACK WINDOW under Wine on
# macOS unless CEF GPU acceleration is disabled. On by default; it only affects
# Steam's own 2D interface, never in-game (DXVK) rendering. Set to 0 to disable.
STEAM_CEF_DISABLE_GPU="${STEAM_CEF_DISABLE_GPU:-1}"
# Extra arguments appended to the Steam launch (advanced).
STEAM_LAUNCH_ARGS="${STEAM_LAUNCH_ARGS:-}"
# Default before we added this: the value is not set in registry (Wine internal default).
# Set to force|enable|disable to override, or leave empty to keep default.
WINE_MOUSE_WARP_OVERRIDE="${WINE_MOUSE_WARP_OVERRIDE:-}"

WINE_URL="https://github.com/Gcenx/macOS_Wine_builds/releases/download/${WINE_VERSION}/wine-${WINE_FLAVOR}-${WINE_VERSION}-osx64.tar.xz"
STEAM_URL="https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe"
DXVK_URL="https://github.com/Gcenx/DXVK-macOS/releases/download/${DXVK_RELEASE}/${DXVK_DIR_NAME}.tar.gz"

log() {
  printf "\n==> %s\n" "$1"
}

die() {
  printf "Error: %s\n" "$1" >&2
  exit 1
}

require_macos_x86_64() {
  log "Checking platform"
  [[ "$(uname -s)" == "Darwin" ]] || die "This script supports macOS only."
  if [[ "$(uname -m)" != "x86_64" ]]; then
    die "This is the Intel (x86_64) edition. On Apple Silicon use the original macos-wine-steam (DXMT/GPTK) project instead."
  fi
}

ensure_wine_installed() {
  log "Ensuring Wine ${WINE_FLAVOR} ${WINE_VERSION} is installed"
  if [[ -x "${WINE_BIN}" ]]; then
    echo "Wine already installed at ${WINE_APP}. Skipping."
    return
  fi

  mkdir -p "${WINE_ROOT}"
  curl -L --fail --retry 5 --retry-delay 1 "${WINE_URL}" | tar xJf - -C "${WINE_ROOT}"
  [[ -x "${WINE_BIN}" ]] || die "Wine binary not found after extraction: ${WINE_BIN}"
}

ensure_wineprefix_alias() {
  log "Ensuring local alias to WINEPREFIX"
  local alias_path="${SCRIPT_DIR}/${WINEPREFIX_ALIAS_NAME}"
  local alias_dir
  alias_dir="$(dirname "${alias_path}")"

  if [[ -e "${alias_path}" && ! -L "${alias_path}" ]]; then
    echo "Path exists and is not a symlink: ${alias_path}. Skipping alias creation."
    return
  fi

  if [[ -L "${alias_path}" ]]; then
    local current_target
    current_target="$(readlink "${alias_path}")"
    if [[ "${current_target}" == "${WINEPREFIX}" ]]; then
      echo "Alias is already up to date: ${alias_path} -> ${WINEPREFIX}"
      return
    fi
  fi

  if [[ ! -d "${alias_dir}" ]]; then
    echo "Alias directory does not exist: ${alias_dir}. Skipping alias creation."
    return
  fi

  if [[ ! -w "${alias_dir}" ]]; then
    echo "Alias directory is not writable: ${alias_dir}. Skipping alias creation."
    return
  fi

  if ! ln -sfn "${WINEPREFIX}" "${alias_path}"; then
    echo "Could not create alias at ${alias_path}. Continuing without it."
    return
  fi

  echo "Alias created: ${alias_path} -> ${WINEPREFIX}"
}

setup_wine_env() {
  export WINEPREFIX
  export PATH
  PATH="$(dirname "${WINE_BIN}"):${PATH}"
}

ensure_wine_prefix() {
  log "Ensuring Wine prefix for Steam"
  if [[ -f "${WINEPREFIX}/system.reg" ]]; then
    echo "Wine prefix already initialized at ${WINEPREFIX}. Skipping."
    return
  fi
  "${WINE_BIN}" wineboot --init
}

ensure_wine_mouse_warp_override() {
  local mode="${WINE_MOUSE_WARP_OVERRIDE}"
  if [[ -z "${mode}" ]]; then
    log "Restoring default Wine MouseWarpOverride"
    if "${WINE_BIN}" reg query "HKCU\\Software\\Wine\\DirectInput" /v MouseWarpOverride >/dev/null 2>&1; then
      "${WINE_BIN}" reg delete "HKCU\\Software\\Wine\\DirectInput" /v MouseWarpOverride /f >/dev/null 2>&1 || true
      echo "Removed MouseWarpOverride from registry (Wine default behavior)."
    else
      echo "MouseWarpOverride is not set. Skipping."
    fi
    return
  fi

  case "${mode}" in
    force|enable|disable) ;;
    *) die "WINE_MOUSE_WARP_OVERRIDE must be one of: force | enable | disable | (empty for default)" ;;
  esac

  log "Configuring Wine MouseWarpOverride=${mode}"
  local query_out
  query_out="$("${WINE_BIN}" reg query "HKCU\\Software\\Wine\\DirectInput" /v MouseWarpOverride 2>/dev/null || true)"
  if printf "%s" "${query_out}" | grep -Eiq "MouseWarpOverride[[:space:]]+REG_SZ[[:space:]]+${mode}"; then
    echo "MouseWarpOverride is already set to ${mode}. Skipping."
    return
  fi

  "${WINE_BIN}" reg add "HKCU\\Software\\Wine\\DirectInput" /v MouseWarpOverride /t REG_SZ /d "${mode}" /f >/dev/null
  echo "Set MouseWarpOverride=${mode}."
}

ensure_wine_retina_mode() {
  local enabled="$1"
  [[ "${enabled}" == "0" || "${enabled}" == "1" ]] || die "WINE_RETINA_MODE must be 0 or 1."

  local desired_value="n"
  if [[ "${enabled}" == "1" ]]; then
    desired_value="y"
  fi

  log "Configuring Wine RetinaMode=${desired_value}"
  local query_out
  query_out="$("${WINE_BIN}" reg query "HKCU\\Software\\Wine\\Mac Driver" /v RetinaMode 2>/dev/null || true)"
  if printf "%s" "${query_out}" | grep -Eiq "RetinaMode[[:space:]]+REG_SZ[[:space:]]+${desired_value}"; then
    echo "RetinaMode is already set to ${desired_value}. Skipping."
    return
  fi

  "${WINE_BIN}" reg add "HKCU\\Software\\Wine\\Mac Driver" /v RetinaMode /t REG_SZ /d "${desired_value}" /f >/dev/null
  echo "Set RetinaMode=${desired_value}."
}

ensure_wine_windows_mouse_accel_disabled() {
  log "Disabling Windows mouse acceleration in Wine"

  # Disable Windows "Enhanced Pointer Precision" (mouse acceleration) inside the prefix.
  # This is independent from macOS pointer acceleration.
  "${WINE_BIN}" reg add "HKCU\\Control Panel\\Mouse" /v MouseSpeed /t REG_SZ /d 0 /f >/dev/null
  "${WINE_BIN}" reg add "HKCU\\Control Panel\\Mouse" /v MouseThreshold1 /t REG_SZ /d 0 /f >/dev/null
  "${WINE_BIN}" reg add "HKCU\\Control Panel\\Mouse" /v MouseThreshold2 /t REG_SZ /d 0 /f >/dev/null

  echo "Set MouseSpeed=0, MouseThreshold1=0, MouseThreshold2=0."
}

find_steam_exe() {
  local steam32="${WINEPREFIX}/drive_c/Program Files (x86)/Steam/steam.exe"
  local steam64="${WINEPREFIX}/drive_c/Program Files/Steam/steam.exe"
  if [[ -f "${steam32}" ]]; then
    printf "%s\n" "${steam32}"
  elif [[ -f "${steam64}" ]]; then
    printf "%s\n" "${steam64}"
  fi
}

cleanup_steam_setup() {
  if [[ -f "${STEAM_SETUP}" ]]; then
    log "Cleaning up Steam installer cache"
    rm -f "${STEAM_SETUP}"
    echo "Removed ${STEAM_SETUP}."
  fi
}

ensure_steam_installed() {
  log "Ensuring Steam is installed in Wine prefix"
  local steam_exe
  steam_exe="$(find_steam_exe || true)"
  if [[ -n "${steam_exe}" ]]; then
    echo "Steam already installed at ${steam_exe}. Skipping installer."
    return
  fi

  if [[ ! -f "${STEAM_SETUP}" ]]; then
    echo "Downloading Steam installer..."
    curl -L --fail --retry 5 --retry-delay 1 -o "${STEAM_SETUP}" "${STEAM_URL}"
  fi

  echo "Launching Steam installer. Complete the wizard in the Wine window."
  "${WINE_BIN}" "${STEAM_SETUP}"

  steam_exe="$(find_steam_exe || true)"
  [[ -n "${steam_exe}" ]] || die "Steam installation appears incomplete (steam.exe not found)."
  cleanup_steam_setup
}

use_dxvk() {
  [[ "${USE_DXVK}" == "1" ]]
}

ensure_dxvk_installed() {
  log "Ensuring DXVK (${DXVK_RELEASE}) is installed"
  if [[ -d "${DXVK_ROOT}/i386-windows" && -d "${DXVK_ROOT}/x86_64-windows" ]]; then
    echo "DXVK already installed at ${DXVK_ROOT}. Skipping."
    return
  fi

  local tmp_dir
  tmp_dir="$(mktemp -d /tmp/dxvk.XXXXXX)"

  curl -L --fail --retry 5 --retry-delay 1 "${DXVK_URL}" | tar xzf - -C "${tmp_dir}"

  local payload_dir=""
  if [[ -d "${tmp_dir}/i386-windows" && -d "${tmp_dir}/x86_64-windows" ]]; then
    payload_dir="${tmp_dir}"
  elif [[ -d "${tmp_dir}/${DXVK_DIR_NAME}/i386-windows" && -d "${tmp_dir}/${DXVK_DIR_NAME}/x86_64-windows" ]]; then
    payload_dir="${tmp_dir}/${DXVK_DIR_NAME}"
  fi

  [[ -n "${payload_dir}" ]] || die "DXVK extraction failed: payload directories not found."

  mkdir -p "${DXVK_ROOT}"
  rm -rf "${DXVK_ROOT}/i386-windows" "${DXVK_ROOT}/x86_64-windows"
  cp -R "${payload_dir}/i386-windows" "${DXVK_ROOT}/"
  cp -R "${payload_dir}/x86_64-windows" "${DXVK_ROOT}/"
  rm -rf "${tmp_dir}"
}

detect_system_mem_mb() {
  local bytes
  bytes="$(sysctl -n hw.memsize 2>/dev/null || echo 0)"
  printf '%s\n' "$(( bytes / 1048576 ))"
}

detect_vram_mb() {
  # Parses lines like "VRAM (Total): 4 GB" or "VRAM (Dynamic, Max): 1536 MB".
  local line num unit
  line="$(system_profiler SPDisplaysDataType 2>/dev/null | awk -F': ' '/VRAM/ {print $2; exit}')"
  [[ -n "${line}" ]] || { printf '0\n'; return; }
  num="$(printf '%s' "${line}" | grep -oE '[0-9]+' | head -1)"
  unit="$(printf '%s' "${line}" | grep -oiE '[a-z]+' | head -1)"
  [[ -n "${num}" ]] || { printf '0\n'; return; }
  case "${unit}" in
    [Gg][Bb]) printf '%s\n' "$(( num * 1024 ))" ;;
    *)        printf '%s\n' "${num}" ;;
  esac
}

clamp_mb() {
  # clamp_mb <value> <min> <max>
  local v="$1" lo="$2" hi="$3"
  if (( v < lo )); then v="${lo}"; fi
  if (( v > hi )); then v="${hi}"; fi
  printf '%s\n' "${v}"
}

configure_dxvk_autotune() {
  if [[ "${MERLOT_AUTO_TUNE}" != "1" ]]; then
    log "DXVK auto-tune disabled (MERLOT_AUTO_TUNE=0)"
    return
  fi
  if [[ -n "${DXVK_CONFIG_FILE:-}" ]]; then
    log "Custom DXVK_CONFIG_FILE is set; skipping memory auto-tune"
    return
  fi

  log "Auto-tuning DXVK memory budget to this Mac"
  local ram_mb vram_mb dev_mb shared_mb tier
  ram_mb="$(detect_system_mem_mb)"
  vram_mb="$(detect_vram_mb)"
  (( ram_mb > 0 ))  || ram_mb=4096    # fallback if detection fails
  (( vram_mb > 0 )) || vram_mb=1536   # conservative VRAM fallback

  # Report true VRAM as device memory so games pick appropriate texture quality.
  dev_mb="${DXVK_MAX_DEVICE_MEMORY:-${vram_mb}}"
  # Shared (system) memory the GPU may spill into: a quarter of RAM, clamped, so
  # low-RAM Macs don't get pushed into swap while big-RAM Macs aren't starved.
  if [[ -n "${DXVK_MAX_SHARED_MEMORY}" ]]; then
    shared_mb="${DXVK_MAX_SHARED_MEMORY}"
  else
    shared_mb="$(clamp_mb "$(( ram_mb / 4 ))" 1024 8192)"
  fi

  if   (( ram_mb < 8192 ));  then tier="low (<8 GB)"
  elif (( ram_mb < 16384 )); then tier="balanced (8-16 GB)"
  else                            tier="high (>=16 GB)"
  fi

  local conf="${WINEPREFIX}/dxvk.conf"
  cat > "${conf}" <<EOF
# Auto-generated by run.command from detected hardware. To stop regenerating
# this, set MERLOT_AUTO_TUNE=0, or point DXVK_CONFIG_FILE at your own file.
# Detected: ${ram_mb} MB system RAM, ${vram_mb} MB VRAM  ->  tier: ${tier}
dxgi.maxDeviceMemory = ${dev_mb}
dxgi.maxSharedMemory = ${shared_mb}
d3d9.maxAvailableMemory = ${dev_mb}
EOF
  export DXVK_CONFIG_FILE="${conf}"
  echo "Detected ${ram_mb} MB RAM, ${vram_mb} MB VRAM -> tier: ${tier}"
  echo "dxgi.maxDeviceMemory=${dev_mb} MB, dxgi.maxSharedMemory=${shared_mb} MB, d3d9.maxAvailableMemory=${dev_mb} MB"
  echo "Wrote ${conf} and exported DXVK_CONFIG_FILE."
}

enable_dxvk_env() {
  log "Enabling DXVK via WINEDLLPATH_PREPEND"
  export WINEDLLPATH_PREPEND
  case ":${WINEDLLPATH_PREPEND:-}:" in
    *":${DXVK_ROOT}:"*) ;;
    *) WINEDLLPATH_PREPEND="${DXVK_ROOT}${WINEDLLPATH_PREPEND:+:${WINEDLLPATH_PREPEND}}" ;;
  esac

  # DXVK reads these directly when set by the caller (e.g. a game config):
  #   DXVK_HUD        e.g. "fps" or "full"
  #   DXVK_FRAME_RATE e.g. "60" to cap the frame rate
  #   DXVK_CONFIG_FILE / DXVK_CONFIG for advanced tuning
  [[ -n "${DXVK_HUD:-}" ]] && export DXVK_HUD
  [[ -n "${DXVK_FRAME_RATE:-}" ]] && export DXVK_FRAME_RATE
  [[ -n "${DXVK_CONFIG:-}" ]] && export DXVK_CONFIG
  [[ -n "${DXVK_CONFIG_FILE:-}" ]] && export DXVK_CONFIG_FILE

  export WINEDEBUG="${WINEDEBUG:--all,err+all}"
}

enable_wined3d_env() {
  log "Using Wine built-in WineD3D (DXVK disabled)"
  # Force Wine's builtin d3d libraries (OpenGL-backed). Slower than DXVK but
  # covers D3D9 and maximizes compatibility for troubleshooting.
  export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:-d3d9,d3d10core,d3d11,dxgi=b}"
  export WINEDEBUG="${WINEDEBUG:--all,err+all}"
  echo "WINEDLLOVERRIDES=${WINEDLLOVERRIDES}"
}

launch_steam() {
  log "Launching Steam"
  local steam_exe
  steam_exe="$(find_steam_exe || true)"
  [[ -n "${steam_exe}" ]] || die "steam.exe not found."

  local -a steam_cmd=("${WINE_BIN}" "${steam_exe}")
  if [[ "${STEAM_CEF_DISABLE_GPU}" == "1" ]]; then
    # Work around the black-window CEF rendering bug on macOS Wine.
    steam_cmd+=(-cef-disable-gpu -cef-disable-gpu-compositing)
  fi
  if [[ -n "${STEAM_LAUNCH_ARGS}" ]]; then
    # Word-split intentionally so callers can pass multiple flags.
    # shellcheck disable=SC2206
    steam_cmd+=(${STEAM_LAUNCH_ARGS})
  fi
  if [[ -n "${STEAM_GAME_ID:-}" ]]; then
    echo "Launching Steam game ${STEAM_GAME_ID}..."
    steam_cmd+=(-applaunch "${STEAM_GAME_ID}")
  fi

  case "${MERLOT_DETACH}" in
    0)
      "${steam_cmd[@]}"
      ;;
    1)
      log "Detaching Steam from this Terminal (log: ${MERLOT_STEAM_LOG})"
      : >"${MERLOT_STEAM_LOG}" || die "Cannot write to ${MERLOT_STEAM_LOG}"
      nohup "${steam_cmd[@]}" </dev/null >>"${MERLOT_STEAM_LOG}" 2>&1 &
      disown
      echo "Steam is running in the background (PID $!). Safe to close this Terminal window."
      echo "Tail the log with: tail -f ${MERLOT_STEAM_LOG}"
      ;;
    *)
      die "MERLOT_DETACH must be 0 or 1."
      ;;
  esac
}

main() {
  require_macos_x86_64
  ensure_wine_installed
  setup_wine_env
  ensure_wine_prefix
  ensure_wineprefix_alias
  ensure_wine_mouse_warp_override
  ensure_wine_retina_mode "${WINE_RETINA_MODE}"
  ensure_wine_windows_mouse_accel_disabled
  ensure_steam_installed
  if use_dxvk; then
    ensure_dxvk_installed
    configure_dxvk_autotune
    enable_dxvk_env
  else
    enable_wined3d_env
  fi
  launch_steam
}

main "$@"
