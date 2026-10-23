#!/bin/bash
# Smoke test: in a fake root directory (STEWARD_TEST_ROOT) run a fresh install, a repeated install and an upgrade
# from claude-unraid, then check the files written. Only install / status are run, never start / restart / watchdog.
# Safe while the real service is running: under a fake root the TAG becomes STEWARD_SVC_TEST, so real processes
# are never touched and nothing is written to syslog.
# Usage: smoke-test.sh [path to steward.sh]. The binary cache from /boot/steward/cache is copied into the fake root
# so each run does not download 250 MB.
set -u
here=$(cd "$(dirname "$0")" && pwd)
src=$(readlink -f "${1:-$here/../steward.sh}")
BASE=$(mktemp -d /tmp/steward-smoke.XXXXXX)
trap 'rm -rf "$BASE"' EXIT
cd / || exit 1

fail=0 n=0
ok() { n=$((n + 1)); [ -n "${VERBOSE:-}" ] && echo "ok    $*"; return 0; }
bad() { n=$((n + 1)); fail=$((fail + 1)); echo "FAIL  $*"; return 0; }
check() { if "$@" >/dev/null 2>&1; then ok "$*"; else bad "$*"; fi; }

mkroot() { # $1=directory. Build a minimal fake Unraid root and drop in the binary cache
  mkdir -p "$1/boot/config/plugins/dynamix" "$1/var/run" "$1/var/log" "$1/root" "$1/usr/local/bin" "$1/boot/steward/cache"
  : >"$1/boot/config/go"
  cp -p /boot/steward/cache/claude-* "$1/boot/steward/cache/" 2>/dev/null || true
}
run() { STEWARD_TEST_ROOT=$1 timeout 120 bash "$src" "${@:2}" </dev/null; }
syslog_lines() { grep -c 'steward' /var/log/syslog 2>/dev/null || echo 0; }

# -- 1. Fresh install --
T=$BASE/fresh; mkroot "$T"
before=$(syslog_lines)
run "$T" install >"$BASE/fresh.log" 2>&1 || bad "fresh install exited non-zero (see $BASE/fresh.log)"
S=$T/boot/steward
for f in steward.sh steward.conf hooks/bash-guard.sh home/settings.json home/.claude.json home/CLAUDE.md; do check test -s "$S/$f"; done
check cmp -s "$S/steward.sh" "$src"
check grep -q -- '--spawn same-dir' "$S/steward.conf"
check bash -n "$S/steward.conf"
check jq -e '.dialogExpiry == "10m"' "$S/home/settings.json"
check jq -e '.hooks.PreToolUse[0].hooks[0].command == "bash /boot/steward/hooks/bash-guard.sh"' "$S/home/settings.json"
check jq -e '.permissions.disableBypassPermissionsMode == "disable"' "$S/home/settings.json"
check jq -e '(.permissions.allow|length) >= 15 and (.permissions.deny|length) >= 23 and (.permissions.ask|length) >= 34' "$S/home/settings.json"
check jq -e '.inputNeededNotifEnabled == true' "$S/home/.claude.json"
check bash -n "$S/hooks/bash-guard.sh"
check test -f "$T/boot/config/plugins/dynamix/steward.cron"
check grep -q 'steward.sh shutdown' "$T/boot/config/stop"
check test -x "$T/usr/local/bin/steward"
check test -f "$T/usr/local/emhttp/plugins/steward/event/stopping"
check grep -q -- '--spawn same-dir' "$S/steward.conf"
[ "$(syslog_lines)" = "$before" ] && ok "nothing written to syslog" || bad "test wrote to the real syslog ($before -> $(syslog_lines))"
grep -q '^TAG="STEWARD_SVC"' "$S/steward.sh" && ok "script carries the production TAG" || bad "script lacks the TAG"

# -- 2. Repeated install: existing settings untouched --
sum() { md5sum "$S/steward.conf" "$S/home/settings.json" "$S/home/CLAUDE.md" "$S/hooks/bash-guard.sh" | awk '{print $1}' | tr '\n' ' '; }
echo '# a change made by the user' >>"$S/steward.conf"
a=$(sum)
run "$T" install >"$BASE/again.log" 2>&1 || bad "second install exited non-zero"
[ "$(sum)" = "$a" ] && ok "repeated install keeps user settings" || bad "repeated install changed existing files"
run "$T" status >"$BASE/status.log" 2>&1; grep -qi 'service' "$BASE/status.log" && ok "status runs" || bad "unexpected status output (see $BASE/status.log)"

