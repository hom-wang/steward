#!/bin/bash
[ -f "$0" ] && grep -q $'\r' "$0" && { t=$(mktemp /tmp/.steward.XXXXXX) && tr -d '\r' <"$0" >"$t" && exec bash "$t" "$@"; } # If the file was saved with Windows line endings, convert it and re-run
#
# Steward - runs Claude Code as a resident service on an Unraid host, operated from your phone or browser via Remote Control.
# Does not depend on the array or on Docker: the service keeps running while the array is stopped.
#
# Copyright (c) 2026 hom-wang (https://github.com/hom-wang)
# Steward is an independent, community-maintained project. It is not affiliated with, endorsed by,
# or sponsored by Anthropic PBC or Lime Technology, Inc. "Claude" and "Claude Code" are trademarks of
# Anthropic PBC; "Unraid" is a trademark of Lime Technology, Inc. This tool downloads the unmodified
# Claude Code binary from Anthropic's release server, pinned to one version and checked against its published SHA256, and runs it as a background service. You sign
# in with your own Claude subscription through Anthropic's own login flow; Steward never sees, stores,
# or forwards your credentials, and all usage is billed to your own account.
#
# Requires: Unraid 7.3 or later with Internal Boot (/boot is ZFS). USB (FAT) boot is not supported.
# Pick one install method (do not install both):
#   Plugin: install steward.plg (which bundles this script) via Plugins -> Install Plugin in the webGUI,
#           then operate it under Settings -> Steward; steward <command> in a terminal works too.
#   Script: bash steward.sh install        then just run steward <command>
# Upgrading from the old name claude-unraid: just install; data is moved automatically from /boot/claude-code to /boot/steward,
#   the old path is kept as a symlink, and the old hooks and old plugin files are removed.
#
# Where things live
#   /boot/steward/           on the boot drive, still there while the array is stopped
#     steward.sh           this script
#     steward.conf         service parameters
#     home/                      Claude Code's config directory: login credentials, settings.json, CLAUDE.md, conversation history
#     workspace/                 working directory for Remote Control
#     cache/                     backup of the Claude Code binary; restored to RAM at boot, no network needed
#   Deliberately not under /boot/config: Unraid Connect's flash backup uploads the whole config/ to the cloud,
#   and login credentials should not go with it. /boot/config only holds hooks with nothing secret in them:
#     one line in stop, plugins/dynamix/steward.cron (watchdog),
#     plus one line in go (script install) or plugins/steward.plg (plugin install).
#   The webGUI's local Flash Backup zips the whole boot drive, which includes this directory; treat that zip as a secret.
#   The binary itself lives in RAM (/root/.local/share/claude). In remote-control mode Claude Code does not update itself,
#   so the watchdog checks once a day after 08:00 and restarts to apply the update only when no session is in use (see auto_update).

set -u
STEWARD_VERSION="2026.10.26"
SPIN_PID="" SPIN_FILE="" SPIN_MSG="" SPIN_T0=0 SPIN_ACTIVE=0 SPIN_OWNER=$$ FANCY=0 TTY_FD=2 HOLD_WINDOW=0
cleanup() { # every exit path ends up here, including Ctrl+C and the terminal being closed
  if [ -n "$SPIN_PID" ]; then # progress display still running: stop it and wipe that line
    kill "$SPIN_PID" 2>/dev/null
    wait "$SPIN_PID" 2>/dev/null
    ((FANCY)) && printf '\r\033[K' >&"$TTY_FD"
  fi
  [ -n "$SPIN_FILE" ] && rm -f "$SPIN_FILE" "$SPIN_FILE.new"
  rm -f "/tmp/.steward-install.$$".* 2>/dev/null
  case "$0" in /tmp/.steward.*) rm -f "$0" ;; esac
  if ((HOLD_WINDOW)) && [ -t 0 ]; then # terminal window opened from the settings page: pause, otherwise the result vanishes as soon as the program exits
    printf '\nYou can close this window now (press any key)' >&"$TTY_FD"
    read -r -n 1 -s _
  fi
  return 0
}
trap cleanup EXIT
trap 'exit 130' INT

P="${STEWARD_TEST_ROOT:-}" # fake root for tests only; empty in production
ROOT="$P/boot/steward"
SELF="$ROOT/steward.sh"
CONF="$ROOT/steward.conf"
CFG_DIR="$ROOT/home"
WORKSPACE="$ROOT/workspace"
CACHE="$ROOT/cache"
ENABLED="$ROOT/enabled" # this file exists = start automatically at boot
GO="$P/boot/config/go"
STOP="$P/boot/config/stop"
CRON="$P/boot/config/plugins/dynamix/steward.cron"
PLUGIN_DIR="$P/usr/local/emhttp/plugins/steward"
BIN_DIR="$P/usr/local/bin"
RUN_DIR="$P/var/run"
LOG="$P/var/log/steward.log"
PIDFILE="$RUN_DIR/steward.pid"
LOCKFILE="$RUN_DIR/steward.lock"
DOWN_FLAG="$RUN_DIR/steward.shutdown" # shutting down: do not bring the service back up
ARRAY_MNT="$P/mnt"
TAG="STEWARD_SVC" # every process under the service carries this env var; that is how we identify them
[ -n "$P" ] && TAG="STEWARD_SVC_TEST" # fake-root tests: use a different tag so tagged_pids / kill_tagged never touch the real service
MARK="# steward"
PLG="$P/boot/config/plugins/steward.plg"   # this file exists = installed via the plugin
INSTALL_LOG="$RUN_DIR/steward.install.log" # most recent output of the Claude Code download or update
JOBLOG="$RUN_DIR/steward.job.log"          # jobs triggered by settings-page buttons write their output here for the web page to read
JOBLOCK="$RUN_DIR/steward.job.lock"
PLUGIN=0
[ -f "$PLG" ] && PLUGIN=1

export HOME="$P/root"
export CLAUDE_CONFIG_DIR="$CFG_DIR"
export PATH="$BIN_DIR:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$HOME/.local/bin"
case "${LC_ALL:-${LANG:-}}" in *[Uu][Tt][Ff]*) ;; *) export LANG=en_US.UTF-8 ;; esac # the boot script's environment has no locale; en_US.UTF-8 is the only UTF-8 locale Unraid ships (C.UTF-8 does not exist and makes perl/virsh warn)
NATIVE_BIN="$HOME/.local/bin/claude"
VERSIONS="$HOME/.local/share/claude/versions"
# Where Claude Code releases come from, and the one version a fresh install downloads. The binary is only installed if its
# SHA256 matches the pinned value below (taken from Anthropic's published manifest for that version). Both values are
# updated with each Steward release; later updates go through Claude Code's own updater and are checked against the manifest.
CLAUDE_RELEASES="https://downloads.claude.ai/claude-code-releases"
CLAUDE_PLATFORM="linux-x64"
CLAUDE_PIN_VERSION="2.1.308"
CLAUDE_PIN_SHA256="356733f185fa988e6bf3aa9a555269fdd167982a2e2a80d3c8a78037bb92ad58"

if [ -n "${STEWARD_TEST_FAST:-}" ]; then TICK=2 BASE=1 HEALTHY=4 NETWAIT=1 BEAT=2; else TICK=600 BASE=5 HEALTHY=300 NETWAIT=10 BEAT=10; fi

# The progress animation is drawn only on an interactive terminal; when output goes to a file or pipe, print one line per step instead.
# Keep a separate copy of the terminal in TTY_FD: if Ctrl+C is pressed while a step's stderr is temporarily redirected to the log, cleanup still has to be able to wipe that line
if [ -t 1 ] && [ -t 2 ] && [ "${TERM:-dumb}" != dumb ]; then
  FANCY=1
  exec {TTY_FD}>&2
fi
SPIN_FRAMES='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' OK_MARK='✔' BAD_MARK='✘' PLAIN=0
case "${TERM:-}" in linux | vt[0-9]*) PLAIN=1 ;; esac # local console attached to a screen: its font lacks these glyphs
[ "${#SPIN_FRAMES}" -le 10 ] || PLAIN=1              # when the locale is not UTF-8, that string is counted as 30 bytes
if ((PLAIN)); then SPIN_FRAMES='|/-'"\\" OK_MARK='*' BAD_MARK='x'; fi

RC_ARGS=(--spawn same-dir --capacity 4)
# shellcheck disable=SC1090
[ -f "$CONF" ] && . <(tr -d '\r' <"$CONF")

say() { printf '%s\n' "$*"; }
warn() { printf 'Warning: %s\n' "$*" >&2; }
err() { printf 'Error: %s\n' "$*" >&2; }
die() {
  [ -n "$SPIN_PID" ] && spin_stop clear
  err "$*"
  exit 1
}
log() {
  printf '%s [steward] %s\n' "$(date '+%F %T')" "$*" >>"$LOG" 2>/dev/null
  [ -z "$P" ] && { logger -t steward -- "$*" 2>/dev/null || true; } # fake-root tests do not write to syslog
  return 0
}
strip_ansi() { sed -u -e 's/\x1b\[[0-9;?]*[A-Za-z]//g' -e 's/\x1b\][^\x07\x1b]*\(\x07\|\x1b\\\)//g' -e 's/\r/\n/g'; }

notify_user() { # $1=subject $2=body $3=level (default warning). Uses Unraid's built-in notifications, which forward to the email / Telegram etc. you configured
  local n="$P/usr/local/emhttp/webGui/scripts/notify"
  [ -x "$n" ] && "$n" -e "Steward" -s "$1" -d "$2" -i "${3:-warning}" >/dev/null 2>&1
  log "Notification: $1 - $2"
}

# ───────────────────────── Progress display while waiting ─────────────────────────
# Usage: spin_start "message" -> do the work (spin_msg can change the text along the way) -> spin_stop ok|fail|clear ["final message"]
# The work runs in the foreground and the progress is drawn in the background, so Ctrl+C interrupts the command that is actually running and leaves nothing running in the background.
# With a terminal, draw the animation. Without one (plugin install window, settings-page job log, output redirected to a file) print one line per step,
# and for long steps add a line every 10 seconds so people know it is still running.

spin_extra() { # $1=path(s) to measure (may be empty or several). Prints a note like "  123 MB  45 s"
  local sz=0 secs=$((SECONDS - SPIN_T0)) out=""
  # shellcheck disable=SC2086
  [ -n "$1" ] && sz=$(du -sm $1 2>/dev/null | awk '{s += $1} END {print s + 0}')
  ((${sz:-0} > 0)) && out="  $sz MB"
  ((secs >= 3)) && out="$out  $secs s"
  printf '%s' "$out"
}

