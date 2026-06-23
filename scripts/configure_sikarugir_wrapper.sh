#!/usr/bin/env bash
# Configure a Sikarugir (Wineskin) wrapper for DXVK + hardware-aware memory tuning
# + game storage on your Mac's main disk (not buried inside the .app bundle).
#
# Usage:
#   ./scripts/configure_sikarugir_wrapper.sh "/path/to/YourWrapper.app"
#   ./scripts/configure_sikarugir_wrapper.sh   # defaults to ~/Applications/Sikarugir/Stream.app
#
# Environment overrides:
#   GAMES_DIR  — where Steam game files live on macOS (default: ~/Games/SteamLibrary)
set -euo pipefail

WRAPPER="${1:-$HOME/Applications/Sikarugir/Stream.app}"
GAMES_DIR="${GAMES_DIR:-$HOME/Games/SteamLibrary}"
PLIST="${WRAPPER}/Contents/Info.plist"
PREFIX="${WRAPPER}/Contents/SharedSupport/prefix"
DOSDEV="${PREFIX}/dosdevices"
DXVK_SRC="${WRAPPER}/Contents/Frameworks/renderer/dxvk/wine"
STARTUP="${WRAPPER}/Contents/Resources/Scripts/StartupScript"
STEAM_WIN='C:\Program Files (x86)\Steam\steam.exe'
STEAM_UNIX="${PREFIX}/drive_c/Program Files (x86)/Steam/steam.exe"
STEAM_LIB_VDF="${PREFIX}/drive_c/Program Files (x86)/Steam/steamapps/libraryfolders.vdf"
STEAM_CFG_VDF="${PREFIX}/drive_c/Program Files (x86)/Steam/config/libraryfolders.vdf"
WIN_GAMES='D:\\'

die() {
  printf 'Error: %s\n' "$1" >&2
  exit 1
}

[[ -d "${WRAPPER}" ]] || die "Wrapper not found: ${WRAPPER}"
[[ -f "${PLIST}" ]] || die "Info.plist missing in wrapper"
[[ -d "${PREFIX}" ]] || die "Wine prefix missing in wrapper"

log() {
  printf '==> %s\n' "$1"
}

detect_ram_mb() {
  local bytes
  bytes="$(sysctl -n hw.memsize 2>/dev/null || echo 0)"
  printf '%s\n' "$(( bytes / 1048576 ))"
}

detect_vram_mb() {
  local line num unit
  line="$(system_profiler SPDisplaysDataType 2>/dev/null | awk -F': ' '/VRAM/ {print $2; exit}')"
  [[ -n "${line}" ]] || { printf '1536\n'; return; }
  num="$(printf '%s' "${line}" | grep -oE '[0-9]+' | head -1)"
  unit="$(printf '%s' "${line}" | grep -oiE '[a-z]+' | head -1)"
  [[ -n "${num}" ]] || { printf '1536\n'; return; }
  case "${unit}" in
    [Gg][Bb]) printf '%s\n' "$(( num * 1024 ))" ;;
    *)        printf '%s\n' "${num}" ;;
  esac
}

disk_free_bytes() {
  local dir="$1"
  mkdir -p "${dir}"
  df -k "${dir}" 2>/dev/null | awk 'NR==2 {print $4 * 1024}'
}

install_dxvk_dlls() {
  [[ -d "${DXVK_SRC}/x86_64-windows" && -d "${DXVK_SRC}/i386-windows" ]] \
    || die "DXVK renderer not found in wrapper: ${DXVK_SRC}"

  local sys32="${PREFIX}/drive_c/windows/system32"
  local wow64="${PREFIX}/drive_c/windows/syswow64"

  log "Installing DXVK DLLs into Wine prefix (activates GPU rendering)"
  cp -f "${DXVK_SRC}/x86_64-windows/"*.dll "${sys32}/"
  cp -f "${DXVK_SRC}/i386-windows/"*.dll "${wow64}/"
}