# -- 3. Upgrade from claude-unraid --
T=$BASE/legacy; mkroot "$T"
L=$T/boot/claude-code; mkdir -p "$L/home" "$L/hooks"
mv "$T/boot/steward/cache" "$L/cache"; rmdir "$T/boot/steward"
printf '# claude-unraid service options (legacy header). After editing, run: claude-unraid restart\nRC_ARGS=(--capacity 4)\n' >"$L/claude-unraid.conf"
printf '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"bash /boot/claude-code/hooks/bash-guard.sh"}]}]},"permissions":{"deny":["Read(//boot/claude-code/home/.credentials.json)"]}}\n' >"$L/home/settings.json"
printf '# legacy CLAUDE.md\nBackups live in /boot/claude-code/backups/\n' >"$L/home/CLAUDE.md"
: >"$L/hooks/bash-guard.sh"; : >"$L/enabled"
: >"$T/boot/config/plugins/claude-unraid.plg"
printf '# claude-unraid watchdog\n*/5 * * * * bash /boot/claude-code/claude-unraid.sh watchdog\n' >"$T/boot/config/plugins/dynamix/claude-unraid.cron"
printf '#!/bin/bash\n[ -f /boot/claude-code/claude-unraid.sh ] && bash /boot/claude-code/claude-unraid.sh shutdown # claude-unraid\n' >"$T/boot/config/stop"
: >"$T/boot/config/plugins/steward.plg" # simulate a plugin install
run "$T" _plugin_install >"$BASE/legacy.log" 2>&1 || bad "legacy upgrade exited non-zero (see $BASE/legacy.log)"
S=$T/boot/steward
check test -d "$S"
check test -L "$L"
[ "$(readlink "$L")" = steward ] && ok "old path is a symlink to steward" || bad "old path symlink is wrong: $(readlink "$L")"
check test -f "$S/steward.conf"
check test ! -e "$S/claude-unraid.conf"
check grep -q -- '--spawn same-dir' "$S/steward.conf"
check grep -q '^# Steward service options' "$S/steward.conf"
check grep -q 'steward restart' "$S/steward.conf"
grep -q 'claude-unraid' "$S/steward.conf" && bad "conf still mentions the old name" || ok "conf has no old name"
check jq -e '.hooks.PreToolUse[0].hooks[0].command == "bash /boot/steward/hooks/bash-guard.sh"' "$S/home/settings.json"
check jq -e '.permissions.deny[0] == "Read(//boot/steward/home/.credentials.json)"' "$S/home/settings.json"
check test -f "$S/home/settings.json.before-steward"
check test -f "$S/home/CLAUDE.md.before-steward"
grep -q '/boot/claude-code' "$S/home/CLAUDE.md" && bad "CLAUDE.md still has the old path" || ok "CLAUDE.md old path rewritten"
check test -f "$T/boot/config/plugins-removed/claude-unraid.plg"
check test ! -e "$T/boot/config/plugins/claude-unraid.plg"
check test ! -e "$T/boot/config/plugins/dynamix/claude-unraid.cron"
check test -f "$T/boot/config/plugins/dynamix/steward.cron"
grep -q 'claude-unraid' "$T/boot/config/stop" && bad "stop still has the old hook" || ok "old stop hook removed"
check grep -q 'steward.sh shutdown' "$T/boot/config/stop"
check test -f "$T/boot/config/stop.before-steward"
check test -f "$S/enabled"
[ "$(syslog_lines)" = "$before" ] && ok "upgrade test wrote nothing to syslog" || bad "upgrade test wrote to the real syslog"

# -- 3b. Upgrading an existing install: dialogExpiry added, everything else untouched --
T=$BASE/upgrade; mkroot "$T"
mkdir -p "$T/boot/steward/home"
printf '{"permissions":{"allow":["Bash(df *)"]},"myKey":1}\n' >"$T/boot/steward/home/settings.json"
: >"$T/boot/config/plugins/steward.plg"
run "$T" _plugin_install >"$BASE/upgrade.log" 2>&1 || bad "existing-install upgrade exited non-zero (see $BASE/upgrade.log)"
S=$T/boot/steward
check jq -e '.dialogExpiry == "10m" and .myKey == 1 and .permissions.allow == ["Bash(df *)"]' "$S/home/settings.json"
check test -f "$S/home/settings.json.before-$(sed -n 's/^STEWARD_VERSION="\(.*\)"/\1/p' "$src")"
run "$T" _plugin_install >/dev/null 2>&1
[ "$(ls "$S/home"/settings.json.before-* 2>/dev/null | wc -l)" = 1 ] && ok "upgrading again makes no second backup" || bad "upgrading again made another backup"
run "$T" status >"$BASE/status2.log" 2>&1; grep -q 'permission-mode' "$BASE/status2.log" && ok "status shows the mode" || bad "status does not show the mode (see $BASE/status2.log)"

# -- 4. Isolation: the fake root cannot see the real service's processes --
got=$(STEWARD_TEST_ROOT=$T bash -c 'P=x; TAG=STEWARD_SVC_TEST; '"$(sed -n '/^tagged_pids() {/,/^}/p' "$src")"'; tagged_pids' | wc -l)
[ "$got" = 0 ] && ok "tagged_pids sees no real service in test mode" || bad "tagged_pids still caught $got real processes in test mode"

echo "smoke-test: $((n - fail))/$n passed"
((fail == 0)) || { echo "logs are in $BASE (deleted on exit; set KEEP=1 to keep them)"; [ -n "${KEEP:-}" ] && trap - EXIT; }
((fail == 0))