spin_loop() { # background loop. Quits on its own once the shell that started it is gone, so it never keeps scribbling on the terminal
  trap 'kill ${!:-} 2>/dev/null; exit 0' TERM
  local i=0 n=${#SPIN_FRAMES} msg="" path="" line="" cols a
  if ((!FANCY)); then
    while
      sleep "$BEAT" >/dev/null 2>&1 & # sleep gets no output: if it is orphaned, whatever reads this pipe will not hang waiting on it
      wait $!
      [ -e "$SPIN_FILE" ] && [ -d "/proc/$SPIN_OWNER" ]
    do
      { IFS= read -r msg && IFS= read -r path; } 2>/dev/null <"$SPIN_FILE"
      say "  $msg, still running$(spin_extra "$path")"
    done
    return 0
  fi
  sleep 0.4 >/dev/null 2>&1 &
  wait $! # steps that finish in under half a second are not drawn, to avoid a flicker
  while [ -e "$SPIN_FILE" ] && [ -d "/proc/$SPIN_OWNER" ]; do
    if ((i % 10 == 0)); then # text refreshes once a second
      { IFS= read -r msg && IFS= read -r path; } 2>/dev/null <"$SPIN_FILE"
      line="$msg$(spin_extra "$path")"
      cols=$(stty size <&"$TTY_FD" 2>/dev/null | cut -d' ' -f2) # order matters: attach stdin to the terminal first, then discard the error message
      a=${line//[^[:ascii:]]/} # ASCII counts as 1 column, CJK as 2. Truncate past the window width; wrapping would garble the display
      while [ -n "$line" ] && ((${#a} + 2 * (${#line} - ${#a}) > ${cols:-80} - 3)); do
        line=${line%?}
        a=${line//[^[:ascii:]]/}
      done
    fi
    printf '\r\033[K\033[36m%s\033[0m %s' "${SPIN_FRAMES:i%n:1}" "$line" >&"$TTY_FD"
    i=$((i + 1))
    sleep 0.1 >/dev/null 2>&1 &
    wait $!
  done
}

spin_start() { # spin_start [-t] "in-progress message". -t is for short query-type waits: leaves no trace when done
  local transient=0
  if [ "${1:-}" = -t ]; then
    transient=1
    shift
  fi
  SPIN_MSG=$1 SPIN_T0=$SECONDS SPIN_ACTIVE=$((1 - transient)) SPIN_OWNER=$BASHPID SPIN_FILE="" SPIN_PID=""
  if ((!FANCY)); then
    ((transient)) && return 0
    say "... $1"
  fi
  SPIN_FILE=$(mktemp /tmp/.steward-spin.XXXXXX 2>/dev/null) || SPIN_FILE=""
  [ -n "$SPIN_FILE" ] || return 0
  printf '%s\n' "$1" >"$SPIN_FILE"
  spin_loop &
  SPIN_PID=$!
}

spin_msg() { # spin_msg "new message" [path]. With a path, also show how many MB it currently occupies, so you can tell whether a download is moving
  ((SPIN_ACTIVE)) || return 0
  ((FANCY)) || say "... $1"
  [ -n "$SPIN_FILE" ] && printf '%s\n%s\n' "$1" "${2:-}" >"$SPIN_FILE.new" 2>/dev/null && mv -f "$SPIN_FILE.new" "$SPIN_FILE" 2>/dev/null
  return 0
}

spin_stop() { # spin_stop ok|fail|clear ["final message"]
  local how=${1:-ok} msg=${2:-$SPIN_MSG} secs=$((SECONDS - SPIN_T0)) took=""
  if [ -n "$SPIN_PID" ]; then
    kill "$SPIN_PID" 2>/dev/null
    wait "$SPIN_PID" 2>/dev/null
    ((FANCY)) && printf '\r\033[K' >&"$TTY_FD"
  fi
  [ -n "$SPIN_FILE" ] && rm -f "$SPIN_FILE" "$SPIN_FILE.new"
  SPIN_PID="" SPIN_FILE="" SPIN_ACTIVE=0
  ((secs >= 3)) && took=" ($secs s)"
  case "$how" in
  ok) if ((FANCY)); then printf '\033[32m%s\033[0m %s%s\n' "$OK_MARK" "$msg" "$took"; else say "$OK_MARK $msg$took"; fi ;;
  fail) if ((FANCY)); then printf '\033[31m%s\033[0m %s\n' "$BAD_MARK" "$msg" >&2; else printf '%s %s\n' "$BAD_MARK" "$msg" >&2; fi ;;
  esac
  return 0
}

# ───────────────────────── Process management ─────────────────────────

tagged_pids() { # every process started by the service. Identified by the env var, so it does not matter if a process calls setsid or gets adopted by init
  local f
  grep -lszxF "$TAG=1" /proc/[0-9]*/environ 2>/dev/null | while IFS= read -r f; do
    f=${f#/proc/}
    f=${f%/environ}
    [ "$f" = "$$" ] || echo "$f"
  done
}

kill_tagged() { # $1=seconds to wait. TERM first, KILL only on timeout
  local grace=$1 pids i
  pids=$(tagged_pids)
  [ -z "$pids" ] && return 0
  # shellcheck disable=SC2086
  kill -TERM $pids 2>/dev/null
  for ((i = 0; i < grace * 10; i++)); do
    [ -z "$(tagged_pids)" ] && return 0
    sleep 0.1
  done
  pids=$(tagged_pids)
  # shellcheck disable=SC2086
  [ -n "$pids" ] && kill -KILL $pids 2>/dev/null
  return 0
}

sup_pid() { # print the running supervisor's pid; return 1 if it is not running
  local pid
  pid=$(cat "$PIDFILE" 2>/dev/null) || return 1
  [[ $pid =~ ^[0-9]+$ ]] && [ -r "/proc/$pid/cmdline" ] || return 1
  tr '\0' ' ' 2>/dev/null <"/proc/$pid/cmdline" | grep -q -- ' _supervise' || return 1
  echo "$pid"
}

close_fds() { # call in the subshell that is about to exec into a background process: do not inherit the caller's open files other than 0, 1, 2 (and the one given in $1)
  local fd keep=${1:-}
  for fd in /proc/"$BASHPID"/fd/*; do
    fd=${fd##*/}
    [[ $fd =~ ^[0-9]+$ ]] || continue
    ((fd <= 2 || fd == 255)) && continue
    [ "$fd" = "$keep" ] && continue
    eval "exec $fd>&-"
  done 2>/dev/null
  return 0
}

launch() {
  [ -n "$P" ] && { log "Test mode (STEWARD_TEST_ROOT): not starting the service"; return 0; } # never start real processes inside the fake root
  sup_pid >/dev/null && return 0
  [ -f "$SELF" ] || return 1
  kill_tagged 15 # supervisor is gone but leftover processes remain (e.g. it was killed unexpectedly): clear them first, so two remote-controls do not fight over the same directory
  # cd /: the supervisor must not inherit the caller's working directory; if that is under /mnt it would block the array.
  # exec: leave no intermediate shell holding the caller's terminal
  (
    cd / || exit 1
    close_fds # when started from the web page the caller is php-fpm; its connection must not be held by the resident process
    exec env "$TAG=1" setsid bash "$SELF" _supervise </dev/null >/dev/null 2>&1
  ) &
  local i
  for ((i = 0; i < 50; i++)); do
    sup_pid >/dev/null && return 0
    sleep 0.1
  done
  return 1
}

rotate_log() { # claude writes the log in append mode, so it can simply be truncated; /var/log is in RAM and must not be allowed to grow
  local sz
  sz=$(stat -c %s "$LOG" 2>/dev/null || echo 0)
  if ((sz > 2097152)); then
    cp -f "$LOG" "$LOG.1" 2>/dev/null
    : >"$LOG"
  fi
}

fail_hint() {
  local last
  last=$(tail -n 40 "$LOG" 2>/dev/null | strip_ansi | grep -v '\[steward\]' |
    grep -a -i -E 'error|not trusted|logged in|login|subscription|token|enable remote control' | tail -n1 | cut -c1-200)
  case "$last" in
  "") echo "Run steward status to see why" ;;
  *ogin* | *"logged in"* | *subscription* | *token* | *"not trusted"* | *"nable Remote Control"*)
    echo "$last / Run in the Unraid terminal: steward setup" ;;
  *) echo "$last / The service keeps retrying; run steward logs for details" ;;
  esac
}

supervise() { # resident loop: restart when claude remote-control exits, backing off gradually on repeated failures
  cd "$ROOT" 2>/dev/null || cd /
  exec 9>"$LOCKFILE"
  flock -n 9 || exit 0
  echo "$$" >"$PIDFILE"
  log "Service started (supervisor pid $$)"
  # child processes always close fd 9, otherwise they keep holding the lock after the supervisor dies and a new one cannot start
  (while sleep "$TICK"; do
    rotate_log
    cache_binary
  done) 9>&- &
  local fails=0 notified=0 t0 ran rc delay
  while [ -f "$ENABLED" ] && [ ! -f "$DOWN_FLAG" ]; do
    if ! cd "$WORKSPACE" 2>/dev/null; then
      log "Cannot enter $WORKSPACE, retrying in 60 s"
      sleep 60 9>&-
      continue
    fi
    if ! claude_ok && ! ensure_binary 9>&-; then
      log "Claude Code is unusable, retrying in 60 s"
      sleep 60 9>&-
      continue
    fi
    rotate_log
    t0=$SECONDS
    "$NATIVE_BIN" remote-control "${RC_ARGS[@]}" </dev/null >>"$LOG" 2>&1 9>&-
    rc=$?
    ran=$((SECONDS - t0))
    [ -f "$ENABLED" ] && [ ! -f "$DOWN_FLAG" ] || break
    if ((ran >= HEALTHY)); then
      fails=0
      notified=0
    else
      fails=$((fails + 1))
    fi
    delay=$((BASE << (fails > 6 ? 6 : (fails > 0 ? fails - 1 : 0)))) # 5,10,20,40,80,160 s...
    ((delay > 300)) && delay=300
    log "remote-control exited (exit $rc, ran $ran s), restarting in $delay s"
    if ((fails >= 6 && notified == 0)); then
      notified=1
      notify_user "Remote Control keeps failing to start" "$(fail_hint)"
    fi
    sleep "$delay" 9>&-
  done
  log "Service stopped"
  rm -f "$PIDFILE"
}

on_array_stop() { # the array is about to stop: if a process under the service is stuck in /mnt (working directory or open file), end it, otherwise the array cannot unmount
  local pid victims=""
  for pid in $(tagged_pids); do
    if readlink "/proc/$pid/cwd" "/proc/$pid/exe" /proc/"$pid"/fd/* 2>/dev/null | grep -q "^$ARRAY_MNT/"; then
      victims="$victims $pid"
    fi
  done
  [ -z "$victims" ] && return 0
  log "Array stopping, ending processes holding $ARRAY_MNT: $victims"
  # shellcheck disable=SC2086
  kill -TERM $victims 2>/dev/null
  local i left
  for ((i = 0; i < 10; i++)); do # emhttpd waits for this script to finish, so wait at most 2 seconds
    left=""
    for pid in $victims; do
      grep -qszxF "$TAG=1" "/proc/$pid/environ" 2>/dev/null && left="$left $pid"
    done
    [ -z "$left" ] && return 0
    sleep 0.2
  done
  # shellcheck disable=SC2086
  kill -KILL $left 2>/dev/null
  return 0
}

# ───────────────────────── Claude Code binary ─────────────────────────

claude_ok() { [ -x "$NATIVE_BIN" ] && "$NATIVE_BIN" --version >/dev/null 2>&1; }
claude_ver() { "$NATIVE_BIN" --version 2>/dev/null | awk '{print $1; exit}'; }

file_sha256() { sha256sum "$1" 2>/dev/null | awk '{print $1; exit}'; }
manifest_sha256() { # $1=version. The SHA256 Anthropic publishes for this platform and version, or nothing if it cannot be fetched
  curl -fsS --max-time 20 "$CLAUDE_RELEASES/$1/manifest.json" 2>/dev/null |
    jq -r --arg p "$CLAUDE_PLATFORM" '.platforms[$p].checksum // empty' 2>/dev/null | grep -E '^[0-9a-f]{64}$'
}
other_version() { # $1=version to exclude. The newest other installed version, or nothing
  find "$VERSIONS" -maxdepth 1 -type f -name '[0-9]*' ! -name "$1" ! -name '.*' 2>/dev/null | sed 's|.*/||' | sort -V | tail -n1
}

verify_installed() { # $1=version that Claude Code's own updater just installed. Compare it with the published checksum; on mismatch remove it and point the launcher back
  local f="$VERSIONS/$1" want got prev
  want=$(manifest_sha256 "$1")
  got=$(file_sha256 "$f")
  if [ -n "$want" ] && [ "$got" = "$want" ]; then
    log "Claude Code $1 matches the published SHA256"
    return 0
  fi
  if [ -z "$want" ]; then
    log "Claude Code $1: could not fetch the published SHA256, so it is not kept; retrying later"
  else
    log "Claude Code $1 does NOT match the published SHA256 (expected $want, got $got); removed"
    notify_user "Claude Code $1 failed verification" "The downloaded binary did not match the checksum Anthropic publishes for this version and was removed. The previous version stays in use. See $LOG"
  fi
  rm -f "$f"
  prev=$(other_version "$1")
  if [ -n "$prev" ]; then ln -sfn "$VERSIONS/$prev" "$NATIVE_BIN"; else rm -f "$NATIVE_BIN"; fi
  return 1
}

cache_binary() { # back up the version currently in use to the boot drive, with its SHA256; after an update this follows along
  local cur ver
  cur=$(readlink -f "$NATIVE_BIN" 2>/dev/null) || return 0
  ver=${cur##*/}
  [[ $ver =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || return 0
  [ -f "$CACHE/claude-$ver" ] && return 0
  [ "$("$cur" --version 2>/dev/null | awk '{print $1; exit}')" = "$ver" ] || return 0 # do not keep a half-downloaded file
  spin_msg "Backing up Claude Code $ver to the boot drive"
  mkdir -p "$CACHE"
  if cp -f "$cur" "$CACHE/.tmp.$$" && mv -f "$CACHE/.tmp.$$" "$CACHE/claude-$ver" && file_sha256 "$CACHE/claude-$ver" >"$CACHE/claude-$ver.sha256"; then
    find "$CACHE" -maxdepth 1 -type f -name 'claude-*' ! -name "claude-$ver" ! -name "claude-$ver.sha256" -delete
    log "Backed up Claude Code $ver to the boot drive"
  else
    rm -f "$CACHE/.tmp.$$" "$CACHE/claude-$ver.sha256"
    log "Backing up Claude Code $ver failed (boot drive out of space?)"
  fi
}

restore_binary() { # restore from the boot drive into the native install layout (versions/<version> plus the launcher shortcut). No network needed
  local f ver tmp want
  f=$(find "$CACHE" -maxdepth 1 -type f -name 'claude-*' ! -name '*.sha256' 2>/dev/null | sort -V | tail -n1)
  [ -n "$f" ] || return 1
  spin_msg "Restoring Claude Code from the boot drive"
  ver=${f##*/claude-}
  # the backup must still match the checksum recorded when it was made; the pinned version must match the pinned value
  want=$(cat "$f.sha256" 2>/dev/null)
  [ "$ver" = "$CLAUDE_PIN_VERSION" ] && want=$CLAUDE_PIN_SHA256
  if [ -n "$want" ] && [ "$(file_sha256 "$f")" != "$want" ]; then
    log "The backup of Claude Code $ver on the boot drive does not match its SHA256; discarding it"
    rm -f "$f" "$f.sha256"
    return 1
  fi
  tmp="$HOME/.local/share/claude/.restore.$$"
  mkdir -p "$VERSIONS" "${NATIVE_BIN%/*}"
  if ! { cp -f "$f" "$tmp" && chmod 755 "$tmp" && mv -f "$tmp" "$VERSIONS/$ver"; }; then
    rm -f "$tmp"
    return 1
  fi
  ln -sfn "$VERSIONS/$ver" "$NATIVE_BIN"
  [ "$(claude_ver)" = "$ver" ] && return 0
  # the restored file does not run. Only when it is identical to the backup does that mean the backup itself is broken: discard it and fall back to downloading
  cmp -s "$f" "$VERSIONS/$ver" && rm -f "$f" "$f.sha256"
  rm -f "$VERSIONS/$ver" "$NATIVE_BIN"
  return 1
}

download_binary() { # download the pinned Claude Code version straight from Anthropic's release server and install it only if its SHA256 matches the pinned value.
  # Only reached on first install, or when the backup on the boot drive is gone. Returns 75 = another download is in progress
  local rc
  (
    flock -n 8 || exit 75
    local i tmp sum
    : >"$INSTALL_LOG"
    spin_msg "Connecting to downloads.claude.ai"
    for ((i = 0; i < 30; i++)); do # the network may not be up yet early in boot; wait up to 5 minutes
      curl -fsS --max-time 10 -o /dev/null "$CLAUDE_RELEASES/$CLAUDE_PIN_VERSION/manifest.json" >>"$INSTALL_LOG" 2>&1 && break
      ((i == 0)) && spin_msg "Waiting for network, retrying every $NETWAIT s (up to 5 minutes)"
      sleep "$NETWAIT"
    done
    ((i < 30)) || { echo "downloads.claude.ai is not reachable" >>"$INSTALL_LOG"; exit 1; }
    mkdir -p "$VERSIONS" "${NATIVE_BIN%/*}" || exit 1
    find "$VERSIONS" -maxdepth 1 -type f -size 0 -delete 2>/dev/null # an interrupted previous run may have left an empty file
    tmp="$VERSIONS/.download.$$"
    spin_msg "Downloading Claude Code $CLAUDE_PIN_VERSION" "$tmp"
    if ! curl -fsSL --max-time 1800 --speed-limit 1024 --speed-time 60 -o "$tmp" "$CLAUDE_RELEASES/$CLAUDE_PIN_VERSION/$CLAUDE_PLATFORM/claude" >>"$INSTALL_LOG" 2>&1; then
      echo "Downloading Claude Code $CLAUDE_PIN_VERSION failed" >>"$INSTALL_LOG"
      rm -f "$tmp"
      exit 1
    fi
    sum=$(file_sha256 "$tmp")
    if [ "$sum" != "$CLAUDE_PIN_SHA256" ]; then
      echo "Claude Code $CLAUDE_PIN_VERSION: SHA256 mismatch, not installed (expected $CLAUDE_PIN_SHA256, got $sum)" >>"$INSTALL_LOG"
      rm -f "$tmp"
      exit 1
    fi
    echo "Claude Code $CLAUDE_PIN_VERSION downloaded, SHA256 verified" >>"$INSTALL_LOG"
    if ! { chmod 755 "$tmp" && mv -f "$tmp" "$VERSIONS/$CLAUDE_PIN_VERSION" && ln -sfn "$VERSIONS/$CLAUDE_PIN_VERSION" "$NATIVE_BIN"; }; then
      rm -f "$tmp"
      exit 1
    fi
    exit 0
  ) 8>"$RUN_DIR/steward.download.lock"
  rc=$?
  ((rc == 0)) || return "$rc"
  cache_binary
  claude_ok
}

ensure_binary() {
  claude_ok && return 0
  if restore_binary; then
    log "Restored Claude Code $(claude_ver) from the boot drive"
    return 0
  fi
  log "No usable backup on the boot drive, downloading Claude Code $CLAUDE_PIN_VERSION instead"
  download_binary
}

need_binary() { # for interactive commands: make sure Claude Code is usable, showing progress if there is a wait; on failure print what the installer said
  claude_ok && return 0
  local rc
  spin_start "Preparing the Claude Code binary"
  ensure_binary 2>>"$INSTALL_LOG"
  rc=$?
  if ((rc == 0)); then
    spin_stop ok "Claude Code $(claude_ver) is ready"
    return 0
  fi
  if ((rc == 75)); then
    spin_stop fail "Another download is in progress, try again later"
  else
    spin_stop fail "Claude Code is not ready"
    if [ -s "$INSTALL_LOG" ]; then strip_ansi <"$INSTALL_LOG" | grep -v '^[[:space:]]*$' | uniq | tail -n 15 >&2; fi
  fi
  return 1
}

# ───────────────────────── Hooks and environment ─────────────────────────

write_exec() { # $1=path, content from stdin
  cat >"$1" && chmod 755 "$1"
}

ensure_runtime() { # all of these live in RAM and are rebuilt at every boot
  mkdir -p "$BIN_DIR" "$PLUGIN_DIR/event" "$RUN_DIR" "${LOG%/*}" "${CRON%/*}"
  chmod 700 "$ROOT" 2>/dev/null

  # claude in any shell uses the config and login on the boot drive
  write_exec "$BIN_DIR/claude" <<EOF
#!/bin/bash
# generated by steward, rebuilt on reboot
export HOME="$HOME" CLAUDE_CONFIG_DIR="$CFG_DIR"
case ":\$PATH:" in *":$HOME/.local/bin:"*) ;; *) PATH="\$PATH:$HOME/.local/bin" ;; esac
[ -x "$NATIVE_BIN" ] || { echo "Claude Code is not ready yet, run steward status" >&2; exit 127; }
exec "$NATIVE_BIN" "\$@"
EOF
  write_exec "$BIN_DIR/steward" <<EOF
#!/bin/bash
exec bash "$SELF" "\$@"
EOF

  # array stop events: emhttpd runs /usr/local/emhttp/plugins/*/event/<event name>
  local ev
  for ev in stopping unmounting_disks; do
    write_exec "$PLUGIN_DIR/event/$ev" <<EOF
#!/bin/bash
[ -f "$SELF" ] && exec bash "$SELF" _event "\$1"
exit 0
EOF
  done

  # watchdog: update_cron picks up /boot/config/plugins/dynamix/*.cron
  printf '%s\n' "# steward watchdog" "*/5 * * * * bash $SELF watchdog >/dev/null 2>&1" >"$CRON.new"
  if cmp -s "$CRON.new" "$CRON"; then rm -f "$CRON.new"; else mv -f "$CRON.new" "$CRON"; fi
  [ -e "$P/usr/local/sbin/update_cron" ] && bash "$P/usr/local/sbin/update_cron" >/dev/null 2>&1
  return 0
}

add_hook() { # $1=file $2=command $3=create means the file may be created if it does not exist
  local f=$1 line="$2  $MARK"
  if [ -f "$f" ]; then
    [ "$(grep -cF -- "$MARK" "$f")" = 1 ] && grep -qxF -- "$line" "$f" && return 0 # already exactly this line: do not rewrite the boot drive
    [ -e "$f.before-steward" ] || cp -p "$f" "$f.before-steward"
    sed -i "\|$MARK|d" "$f"
    [ -z "$(tail -c1 "$f")" ] || echo >>"$f"
  elif [ "${3:-}" = create ]; then
    printf '#!/bin/bash\n' >"$f"
  else
    return 1
  fi
  printf '%s\n' "$line" >>"$f"
}

boot_shared_over_smb() {
  command -v testparm >/dev/null 2>&1 || return 1
  testparm -s 2>/dev/null | grep -Eq '^[[:space:]]*path[[:space:]]*=[[:space:]]*/boot/?[[:space:]]*$'
}

write_default() { # $1=path, content from stdin. If the file already exists leave it alone, preserving your changes
  if [ -e "$1" ]; then cat >/dev/null; else cat >"$1"; fi
}

write_defaults() {
  write_default "$CONF" <<'EOF'
# Steward service options. After editing, run: steward restart
#
# Arguments passed to claude remote-control.
# --spawn same-dir: new sessions opened from the phone run directly in the workspace. Without it, if /boot is a git repo
#   (it is for anyone using Unraid Connect flash backup), Claude Code switches to worktree mode and sessions run in a copy.
# --capacity is the number of sessions that can be open at once; each session is a separate process and uses memory.
RC_ARGS=(--spawn same-dir --capacity 4)

# Example: auto mode -- a classifier lets low-risk actions through and asks only for risky ones; the deny / ask rules in settings.json and bash-guard still apply.
#   If the plan does not support it, Claude Code falls back to asking for each action and the conversation shows "auto mode is unavailable".
# RC_ARGS=(--spawn same-dir --capacity 4 --permission-mode auto)
# Example: auto-accept file edits only, still ask for every command
# RC_ARGS=(--spawn same-dir --capacity 4 --permission-mode acceptEdits)
EOF

  # Second line of defense: settings.json rules only match the start of a command; this hook checks the whole command (full paths, sh -c, ; chains and pipelines are all visible)
  mkdir -p "$ROOT/hooks"
  write_default "$ROOT/hooks/bash-guard.sh" <<'HOOK'
#!/bin/bash
# Steward's PreToolUse hook (matcher: Bash). Reads the tool call JSON from stdin and checks the WHOLE command string,
# so when the prefix-only rules in settings.json are bypassed with full paths, sh -c, ; chains, pipelines or xargs, this still catches it.
#   deny: disk wipe / format tools, reading password hashes / keys / tokens
#   ask : destructive or host-level commands, writing /boot/config from the shell, git rewriting the work tree of the /boot repo,
#         modifying this hook or settings.json
# Everything else is handed back to the normal permission rules (in auto mode the classifier decides).
# Known limitation: text matching only. A command that merely "mentions" a keyword is caught too (e.g. echo rm); commands inside
# a script file being run (bash x.sh, . x.sh) do not pass through here again. This is a deliberate trade-off.

cmd=$(jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[[ -z "$cmd" ]] && exit 0

emit() { # $1=deny|ask $2=reason
  jq -cn --arg d "$1" --arg r "$2" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:$d,permissionDecisionReason:$r}}'
  exit 0
}

# ---------- DENY: never allowed, anywhere in the command ----------
if [[ "$cmd" =~ (^|[^[:alnum:]_.-])(mkfs(\.[[:alnum:]]+)?|wipefs|sgdisk|blkdiscard|shred)([^[:alnum:]_-]|$) ]]; then
  emit deny "bash-guard: disk wipe/format tools are always forbidden (use the webGUI)"
fi
if [[ "$cmd" =~ zpool[[:space:]]+(destroy|labelclear) ]]; then
  emit deny "bash-guard: zpool destroy/labelclear is always forbidden"
fi
# Paths of password hashes / keys / tokens. Prefix match, so backups like /etc/shadow- and globs like /etc/shad* are caught too
secret_paths='/etc/g?shad|/boot/config/shad|smbpasswd|secrets\.tdb|/boot/config/ssh|/boot/config/ssl|/boot/config/wireguard|/etc/wireguard|/root/\.ssh|/root/keyfile|\.credentials|unraid-api\.key|/var/lib/samba/private'
if [[ "$cmd" =~ ($secret_paths) ]]; then
  emit deny "bash-guard: command touches a password hash/key/token path; reading or printing it is forbidden"
fi

# ---------- ASK: always ask the user first ----------
# Command position: at the start, or after ; & | ( ` quotes or whitespace (catches sh -c "...", pipelines, chains, timeout/nice/env prefixes), optionally with sudo or a full path
cmdpos='(^|[;&|(`'"'"'"]|[[:space:]])(sudo[[:space:]]+)?(/[[:alnum:]_./-]*/)?'
dangerous='(rm|dd|mdcmd|emcmd|reboot|poweroff|powerdown|shutdown|halt|truncate)'
if [[ "$cmd" =~ ${cmdpos}${dangerous}([[:space:]]|$) ]]; then
  emit ask "bash-guard: contains a delete/overwrite/array-control/shutdown command; needs user confirmation"
fi
if [[ "$cmd" =~ (xargs[[:space:]]+(-[^[:space:]]+[[:space:]]+)*rm([[:space:]]|$)|-exec[[:space:]]+rm([[:space:]]|$)|-delete([[:space:]]|$)) ]]; then
  emit ask "bash-guard: deletes files via xargs/find; needs user confirmation"
fi
if [[ "$cmd" =~ zfs[[:space:]]+(destroy|rollback)|docker[[:space:]]+(rm|rmi|volume[[:space:]]+(rm|prune)|system[[:space:]]+prune|container[[:space:]]+(rm|prune)|image[[:space:]]+prune)|virsh[[:space:]]+(destroy|undefine) ]]; then
  emit ask "bash-guard: removes ZFS/container/VM resources; needs user confirmation"
fi
# The real command hidden inside a string: eval, sh -c (including combined forms like -lc, -ec), base64 decode then execute
if [[ "$cmd" =~ (^|[^[:alnum:]_])eval([[:space:]]|$)|base64[[:space:]]+(-d|--decode)|(^|[^[:alnum:]_])(ba)?sh[[:space:]]+-[a-zA-Z]*c[[:space:]] ]]; then
  emit ask "bash-guard: indirect execution (eval/sh -c/base64 -d); needs user confirmation"
fi

# Writing /boot/config from the shell instead of with the Edit tool. Counts whether the absolute path is used or it first cd's into /boot and then uses a relative config/... path
write_verbs='(^|[^[:alnum:]_])(cp|mv|tee|install|rsync|ln|touch|mkdir|chmod|chown|chattr|patch|dd|truncate|fromdos|todos|dos2unix|unix2dos)([[:space:]]|$)'
inplace_edit='(^|[^[:alnum:]_])(sed[[:space:]]+(-[^[:space:]]*i|--in-place)|perl[[:space:]]+-[^[:space:]]*[ip])'
cd_boot='(^|[;&|[:space:]])cd[[:space:]]+/boot/?([[:space:]]*(&&|;|\|)|[[:space:]]*$)'
targets_boot_config=0
[[ "$cmd" =~ /boot/config ]] && targets_boot_config=1
[[ "$cmd" =~ $cd_boot && "$cmd" =~ (^|[[:space:]>])config/ ]] && targets_boot_config=1
if ((targets_boot_config)); then
  if [[ "$cmd" =~ $write_verbs ]] || [[ "$cmd" =~ $inplace_edit ]] ||
    [[ "$cmd" =~ \>[[:space:]]*(/boot/)?config/ ]] ||
    [[ "$cmd" =~ (^|[^[:alnum:]_])git[[:space:]]+(reset|checkout|restore|clean|stash|rm|mv)([[:space:]]|$) ]]; then
    emit ask "bash-guard: writes /boot/config from the shell (back up to /boot/steward/backups/ first)"
  fi
fi

# git rewriting the work tree: /boot is the git repo of Unraid Connect flash backup, /boot/config is tracked, and our working directory is inside it.
# reset --hard / checkout / restore / stash roll the config back to the last auto-commit; clean deletes files that were never tracked (e.g. wireguard/).
# Only /boot matters: ask when no repo is given (the default is /boot) or -C / --git-dir / --work-tree points at /boot itself; another repo is not asked about
git_opts='([[:space:]]+(-C[[:space:]]*[^[:space:]]+|--git-dir(=|[[:space:]]+)[^[:space:]]+|--work-tree(=|[[:space:]]+)[^[:space:]]+|-c[[:space:]]+[^[:space:]]+|--[a-z-]+(=[^[:space:]]+)?))*'
if [[ "$cmd" =~ (^|[^[:alnum:]_])git${git_opts}[[:space:]]+(reset|clean|checkout|restore|stash)([[:space:]]|$) ]]; then
  sub=${BASH_REMATCH[$((${#BASH_REMATCH[@]} - 2))]}
  repo=""
  if [[ "$cmd" =~ git[[:space:]]+([^[:space:]]+[[:space:]]+)*(-C[[:space:]]*|--git-dir[=[:space:]]|--work-tree[=[:space:]])([^[:space:]]+) ]]; then
    repo=${BASH_REMATCH[3]%/}
    repo=${repo%/.git}
  fi
  rewrites=0
  case "$sub" in
  reset) [[ "$cmd" =~ --hard ]] && rewrites=1 ;;
  checkout) [[ "$cmd" =~ checkout[[:space:]].*(--|[[:space:]]\.)([[:space:]]|$) || "$cmd" =~ checkout[[:space:]]+\.$ ]] && rewrites=1 ;;
  stash) [[ "$cmd" =~ stash[[:space:]]+(list|show) ]] || rewrites=1 ;;
  clean | restore) rewrites=1 ;;
  esac
  [[ "$cmd" =~ --help ]] && rewrites=0
  if ((rewrites)) && { [ -z "$repo" ] || [ "$repo" = /boot ]; }; then
    emit ask "bash-guard: git $sub rewrites the work tree of /boot (/boot/config is in this repo); needs user confirmation"
  fi
fi

# Modifying this hook or the permission settings (the old path /boot/claude-code is a symlink to /boot/steward; cd'ing in first and using a relative path counts too)
guard_target=0
[[ "$cmd" =~ /boot/(steward|claude-code)/(hooks/|home/settings\.json) ]] && guard_target=1
[[ "$cmd" =~ (^|[;&|[:space:]])cd[[:space:]]+/boot/(steward|claude-code)(/home|/hooks)?/?[[:space:]]*(&&|;|\|) && "$cmd" =~ (hooks/|bash-guard|settings\.json) ]] && guard_target=1
if ((guard_target)); then
  if [[ "$cmd" =~ $write_verbs ]] || [[ "$cmd" =~ $inplace_edit ]] || [[ "$cmd" =~ (^|[^[:alnum:]_])(sed|rm|perl)([[:space:]]|$)|\> ]]; then
    emit ask "bash-guard: modifies the permission rules or the guard script; needs user confirmation"
  fi
fi

exit 0
HOOK
  # The hook is invoked with bash, so it needs no execute bit; permissions of an existing file are left alone too

  # dialogExpiry: how long a permission prompt forwarded to the phone waits before it is cancelled automatically (official default 5m)
  write_default "$CFG_DIR/settings.json" <<'EOF'
{
  "dialogExpiry": "10m",
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "bash /boot/steward/hooks/bash-guard.sh",
            "timeout": 10,
            "onFailure": "block",
            "statusMessage": "bash-guard checking"
          }
        ]
      }
    ]
  },
  "permissions": {
    "disableBypassPermissionsMode": "disable",
    "deny": [
      "Bash(mkfs*)",
      "Bash(/sbin/mkfs*)",
      "Bash(/usr/sbin/mkfs*)",
      "Bash(wipefs *)",
      "Bash(/sbin/wipefs *)",
      "Bash(/usr/sbin/wipefs *)",
      "Bash(sgdisk *)",
      "Bash(blkdiscard *)",
      "Bash(shred *)",
      "Bash(zpool destroy *)",
      "Bash(zpool labelclear *)",
      "Read(//etc/shadow)",
      "Read(//boot/config/shadow)",
      "Read(//boot/config/smbpasswd)",
      "Read(//boot/config/secrets.tdb)",
      "Read(//boot/config/ssh/**)",
      "Read(//boot/config/ssl/**)",
      "Read(//boot/config/wireguard/**)",
      "Read(//etc/wireguard/**)",
      "Read(//root/.ssh/**)",
      "Read(//root/keyfile)",
      "Read(//boot/steward/home/.credentials.json)",
      "Read(//boot/steward/home/unraid-api.key)"
    ],
    "ask": [
      "Bash(rm *)",
      "Bash(/bin/rm *)",
      "Bash(/usr/bin/rm *)",
      "Bash(dd *)",
      "Bash(truncate *)",
      "Bash(mdcmd *)",
      "Bash(emcmd *)",
      "Bash(reboot*)",
      "Bash(poweroff*)",
      "Bash(powerdown*)",
      "Bash(shutdown *)",
      "Bash(halt*)",
      "Bash(sh -c *)",
      "Bash(bash -c *)",
      "Bash(eval *)",
      "Bash(git reset --hard*)",
      "Bash(git clean *)",
      "Bash(git checkout -- *)",
      "Bash(git restore *)",
      "Bash(zfs destroy *)",
      "Bash(zfs rollback *)",
      "Bash(docker rm *)",
      "Bash(docker rmi *)",
      "Bash(docker container rm *)",
      "Bash(docker container prune*)",
      "Bash(docker image prune*)",
      "Bash(docker volume rm *)",
      "Bash(docker volume prune*)",
      "Bash(docker system prune*)",
      "Bash(virsh destroy *)",
      "Bash(virsh undefine *)",
      "Edit(//boot/config/**)",
      "Edit(//boot/steward/hooks/**)",
      "Edit(//boot/steward/home/settings.json)"
    ],
    "allow": [
      "Bash(docker ps *)",
      "Bash(docker logs *)",
      "Bash(docker images *)",
      "Bash(docker stats --no-stream *)",
      "Bash(virsh list *)",
      "Bash(df *)",
      "Bash(free *)",
      "Bash(uptime)",
      "Bash(lsblk *)",
      "Bash(sensors *)",
      "Bash(smartctl -a *)",
      "Bash(smartctl -H *)",
      "Bash(zpool status *)",
      "Bash(zpool list *)",
      "Bash(zfs list *)"
    ]
  }
}
EOF

  # Push notifications: push to the phone when a permission prompt or question is waiting for you ("Push when actions required" in /config).
  # Claude Code maintains this file itself after login, so it is only written on a fresh install when it does not exist yet
  write_default "$CFG_DIR/.claude.json" <<'EOF'
{
  "inputNeededNotifEnabled": true
}
EOF

  write_default "$CFG_DIR/CLAUDE.md" <<'EOF'
