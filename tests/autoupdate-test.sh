#!/bin/bash
# Scenario tests for auto_update. Only auto_update itself is extracted from steward.sh; every dependency
# (processes, network, binary, restart) is replaced by a fake, so the real service is never touched.
# Usage: autoupdate-test.sh [path to steward.sh]
set -u
here=$(cd "$(dirname "$0")" && pwd)
src=${1:-$here/../steward.sh}
W=$(mktemp -d /tmp/steward-au-test.XXXXXX)
trap 'rm -rf "$W"' EXIT
# shellcheck disable=SC2034 # these variables are used by the sourced auto_update()
RUN_DIR=$W CFG_DIR=$W INSTALL_LOG=$W/install.log NATIVE_BIN=fake_claude
eval "$(sed -n '/^AU_DONE=/,/^AU_NEXT=/p; /^auto_update() {/,/^}/p' "$src")"
declare -f auto_update >/dev/null || { echo "auto_update() not found in $src" >&2; exit 2; }

# Adjustable fake state
HOUR=9 NOW=1000000 INSTALLED=2.1.296 RUNNING=2.1.296 STABLE=2.1.308 BUSY=0 INSTALL_OK=1 RESTART_OK=1 CALLS=""
date() { case "$1" in +%F) echo 2026-10-23 ;; +%s) echo "$NOW" ;; +%-H) echo "$HOUR" ;; esac; }
timeout() { shift; "$@"; } # the real timeout cannot run a shell function
log() { :; }
claude_ok() { true; }
claude_ver() { cat "$W/installed"; }
running_ver() { [ -n "$RUNNING" ] && echo "$RUNNING"; }
sessions_busy() { ((BUSY)); }
curl() { [ -n "$STABLE" ] && echo "$STABLE"; }
# auto_update runs the installer in a subshell, so the install record must go to a file to be visible here
fake_claude() { printf 'install:%s ' "$2" >>"$W/calls"; ((INSTALL_OK)) && echo "$2" >"$W/installed"; }
cache_binary() { CALLS+="cache "; }
cmd_restart() { CALLS+="restart "; ((RESTART_OK)) && RUNNING=$(claude_ver); ((RESTART_OK)); }
notify_user() { CALLS+="notify "; }
reset() { rm -f "$AU_DONE" "$AU_NEXT" "$W/calls"; CALLS=""; echo "$INSTALLED" >"$W/installed"; }

fail=0 n=0
check() { # $1=description $2=expected call sequence $3=expected "done for today" marker (y/n)
  local d=n
  CALLS="$(cat "$W/calls" 2>/dev/null)$CALLS"
  rm -f "$W/calls"
  [ -f "$AU_DONE" ] && d=y
  n=$((n + 1))
  if [ "$CALLS" = "$2" ] && [ "$d" = "$3" ]; then
    [ -n "${VERBOSE:-}" ] && echo "ok    $1"
  else
    echo "FAIL  $1: calls='$CALLS' expected '$2'; done=$d expected $3"
    fail=$((fail + 1))
  fi
}

reset; HOUR=7; auto_update; check "07:00: does nothing" "" n
HOUR=9
reset; STABLE=2.1.296; auto_update; check "already current: marked done for today" "" y
reset; STABLE=2.1.290; auto_update; check "newer than stable: no downgrade" "" y
reset; STABLE=; auto_update; check "version lookup failed (offline): no action, retry in an hour" "" n
reset; STABLE=garbage; auto_update; check "malformed version string: no action" "" n
STABLE=2.1.308
reset; auto_update; check "new version, idle: install, cache, restart, notify" "install:2.1.308 cache restart notify " y
CALLS=""; NOW=$((NOW + 7200)); auto_update; check "second run on the same day: no action" "" y
INSTALLED=2.1.296 RUNNING=2.1.296
reset; BUSY=1; auto_update; check "sessions busy: install only, no restart" "install:2.1.308 cache " n
CALLS=""; NOW=$((NOW + 1800)); auto_update; check "30 minutes later: retry time not reached" "" n
CALLS=""; NOW=$((NOW + 1900)); auto_update; check "an hour later, still busy: no reinstall, no restart" "" n
CALLS=""; NOW=$((NOW + 3700)); BUSY=0; auto_update; check "idle again: no reinstall, restart to apply" "restart notify " y
INSTALLED=2.1.296 RUNNING=2.1.296
reset; INSTALL_OK=0; auto_update; check "install failed: no restart, not marked done" "install:2.1.308 " n
INSTALL_OK=1
reset; RESTART_OK=0; auto_update; check "restart failed: not marked done, no notification" "install:2.1.308 cache restart " n
RESTART_OK=1
reset; RUNNING=; auto_update; check "remote-control not running: no action" "" n
RUNNING=2.1.296

echo "autoupdate-test: $((n - fail))/$n passed"
((fail == 0))
