#!/bin/bash
# Scenario tests for the pinned, verified Claude Code download and the checksum checks around it (cache, restore,
# verification after an update). Everything is mocked: curl copies a local fixture, nothing is fetched, and no real
# Claude Code installation is touched. Usage: download-test.sh [path to steward.sh]
set -u
here=$(cd "$(dirname "$0")" && pwd)
src=${1:-$here/../steward.sh}
W=$(mktemp -d /tmp/steward-dl-test.XXXXXX)
trap 'rm -rf "$W"' EXIT
HOME=$W/root
# shellcheck disable=SC2034 # used by the sourced functions
VERSIONS=$HOME/.local/share/claude/versions NATIVE_BIN=$HOME/.local/bin/claude CACHE=$W/cache RUN_DIR=$W/run INSTALL_LOG=$W/install.log LOG=$W/steward.log NETWAIT=0
CLAUDE_RELEASES=https://example.invalid/releases CLAUDE_PLATFORM=linux-x64
mkdir -p "$RUN_DIR" "$CACHE"
eval "$(sed -n '/^manifest_sha256() {/,/^}/p; /^other_version() {/,/^}/p; /^verify_installed() {/,/^}/p; /^cache_binary() {/,/^}/p; /^restore_binary() {/,/^}/p; /^download_binary() {/,/^}/p; /^ensure_binary() {/,/^}/p' "$src")"
for f in manifest_sha256 other_version verify_installed cache_binary restore_binary download_binary ensure_binary; do
  declare -f "$f" >/dev/null || { echo "$f() not found in $src" >&2; exit 2; }
done
# one-line helpers from steward.sh, repeated here because a sed range cannot extract a one-liner safely
file_sha256() { sha256sum "$1" 2>/dev/null | awk '{print $1; exit}'; }
claude_ok() { [ -x "$NATIVE_BIN" ] && "$NATIVE_BIN" --version >/dev/null 2>&1; }
claude_ver() { "$NATIVE_BIN" --version 2>/dev/null | awk '{print $1; exit}'; }
spin_msg() { :; }
log() { echo "log: $*" >>"$LOG"; }
notify_user() { echo "notify: $1" >>"$LOG"; }

# The "binary" is a script that answers --version like the real one
FIX=$W/fixture
printf '#!/bin/bash\necho "9.9.9 (fake)"\n' >"$FIX"
FIX_SUM=$(file_sha256 "$FIX")
CLAUDE_PIN_VERSION=9.9.9 CLAUDE_PIN_SHA256=$FIX_SUM
TAMPER=0 OFFLINE=0 MANIFEST_SUM=$FIX_SUM
curl() { # mock: only the URL and -o matter. Records every call
  local out="" url="" a
  for a in "$@"; do case "$a" in http*) url=$a ;; esac; done
  while [ $# -gt 0 ]; do [ "$1" = -o ] && out=$2; shift; done
  echo "$url" >>"$W/curl.calls"
  ((OFFLINE)) && return 6
  case "$url" in
  */manifest.json)
    [ "$out" = /dev/null ] && return 0
    printf '{"version":"x","platforms":{"linux-x64":{"checksum":"%s","size":1}}}\n' "$MANIFEST_SUM"
    return 0
    ;;
  */linux-x64/claude)
    if ((TAMPER)); then printf '#!/bin/bash\necho "9.9.9 (tampered)"\n' >"$out"; else cp "$FIX" "$out"; fi
    return 0
    ;;
  esac
  return 22
}
reset() { rm -rf "$HOME" "$CACHE" "$W/curl.calls"; : >"$LOG"; : >"$INSTALL_LOG"; mkdir -p "$CACHE"; TAMPER=0 OFFLINE=0 MANIFEST_SUM=$FIX_SUM; }
good_cache() { mkdir -p "$CACHE"; cp "$FIX" "$CACHE/claude-9.9.9"; echo "$FIX_SUM" >"$CACHE/claude-9.9.9.sha256"; }

fail=0 n=0
ok() { n=$((n + 1)); [ -n "${VERBOSE:-}" ] && echo "ok    $*"; return 0; }
bad() { n=$((n + 1)); fail=$((fail + 1)); echo "FAIL  $*"; return 0; }
check() { if "$@" >/dev/null 2>&1; then ok "$*"; else bad "$*"; fi; }

# -- 1. Fresh download of the pinned version --
reset
download_binary && ok "download_binary succeeds" || bad "download_binary failed: $(cat "$INSTALL_LOG")"
check test "$(claude_ver)" = 9.9.9
check test "$(readlink -f "$NATIVE_BIN")" = "$VERSIONS/9.9.9"
check grep -q 'SHA256 verified' "$INSTALL_LOG"
check test -f "$CACHE/claude-9.9.9"
check test "$(cat "$CACHE/claude-9.9.9.sha256")" = "$FIX_SUM"
check test ! -e "$VERSIONS/.download.$$"
grep -q 'install.sh' "$W/curl.calls" && bad "install.sh was fetched" || ok "install.sh is never fetched"