# This machine is an Unraid server, and you run directly on the host as root

You are the resident admin assistant of this NAS; the user sends instructions through Remote Control from a phone or browser.
There is no container isolation here: every command acts directly on the host, and lost data cannot be recovered. When unsure, ask first.

## What is special about this machine

- The root filesystem lives in RAM: changes outside `/boot` and `/mnt` are gone after a reboot. Settings that must persist go in `/boot/config`, or are rebuilt on every boot by the startup script `/boot/config/go`.
- `/boot` is the boot drive (Internal Boot, ZFS) and stays available while the array is stopped. Space is limited; do not put large files there.
- `/mnt/user/<share>` is a user share (merged view); `/mnt/diskN` and `/mnt/<pool>` are the underlying disks. Never mix `/mnt/user` and `/mnt/diskN` in the same copy or move command; it corrupts files.
- When the array is stopped, `/mnt/user`, `/mnt/disk*` and every pool disappear, and Docker and VMs stop too. You yourself (`/boot/steward`) are unaffected.
- Check the array state before acting: `grep -E '^(mdState|fsState)=' /var/local/emhttp/var.ini`

## Always follow these rules

1. Never leave the working directory under `/mnt`; always use absolute paths. Any process stuck in `/mnt` prevents the array from unmounting.
2. For the following operations, explain the impact first, get the user's explicit consent, and do one thing at a time: stopping or starting the array, rebooting or shutting down, parity checks, changing disk assignments, deleting containers / VMs / shares, updating Unraid or plugins.
3. Never run New Config, clear or format disks, `zpool destroy`, `mkfs` or `wipefs`. Have the user do those themselves in the webGUI.
4. Before modifying any file under `/boot/config`, back it up to `/boot/steward/backups/<datetime>/`, and tell the user what you changed, how to restore it, and whether a service restart or reboot is needed for it to take effect.
5. Do not read or print password hashes, keys, tokens or WireGuard private keys. Conversation logs are stored in plain text on the boot drive and synced to Anthropic.
6. When a long task finishes, or the user needs to make a decision, send an Unraid notification:
   `/usr/local/emhttp/webGui/scripts/notify -e "Steward" -s "<subject>" -d "<body>" -i normal`

