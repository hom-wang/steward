#!/bin/bash
# 煙霧測試：在 STEWARD_TEST_ROOT 假根目錄跑全新安裝、重複安裝、從 claude-unraid 升級，檢查寫出的檔案。
# 只跑 install / status，不跑 start / restart / watchdog。有真實服務在跑時也安全：
# 假根目錄下 TAG 會換成 STEWARD_SVC_TEST，不會碰到真實行程，也不寫 syslog。
# 用法：smoke-test.sh [steward.sh 路徑]。會把 /boot/steward/cache 的執行檔備份複製進假根目錄，避免每次下載 250MB。
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

mkroot() { # $1=目錄。建最小的假 Unraid 根目錄，並放入執行檔備份
  mkdir -p "$1/boot/config/plugins/dynamix" "$1/var/run" "$1/var/log" "$1/root" "$1/usr/local/bin" "$1/boot/steward/cache"
  : >"$1/boot/config/go"
  cp -p /boot/steward/cache/claude-* "$1/boot/steward/cache/" 2>/dev/null || true
}
run() { STEWARD_TEST_ROOT=$1 timeout 120 bash "$src" "${@:2}" </dev/null; }
syslog_lines() { grep -c 'steward' /var/log/syslog 2>/dev/null || echo 0; }

# ── 1. 全新安裝 ──
T=$BASE/fresh; mkroot "$T"
before=$(syslog_lines)
run "$T" install >"$BASE/fresh.log" 2>&1 || bad "fresh install 結束碼非 0（見 $BASE/fresh.log）"
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
[ "$(syslog_lines)" = "$before" ] && ok "沒有寫 syslog" || bad "測試寫進了真實 syslog（$before → $(syslog_lines)）"
grep -q '^TAG="STEWARD_SVC"' "$S/steward.sh" && ok "腳本含正式 TAG" || bad "腳本缺 TAG"

# ── 2. 重複安裝：不改既有設定 ──
sum() { md5sum "$S/steward.conf" "$S/home/settings.json" "$S/home/CLAUDE.md" "$S/hooks/bash-guard.sh" | awk '{print $1}' | tr '\n' ' '; }
echo '# 使用者自己的修改' >>"$S/steward.conf"
a=$(sum)
run "$T" install >"$BASE/again.log" 2>&1 || bad "再次 install 結束碼非 0"
[ "$(sum)" = "$a" ] && ok "重複安裝不覆蓋使用者設定" || bad "重複安裝改動了既有檔案"
run "$T" status >"$BASE/status.log" 2>&1; grep -q '服務' "$BASE/status.log" && ok "status 可執行" || bad "status 輸出異常（見 $BASE/status.log）"