setup_games_storage() {
  mkdir -p "${GAMES_DIR}/steamapps/common" "${GAMES_DIR}/steamapps/downloading"
  log "Game storage folder: ${GAMES_DIR} ($(df -h "${GAMES_DIR}" | awk 'NR==2 {print $4}') free)"

  mkdir -p "${DOSDEV}"
  ln -sfn "${GAMES_DIR}" "${DOSDEV}/d:"
  log "Mapped Wine drive D: -> ${GAMES_DIR}"

  if [[ ! -f "${STEAM_UNIX}" ]]; then
    log "Steam not installed yet — storage ready; add library folder D:\\ in Steam after login"
    return
  fi

  local free_bytes
  free_bytes="$(disk_free_bytes "${GAMES_DIR}")"
  [[ -n "${free_bytes}" && "${free_bytes}" -gt 0 ]] || free_bytes=107374182400

  for vdf in "${STEAM_LIB_VDF}" "${STEAM_CFG_VDF}"; do
    [[ -f "${vdf}" ]] || continue
    if grep -q 'D:\\\\' "${vdf}" 2>/dev/null || grep -q 'D:\\' "${vdf}" 2>/dev/null; then
      log "Steam library D: already in $(basename "$(dirname "${vdf}")")/$(basename "${vdf}")"
      continue
    fi
    # Append a second library entry pointing at D:\ (your ~/Games/SteamLibrary).
    python3 - "${vdf}" "${WIN_GAMES}" "${free_bytes}" <<'PY'
import re, sys
path, win_path, free = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path, encoding="utf-8", errors="replace").read()
if re.search(r'"path"\s+"D:\\\\', text):
    sys.exit(0)
insert = f'''
\t"1"
\t{{
\t\t"path"\t\t"{win_path}"
\t\t"label"\t\t"Mac Games Drive"
\t\t"contentid"\t\t"1"
\t\t"totalsize"\t\t"{free}"
\t\t"update_clean_bytes_tally"\t\t"0"
\t\t"time_last_update_verified"\t\t"0"
\t\t"apps"
\t\t{{
\t\t}}
\t}}'''
text = text.rstrip()
if text.endswith('}'):
    text = text[:-1].rstrip() + insert + "\n}\n"
open(path, "w", encoding="utf-8").write(text)
PY
    log "Added Steam library ${WIN_GAMES} -> ${GAMES_DIR} in ${vdf##*/}"
  done
}

write_dxvk_conf() {
  local ram_mb="$1" vram_mb="$2" shared_mb="$3" conf="$4" header="$5"
  cat > "${conf}" <<EOF
${header}
# ${ram_mb} MB system RAM, ${vram_mb} MB VRAM, ${shared_mb} MB shared GPU budget
dxgi.maxDeviceMemory = ${vram_mb}
dxgi.maxSharedMemory = ${shared_mb}
d3d9.maxAvailableMemory = ${vram_mb}
EOF
}

log "Configuring ${WRAPPER}"

# Enable DXVK (disable Apple-Silicon-only backends).
/usr/libexec/PlistBuddy -c 'Set :DXVK 1' "${PLIST}"
/usr/libexec/PlistBuddy -c 'Set :D3DMETAL 0' "${PLIST}"
/usr/libexec/PlistBuddy -c 'Set :DXMT 0' "${PLIST}"
/usr/libexec/PlistBuddy -c 'Set :D9VK 0' "${PLIST}"
/usr/libexec/PlistBuddy -c 'Set :Try To Use GPU Info 1' "${PLIST}" 2>/dev/null || true
log "Enabled DXVK in Info.plist"

install_dxvk_dlls
setup_games_storage

if [[ -f "${STEAM_UNIX}" ]]; then
  /usr/libexec/PlistBuddy -c 'Set :Program\ Name\ and\ Path C:\\Program\ Files\ \(x86\)\\Steam\\steam.exe' "${PLIST}"
  log "Set main program to ${STEAM_WIN}"