## Conventions

- Docker: containers are managed by templates (`/boot/config/plugins/dockerMan/templates-user/my-*.xml`). Do not create containers meant to stay with a manual `docker run`; the webGUI has no template for them, so they cannot be edited or updated in the UI later.
- Config files live in `/boot/config` (`ident.cfg`, `network.cfg`, `share.cfg`, `disk.cfg`, `docker.cfg`, `shares/*.cfg`, etc.). Editing a file directly does not take effect immediately; use the official UI whenever possible.
- Unraid API (GraphQL, built in since 7.2): docs at https://docs.unraid.net/API/ , local CLI via `unraid-api --help`. When an API key is needed, ask the user first, then create it with `unraid-api apikey --create` with the minimum permissions that suffice; store the key as `/boot/steward/home/unraid-api.key` (mode 600) and do not print it.
- Stop or start the array only through the official UI; no `mdcmd stop`, no manual umount.
- Files you create in a share (`/mnt/user/...`) belong to root by default and SMB users cannot open them: after creating them, run `chown nobody:users` and `chmod ug+rw` on those files. Only touch files you created yourself; do not recursively change permissions on appdata or an entire share.
- Logs: system in `/var/log/syslog`, containers via `docker logs <name>`. Diagnostics bundle via `diagnostics` (output in `/boot/logs`).
- Your own service is managed by `steward` (`status`, `restart`, `update`, `logs`). Do not kill claude processes yourself.
EOF

  merge_settings
}