# ── 3. 從 claude-unraid 升級 ──
T=$BASE/legacy; mkroot "$T"
L=$T/boot/claude-code; mkdir -p "$L/home" "$L/hooks"
mv "$T/boot/steward/cache" "$L/cache"; rmdir "$T/boot/steward"
printf '# claude-unraid 服務參數。改完執行：claude-unraid restart\nRC_ARGS=(--capacity 4)\n' >"$L/claude-unraid.conf"
printf '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"bash /boot/claude-code/hooks/bash-guard.sh"}]}]},"permissions":{"deny":["Read(//boot/claude-code/home/.credentials.json)"]}}\n' >"$L/home/settings.json"
printf '# 舊版 CLAUDE.md\n備份在 /boot/claude-code/backups/\n' >"$L/home/CLAUDE.md"
: >"$L/hooks/bash-guard.sh"; : >"$L/enabled"
: >"$T/boot/config/plugins/claude-unraid.plg"
printf '# claude-unraid watchdog\n*/5 * * * * bash /boot/claude-code/claude-unraid.sh watchdog\n' >"$T/boot/config/plugins/dynamix/claude-unraid.cron"
printf '#!/bin/bash\n[ -f /boot/claude-code/claude-unraid.sh ] && bash /boot/claude-code/claude-unraid.sh shutdown # claude-unraid\n' >"$T/boot/config/stop"
: >"$T/boot/config/plugins/steward.plg" # 模擬外掛安裝
run "$T" _plugin_install >"$BASE/legacy.log" 2>&1 || bad "legacy 升級結束碼非 0（見 $BASE/legacy.log）"
S=$T/boot/steward
check test -d "$S"
check test -L "$L"
[ "$(readlink "$L")" = steward ] && ok "舊路徑是指向 steward 的符號連結" || bad "舊路徑符號連結不對：$(readlink "$L")"
check test -f "$S/steward.conf"
check test ! -e "$S/claude-unraid.conf"
check grep -q -- '--spawn same-dir' "$S/steward.conf"
check grep -q '^# Steward 服務參數' "$S/steward.conf"
check grep -q 'steward restart' "$S/steward.conf"
grep -q 'claude-unraid' "$S/steward.conf" && bad "conf 仍有舊名稱" || ok "conf 沒有舊名稱"
check jq -e '.hooks.PreToolUse[0].hooks[0].command == "bash /boot/steward/hooks/bash-guard.sh"' "$S/home/settings.json"
check jq -e '.permissions.deny[0] == "Read(//boot/steward/home/.credentials.json)"' "$S/home/settings.json"
check test -f "$S/home/settings.json.before-steward"
check test -f "$S/home/CLAUDE.md.before-steward"
grep -q '/boot/claude-code' "$S/home/CLAUDE.md" && bad "CLAUDE.md 仍有舊路徑" || ok "CLAUDE.md 舊路徑已改寫"
check test -f "$T/boot/config/plugins-removed/claude-unraid.plg"
check test ! -e "$T/boot/config/plugins/claude-unraid.plg"
check test ! -e "$T/boot/config/plugins/dynamix/claude-unraid.cron"
check test -f "$T/boot/config/plugins/dynamix/steward.cron"
grep -q 'claude-unraid' "$T/boot/config/stop" && bad "stop 仍有舊鉤子" || ok "stop 舊鉤子已拆"
check grep -q 'steward.sh shutdown' "$T/boot/config/stop"
check test -f "$T/boot/config/stop.before-steward"
check test -f "$S/enabled"
[ "$(syslog_lines)" = "$before" ] && ok "升級測試沒有寫 syslog" || bad "升級測試寫進了真實 syslog"

# ── 3b. 既有安裝升級：補 dialogExpiry，其餘不動 ──
T=$BASE/upgrade; mkroot "$T"
mkdir -p "$T/boot/steward/home"
printf '{"permissions":{"allow":["Bash(df *)"]},"myKey":1}\n' >"$T/boot/steward/home/settings.json"
: >"$T/boot/config/plugins/steward.plg"
run "$T" _plugin_install >"$BASE/upgrade.log" 2>&1 || bad "既有安裝升級結束碼非 0（見 $BASE/upgrade.log）"
S=$T/boot/steward
check jq -e '.dialogExpiry == "10m" and .myKey == 1 and .permissions.allow == ["Bash(df *)"]' "$S/home/settings.json"
check test -f "$S/home/settings.json.before-$(sed -n 's/^STEWARD_VERSION="\(.*\)"/\1/p' "$src")"
run "$T" _plugin_install >/dev/null 2>&1
[ "$(ls "$S/home"/settings.json.before-* 2>/dev/null | wc -l)" = 1 ] && ok "再升級一次不會再備份" || bad "再升級一次又產生備份"
run "$T" status >"$BASE/status2.log" 2>&1; grep -q '模式　　：permission-mode' "$BASE/status2.log" && ok "status 顯示模式" || bad "status 沒顯示模式（見 $BASE/status2.log）"

# ── 4. 隔離：假根目錄下看不到真實服務的行程 ──
got=$(STEWARD_TEST_ROOT=$T bash -c 'P=x; TAG=STEWARD_SVC_TEST; '"$(sed -n '/^tagged_pids() {/,/^}/p' "$src")"'; tagged_pids' | wc -l)
[ "$got" = 0 ] && ok "tagged_pids 在測試模式下看不到真實服務" || bad "tagged_pids 在測試模式下仍抓到 $got 個真實行程"

echo "smoke-test：$((n - fail))/$n 通過"
((fail == 0)) || { echo "紀錄在 $BASE（結束時會刪除；要保留請設 KEEP=1）"; [ -n "${KEEP:-}" ] && trap - EXIT; }
((fail == 0))
