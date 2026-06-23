#!/bin/bash
# Stream.app entry point — focus existing Wine Steam, or cold-start once.
set -euo pipefail

APP="$(cd "$(dirname "$0")/../.." && pwd)"
SIKARUGIR="$(dirname "$0")/Sikarugir"
WINE_BIN="${APP}/Contents/SharedSupport/wine/bin"
WINE_SERVER="${WINE_BIN}/wineserver"
WINEPREFIX="${APP}/Contents/SharedSupport/prefix"
STEAM_UNIX="${WINEPREFIX}/drive_c/Program Files (x86)/Steam/steam.exe"
STARTUP="${APP}/Contents/Resources/Scripts/StartupScript"
FRAMEWORKS="${APP}/Contents/Frameworks"

export WINEPREFIX
export DYLD_FALLBACK_LIBRARY_PATH="${FRAMEWORKS}${DYLD_FALLBACK_LIBRARY_PATH:+:${DYLD_FALLBACK_LIBRARY_PATH}}"

launcher_lockfile() {
  local tmp encoded
  tmp="${TMPDIR:-/tmp}"
  encoded="$(printf '%s' "${APP}" | sed 's|/|xKWx|g')"
  printf '%s%s/lockfile' "${tmp}" "${encoded}"
}

remove_launcher_lock() {
  rm -f "$(launcher_lockfile)" 2>/dev/null || true
}

prefix_is_running() {
  [[ -x "${WINE_SERVER}" ]] && WINEPREFIX="${WINEPREFIX}" "${WINE_SERVER}" -p >/dev/null 2>&1
}

steam_is_running() {
  pgrep -f "${APP}/Contents/SharedSupport/prefix" >/dev/null 2>&1
}

focus_wine() {
  osascript <<'APPLESCRIPT' 2>/dev/null || true
tell application "System Events"
  if exists process "wine" then
    set frontmost of process "wine" to true
    try
      if (count of windows of process "wine") > 0 then
        perform action "AXRaise" of front window of process "wine"
      end if
    end try
  end if
end tell
APPLESCRIPT
}

# Already running — bring Wine/Steam to front; never relaunch or reinstall.
if prefix_is_running || steam_is_running; then
  focus_wine
  exit 0
fi

# Cold start: clear stale Sikarugir lock, then launch once.
remove_launcher_lock

if [[ -x "${STARTUP}" ]]; then
  STREAM_CONTENTSFOLD="${APP}/Contents" /bin/sh "${STARTUP}"
fi

exec "${SIKARUGIR}"