merge_settings() { # When upgrading an existing install, add default keys that only exist in the new version. Only missing keys are added, user changes are untouched; the original is kept as a backup
  local f="$CFG_DIR/settings.json" tmp
  [ -s "$f" ] || return 0
  jq -e 'has("dialogExpiry")' "$f" >/dev/null 2>&1 && return 0
  tmp=$(mktemp "$f.XXXXXX") || return 0
  if jq '.dialogExpiry = "10m"' "$f" >"$tmp" 2>/dev/null && jq -e . "$tmp" >/dev/null 2>&1; then
    cp -p "$f" "$f.before-$STEWARD_VERSION"
    mv -f "$tmp" "$f"
    log "settings.json: added dialogExpiry=10m (original backed up as settings.json.before-$STEWARD_VERSION)"
  else
    rm -f "$tmp"
  fi
}

preflight() {
  [ "$(id -u)" = 0 ] || die "Run as root"
  if [ -z "$P" ]; then mountpoint -q /boot || die "/boot is not mounted"; fi
  case "$(stat -f -c %T "$P/boot" 2>/dev/null)" in
  msdos | vfat | fat* | exfat) die "/boot is a FAT filesystem (USB boot). This script stores its data directly on the boot drive and only works with Internal Boot (ZFS)" ;;
  esac
  [ -e "$P/boot/config/plugins/claude-code.plg" ] && die "Another Claude Code plugin (claude-code.plg) is installed; the two would overwrite each other's /usr/local/bin/claude. Pick one"
  mkdir -p "$ROOT" || die "Cannot create $ROOT"
  # Check for real whether the boot drive preserves permissions and symlinks
  local t="$ROOT/.probe.$$" ok=1
  : >"$t" && chmod 600 "$t" && [ "$(stat -c %a "$t")" = 600 ] && ln -s "$t" "$t.l" 2>/dev/null && ok=0
  rm -f "$t" "$t.l"
  [ "$ok" = 0 ] || die "The filesystem holding $ROOT does not support file permissions or symlinks; login credentials cannot be stored there safely"
  local avail
  avail=$(df --output=avail -BM "$P/boot" 2>/dev/null | tail -n1 | tr -dc '0-9')
  [ -n "$avail" ] && ((avail < 1024)) && warn "Only ${avail}MB left on the boot drive; the Claude Code binary backup needs about 300MB"
  return 0
}

# ───────────────────────── Commands ─────────────────────────

install_self() { # Put the script currently running onto the boot drive. Returns 0 if the content changed; 1 if unchanged, and then nothing is written to the boot drive
  local src
  src=$(readlink -f "${BASH_SOURCE[0]:-}" 2>/dev/null)
  [ -f "$src" ] || die "Save the script to a file before running it"
  [ "$src" = "$(readlink -f "$SELF" 2>/dev/null)" ] && return 1
  cmp -s <(tr -d '\r' <"$src" 2>/dev/null) "$SELF" && return 1 # cmp stops reading at the first difference; tr's complaint is not worth showing
  # Write a temp file first, then rename: the running service still has the old file open, and overwriting in place would make it read a mix of old and new
  if ! { tr -d '\r' <"$src" >"$SELF.new" && mv -f "$SELF.new" "$SELF"; }; then die "Cannot write $SELF"; fi
  return 0
}

stop_hook() { add_hook "$STOP" "[ -f $SELF ] && bash $SELF shutdown >/dev/null 2>&1" create; }
drop_go_hook() { if grep -qsF "$MARK" "$GO"; then sed -i "\|$MARK|d" "$GO"; fi; }