else
  log "Steam not found in prefix yet — skipping Program Name and Path (install Steam first, then re-run)"
fi

mkdir -p "$(dirname "${STARTUP}")"
cat > "${STARTUP}" <<'SCRIPT'
#!/bin/sh
# Auto-generated by macos-wine-steam-intel/scripts/configure_sikarugir_wrapper.sh
# Detects this Mac's RAM/VRAM and writes dxvk.conf before Wine starts.
if [ -n "${STREAM_CONTENTSFOLD:-}" ]; then
  CONTENTSFOLD="${STREAM_CONTENTSFOLD}"
else
  cd "$(dirname "$0")/../.." || exit 0
  CONTENTSFOLD="$PWD"
fi
PREFIX="${CONTENTSFOLD}/SharedSupport/prefix"
CONF="${PREFIX}/dxvk.conf"

ram_mb=$(($(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1048576))
[ "${ram_mb}" -gt 0 ] || ram_mb=4096

vram_line=$(system_profiler SPDisplaysDataType 2>/dev/null | awk -F': ' '/VRAM/ {print $2; exit}')
vram_mb=1536
if [ -n "${vram_line}" ]; then
  vnum=$(printf '%s' "${vram_line}" | grep -oE '[0-9]+' | head -1)
  vunit=$(printf '%s' "${vram_line}" | grep -oiE '[a-z]+' | head -1)
  case "${vunit}" in
    [Gg][Bb]|[gG][bB]) vram_mb=$((vnum * 1024)) ;;
    *) [ -n "${vnum}" ] && vram_mb="${vnum}" ;;
  esac
fi

shared_mb=$((ram_mb / 4))
[ "${shared_mb}" -lt 1024 ] && shared_mb=1024
[ "${shared_mb}" -gt 8192 ] && shared_mb=8192

cat > "${CONF}" <<EOF
# Auto-generated at wrapper launch from this Mac's hardware.
# ${ram_mb} MB system RAM, ${vram_mb} MB VRAM, ${shared_mb} MB shared GPU budget
dxgi.maxDeviceMemory = ${vram_mb}
dxgi.maxSharedMemory = ${shared_mb}
d3d9.maxAvailableMemory = ${vram_mb}
EOF

export DXVK_CONFIG_FILE="${CONF}"
# Optional: uncomment to show FPS overlay in games
# export DXVK_HUD=fps
SCRIPT
chmod +x "${STARTUP}"
log "Installed memory-aware StartupScript"

STREAM_RUN="${WRAPPER}/Contents/MacOS/StreamRun"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cp -f "${SCRIPT_DIR}/stream_run_launcher.sh" "${STREAM_RUN}"
chmod +x "${STREAM_RUN}"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable StreamRun' "${PLIST}" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c 'Add :CFBundleExecutable string StreamRun' "${PLIST}"
log "Installed StreamRun launcher (focus running Steam or clear stale lock + start)"

ram_mb="$(detect_ram_mb)"
vram_mb="$(detect_vram_mb)"
shared_mb=$(( ram_mb / 4 ))
(( shared_mb < 1024 )) && shared_mb=1024
(( shared_mb > 8192 )) && shared_mb=8192

write_dxvk_conf "${ram_mb}" "${vram_mb}" "${shared_mb}" \
  "${PREFIX}/dxvk.conf" "# Auto-generated by configure_sikarugir_wrapper.sh"
log "Wrote ${PREFIX}/dxvk.conf (${ram_mb} MB RAM, ${vram_mb} MB VRAM, ${shared_mb} MB shared)"

printf '\nDone.\n'
printf '  Memory: games see %s MB VRAM + %s MB shared (from your %s MB RAM)\n' "${vram_mb}" "${shared_mb}" "${ram_mb}"
printf '  Storage: install games to D:\\  ->  %s\n' "${GAMES_DIR}"
printf '  Launch:  %s\n' "${WRAPPER}"
