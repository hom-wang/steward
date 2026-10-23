#!/bin/bash
# auto_update 的情境測試。只把 auto_update 本身從 steward.sh 抽出來，其餘依賴（行程、網路、執行檔、重啟）全部換成假的，
# 所以不會碰到真實服務。用法：autoupdate-test.sh [steward.sh 路徑]
set -u
here=$(cd "$(dirname "$0")" && pwd)
src=${1:-$here/../steward.sh}
W=$(mktemp -d /tmp/steward-au-test.XXXXXX)
trap 'rm -rf "$W"' EXIT
# shellcheck disable=SC2034 # 這些變數給被 source 進來的 auto_update() 用
RUN_DIR=$W CFG_DIR=$W INSTALL_LOG=$W/install.log NATIVE_BIN=fake_claude
eval "$(sed -n '/^AU_DONE=/,/^AU_NEXT=/p; /^auto_update() {/,/^}/p' "$src")"
declare -f auto_update >/dev/null || { echo "在 $src 找不到 auto_update()" >&2; exit 2; }

# 可調的假狀態
HOUR=9 NOW=1000000 INSTALLED=2.1.296 RUNNING=2.1.296 STABLE=2.1.308 BUSY=0 INSTALL_OK=1 RESTART_OK=1 CALLS=""
date() { case "$1" in +%F) echo 2026-10-23 ;; +%s) echo "$NOW" ;; +%-H) echo "$HOUR" ;; esac; }
timeout() { shift; "$@"; } # 真的 timeout 跑不了 shell 函式
log() { :; }
claude_ok() { true; }
claude_ver() { cat "$W/installed"; }
running_ver() { [ -n "$RUNNING" ] && echo "$RUNNING"; }
sessions_busy() { ((BUSY)); }
curl() { [ -n "$STABLE" ] && echo "$STABLE"; }
# auto_update 在子 shell 裡呼叫安裝，所以安裝的紀錄要寫進檔案才看得到
fake_claude() { printf 'install:%s ' "$2" >>"$W/calls"; ((INSTALL_OK)) && echo "$2" >"$W/installed"; }
cache_binary() { CALLS+="cache "; }
cmd_restart() { CALLS+="restart "; ((RESTART_OK)) && RUNNING=$(claude_ver); ((RESTART_OK)); }
notify_user() { CALLS+="notify "; }
reset() { rm -f "$AU_DONE" "$AU_NEXT" "$W/calls"; CALLS=""; echo "$INSTALLED" >"$W/installed"; }

fail=0 n=0
check() { # $1=說明 $2=預期的呼叫序列 $3=預期是否已記為今天完成（y/n）
  local d=n
  CALLS="$(cat "$W/calls" 2>/dev/null)$CALLS"
  rm -f "$W/calls"
  [ -f "$AU_DONE" ] && d=y
  n=$((n + 1))
  if [ "$CALLS" = "$2" ] && [ "$d" = "$3" ]; then
    [ -n "${VERBOSE:-}" ] && echo "ok    $1"
  else
    echo "FAIL  $1：呼叫='$CALLS' 預期 '$2'；done=$d 預期 $3"
    fail=$((fail + 1))
  fi
}

reset; HOUR=7; auto_update; check "早上 7 點不動作" "" n
HOUR=9
reset; STABLE=2.1.296; auto_update; check "已是最新：記為今天完成" "" y
reset; STABLE=2.1.290; auto_update; check "比 stable 新：不降版" "" y
reset; STABLE=; auto_update; check "查不到版本（斷網）：不動作、一小時後再試" "" n
reset; STABLE=garbage; auto_update; check "版本字串不合法：不動作" "" n
STABLE=2.1.308
reset; auto_update; check "有新版、沒人用：安裝、備份、重啟、通知" "install:2.1.308 cache restart notify " y
CALLS=""; NOW=$((NOW + 7200)); auto_update; check "同一天第二次：不動作" "" y
INSTALLED=2.1.296 RUNNING=2.1.296
reset; BUSY=1; auto_update; check "有人在用：只安裝，不重啟" "install:2.1.308 cache " n
CALLS=""; NOW=$((NOW + 1800)); auto_update; check "半小時後：還沒到重試時間" "" n
CALLS=""; NOW=$((NOW + 1900)); auto_update; check "一小時後仍忙：不重裝也不重啟" "" n
CALLS=""; NOW=$((NOW + 3700)); BUSY=0; auto_update; check "閒下來：不重裝，直接重啟套用" "restart notify " y
INSTALLED=2.1.296 RUNNING=2.1.296
reset; INSTALL_OK=0; auto_update; check "安裝失敗：不重啟、不記完成" "install:2.1.308 " n
INSTALL_OK=1
reset; RESTART_OK=0; auto_update; check "重啟失敗：不記完成、不發通知" "install:2.1.308 cache restart " n
RESTART_OK=1
reset; RUNNING=; auto_update; check "remote-control 不在：不動作" "" n
RUNNING=2.1.296

echo "autoupdate-test：$((n - fail))/$n 通過"
((fail == 0))