LEGACY_ROOT="$P/boot/claude-code"
LEGACY_TAG="CLAUDE_UNRAID_SVC"
migrate_legacy() { # Upgrade from the old name claude-unraid: move the data, stop the old service, remove the old hooks. Done once, only when the old directory exists and the new one does not
  [ -d "$LEGACY_ROOT" ] && [ ! -L "$LEGACY_ROOT" ] || return 0
  if [ -e "$ROOT" ]; then # preflight already ran mkdir: only an empty directory counts as "new directory does not exist"
    [ -d "$ROOT" ] && [ -z "$(ls -A "$ROOT" 2>/dev/null)" ] && rmdir "$ROOT" || return 0
  fi
  log "Found data from the old claude-unraid version, moving it to $ROOT"
  # Processes of the old service carry CLAUDE_UNRAID_SVC. If the upgrade is triggered from Claude inside the old service, it gets stopped here as well; reconnect from the phone once the new service is up
  local pids=""
  [ -z "$P" ] && pids=$(grep -lszxF "$LEGACY_TAG=1" /proc/[0-9]*/environ 2>/dev/null | sed 's#^/proc/##; s#/environ$##' | grep -vx "$$") # With a fake root for testing, leave real processes alone
  if [ -n "$pids" ]; then
    # shellcheck disable=SC2086
    kill -TERM $pids 2>/dev/null
    sleep 3
    # shellcheck disable=SC2086
    kill -KILL $pids 2>/dev/null
  fi
  mv "$LEGACY_ROOT" "$ROOT" || die "Cannot move $LEGACY_ROOT to $ROOT"
  ln -s steward "$LEGACY_ROOT" # Keep a symlink at the old path: /boot/claude-code written in old settings, memory and notes keeps working
  if [ -f "$ROOT/claude-unraid.conf" ]; then
    mv -f "$ROOT/claude-unraid.conf" "$CONF"
    sed -i 's/claude-unraid/steward/g; 1s/^# [sS]teward .*/# Steward service options. After editing, run: steward restart/' "$CONF" # Also rewrites the legacy header line (line 1) to the current English wording
    # New default --spawn same-dir: only added when the old config does not specify --spawn; a user-set value is left alone
    grep -q -- '--spawn' "$CONF" || sed -i 's/^RC_ARGS=(\(.*\))$/RC_ARGS=(\1 --spawn same-dir)/' "$CONF"
  fi
  rm -f "$ROOT/claude-unraid.sh"
  # Old hooks: cron, command shortcut, runtime files, lines tagged "# claude-unraid" in stop/go
  rm -f "$P/boot/config/plugins/dynamix/claude-unraid.cron" "$BIN_DIR/claude-unraid" "$RUN_DIR"/claude-unraid.*
  local f
  for f in "$STOP" "$GO"; do
    [ -f "$f" ] && grep -qF '# claude-unraid' "$f" || continue
    [ -e "$f.before-steward" ] || cp -p "$f" "$f.before-steward"
    sed -i '\|# claude-unraid|d' "$f"
  done
  rm -rf "$P/usr/local/emhttp/plugins/claude-unraid"
  if [ -f "$P/boot/config/plugins/claude-unraid.plg" ]; then
    # Do not run the old plugin's remove section: it would delete the shared /usr/local/bin/claude too. Moving it to plugins-removed stops it from loading
    mkdir -p "$P/boot/config/plugins-removed"
    mv -f "$P/boot/config/plugins/claude-unraid.plg" "$P/boot/config/plugins-removed/"
    rm -f "$P/var/log/plugins/claude-unraid.plg" # the plugin manager's "installed" marker (RAM); otherwise update_cron keeps looking for the old plugin until reboot
  fi
  [ -e "$P/usr/local/sbin/update_cron" ] && bash "$P/usr/local/sbin/update_cron" >/dev/null 2>&1
  # Paths and names inside the old config files (originals backed up)
  for f in "$CFG_DIR/settings.json" "$CFG_DIR/CLAUDE.md"; do
    [ -f "$f" ] || continue
    cp -p "$f" "$f.before-steward"
    sed -i 's#/boot/claude-code#/boot/steward#g; s#claude-unraid#steward#g' "$f"
  done
  log "Migration done: $LEGACY_ROOT -> $ROOT"
  say "Migrated from the old claude-unraid version to $ROOT (old path /boot/claude-code kept as a symlink, old plugin file moved to plugins-removed)"
}

cmd_install() {
  preflight
  migrate_legacy
  mkdir -p "$CFG_DIR" "$WORKSPACE" "$CACHE" "$RUN_DIR" "${LOG%/*}"
  install_self
  write_defaults
  if ((PLUGIN)); then
    drop_go_hook # Installed as a plugin: loaded by the plugin at boot, the line in go is not needed
  else
    # go must not be created when missing: Unraid would run go instead of starting emhttp and the webGUI would not come up
    add_hook "$GO" "[ -f $SELF ] && bash $SELF boot >/dev/null 2>&1 &" ||
      warn "$GO not found, boot hook not added. Add this line to the go file manually: bash $SELF boot &"
  fi
  stop_hook
  ensure_runtime
  need_binary || die "Check the network and rerun: steward install"
  say "Install complete: Claude Code $(claude_ver), data in $ROOT"
  boot_shared_over_smb && warn "The boot drive is currently shared over SMB, and the login credentials are stored on it. On the Main page, open the boot device and set Export under SMB Security Settings to No"
  if [ -t 0 ]; then
    local a
    read -r -p "Log in and complete the Remote Control setup now? [Y/n] " a
    case "$a" in n | N) ;; *)
      cmd_setup
      return
      ;;
    esac
  fi
  say "Next step: steward setup"
}

auth_method() { timeout 20 "$NATIVE_BIN" auth status 2>/dev/null | sed -n 's/.*"authMethod"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1; }

cmd_setup() {
  [ -t 0 ] || die "setup needs an interactive terminal (Unraid web terminal or SSH)"
  need_binary || die "Check the network and try again, or run steward install to see why"
  if [ "$(auth_method)" = "claude.ai" ]; then
    say "Step 1/2: already logged in to claude.ai"
  else
    say "Step 1/2: log in to claude.ai (Remote Control does not support API keys)"
    say "  Paste the URL shown into a browser to log in, then paste the code back here. The URL is long, so widen the terminal window before copying."
    "$NATIVE_BIN" auth login || die "Login was not completed"
  fi
  # Stop the background service and disable it for now, so the watchdog does not bring it back while you are working
  rm -f "$ENABLED"
  stop_service 30
  say ""
  say "Step 2/2: start Remote Control once in the foreground and answer the one-time questions"
  say "  1. Answer y when asked whether to trust this directory and whether to enable Remote Control"
  say "  2. Once the connection URL appears, open the Code tab in the Claude phone app or claude.ai/code and confirm this machine is listed"
  say "  3. Press Ctrl+C to return here"
  say ""
  trap : INT # Ctrl+C only ends claude, not this script
  cd "$WORKSPACE" || die "Cannot enter $WORKSPACE"
  "$NATIVE_BIN" remote-control "${RC_ARGS[@]}"
  cd / || true
  trap 'exit 130' INT
  say ""
  local a
  read -r -p "Did it connect successfully? Enable the resident service (start at boot)? [Y/n] " a
  case "$a" in n | N)
    say "Not enabled. After fixing the problem, run steward setup again, or just steward start"
    return 0
    ;;
  esac
  cmd_start
}

stop_service() { # $1=max seconds to wait $2=what to say when nothing is running (optional)
  if [ -n "$(tagged_pids)" ]; then
    spin_start "Stopping service"
    kill_tagged "$1"
    spin_stop ok "Service stopped"
  elif [ -n "${2:-}" ]; then
    say "$2"
  fi
  rm -f "$PIDFILE"
}

log_size() { stat -c %s "$LOG" 2>/dev/null || echo 0; }

wait_connected() { # $1=size of the log file before start. Wait until Remote Control has really connected (the connection URL appears in the log), or it has definitely failed
  local off=$1 t0=$SECONDS url seen=0
  spin_start "Waiting for Remote Control to connect"
  while ((SECONDS - t0 < 15)); do
    (($(log_size) < off)) && off=0 # The log was just rotated and emptied
    if tail -c "+$((off + 1))" "$LOG" 2>/dev/null | grep -a -q 'remote-control exited'; then
      spin_stop fail "Remote Control did not connect: $(fail_hint)"
      return 1
    fi
    url=$(tail -c "+$((off + 1))" "$LOG" 2>/dev/null | grep -a -o 'https://claude\.ai/code[^[:space:][:cntrl:]"]*' | tail -n1)
    if [ -n "$url" ]; then
      seen=$((seen + 1)) # Keep watching for another second after the URL appears: an error message may contain a URL too, so make sure the program does not exit right after
      if ((seen >= 8)); then
        spin_stop ok "Remote Control connected"
        say "  $url"
        return 0
      fi
    fi
    sleep 0.1
  done
  spin_stop clear
  say "The service is running in the background, but no connection URL has appeared in the log yet. Check claude.ai/code or the phone app for this machine; see steward logs for details"
}

cmd_start() { # Returns 0=service running and connected (or still connecting) 1=not started or not connected
  if ! need_binary; then
    err "Claude Code is not ready yet. Check the network and try again, or run steward install to see why"
    return 1
  fi
  rm -f "$DOWN_FLAG"
  : >"$ENABLED"
  if sup_pid >/dev/null; then
    say "Service already running (pid $(sup_pid)). Check with: steward status"
    return 0
  fi
  local off
  off=$(log_size)
  spin_start "Starting service"
  if ! launch; then
    spin_stop fail "Service did not start, see steward logs"
    return 1
  fi
  spin_stop ok "Service started (pid $(sup_pid)), will start automatically at boot"
  wait_connected "$off"
}

cmd_stop() {
  rm -f "$ENABLED"
  stop_service 30 "Service was not running"
  say "Start at boot disabled. Run steward start to re-enable it"
}

cmd_restart() {
  stop_service 30
  cmd_start
}

cmd_shutdown() { # Called from /boot/config/stop. Leaves the "start at boot" setting alone, and must not hold up the shutdown
  : >"$DOWN_FLAG"
  log "System shutting down, stopping service"
  kill_tagged 10
  rm -f "$PIDFILE"
}

cmd_boot() { # Runs in the background at boot: called from /boot/config/go for script installs, from the plugin's install step for plugin installs
  ensure_runtime
  log "Boot: runtime rebuilt"
  if ! ensure_binary; then
    notify_user "Claude Code could not start" "Both restore and download failed at boot; run steward status"
    exit 1
  fi
  if [ -f "$ENABLED" ]; then launch || log "Boot: service did not start"; fi
}

cmd_watchdog() { # Called by cron every 5 minutes
  [ -f "$ENABLED" ] && [ ! -f "$DOWN_FLAG" ] || return 0
  if sup_pid >/dev/null; then
    auto_update
    return 0
  fi
  claude_ok || ensure_binary || return 0
  log "watchdog: service is gone, restarting"
  launch
}

running_ver() { # Which version the running remote-control uses (differs from claude_ver after an update, before a restart)
  local p exe
  for p in $(tagged_pids); do
    # Only accept processes whose argv[1] is exactly remote-control and whose executable is under versions/; commands in a session that mention this string do not count
    [ "$(tr '\0' '\n' 2>/dev/null <"/proc/$p/cmdline" | sed -n 2p)" = remote-control ] || continue
    exe=$(readlink "/proc/$p/exe" 2>/dev/null) || continue
    exe=${exe% (deleted)}
    case "$exe" in "$VERSIONS"/*) ;; *) continue ;; esac
    echo "${exe##*/}"
    return 0
  done
  return 1
}

sessions_busy() { # If a session wrote to its conversation log in the last 15 minutes, treat it as in use
  find "$CFG_DIR/projects" -name '*.jsonl' -mmin -15 2>/dev/null | grep -q .
}