# -- 2. Tampered download: refused, nothing installed, nothing cached --
reset; TAMPER=1
download_binary && bad "tampered download was accepted" || ok "tampered download refused"
check grep -q 'SHA256 mismatch' "$INSTALL_LOG"
check test ! -e "$VERSIONS/9.9.9"
check test ! -e "$NATIVE_BIN"
[ -z "$(ls -A "$CACHE")" ] && ok "cache stays empty after a refused download" || bad "cache not empty after a refused download"
[ -z "$(ls -A "$VERSIONS" 2>/dev/null)" ] && ok "no temp file left in versions/" || bad "leftover in versions/: $(ls -A "$VERSIONS")"

# -- 3. Offline: no install.sh fallback, clear message --
reset; OFFLINE=1
download_binary && bad "download succeeded while offline" || ok "download fails while offline"
check grep -q 'not reachable' "$INSTALL_LOG"

# -- 4. Restore from a good backup needs no network --
reset; good_cache
ensure_binary && ok "ensure_binary restores from the boot drive" || bad "ensure_binary failed with a good backup"
check test "$(claude_ver)" = 9.9.9
[ -e "$W/curl.calls" ] && bad "restore touched the network" || ok "restore made no network call"

# -- 5. Corrupted backup: rejected and discarded, then re-downloaded --
reset; good_cache; echo "garbage" >>"$CACHE/claude-9.9.9"
restore_binary && bad "corrupted backup was restored" || ok "corrupted backup rejected"
check test ! -e "$CACHE/claude-9.9.9"
check test ! -e "$CACHE/claude-9.9.9.sha256"
check grep -q 'does not match its SHA256' "$LOG"
ensure_binary && ok "ensure_binary falls back to downloading" || bad "ensure_binary did not recover by downloading"
check test "$(claude_ver)" = 9.9.9

# -- 6. A replaced backup of the pinned version with a matching .sha256 is still rejected (the pin wins) --
reset; mkdir -p "$CACHE"; printf '#!/bin/bash\necho "9.9.9 (replaced)"\n' >"$CACHE/claude-9.9.9"; file_sha256 "$CACHE/claude-9.9.9" >"$CACHE/claude-9.9.9.sha256"
restore_binary && bad "replaced pinned backup was restored" || ok "replaced pinned backup rejected"
check test ! -e "$CACHE/claude-9.9.9"

# -- 7. A backup of another version is checked against its own recorded SHA256 --
reset; mkdir -p "$CACHE"; printf '#!/bin/bash\necho "9.9.8 (fake)"\n' >"$CACHE/claude-9.9.8"; file_sha256 "$CACHE/claude-9.9.8" >"$CACHE/claude-9.9.8.sha256"
restore_binary && ok "other version restored from a matching backup" || bad "matching backup of another version rejected"
check test "$(claude_ver)" = 9.9.8

# -- 8. verify_installed after Claude Code's own updater --
setup_versions() { reset; mkdir -p "$VERSIONS" "${NATIVE_BIN%/*}"; printf '#!/bin/bash\necho "9.9.8 (fake)"\n' >"$VERSIONS/9.9.8"; cp "$FIX" "$VERSIONS/9.9.9"; chmod 755 "$VERSIONS"/*; ln -sfn "$VERSIONS/9.9.9" "$NATIVE_BIN"; }
setup_versions
verify_installed 9.9.9 && ok "verify_installed accepts a matching binary" || bad "verify_installed rejected a matching binary"
check test "$(claude_ver)" = 9.9.9
setup_versions; MANIFEST_SUM=0000000000000000000000000000000000000000000000000000000000000000
verify_installed 9.9.9 && bad "verify_installed accepted a mismatching binary" || ok "verify_installed rejects a mismatching binary"
check test ! -e "$VERSIONS/9.9.9"
check test "$(claude_ver)" = 9.9.8
check grep -q 'notify: Claude Code 9.9.9 failed verification' "$LOG"
setup_versions; MANIFEST_SUM=""
verify_installed 9.9.9 && bad "verify_installed accepted without a published checksum" || ok "verify_installed refuses when no checksum can be fetched"
check test "$(claude_ver)" = 9.9.8
grep -q 'notify:' "$LOG" && bad "a fetch failure sent a notification" || ok "a fetch failure does not notify"
setup_versions; rm -f "$VERSIONS/9.9.8"; MANIFEST_SUM=0000000000000000000000000000000000000000000000000000000000000000
verify_installed 9.9.9 && bad "accepted" || ok "mismatch with no other version removes the launcher"
check test ! -e "$NATIVE_BIN"

echo "download-test: $((n - fail))/$n passed"
((fail == 0))