# In remote-control mode Claude Code does not update itself, so the watchdog does it:
# once a day after 08:00 it checks the stable channel; a new version is installed and backed up to the boot drive, and the service is restarted to apply it only when no session is in use, otherwise it retries an hour later
AU_DONE="$RUN_DIR/steward.autoupdate.done" # Contains the date that has already been handled today
AU_NEXT="$RUN_DIR/steward.autoupdate.next" # Contains the earliest time to try again (epoch seconds)
auto_update() {
  local today now next cur run latest rc
  today=$(date +%F) now=$(date +%s)
  (($(date +%-H) >= 8)) || return 0
  [ "$(cat "$AU_DONE" 2>/dev/null)" = "$today" ] && return 0
  next=$(cat "$AU_NEXT" 2>/dev/null)
  [[ $next =~ ^[0-9]+$ ]] || next=0
  ((now >= next)) || return 0
  echo $((now + 3600)) >"$AU_NEXT"
  claude_ok || return 0
  run=$(running_ver) || return 0 # remote-control is retrying its start or similar; try next time
  cur=$(claude_ver)
  if [ "$run" = "$cur" ]; then # No version waiting to be applied: check for a new one
    latest=$(curl -fsS --max-time 10 https://downloads.claude.ai/claude-code-releases/stable 2>/dev/null) || return 0
    [[ $latest =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 0
    if [ "$(printf '%s\n' "$latest" "$cur" | sort -V | tail -n1)" = "$cur" ]; then # Already up to date (or newer than stable)
      echo "$today" >"$AU_DONE"
      return 0
    fi
    log "Auto-update: installing Claude Code $latest (current $cur)"
    (
      flock -n 8 || exit 75
      timeout 600 "$NATIVE_BIN" install "$latest" </dev/null >"$INSTALL_LOG" 2>&1 # Even if it hangs, it must not hold the download lock forever
    ) 8>"$RUN_DIR/steward.download.lock"
    rc=$?
    if ((rc == 75)); then
      log "Auto-update: another download is in progress, retrying in an hour"
      return 0
    fi
    if [ "$(claude_ver)" != "$latest" ]; then
      log "Auto-update: $latest did not install properly (exit code $rc), retrying in an hour (output in $INSTALL_LOG)"
      return 0
    fi
    verify_installed "$latest" || return 0 # the updater's download is checked against the published SHA256 before it is kept
    cache_binary
    cur=$latest
  fi
  if sessions_busy; then
    log "Auto-update: $cur is installed, but a session is in use; retrying in an hour"
    return 0
  fi
  log "Auto-update: restarting service to apply $cur (was $run)"
  if ! cmd_restart >/dev/null 2>&1 || [ "$(running_ver)" != "$cur" ]; then
    log "Auto-update: service did not come back properly after the restart, retrying in an hour (the watchdog brings it up if it is gone)"
    return 0
  fi
  echo "$today" >"$AU_DONE"
  notify_user "Claude Code updated to $cur" "Was $run. The service was restarted while no session was in use; conversations on the phone can continue" normal
}

cmd_update() {
  claude_ok || die "Claude Code not found, run first: steward install"
  local before after ver
  before=$(readlink -f "$NATIVE_BIN")
  "$NATIVE_BIN" update # It shows its own progress
  after=$(readlink -f "$NATIVE_BIN")
  ver=${after##*/}
  if [ "$before" != "$after" ]; then
    spin_start "Checking Claude Code $ver against the published SHA256"
    if verify_installed "$ver"; then
      spin_stop ok "Claude Code $ver matches the published SHA256"
    else
      spin_stop fail "Claude Code $ver did not verify and was removed; the previous version stays in use"
      return 1
    fi
  fi
  if [ ! -f "$CACHE/claude-$ver" ]; then
    spin_start "Backing up Claude Code $ver to the boot drive"
    cache_binary
    if [ -f "$CACHE/claude-$ver" ]; then
      spin_stop ok "Backed up Claude Code $ver to the boot drive"
    else
      spin_stop fail "Could not back up to the boot drive; it will be downloaded again at next boot"
    fi
  fi
  if [ "$before" != "$after" ] && sup_pid >/dev/null; then
    say "Version updated, restarting service to apply"
    cmd_restart
  fi
}

rc_opt() { # $1=option name $2=default when unset. Extract that option's value from RC_ARGS
  local i
  for ((i = 0; i < ${#RC_ARGS[@]}; i++)); do
    [ "${RC_ARGS[i]}" = "$1" ] && { echo "${RC_ARGS[i + 1]:-$2}"; return 0; }
  done
  echo "$2"
}

cmd_status() {
  local pid v r m="" url arr smb=0
  if pid=$(sup_pid); then
    say "Service:    running (pid $pid, up $(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' '))"
  elif [ -f "$ENABLED" ]; then
    say "Service:    enabled but not running (the watchdog brings it up within 5 minutes, or run steward start)"
  else
    say "Service:    not enabled (steward setup or steward start)"
  fi
  say "Mode:       permission-mode $(rc_opt --permission-mode default)  spawn $(rc_opt --spawn worktree)  capacity $(rc_opt --capacity 1)"
  spin_start -t "Checking Claude Code and login status"
  v=$(claude_ver)
  [ -n "$v" ] && m=$(auth_method)
  boot_shared_over_smb && smb=1
  spin_stop clear
  if [ -n "$v" ]; then
    say "Version:    $v  boot drive backups: $(find "$CACHE" -maxdepth 1 -name 'claude-*' -printf '%f ' 2>/dev/null | sed 's/claude-//g')"
    if r=$(running_ver) && [ "$r" != "$v" ]; then say "            the running service is still on $r; $v is used after a restart"; fi
    case "$m" in
    claude.ai) say "Login:      claude.ai" ;;
    "" | none) say "Login:      not logged in -> steward setup" ;;
    *) say "Login:      $m (Remote Control needs a claude.ai login) -> steward setup" ;;
    esac
  elif ! flock -n "$RUN_DIR/steward.download.lock" true 2>/dev/null; then
    say "Version:    Claude Code is downloading, please wait"
  else
    say "Version:    Claude Code not ready -> steward install"
    if [ -s "$INSTALL_LOG" ]; then
      say "  Last output of the installer:"
      strip_ansi <"$INSTALL_LOG" | grep -v '^[[:space:]]*$' | tail -n 3 | sed 's/^/    /'
    fi
  fi
  arr=$(sed -n 's/^mdState="\{0,1\}\([A-Z_]*\).*/\1/p' "$P/var/local/emhttp/var.ini" 2>/dev/null)
  say "Array:      ${arr:-unknown} (the service does not depend on the array)"
  say "Boot drive: $(df -h --output=avail "$P/boot" 2>/dev/null | tail -n1 | tr -d ' ') free"
  if ((PLUGIN)); then
    say "Install:    plugin $STEWARD_VERSION (managed on the Plugins page of the webGUI)"
  else
    say "Install:    script $STEWARD_VERSION"
    grep -qsF "$MARK" "$GO" || say "Boot hook:  the steward line is missing from $GO; it will not start automatically after a reboot -> steward install"
  fi
  url=$(cat "$LOG.1" "$LOG" 2>/dev/null | grep -a -o 'https://claude\.ai/code[^[:space:][:cntrl:]"]*' | tail -n1)
  [ -n "$url" ] && say "Last URL:   $url"
  ((smb)) && warn "The boot drive is currently shared over SMB and the login credentials are stored on it; disabling the share is recommended"
  say "Recent log:"
  tail -n 6 "$LOG" 2>/dev/null | strip_ansi | sed 's/^/  /'
  return 0
}

cmd_logs() {
  if [ "${1:-}" = "-f" ]; then tail -n 30 -f "$LOG"; else tail -n "${1:-60}" "$LOG" 2>/dev/null | strip_ansi; fi
}

do_uninstall() {
  rm -f "$ENABLED"
  stop_service 30
  rm -f "$CRON" "$BIN_DIR/claude" "$BIN_DIR/steward"
  rm -rf "$PLUGIN_DIR"
  [ -f "$GO" ] && sed -i "\|$MARK|d" "$GO"
  [ -f "$STOP" ] && sed -i "\|$MARK|d" "$STOP"
  [ -e "$P/usr/local/sbin/update_cron" ] && bash "$P/usr/local/sbin/update_cron" >/dev/null 2>&1
  say "Hooks removed and service stopped. The binary in RAM disappears after a reboot."
  say "Data (including login credentials) is still in $ROOT; delete it manually once you are sure you no longer need it."
}

cmd_uninstall() {
  ((PLUGIN)) && die "This was installed as a plugin: remove it on the Plugins page of the webGUI, or run plugin remove steward.plg"
  do_uninstall
}

# ───────────────────────── Plugin (steward.plg) entry points ─────────────────────────

webgui_up() { # Is emhttpd up yet. At boot the plugin loads before emhttpd, and nothing slow may be done in that phase
  [ -e "$P/var/local/emhttp/var.ini" ] || return 1
  [ -n "$P" ] || [ -n "$(pgrep --ns $$ -x emhttpd 2>/dev/null)" ]
}

cmd_plugin_install() { # The plugin manager runs this on every boot, and also when the plugin is installed or updated from the webGUI
  PLUGIN=1
  local booting=1 changed=0 problem
  webgui_up && booting=0
  if ((booting)); then
    # Failure must not be reported at boot: the plugin manager would move the .plg to plugins-error and never load it again on later boots
    if ! problem=$( (preflight) 2>&1); then
      log "Boot: preflight failed, not starting this time -- $problem"
      notify_user "Claude Code plugin did not start" "$problem"
      say "steward: $problem"
      return 0
    fi
  else
    preflight
  fi
  migrate_legacy
  mkdir -p "$CFG_DIR" "$WORKSPACE" "$CACHE" "$RUN_DIR" "${LOG%/*}"
  install_self && changed=1
  write_defaults
  drop_go_hook # If the script install was used before, go has a line; the plugin now loads it at boot instead
  stop_hook
  ensure_runtime
  if ((booting)); then
    # Restoring the binary takes seconds, and without a backup it has to be downloaded; push all of it to the background so boot is not held up
    (
      cd / || exit 1
      close_fds
      exec setsid bash "$SELF" boot </dev/null >/dev/null 2>&1
    ) &
    say "steward $STEWARD_VERSION: loaded, service starting in the background"
    return 0
  fi
  say "steward $STEWARD_VERSION: plugin files in place"
  if ! need_binary; then
    warn "Plugin installed, but Claude Code has not downloaded successfully yet. Check the network, then press \"Start\" under Settings -> Steward, or run steward install in a terminal"
    return 0
  fi
  if sup_pid >/dev/null; then
    if ((changed)); then
      say "Script updated, restarting service to apply"
      if [ -n "${STEWARD_SVC:-}" ]; then
        # The plugin manager was started from a session inside the service (carrying the service tag): a direct restart would kill it too,
        # and its last step "copy the .plg to /boot/config/plugins" would never happen. Instead drop the tag, wait for it to finish, then restart
        (
          cd / || exit 1
          close_fds
          exec env -u "$TAG" setsid bash -c 'sleep 10; exec bash "$0" restart' "$SELF" </dev/null >/dev/null 2>&1
        ) &
        say "(Triggered from a session inside the service: restarting in the background in 10 seconds; Remote Control will drop briefly)"
      else
        cmd_restart
      fi
    else
      say "Service running, no restart needed"
    fi
  elif [ -f "$ENABLED" ]; then
    cmd_start
  elif [ "$(auth_method)" = "claude.ai" ]; then
    say "Next step: press \"Start\" under Settings -> Steward. If the first-time Remote Control setup has not been done yet, press \"Sign in & first-time setup\" first"
  else
    say "Next step: press \"Sign in & first-time setup\" under Settings -> Steward, or run steward setup in a terminal"
  fi
  boot_shared_over_smb && warn "The boot drive is currently shared over SMB, and the login credentials are stored on it. On the Main page, open the boot device and set Export under SMB Security Settings to No"
  return 0
}

cmd_plugin_remove() { do_uninstall; }

# Backend of the settings page (Settings -> Steward). Actions triggered by buttons always run in the background and the page polls for progress every second,
# so no web request ever waits until it times out, and progress is visible even for things that take minutes, like a download.

job_busy() { [ -e "$JOBLOCK" ] && ! flock -n "$JOBLOCK" true 2>/dev/null; }

cmd_gui() {
  local what=${1:-} arg=${2:-} sock p i
  case "$what" in
  status | poll) # The first lines are state for the page to parse, followed by the job log; status also appends the full status
    if job_busy; then say "busy 1"; else say "busy 0"; fi
    if sup_pid >/dev/null; then say "service 1"; else say "service 0"; fi
    if [ -f "$ENABLED" ]; then say "enabled 1"; else say "enabled 0"; fi
    say "--- job"
    if [ -s "$JOBLOG" ]; then
      strip_ansi <"$JOBLOG"
      [ -z "$(tail -c1 "$JOBLOG")" ] || say ""
    fi
    if [ "$what" = status ]; then
      say "--- status"
      cmd_status 2>&1
    fi
    ;;
  run)
    case "$arg" in start | stop | restart) ;; *) die "Unsupported action: $arg" ;; esac
    mkdir -p "$RUN_DIR"
    exec 7>"$JOBLOCK"
    if ! flock -n 7; then
      say "busy"
      return 0
    fi
    : >"$JOBLOG"
    ( # The lock (fd 7) is handed to the background job and released only when it exits
      cd / || exit 1
      close_fds 7
      exec setsid bash "$SELF" _gui job "$arg" </dev/null >>"$JOBLOG" 2>&1
    ) &
    exec 7>&-
    say "started"
    ;;
  job)
    case "$arg" in
    start) cmd_start ;;
    stop) cmd_stop ;;
    restart) cmd_restart ;;
    esac
    ;;
  terminal) # "Sign in & first-time setup": open a web terminal that only runs setup, at the URL /logterminal/steward/
    sock="$P/var/tmp/steward.sock"
    command -v ttyd-exec >/dev/null 2>&1 || die "This machine has no ttyd-exec; run steward setup in a terminal instead"
    for p in $(pgrep --ns $$ -x ttyd 2>/dev/null); do # If the window from last time is still open, end it first and wait until it is really gone before opening a new one
      [ -r "/proc/$p/cmdline" ] || continue
      tr '\0' '\n' <"/proc/$p/cmdline" 2>/dev/null | grep -qxF -- "$sock" || continue
      kill "$p" 2>/dev/null
      for ((i = 0; i < 20; i++)); do
        [ -d "/proc/$p" ] || break
        sleep 0.1
      done
    done
    mkdir -p "${sock%/*}"
    rm -f "$sock"
    ttyd-exec -om1 -i "$sock" bash "$SELF" _gui setup
    for ((i = 0; i < 30; i++)); do
      [ -S "$sock" ] && break
      sleep 0.1
    done
    [ -S "$sock" ] || die "The terminal did not start; run steward setup in the Unraid terminal instead"
    say "ok"
    ;;
  setup) # What runs inside that terminal window
    HOLD_WINDOW=1
    cmd_setup
    ;;
  *) return 2 ;;
  esac
}

# ───────────────────────── Optional skills ─────────────────────────
# Guides for Claude (array, docs, tools, health checks) that a user can opt into. A fresh install ships none of them:
# the plugin carries the files under $PLUGIN_DIR/skills, and "steward skills install" copies one into the config dir,
# where Claude Code picks it up at the next session. Script installs have no plugin dir and download from the repository.
SKILLS_SRC="$PLUGIN_DIR/skills"
SKILLS_DST="$CFG_DIR/skills"
SKILLS_RAW="https://raw.githubusercontent.com/hom-wang/steward/main/skills"
SKILL_NAMES="unraid unraid-docs unraid-tools unraid-health" # must match the skills/ directory in the repository (tests check)

skill_source() { # $1=name $2=download timeout in seconds. Prints the path of a SKILL.md to install from: the shipped copy, else a downloaded temp file
  if [ -f "$SKILLS_SRC/$1/SKILL.md" ]; then
    printf '%s\n' "$SKILLS_SRC/$1/SKILL.md"
    return 0
  fi
  local t
  t=$(mktemp "/tmp/.steward-install.$$.skill.XXXXXX") || return 1 # the cleanup trap removes /tmp/.steward-install.$$.* on any exit
  # Accept the download only if it looks like one of our skills: a captive portal or proxy page also answers 200
  if curl -fsSL --max-time "${2:-30}" "$SKILLS_RAW/$1/SKILL.md" -o "$t" 2>/dev/null && [ "$(head -n1 "$t")" = "---" ] &&
    grep -qx "name: $1" "$t" && [ -n "$(skill_meta "$t" skill-version)" ]; then
    printf '%s\n' "$t"
  else
    rm -f "$t"
    return 1
  fi
}
skill_meta() { # $1=SKILL.md $2=front-matter key (skill-version, unraid-verified, unraid-applies)
  sed -n '2,/^---$/p' "$1" | sed -n "s/^[[:space:]]*$2:[[:space:]]*\"\{0,1\}\([^\"]*\)\"\{0,1\}[[:space:]]*$/\1/p" | head -n1
}
skill_known() { # $1=name. Only names from the fixed list, so nothing outside $SKILLS_DST/<name> can ever be touched
  case "$1" in '' | *[!a-z0-9-]*) return 1 ;; esac
  case " $SKILL_NAMES " in *" $1 "*) return 0 ;; esac
  return 1
}
skill_tmp_done() { case "$1" in /tmp/.steward-install.*) rm -f "$1" ;; esac; }

cmd_skills() {
  local sub=${1:-list} name f dst state
  [ $# -gt 0 ] && shift
  case "$sub" in
  list)
    say "Optional skills. Install: steward skills install <name>   Remove: steward skills remove <name>"
    say "Installed skills live in $SKILLS_DST and are read by Claude Code at the start of each session."
    [ -d "$SKILLS_SRC" ] || say "(no shipped copies on this install; versions below come from a quick download and may be missing offline)"
    for name in $SKILL_NAMES; do
      state="not installed"
      if [ -f "$SKILLS_DST/$name/SKILL.md" ]; then state="installed $(skill_meta "$SKILLS_DST/$name/SKILL.md" skill-version)"; fi
      if f=$(skill_source "$name" 8); then
        if [ -f "$SKILLS_DST/$name/SKILL.md" ] && ! cmp -s "$f" "$SKILLS_DST/$name/SKILL.md"; then
          if [ "$(skill_meta "$f" skill-version)" = "$(skill_meta "$SKILLS_DST/$name/SKILL.md" skill-version)" ]; then
            state="$state, differs from the shipped copy (edited locally?)"
          else
            state="$state, update available $(skill_meta "$f" skill-version)"
          fi
        fi
        printf '  %-14s %-12s verified %-7s applies %-10s %s\n' "$name" "$(skill_meta "$f" skill-version)" "$(skill_meta "$f" unraid-verified)" "$(skill_meta "$f" unraid-applies)" "$state"
        skill_tmp_done "$f"
      else
        printf '  %-14s %-12s %-35s %s\n' "$name" "?" "(not available offline)" "$state"
      fi
    done
    ;;
  install)
    [ $# -ge 1 ] || die "usage: steward skills install <name> [<name> ...]   (names: $SKILL_NAMES)"
    for name in "$@"; do
      skill_known "$name" || die "unknown skill: $name (steward skills list)"
      f=$(skill_source "$name" 30) || die "cannot get $name: not shipped with this install and the download failed"
      dst=$SKILLS_DST/$name
      mkdir -p "$dst" || die "cannot create $dst"
      if [ -f "$dst/SKILL.md" ] && ! cmp -s "$f" "$dst/SKILL.md"; then
        cp -p "$dst/SKILL.md" "$dst/SKILL.md.before-$(date +%Y%m%d-%H%M%S)" || die "cannot back up the existing $dst/SKILL.md"
        say "$name: existing copy differs, kept as SKILL.md.before-<timestamp>"
      fi
      cp "$f" "$dst/SKILL.md" && chmod 644 "$dst/SKILL.md" || die "cannot write $dst/SKILL.md"
      say "$name $(skill_meta "$dst/SKILL.md" skill-version) installed (verified on Unraid $(skill_meta "$dst/SKILL.md" unraid-verified)); new sessions will see it"
      skill_tmp_done "$f"
    done
    ;;
  remove)
    [ $# -ge 1 ] || die "usage: steward skills remove <name> [<name> ...]"
    for name in "$@"; do
      skill_known "$name" || die "unknown skill: $name"
      if [ -d "$SKILLS_DST/$name" ]; then
        rm -rf "${SKILLS_DST:?}/$name" && say "$name removed (including its SKILL.md.before-* backups)"
      else
        say "$name is not installed"
      fi
    done
    rmdir "$SKILLS_DST" 2>/dev/null || true # back to the clean state when nothing is left
    ;;
  *) die "usage: steward skills [list | install <name> ... | remove <name> ...]" ;;
  esac
}

usage() {
  cat <<'EOF'
steward <command>
  install      First install or repair: create directories and hooks, prepare Claude Code (not needed manually for plugin installs)
  setup        Log in to claude.ai and complete the first-time Remote Control confirmation (needs an interactive terminal)
  start        Start the resident service and enable start at boot
  stop         Stop the service and disable start at boot
  restart      Restart the service (use after editing steward.conf)
  status       Service, login, version, last connection URL
  logs [-f|N]  Show the log
  update       Update Claude Code now (normally updated automatically daily after 08:00 when no session is in use)
  uninstall    Remove hooks and stop the service, keeping the data (for plugin installs, remove it on the Plugins page)
  skills       Optional guides for Claude: list, install <name>, remove <name>. Nothing is installed by default
EOF
}

cmd=${1:-help}
[ $# -gt 0 ] && shift

# These commands end every process under the service. If Claude inside the service called them itself, run them outside the service instead, so it does not kill itself halfway through
if [ -n "${STEWARD_SVC:-}" ]; then
  case "$cmd" in
  start | stop | restart | update | uninstall | watchdog) # watchdog may trigger the restart in auto_update
    log "$cmd requested from inside the service, handing it to the background"
    (
      cd / || exit 1
      close_fds
      exec env -u "$TAG" setsid bash "$SELF" "$cmd" "$@" </dev/null >/dev/null 2>&1
    ) &
    say "$cmd handed to the background. If the service restarts because of it, the Remote Control connection will drop briefly."
    exit 0
    ;;
  esac
fi

case "$cmd" in
install) cmd_install ;;
setup) cmd_setup ;;
start) cmd_start ;;
stop) cmd_stop ;;
restart) cmd_restart ;;
status) cmd_status ;;
logs) cmd_logs "$@" ;;
update) cmd_update ;;
uninstall) cmd_uninstall ;;
boot) cmd_boot ;;
shutdown) cmd_shutdown ;;
watchdog) cmd_watchdog ;;
_supervise) supervise ;;
_event) on_array_stop ;;
_plugin_install) cmd_plugin_install ;;
_plugin_remove) cmd_plugin_remove ;;
_gui) cmd_gui "$@" ;;
skills) cmd_skills "$@" ;;
*) usage ;;
esac
