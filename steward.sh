#!/bin/bash
[ -f "$0" ] && grep -q $'\r' "$0" && { tr -d '\r' <"$0" >"/tmp/.steward.$$" && exec bash "/tmp/.steward.$$" "$@"; } # 檔案若被存成 Windows 換行，轉換後重跑
#
# Steward — 讓 Claude Code 以常駐服務跑在 Unraid 主機上，用 Remote Control 從手機或瀏覽器操作。
# 不依賴陣列、不依賴 Docker：陣列停止時服務照常運作。
#
# Copyright (c) 2026 hom-wang (https://github.com/hom-wang)
# Steward is an independent, community-maintained project. It is not affiliated with, endorsed by,
# or sponsored by Anthropic PBC or Lime Technology, Inc. "Claude" and "Claude Code" are trademarks of
# Anthropic PBC; "Unraid" is a trademark of Lime Technology, Inc. This tool installs the unmodified
# Claude Code binary via Anthropic's official installer and runs it as a background service. You sign
# in with your own Claude subscription through Anthropic's own login flow; Steward never sees, stores,
# or forwards your credentials, and all usage is billed to your own account.
# （Steward 是獨立的社群專案，與 Anthropic、Lime Technology 無關。它安裝未修改的官方 Claude Code
#   執行檔並以服務方式執行；登入走 Anthropic 自己的流程，Steward 不經手憑證，用量算在你自己的帳號。）
#
# 適用：Unraid 7.3 以上、Internal Boot（/boot 是 ZFS）。USB (FAT) 開機不適用。
# 安裝方式二選一（不要兩種都裝）：
#   外掛：webGUI 的 Plugins → Install Plugin 安裝 steward.plg（裡面包著這支腳本），
#         之後在 Settings → Steward 操作；終端機裡的 steward <指令> 一樣能用。
#   腳本：bash steward.sh install        之後直接打 steward <指令>
# 從舊名稱 claude-unraid 升級：直接安裝即可，資料會自動從 /boot/claude-code 搬到 /boot/steward，
#   舊路徑保留為符號連結，舊鉤子與舊外掛檔會被拆掉。
#
# 東西放在哪裡
#   /boot/steward/           開機碟上，陣列停止時仍在
#     steward.sh           本腳本
#     steward.conf         服務參數
#     home/                      Claude Code 的設定目錄：登入憑證、settings.json、CLAUDE.md、對話紀錄
#     workspace/                 Remote Control 的工作目錄
#     cache/                     Claude Code 執行檔的備份；開機時還原到 RAM，不需要網路
#   刻意不放在 /boot/config 底下：Unraid Connect 的 flash backup 會把整個 config/ 上傳雲端，
#   登入憑證不該跟著上去。/boot/config 裡只有不含機密的掛鉤：
#     stop 一行、plugins/dynamix/steward.cron（watchdog），
#     再加上 go 一行（腳本安裝）或 plugins/steward.plg（外掛安裝）。
#   webGUI 的本機 Flash Backup 是把整個開機碟打包成 zip，裡面會有這個目錄，請把那個 zip 當成機密保管。
#   執行檔本體在 RAM（/root/.local/share/claude）。remote-control 模式下 Claude Code 不會自己更新，
#   改由 watchdog 每天 08:00 後檢查一次，沒有 session 在用才重啟套用（見 auto_update）。

set -u
STEWARD_VERSION="2026.10.24"
SPIN_PID="" SPIN_FILE="" SPIN_MSG="" SPIN_T0=0 SPIN_ACTIVE=0 SPIN_OWNER=$$ FANCY=0 TTY_FD=2 HOLD_WINDOW=0
cleanup() { # 任何方式結束都會跑到這裡，包含 Ctrl+C 與終端機被關掉
  if [ -n "$SPIN_PID" ]; then # 進度顯示還在：停掉，並把那一行擦乾淨
    kill "$SPIN_PID" 2>/dev/null
    wait "$SPIN_PID" 2>/dev/null
    ((FANCY)) && printf '\r\033[K' >&"$TTY_FD"
  fi
  [ -n "$SPIN_FILE" ] && rm -f "$SPIN_FILE" "$SPIN_FILE.new"
  rm -f "/tmp/.steward-install.$$".* 2>/dev/null
  case "$0" in /tmp/.steward.*) rm -f "$0" ;; esac
  if ((HOLD_WINDOW)) && [ -t 0 ]; then # 設定頁開的終端機視窗：停一下，不然程式一結束就看不到結果
    printf '\n可以關閉這個視窗了（按任意鍵結束）' >&"$TTY_FD"
    read -r -n 1 -s _
  fi
  return 0
}
trap cleanup EXIT
trap 'exit 130' INT

P="${STEWARD_TEST_ROOT:-}" # 只給測試用的假根目錄；正式環境是空字串
ROOT="$P/boot/steward"
SELF="$ROOT/steward.sh"
CONF="$ROOT/steward.conf"
CFG_DIR="$ROOT/home"
WORKSPACE="$ROOT/workspace"
CACHE="$ROOT/cache"
ENABLED="$ROOT/enabled" # 這個檔案存在 = 開機自動啟動
GO="$P/boot/config/go"
STOP="$P/boot/config/stop"
CRON="$P/boot/config/plugins/dynamix/steward.cron"
PLUGIN_DIR="$P/usr/local/emhttp/plugins/steward"
BIN_DIR="$P/usr/local/bin"
RUN_DIR="$P/var/run"
LOG="$P/var/log/steward.log"
PIDFILE="$RUN_DIR/steward.pid"
LOCKFILE="$RUN_DIR/steward.lock"
DOWN_FLAG="$RUN_DIR/steward.shutdown" # 關機中：不要再把服務拉起來
ARRAY_MNT="$P/mnt"
TAG="STEWARD_SVC" # 服務底下所有行程都帶這個環境變數，靠它辨識
[ -n "$P" ] && TAG="STEWARD_SVC_TEST" # 假根目錄測試：用另一個標記，tagged_pids / kill_tagged 才不會碰到真實服務
MARK="# steward"
PLG="$P/boot/config/plugins/steward.plg"   # 這個檔案存在 = 是用外掛安裝的
INSTALL_LOG="$RUN_DIR/steward.install.log" # 官方安裝程式最近一次的輸出
JOBLOG="$RUN_DIR/steward.job.log"          # 設定頁按鈕觸發的工作，輸出寫在這裡給網頁讀
JOBLOCK="$RUN_DIR/steward.job.lock"
PLUGIN=0
[ -f "$PLG" ] && PLUGIN=1

export HOME="$P/root"
export CLAUDE_CONFIG_DIR="$CFG_DIR"
export PATH="$BIN_DIR:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$HOME/.local/bin"
case "${LC_ALL:-${LANG:-}}" in *[Uu][Tt][Ff]*) ;; *) export LANG=C.UTF-8 ;; esac # 開機腳本的環境沒有語系，補上 UTF-8
NATIVE_BIN="$HOME/.local/bin/claude"
VERSIONS="$HOME/.local/share/claude/versions"

if [ -n "${STEWARD_TEST_FAST:-}" ]; then TICK=2 BASE=1 HEALTHY=4 NETWAIT=1 BEAT=2; else TICK=600 BASE=5 HEALTHY=300 NETWAIT=10 BEAT=10; fi

# 進度動畫只在互動式終端機上畫；輸出被導到檔案或管線時，改成一步印一行文字。
# 終端機另外留一份在 TTY_FD：某個步驟的 stderr 被暫時導進紀錄檔時按 Ctrl+C，收尾仍然要能把那一行擦掉
if [ -t 1 ] && [ -t 2 ] && [ "${TERM:-dumb}" != dumb ]; then
  FANCY=1
  exec {TTY_FD}>&2
fi
SPIN_FRAMES='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' OK_MARK='✔' BAD_MARK='✘' PLAIN=0
case "${TERM:-}" in linux | vt[0-9]*) PLAIN=1 ;; esac # 接螢幕的本機主控台，字型裡沒有這些符號
[ "${#SPIN_FRAMES}" -le 10 ] || PLAIN=1              # 語系不是 UTF-8 時，那串符號會被算成 30 個位元組
if ((PLAIN)); then SPIN_FRAMES='|/-'"\\" OK_MARK='*' BAD_MARK='x'; fi

RC_ARGS=(--spawn same-dir --capacity 4)
# shellcheck disable=SC1090
[ -f "$CONF" ] && . <(tr -d '\r' <"$CONF")

say() { printf '%s\n' "$*"; }
warn() { printf '注意：%s\n' "$*" >&2; }
err() { printf '錯誤：%s\n' "$*" >&2; }
die() {
  [ -n "$SPIN_PID" ] && spin_stop clear
  err "$*"
  exit 1
}
log() {
  printf '%s [steward] %s\n' "$(date '+%F %T')" "$*" >>"$LOG" 2>/dev/null
  [ -z "$P" ] && { logger -t steward -- "$*" 2>/dev/null || true; } # 假根目錄測試不寫 syslog
  return 0
}
strip_ansi() { sed -u -e 's/\x1b\[[0-9;?]*[A-Za-z]//g' -e 's/\x1b\][^\x07\x1b]*\(\x07\|\x1b\\\)//g' -e 's/\r/\n/g'; }

notify_user() { # $1=主旨 $2=內容 $3=等級（預設 warning）。走 Unraid 內建通知，會轉送到你設定的 email / Telegram 等
  local n="$P/usr/local/emhttp/webGui/scripts/notify"
  [ -x "$n" ] && "$n" -e "Steward" -s "$1" -d "$2" -i "${3:-warning}" >/dev/null 2>&1
  log "通知：$1 — $2"
}

# ───────────────────────── 等待時的進度顯示 ─────────────────────────
# 用法：spin_start "訊息" → 做事（途中可用 spin_msg 換文字）→ spin_stop ok|fail|clear ["結尾訊息"]
# 事情在前景做、進度在背景畫，所以 Ctrl+C 中斷的是真正在跑的指令，不會留下東西在背景繼續跑。
# 有終端機時畫動畫。沒有終端機時（外掛安裝視窗、設定頁的工作紀錄、輸出被導到檔案）一步印一行，
# 久的步驟每 10 秒補一行，讓人知道還在跑。

spin_extra() { # $1=要量大小的路徑（可空、可多個）。印出「　123 MB　45 秒」這樣的附註
  local sz=0 secs=$((SECONDS - SPIN_T0)) out=""
  # shellcheck disable=SC2086
  [ -n "$1" ] && sz=$(du -sm $1 2>/dev/null | awk '{s += $1} END {print s + 0}')
  ((${sz:-0} > 0)) && out="　$sz MB"
  ((secs >= 3)) && out="$out　$secs 秒"
  printf '%s' "$out"
}

spin_loop() { # 背景迴圈。啟動它的 shell 不見了就自己收工，不會留在終端機上亂畫
  trap 'kill ${!:-} 2>/dev/null; exit 0' TERM
  local i=0 n=${#SPIN_FRAMES} msg="" path="" line="" cols a
  if ((!FANCY)); then
    while
      sleep "$BEAT" >/dev/null 2>&1 & # sleep 不接輸出：萬一它變成孤兒，也不會讓讀取這條管線的程式空等
      wait $!
      [ -e "$SPIN_FILE" ] && [ -d "/proc/$SPIN_OWNER" ]
    do
      { IFS= read -r msg && IFS= read -r path; } 2>/dev/null <"$SPIN_FILE"
      say "　$msg，還在進行$(spin_extra "$path")"
    done
    return 0
  fi
  sleep 0.4 >/dev/null 2>&1 &
  wait $! # 不到半秒就做完的步驟不畫，免得閃一下
  while [ -e "$SPIN_FILE" ] && [ -d "/proc/$SPIN_OWNER" ]; do
    if ((i % 10 == 0)); then # 文字每秒更新一次
      { IFS= read -r msg && IFS= read -r path; } 2>/dev/null <"$SPIN_FILE"
      line="$msg$(spin_extra "$path")"
      cols=$(stty size <&"$TTY_FD" 2>/dev/null | cut -d' ' -f2) # 順序不能反：先把 stdin 接到終端機，再丟掉錯誤訊息
      a=${line//[^[:ascii:]]/} # 英數算 1 欄、中文算 2 欄。超出視窗寬度就截掉，折行會把畫面弄亂
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

spin_start() { # spin_start [-t] "進行中的訊息"。-t 用在查詢類的短暫等待：做完不留痕跡
  local transient=0
  if [ "${1:-}" = -t ]; then
    transient=1
    shift
  fi
  SPIN_MSG=$1 SPIN_T0=$SECONDS SPIN_ACTIVE=$((1 - transient)) SPIN_OWNER=$BASHPID SPIN_FILE="" SPIN_PID=""
  if ((!FANCY)); then
    ((transient)) && return 0
    say "… $1"
  fi
  SPIN_FILE=$(mktemp /tmp/.steward-spin.XXXXXX 2>/dev/null) || SPIN_FILE=""
  [ -n "$SPIN_FILE" ] || return 0
  printf '%s\n' "$1" >"$SPIN_FILE"
  spin_loop &
  SPIN_PID=$!
}

spin_msg() { # spin_msg "新訊息" [路徑]。有給路徑就一併顯示它目前佔多少 MB，下載時看得出有沒有在動
  ((SPIN_ACTIVE)) || return 0
  ((FANCY)) || say "… $1"
  [ -n "$SPIN_FILE" ] && printf '%s\n%s\n' "$1" "${2:-}" >"$SPIN_FILE.new" 2>/dev/null && mv -f "$SPIN_FILE.new" "$SPIN_FILE" 2>/dev/null
  return 0
}

spin_stop() { # spin_stop ok|fail|clear ["結尾訊息"]
  local how=${1:-ok} msg=${2:-$SPIN_MSG} secs=$((SECONDS - SPIN_T0)) took=""
  if [ -n "$SPIN_PID" ]; then
    kill "$SPIN_PID" 2>/dev/null
    wait "$SPIN_PID" 2>/dev/null
    ((FANCY)) && printf '\r\033[K' >&"$TTY_FD"
  fi
  [ -n "$SPIN_FILE" ] && rm -f "$SPIN_FILE" "$SPIN_FILE.new"
  SPIN_PID="" SPIN_FILE="" SPIN_ACTIVE=0
  ((secs >= 3)) && took="（$secs 秒）"
  case "$how" in
  ok) if ((FANCY)); then printf '\033[32m%s\033[0m %s%s\n' "$OK_MARK" "$msg" "$took"; else say "$OK_MARK $msg$took"; fi ;;
  fail) if ((FANCY)); then printf '\033[31m%s\033[0m %s\n' "$BAD_MARK" "$msg" >&2; else printf '%s %s\n' "$BAD_MARK" "$msg" >&2; fi ;;
  esac
  return 0
}

# ───────────────────────── 行程管理 ─────────────────────────

tagged_pids() { # 服務啟動的所有行程。用環境變數辨識，不怕行程自己 setsid 或被 init 收養
  local f
  grep -lszxF "$TAG=1" /proc/[0-9]*/environ 2>/dev/null | while IFS= read -r f; do
    f=${f#/proc/}
    f=${f%/environ}
    [ "$f" = "$$" ] || echo "$f"
  done
}

kill_tagged() { # $1=等待秒數。先 TERM，逾時才 KILL
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

sup_pid() { # 印出執行中的 supervisor pid；沒在跑就回傳 1
  local pid
  pid=$(cat "$PIDFILE" 2>/dev/null) || return 1
  [[ $pid =~ ^[0-9]+$ ]] && [ -r "/proc/$pid/cmdline" ] || return 1
  tr '\0' ' ' 2>/dev/null <"/proc/$pid/cmdline" | grep -q -- ' _supervise' || return 1
  echo "$pid"
}

close_fds() { # 在即將 exec 成背景行程的子 shell 裡呼叫：除了 0、1、2（和 $1 指定的）之外，不繼承呼叫者開著的檔案
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
  [ -n "$P" ] && { log "測試模式（STEWARD_TEST_ROOT）：不啟動服務"; return 0; } # 假根目錄裡絕不起真的行程
  sup_pid >/dev/null && return 0
  [ -f "$SELF" ] || return 1
  kill_tagged 15 # supervisor 不在卻還有殘留行程（例如它被意外殺掉）：先清掉，免得兩個 remote-control 搶同一個目錄
  # cd /：supervisor 不能繼承呼叫者的工作目錄，萬一那是 /mnt 底下就會卡住陣列。
  # 用 exec：中間不留一個握著呼叫者終端機的 shell
  (
    cd / || exit 1
    close_fds # 從網頁啟動時，呼叫者是 php-fpm；它的連線不該被常駐行程握著
    exec env "$TAG=1" setsid bash "$SELF" _supervise </dev/null >/dev/null 2>&1
  ) &
  local i
  for ((i = 0; i < 50; i++)); do
    sup_pid >/dev/null && return 0
    sleep 0.1
  done
  return 1
}

rotate_log() { # claude 以 append 模式寫紀錄，所以可以直接清空；/var/log 在 RAM，不能放任它長大
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
  "") echo "請執行 steward status 查看原因" ;;
  *ogin* | *"logged in"* | *subscription* | *token* | *"not trusted"* | *"nable Remote Control"*)
    echo "$last ／ 請在 Unraid 終端機執行：steward setup" ;;
  *) echo "$last ／ 服務會持續重試，細節請執行 steward logs" ;;
  esac
}

supervise() { # 常駐迴圈：claude remote-control 結束就重啟，連續失敗時逐步拉長間隔
  cd "$ROOT" 2>/dev/null || cd /
  exec 9>"$LOCKFILE"
  flock -n 9 || exit 0
  echo "$$" >"$PIDFILE"
  log "服務啟動（supervisor pid $$）"
  # 子行程一律關掉 9 號 fd，否則 supervisor 死後它們會繼續握著鎖，新的起不來
  (while sleep "$TICK"; do
    rotate_log
    cache_binary
  done) 9>&- &
  local fails=0 notified=0 t0 ran rc delay
  while [ -f "$ENABLED" ] && [ ! -f "$DOWN_FLAG" ]; do
    if ! cd "$WORKSPACE" 2>/dev/null; then
      log "進不去 $WORKSPACE，60 秒後再試"
      sleep 60 9>&-
      continue
    fi
    if ! claude_ok && ! ensure_binary 9>&-; then
      log "Claude Code 無法使用，60 秒後再試"
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
    delay=$((BASE << (fails > 6 ? 6 : (fails > 0 ? fails - 1 : 0)))) # 5,10,20,40,80,160 秒…
    ((delay > 300)) && delay=300
    log "remote-control 結束（exit $rc，跑了 $ran 秒），$delay 秒後重啟"
    if ((fails >= 6 && notified == 0)); then
      notified=1
      notify_user "Remote Control 連續啟動失敗" "$(fail_hint)"
    fi
    sleep "$delay" 9>&-
  done
  log "服務結束"
  rm -f "$PIDFILE"
}

on_array_stop() { # 陣列要停了：服務底下若有行程卡在 /mnt（工作目錄或開著的檔案），結束它，否則陣列卸載不了
  local pid victims=""
  for pid in $(tagged_pids); do
    if readlink "/proc/$pid/cwd" "/proc/$pid/exe" /proc/"$pid"/fd/* 2>/dev/null | grep -q "^$ARRAY_MNT/"; then
      victims="$victims $pid"
    fi
  done
  [ -z "$victims" ] && return 0
  log "陣列停止中，結束佔用 $ARRAY_MNT 的行程：$victims"
  # shellcheck disable=SC2086
  kill -TERM $victims 2>/dev/null
  local i left
  for ((i = 0; i < 10; i++)); do # emhttpd 會等這支腳本跑完，所以最多等 2 秒
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

# ───────────────────────── Claude Code 執行檔 ─────────────────────────

claude_ok() { [ -x "$NATIVE_BIN" ] && "$NATIVE_BIN" --version >/dev/null 2>&1; }
claude_ver() { "$NATIVE_BIN" --version 2>/dev/null | awk '{print $1; exit}'; }

cache_binary() { # 把目前使用中的版本備份到開機碟；更新之後這裡也會跟上
  local cur ver
  cur=$(readlink -f "$NATIVE_BIN" 2>/dev/null) || return 0
  ver=${cur##*/}
  [[ $ver =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || return 0
  [ -f "$CACHE/claude-$ver" ] && return 0
  [ "$("$cur" --version 2>/dev/null | awk '{print $1; exit}')" = "$ver" ] || return 0 # 下載到一半的檔案不收
  spin_msg "備份 Claude Code $ver 到開機碟"
  mkdir -p "$CACHE"
  if cp -f "$cur" "$CACHE/.tmp.$$" && mv -f "$CACHE/.tmp.$$" "$CACHE/claude-$ver"; then
    find "$CACHE" -maxdepth 1 -type f -name 'claude-*' ! -name "claude-$ver" -delete
    log "已備份 Claude Code $ver 到開機碟"
  else
    rm -f "$CACHE/.tmp.$$"
    log "備份 Claude Code $ver 失敗（開機碟空間不足？）"
  fi
}

restore_binary() { # 從開機碟還原成原生安裝的配置（versions/<版本> 加上啟動捷徑）。不需要網路
  local f ver tmp
  f=$(find "$CACHE" -maxdepth 1 -type f -name 'claude-*' 2>/dev/null | sort -V | tail -n1)
  [ -n "$f" ] || return 1
  spin_msg "從開機碟還原 Claude Code"
  ver=${f##*/claude-}
  tmp="$HOME/.local/share/claude/.restore.$$"
  mkdir -p "$VERSIONS" "${NATIVE_BIN%/*}"
  if ! { cp -f "$f" "$tmp" && chmod 755 "$tmp" && mv -f "$tmp" "$VERSIONS/$ver"; }; then
    rm -f "$tmp"
    return 1
  fi
  ln -sfn "$VERSIONS/$ver" "$NATIVE_BIN"
  [ "$(claude_ver)" = "$ver" ] && return 0
  # 還原出來的檔案跑不起來。只有在它和備份內容完全相同時，才代表備份本身壞了，丟掉改走下載
  cmp -s "$f" "$VERSIONS/$ver" && rm -f "$f"
  rm -f "$VERSIONS/$ver" "$NATIVE_BIN"
  return 1
}

download_binary() { # 官方安裝程式。只有第一次安裝、或開機碟上的備份不見時才會走到這裡。回傳 75 = 另一個下載正在進行
  local rc
  (
    flock -n 8 || exit 75
    local i tmp rc
    : >"$INSTALL_LOG"
    spin_msg "連線到 downloads.claude.ai"
    for ((i = 0; i < 30; i++)); do # 開機初期網路可能還沒好，最多等 5 分鐘
      curl -fsS --max-time 10 -o /dev/null https://downloads.claude.ai/claude-code-releases/latest >>"$INSTALL_LOG" 2>&1 && break
      ((i == 0)) && spin_msg "等待網路連線，每 $NETWAIT 秒重試（最多 5 分鐘）"
      sleep "$NETWAIT"
    done
    ((i < 30)) || exit 1
    find "$VERSIONS" -maxdepth 1 -type f -size 0 -delete 2>/dev/null # 上次被中斷時可能留下空檔
    tmp=$(mktemp "/tmp/.steward-install.$$.XXXXXX") || exit 1
    spin_msg "下載並安裝 Claude Code" "$HOME/.claude/downloads $VERSIONS"
    # 安裝程式的輸出一律收進檔案：它（或它留在背景的行程）不該握著呼叫者的終端機或管線
    curl -fsSL --max-time 60 https://claude.ai/install.sh -o "$tmp" >>"$INSTALL_LOG" 2>&1 &&
      bash "$tmp" </dev/null >>"$INSTALL_LOG" 2>&1
    rc=$?
    rm -f "$tmp"
    exit "$rc"
  ) 8>"$RUN_DIR/steward.download.lock"
  rc=$?
  ((rc == 0)) || return "$rc"
  cache_binary
  claude_ok
}

ensure_binary() {
  claude_ok && return 0
  if restore_binary; then
    log "已從開機碟還原 Claude Code $(claude_ver)"
    return 0
  fi
  log "開機碟沒有可用的備份，改用官方安裝程式下載"
  download_binary
}

need_binary() { # 互動指令用：確保 Claude Code 可用，要等就顯示進度；失敗時印出安裝程式說了什麼
  claude_ok && return 0
  local rc
  spin_start "準備 Claude Code 執行檔"
  ensure_binary 2>>"$INSTALL_LOG"
  rc=$?
  if ((rc == 0)); then
    spin_stop ok "Claude Code $(claude_ver) 已就緒"
    return 0
  fi
  if ((rc == 75)); then
    spin_stop fail "另一個下載正在進行，請稍後再試"
  else
    spin_stop fail "Claude Code 沒有準備好"
    if [ -s "$INSTALL_LOG" ]; then strip_ansi <"$INSTALL_LOG" | grep -v '^[[:space:]]*$' | uniq | tail -n 15 >&2; fi
  fi
  return 1
}

# ───────────────────────── 掛鉤與環境 ─────────────────────────

write_exec() { # $1=路徑，內容從 stdin
  cat >"$1" && chmod 755 "$1"
}

ensure_runtime() { # 這些都在 RAM 裡，每次開機重建
  mkdir -p "$BIN_DIR" "$PLUGIN_DIR/event" "$RUN_DIR" "${LOG%/*}" "${CRON%/*}"
  chmod 700 "$ROOT" 2>/dev/null

  # 任何 shell 裡的 claude 都用開機碟上的設定與登入
  write_exec "$BIN_DIR/claude" <<EOF
#!/bin/bash
# 由 steward 產生，重開機會重建
export HOME="$HOME" CLAUDE_CONFIG_DIR="$CFG_DIR"
case ":\$PATH:" in *":$HOME/.local/bin:"*) ;; *) PATH="\$PATH:$HOME/.local/bin" ;; esac
[ -x "$NATIVE_BIN" ] || { echo "Claude Code 尚未就緒，請執行 steward status" >&2; exit 127; }
exec "$NATIVE_BIN" "\$@"
EOF
  write_exec "$BIN_DIR/steward" <<EOF
#!/bin/bash
exec bash "$SELF" "\$@"
EOF

  # 陣列停止事件：emhttpd 會執行 /usr/local/emhttp/plugins/*/event/<事件名>
  local ev
  for ev in stopping unmounting_disks; do
    write_exec "$PLUGIN_DIR/event/$ev" <<EOF
#!/bin/bash
[ -f "$SELF" ] && exec bash "$SELF" _event "\$1"
exit 0
EOF
  done

  # watchdog：update_cron 會收 /boot/config/plugins/dynamix/*.cron
  printf '%s\n' "# steward watchdog" "*/5 * * * * bash $SELF watchdog >/dev/null 2>&1" >"$CRON.new"
  if cmp -s "$CRON.new" "$CRON"; then rm -f "$CRON.new"; else mv -f "$CRON.new" "$CRON"; fi
  [ -e "$P/usr/local/sbin/update_cron" ] && bash "$P/usr/local/sbin/update_cron" >/dev/null 2>&1
  return 0
}

add_hook() { # $1=檔案 $2=指令 $3=create 表示檔案不存在時可以新建
  local f=$1 line="$2  $MARK"
  if [ -f "$f" ]; then
    [ "$(grep -cF -- "$MARK" "$f")" = 1 ] && grep -qxF -- "$line" "$f" && return 0 # 已經是這一行：不重寫開機碟
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

write_default() { # $1=路徑，內容從 stdin。檔案已存在就不動，保留你的修改
  if [ -e "$1" ]; then cat >/dev/null; else cat >"$1"; fi
}

write_defaults() {
  write_default "$CONF" <<'EOF'
# Steward 服務參數。改完執行：steward restart
#
# 傳給 claude remote-control 的參數。
# --spawn same-dir：手機開的新 session 直接在 workspace 裡跑。不指定的話，/boot 若是 git repo
#   （用 Unraid Connect flash backup 的人都是），Claude Code 會改用 worktree 模式，session 跑在副本裡。
# --capacity 是同時可開的 session 數；每個 session 是一個獨立行程，會佔記憶體。
RC_ARGS=(--spawn same-dir --capacity 4)

# 例：auto mode——由分類器放行低風險動作，有風險的才問；settings.json 的 deny / ask 規則與 bash-guard 照樣生效。
#   方案不支援時 Claude Code 會退回逐一詢問，對話裡會出現 "auto mode is unavailable"。
# RC_ARGS=(--spawn same-dir --capacity 4 --permission-mode auto)
# 例：只自動接受檔案編輯，指令仍逐一詢問
# RC_ARGS=(--spawn same-dir --capacity 4 --permission-mode acceptEdits)
EOF

  # 第二道防線：settings.json 的規則只比對指令開頭，這個 hook 檢查整段指令（全路徑、sh -c、; 串接、管線都看得到）
  mkdir -p "$ROOT/hooks"
  write_default "$ROOT/hooks/bash-guard.sh" <<'HOOK'
#!/bin/bash
# Steward 的 PreToolUse hook（matcher: Bash）。從 stdin 讀工具呼叫的 JSON，檢查「整段」指令字串，
# 所以 settings.json 只比對開頭的規則被全路徑、sh -c、; 串接、管線、xargs 繞過時，這裡仍擋得到。
#   deny：清碟 / 格式化工具、讀取密碼雜湊 / 金鑰 / token
#   ask ：破壞性或主機層級的指令、以 shell 寫入 /boot/config、在 /boot 這個 repo 裡用 git 改寫工作樹、
#         修改這個 hook 或 settings.json
# 其他指令交回一般權限規則（auto mode 下由分類器判斷）。
# 已知限制：只做文字比對。指令文字「提到」關鍵字也會被攔（例如 echo rm）；執行腳本檔（bash x.sh、. x.sh）
# 裡面的指令不會再經過這裡，這是刻意接受的取捨。

cmd=$(jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[[ -z "$cmd" ]] && exit 0

emit() { # $1=deny|ask $2=原因
  jq -cn --arg d "$1" --arg r "$2" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:$d,permissionDecisionReason:$r}}'
  exit 0
}

# ---------- DENY：指令裡任何位置出現都不准執行 ----------
if [[ "$cmd" =~ (^|[^[:alnum:]_.-])(mkfs(\.[[:alnum:]]+)?|wipefs|sgdisk|blkdiscard|shred)([^[:alnum:]_-]|$) ]]; then
  emit deny "bash-guard: 磁碟清除/格式化工具一律禁止（請在 webGUI 操作）"
fi
if [[ "$cmd" =~ zpool[[:space:]]+(destroy|labelclear) ]]; then
  emit deny "bash-guard: zpool destroy/labelclear 一律禁止"
fi
# 密碼雜湊 / 金鑰 / token 的路徑。用前綴比對，/etc/shadow- 這種備份檔與 /etc/shad* 這種 glob 也會命中
secret_paths='/etc/g?shad|/boot/config/shad|smbpasswd|secrets\.tdb|/boot/config/ssh|/boot/config/ssl|/boot/config/wireguard|/etc/wireguard|/root/\.ssh|/root/keyfile|\.credentials|unraid-api\.key|/var/lib/samba/private'
if [[ "$cmd" =~ ($secret_paths) ]]; then
  emit deny "bash-guard: 指令觸及密碼雜湊/金鑰/token 路徑，禁止讀取或輸出"
fi

# ---------- ASK：一律先問使用者 ----------
# 指令位置：開頭，或接在 ; & | ( ` 引號、空白之後（抓得到 sh -c "..."、管線、串接、timeout/nice/env 前綴），可加 sudo 或全路徑
cmdpos='(^|[;&|(`'"'"'"]|[[:space:]])(sudo[[:space:]]+)?(/[[:alnum:]_./-]*/)?'
dangerous='(rm|dd|mdcmd|emcmd|reboot|poweroff|powerdown|shutdown|halt|truncate)'
if [[ "$cmd" =~ ${cmdpos}${dangerous}([[:space:]]|$) ]]; then
  emit ask "bash-guard: 含刪除/覆寫/陣列控制/關機指令，需使用者確認"
fi
if [[ "$cmd" =~ (xargs[[:space:]]+(-[^[:space:]]+[[:space:]]+)*rm([[:space:]]|$)|-exec[[:space:]]+rm([[:space:]]|$)|-delete([[:space:]]|$)) ]]; then
  emit ask "bash-guard: 透過 xargs/find 刪除檔案，需使用者確認"
fi
if [[ "$cmd" =~ zfs[[:space:]]+(destroy|rollback)|docker[[:space:]]+(rm|rmi|volume[[:space:]]+(rm|prune)|system[[:space:]]+prune|container[[:space:]]+(rm|prune)|image[[:space:]]+prune)|virsh[[:space:]]+(destroy|undefine) ]]; then
  emit ask "bash-guard: 刪除 ZFS/容器/VM 資源，需使用者確認"
fi
# 把真正要跑的指令藏在字串裡：eval、sh -c（含 -lc、-ec 等合併寫法）、base64 解碼後執行
if [[ "$cmd" =~ (^|[^[:alnum:]_])eval([[:space:]]|$)|base64[[:space:]]+(-d|--decode)|(^|[^[:alnum:]_])(ba)?sh[[:space:]]+-[a-zA-Z]*c[[:space:]] ]]; then
  emit ask "bash-guard: 間接執行（eval/sh -c/base64 -d），需使用者確認"
fi

# 用 shell 寫 /boot/config，而不是用 Edit 工具。寫了絕對路徑，或先 cd 進 /boot 再用相對路徑 config/...，都算
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
    emit ask "bash-guard: 以 shell 寫入 /boot/config（請先備份到 /boot/steward/backups/）"
  fi
fi

# git 改寫工作樹：/boot 是 Unraid Connect flash backup 的 git repo，/boot/config 被追蹤，而且我們的工作目錄就在裡面。
# reset --hard / checkout / restore / stash 會把設定倒回上次自動提交；clean 會刪掉從沒被追蹤的檔案（例如 wireguard/）。
# 只管 /boot：沒指定 repo（預設就是 /boot）、或用 -C / --git-dir / --work-tree 指到 /boot 本身才問；指到別的 repo 不問
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
    emit ask "bash-guard: git $sub 會改寫 /boot 的工作樹（/boot/config 在這個 repo 裡），需使用者確認"
  fi
fi

# 修改這個 hook 或權限設定（舊路徑 /boot/claude-code 是指向 /boot/steward 的符號連結；先 cd 進去再用相對路徑也算）
guard_target=0
[[ "$cmd" =~ /boot/(steward|claude-code)/(hooks/|home/settings\.json) ]] && guard_target=1
[[ "$cmd" =~ (^|[;&|[:space:]])cd[[:space:]]+/boot/(steward|claude-code)(/home|/hooks)?/?[[:space:]]*(&&|;|\|) && "$cmd" =~ (hooks/|bash-guard|settings\.json) ]] && guard_target=1
if ((guard_target)); then
  if [[ "$cmd" =~ $write_verbs ]] || [[ "$cmd" =~ $inplace_edit ]] || [[ "$cmd" =~ (^|[^[:alnum:]_])(sed|rm|perl)([[:space:]]|$)|\> ]]; then
    emit ask "bash-guard: 修改權限規則或防護腳本，需使用者確認"
  fi
fi

exit 0
HOOK
  # hook 是用 bash 呼叫的，不需要執行權限；既有檔案的權限也不動

  # dialogExpiry：轉到手機的權限確認等多久才自動取消（官方預設 5m）
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
            "statusMessage": "bash-guard 檢查中"
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

  # 推播：有權限確認或問題在等你時推到手機（/config 的 "Push when actions required"）。
  # 這個檔案在登入後由 Claude Code 自己維護，所以只在全新安裝、它還不存在時寫入
  write_default "$CFG_DIR/.claude.json" <<'EOF'
{
  "inputNeededNotifEnabled": true
}
EOF

  write_default "$CFG_DIR/CLAUDE.md" <<'EOF'
# 這台機器是 Unraid 伺服器，你以 root 身分直接跑在主機上

你是這台 NAS 的常駐管理助手，使用者透過 Remote Control 從手機或瀏覽器下指令。
這裡沒有容器隔離：每個指令都直接作用在主機上，資料遺失無法復原。不確定就先問。

## 這台機器的特性

- 根檔案系統在 RAM：`/boot` 與 `/mnt` 以外的變更重開機就消失。要保留的設定必須寫在 `/boot/config`，或由開機腳本 `/boot/config/go` 每次重建。
- `/boot` 是開機碟（Internal Boot，ZFS），陣列停止時仍可用。空間有限，不要放大檔案。
- `/mnt/user/<share>` 是使用者共享（合併視圖）；`/mnt/diskN`、`/mnt/<pool>` 是底層磁碟。同一個複製或搬移指令裡絕不能混用 `/mnt/user` 與 `/mnt/diskN`，會毀損檔案。
- 陣列停止時 `/mnt/user`、`/mnt/disk*`、各 pool 全部消失，Docker 與 VM 也會停。你自己（`/boot/steward`）不受影響。
- 動手前先確認陣列狀態：`grep -E '^(mdState|fsState)=' /var/local/emhttp/var.ini`

## 一定要遵守

1. 工作目錄不要停在 `/mnt` 底下，一律用絕對路徑。任何行程卡在 `/mnt`，陣列就卸載不了。
2. 下列操作先說明影響、取得使用者明確同意，一次只做一件：停止或啟動陣列、重開機或關機、同位檢查、變更磁碟指派、刪除容器 / VM / 共享、更新 Unraid 或外掛。
3. 永遠不要執行 New Config、清除或格式化磁碟、`zpool destroy`、`mkfs`、`wipefs`。這些請使用者自己在 webGUI 操作。
4. 修改 `/boot/config` 內的檔案前，先備份到 `/boot/steward/backups/<日期時間>/`，並告訴使用者改了什麼、怎麼還原、要不要重啟服務或重開機才生效。
5. 不要讀取或輸出密碼雜湊、金鑰、token、WireGuard 私鑰。對話紀錄會以明文存在開機碟，並同步到 Anthropic。
6. 長時間的工作完成、或需要使用者決定時，發 Unraid 通知：
   `/usr/local/emhttp/webGui/scripts/notify -e "Steward" -s "<主旨>" -d "<內容>" -i normal`

## 慣例

- Docker：容器由範本管理（`/boot/config/plugins/dockerMan/templates-user/my-*.xml`）。要長期保留的容器不要用 `docker run` 手動建立，那樣 webGUI 沒有它的範本，之後無法在介面上編輯或更新。
- 設定檔在 `/boot/config`（`ident.cfg`、`network.cfg`、`share.cfg`、`disk.cfg`、`docker.cfg`、`shares/*.cfg` 等）。直接改檔案不會立即生效，能用官方介面就用官方介面。
- Unraid API（GraphQL，7.2 起內建）：文件在 https://docs.unraid.net/API/ ，本機 CLI 用 `unraid-api --help` 查。需要 API key 時先問使用者，再用 `unraid-api apikey --create` 建立，權限給最小夠用的；金鑰存成 `/boot/steward/home/unraid-api.key`（權限 600），不要印出來。
- 停止或啟動陣列只走官方介面，不要 `mdcmd stop`，不要手動 umount。
- 你在共享（`/mnt/user/...`）新建的檔案預設屬於 root，SMB 使用者會打不開：建好後對那些檔案 `chown nobody:users` 並 `chmod ug+rw`。只處理你自己建的檔案，不要對 appdata 或整個共享遞迴改權限。
- 紀錄：系統在 `/var/log/syslog`，容器用 `docker logs <名稱>`。診斷包用 `diagnostics`（輸出在 `/boot/logs`）。
- 你自己的服務由 `steward` 管理（`status`、`restart`、`update`、`logs`）。不要自己 kill claude 行程。
EOF

  merge_settings
}

merge_settings() { # 既有安裝升級時補上新版才有的預設鍵。只補缺少的，使用者改過的不動；原檔留備份
  local f="$CFG_DIR/settings.json" tmp
  [ -s "$f" ] || return 0
  jq -e 'has("dialogExpiry")' "$f" >/dev/null 2>&1 && return 0
  tmp=$(mktemp "$f.XXXXXX") || return 0
  if jq '.dialogExpiry = "10m"' "$f" >"$tmp" 2>/dev/null && jq -e . "$tmp" >/dev/null 2>&1; then
    cp -p "$f" "$f.before-$STEWARD_VERSION"
    mv -f "$tmp" "$f"
    log "settings.json 補上 dialogExpiry=10m（原檔備份為 settings.json.before-$STEWARD_VERSION）"
  else
    rm -f "$tmp"
  fi
}

preflight() {
  [ "$(id -u)" = 0 ] || die "請用 root 執行"
  if [ -z "$P" ]; then mountpoint -q /boot || die "/boot 沒有掛載"; fi
  case "$(stat -f -c %T "$P/boot" 2>/dev/null)" in
  msdos | vfat | fat* | exfat) die "/boot 是 FAT 檔案系統（USB 開機）。這支腳本把資料直接放在開機碟，只適用 Internal Boot (ZFS)" ;;
  esac
  [ -e "$P/boot/config/plugins/claude-code.plg" ] && die "已安裝另一個 Claude Code 外掛（claude-code.plg），兩者會互相覆蓋 /usr/local/bin/claude，請擇一"
  mkdir -p "$ROOT" || die "無法建立 $ROOT"
  # 實測開機碟是否保得住權限與符號連結
  local t="$ROOT/.probe.$$" ok=1
  : >"$t" && chmod 600 "$t" && [ "$(stat -c %a "$t")" = 600 ] && ln -s "$t" "$t.l" 2>/dev/null && ok=0
  rm -f "$t" "$t.l"
  [ "$ok" = 0 ] || die "$ROOT 所在的檔案系統不支援檔案權限或符號連結，無法安全存放登入憑證"
  local avail
  avail=$(df --output=avail -BM "$P/boot" 2>/dev/null | tail -n1 | tr -dc '0-9')
  [ -n "$avail" ] && ((avail < 1024)) && warn "開機碟剩餘空間只有 ${avail}MB，Claude Code 執行檔備份約需 300MB"
  return 0
}

# ───────────────────────── 指令 ─────────────────────────

install_self() { # 把正在執行的這份腳本放到開機碟。內容有變回傳 0；沒變回傳 1，而且不寫開機碟
  local src
  src=$(readlink -f "${BASH_SOURCE[0]:-}" 2>/dev/null)
  [ -f "$src" ] || die "請把腳本存成檔案再執行"
  [ "$src" = "$(readlink -f "$SELF" 2>/dev/null)" ] && return 1
  cmp -s <(tr -d '\r' <"$src" 2>/dev/null) "$SELF" && return 1 # cmp 一發現不同就不讀了，tr 的抱怨不必給人看
  # 先寫暫存檔再改名：執行中的服務還開著舊檔，直接覆寫會讓它讀到新舊混雜的內容
  if ! { tr -d '\r' <"$src" >"$SELF.new" && mv -f "$SELF.new" "$SELF"; }; then die "無法寫入 $SELF"; fi
  return 0
}

stop_hook() { add_hook "$STOP" "[ -f $SELF ] && bash $SELF shutdown >/dev/null 2>&1" create; }
drop_go_hook() { if grep -qsF "$MARK" "$GO"; then sed -i "\|$MARK|d" "$GO"; fi; }

LEGACY_ROOT="$P/boot/claude-code"
LEGACY_TAG="CLAUDE_UNRAID_SVC"
migrate_legacy() { # 從舊名稱 claude-unraid 升級：搬資料、停舊服務、拆舊鉤子。只在舊目錄存在而新目錄不存在時做一次
  [ -d "$LEGACY_ROOT" ] && [ ! -L "$LEGACY_ROOT" ] || return 0
  if [ -e "$ROOT" ]; then # preflight 已經 mkdir 過：只有空目錄才算「新目錄不存在」
    [ -d "$ROOT" ] && [ -z "$(ls -A "$ROOT" 2>/dev/null)" ] && rmdir "$ROOT" || return 0
  fi
  log "發現舊版 claude-unraid 的資料，搬移到 $ROOT"
  # 舊服務的行程帶 CLAUDE_UNRAID_SVC。若是從舊服務裡的 Claude 觸發升級，它自己也會在這裡被停掉；新服務起來後從手機重新連線即可
  local pids=""
  [ -z "$P" ] && pids=$(grep -lszxF "$LEGACY_TAG=1" /proc/[0-9]*/environ 2>/dev/null | sed 's#^/proc/##; s#/environ$##' | grep -vx "$$") # 測試用假根目錄時不碰真實行程
  if [ -n "$pids" ]; then
    # shellcheck disable=SC2086
    kill -TERM $pids 2>/dev/null
    sleep 3
    # shellcheck disable=SC2086
    kill -KILL $pids 2>/dev/null
  fi
  mv "$LEGACY_ROOT" "$ROOT" || die "無法把 $LEGACY_ROOT 搬到 $ROOT"
  ln -s steward "$LEGACY_ROOT" # 舊路徑保留符號連結：舊設定、記憶、筆記裡寫的 /boot/claude-code 仍然有效
  if [ -f "$ROOT/claude-unraid.conf" ]; then
    mv -f "$ROOT/claude-unraid.conf" "$CONF"
    sed -i 's/claude-unraid/steward/g; s/# steward 服務參數/# Steward 服務參數/' "$CONF"
    # 新預設 --spawn same-dir：舊設定沒指定 --spawn 才補上，使用者自己設的不動
    grep -q -- '--spawn' "$CONF" || sed -i 's/^RC_ARGS=(\(.*\))$/RC_ARGS=(\1 --spawn same-dir)/' "$CONF"
  fi
  rm -f "$ROOT/claude-unraid.sh"
  # 舊鉤子：cron、指令捷徑、執行期檔案、stop/go 裡標了 "# claude-unraid" 的行
  rm -f "$P/boot/config/plugins/dynamix/claude-unraid.cron" "$BIN_DIR/claude-unraid" "$RUN_DIR"/claude-unraid.*
  local f
  for f in "$STOP" "$GO"; do
    [ -f "$f" ] && grep -qF '# claude-unraid' "$f" || continue
    [ -e "$f.before-steward" ] || cp -p "$f" "$f.before-steward"
    sed -i '\|# claude-unraid|d' "$f"
  done
  rm -rf "$P/usr/local/emhttp/plugins/claude-unraid"
  if [ -f "$P/boot/config/plugins/claude-unraid.plg" ]; then
    # 不跑舊外掛的移除段：它會把共用的 /usr/local/bin/claude 也刪掉。搬到 plugins-removed 就不會再載入
    mkdir -p "$P/boot/config/plugins-removed"
    mv -f "$P/boot/config/plugins/claude-unraid.plg" "$P/boot/config/plugins-removed/"
  fi
  [ -e "$P/usr/local/sbin/update_cron" ] && bash "$P/usr/local/sbin/update_cron" >/dev/null 2>&1
  # 舊設定檔裡的路徑與名稱（備份原檔）
  for f in "$CFG_DIR/settings.json" "$CFG_DIR/CLAUDE.md"; do
    [ -f "$f" ] || continue
    cp -p "$f" "$f.before-steward"
    sed -i 's#/boot/claude-code#/boot/steward#g; s#claude-unraid#steward#g' "$f"
  done
  log "搬移完成：$LEGACY_ROOT → $ROOT"
  say "已從舊版 claude-unraid 搬移到 $ROOT（舊路徑 /boot/claude-code 保留為符號連結，舊外掛檔移到 plugins-removed）"
}

cmd_install() {
  preflight
  migrate_legacy
  mkdir -p "$CFG_DIR" "$WORKSPACE" "$CACHE" "$RUN_DIR" "${LOG%/*}"
  install_self
  write_defaults
  if ((PLUGIN)); then
    drop_go_hook # 用外掛安裝的：開機時由外掛載入，不需要 go 裡那一行
  else
    # go 不存在時不能新建：Unraid 會改跑 go 而不啟動 emhttp，webGUI 就起不來
    add_hook "$GO" "[ -f $SELF ] && bash $SELF boot >/dev/null 2>&1 &" ||
      warn "找不到 $GO，沒有加上開機掛鉤。請手動在 go 檔加一行：bash $SELF boot &"
  fi
  stop_hook
  ensure_runtime
  need_binary || die "確認網路後重跑：steward install"
  say "安裝完成：Claude Code $(claude_ver)，資料放在 $ROOT"
  boot_shared_over_smb && warn "開機碟目前有透過 SMB 分享，而登入憑證就放在開機碟上。建議到 Main 頁點開機裝置，把 SMB Security Settings 的 Export 設成 No"
  if [ -t 0 ]; then
    local a
    read -r -p "現在就登入並完成 Remote Control 設定嗎？[Y/n] " a
    case "$a" in n | N) ;; *)
      cmd_setup
      return
      ;;
    esac
  fi
  say "下一步：steward setup"
}

auth_method() { timeout 20 "$NATIVE_BIN" auth status 2>/dev/null | sed -n 's/.*"authMethod"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1; }

cmd_setup() {
  [ -t 0 ] || die "setup 需要互動式終端機（Unraid 網頁終端機或 SSH）"
  need_binary || die "確認網路後再試一次，或執行 steward install 查看原因"
  if [ "$(auth_method)" = "claude.ai" ]; then
    say "步驟 1/2：已登入 claude.ai"
  else
    say "步驟 1/2：登入 claude.ai（Remote Control 不支援 API key）"
    say "　把顯示的網址貼到瀏覽器登入，再把代碼貼回這裡。網址很長，請先把終端機視窗拉寬再複製。"
    "$NATIVE_BIN" auth login || die "登入沒有完成"
  fi
  # 先停掉背景服務並暫時停用，免得 watchdog 在你操作時又把它拉起來
  rm -f "$ENABLED"
  stop_service 30
  say ""
  say "步驟 2/2：在前景啟動一次 Remote Control，回答只會問一次的問題"
  say "　1. 問是否信任這個目錄、是否啟用 Remote Control，都回答 y"
  say "　2. 看到連線網址後，打開手機 Claude App 的 Code 分頁或 claude.ai/code，確認看得到這台機器"
  say "　3. 按 Ctrl+C 回到這裡"
  say ""
  trap : INT # Ctrl+C 只結束 claude，不結束這支腳本
  cd "$WORKSPACE" || die "進不去 $WORKSPACE"
  "$NATIVE_BIN" remote-control "${RC_ARGS[@]}"
  cd / || true
  trap 'exit 130' INT
  say ""
  local a
  read -r -p "剛才有成功連上嗎？要啟用常駐服務（開機自動啟動）嗎？[Y/n] " a
  case "$a" in n | N)
    say "尚未啟用。問題排除後可再跑一次 steward setup，或直接 steward start"
    return 0
    ;;
  esac
  cmd_start
}

stop_service() { # $1=最多等幾秒 $2=沒有東西在跑時要說的話（可省略）
  if [ -n "$(tagged_pids)" ]; then
    spin_start "停止服務"
    kill_tagged "$1"
    spin_stop ok "服務已停止"
  elif [ -n "${2:-}" ]; then
    say "$2"
  fi
  rm -f "$PIDFILE"
}

log_size() { stat -c %s "$LOG" 2>/dev/null || echo 0; }

wait_connected() { # $1=啟動前紀錄檔的大小。等到 Remote Control 真的連上（紀錄裡出現連線網址），或確定失敗
  local off=$1 t0=$SECONDS url seen=0
  spin_start "等待 Remote Control 連線"
  while ((SECONDS - t0 < 15)); do
    (($(log_size) < off)) && off=0 # 紀錄檔剛好被清空輪替
    if tail -c "+$((off + 1))" "$LOG" 2>/dev/null | grep -a -q 'remote-control 結束'; then
      spin_stop fail "Remote Control 沒有連上：$(fail_hint)"
      return 1
    fi
    url=$(tail -c "+$((off + 1))" "$LOG" 2>/dev/null | grep -a -o 'https://claude\.ai/code[^[:space:][:cntrl:]"]*' | tail -n1)
    if [ -n "$url" ]; then
      seen=$((seen + 1)) # 網址出現後再看一秒：錯誤訊息裡也可能帶網址，要確定程式沒有接著就結束
      if ((seen >= 8)); then
        spin_stop ok "Remote Control 已連線"
        say "　$url"
        return 0
      fi
    fi
    sleep 0.1
  done
  spin_stop clear
  say "服務在背景執行中，但還沒在紀錄裡看到連線網址。請到 claude.ai/code 或手機 App 確認有沒有這台機器；細節用 steward logs 查看"
}

cmd_start() { # 回傳 0=服務在跑而且連上了（或還在連） 1=沒啟動或沒連上
  if ! need_binary; then
    err "Claude Code 還沒準備好。確認網路後再試一次，或執行 steward install 查看原因"
    return 1
  fi
  rm -f "$DOWN_FLAG"
  : >"$ENABLED"
  if sup_pid >/dev/null; then
    say "服務已在執行（pid $(sup_pid)）。查看狀態：steward status"
    return 0
  fi
  local off
  off=$(log_size)
  spin_start "啟動服務"
  if ! launch; then
    spin_stop fail "服務沒有啟動，請看 steward logs"
    return 1
  fi
  spin_stop ok "服務已啟動（pid $(sup_pid)），開機會自動啟動"
  wait_connected "$off"
}

cmd_stop() {
  rm -f "$ENABLED"
  stop_service 30 "服務原本就沒有在執行"
  say "已取消開機自動啟動。要恢復請執行 steward start"
}

cmd_restart() {
  stop_service 30
  cmd_start
}

cmd_shutdown() { # 由 /boot/config/stop 呼叫。不改「開機自動啟動」的設定，而且不能拖住關機
  : >"$DOWN_FLAG"
  log "系統關機，停止服務"
  kill_tagged 10
  rm -f "$PIDFILE"
}

cmd_boot() { # 開機時在背景跑：腳本安裝由 /boot/config/go 呼叫，外掛安裝由外掛的載入步驟呼叫
  ensure_runtime
  log "開機：環境已重建"
  if ! ensure_binary; then
    notify_user "Claude Code 無法啟動" "開機時還原與下載都失敗，請執行 steward status"
    exit 1
  fi
  if [ -f "$ENABLED" ]; then launch || log "開機：服務沒有啟動"; fi
}

cmd_watchdog() { # cron 每 5 分鐘呼叫
  [ -f "$ENABLED" ] && [ ! -f "$DOWN_FLAG" ] || return 0
  if sup_pid >/dev/null; then
    auto_update
    return 0
  fi
  claude_ok || ensure_binary || return 0
  log "watchdog：服務不在，重新啟動"
  launch
}

running_ver() { # 執行中的 remote-control 用的是哪一版（更新後、重啟前會和 claude_ver 不同）
  local p exe
  for p in $(tagged_pids); do
    # 只認 argv[1] 剛好是 remote-control、而且執行檔在 versions/ 底下的行程；session 裡提到這個字串的指令不算
    [ "$(tr '\0' '\n' 2>/dev/null <"/proc/$p/cmdline" | sed -n 2p)" = remote-control ] || continue
    exe=$(readlink "/proc/$p/exe" 2>/dev/null) || continue
    exe=${exe% (deleted)}
    case "$exe" in "$VERSIONS"/*) ;; *) continue ;; esac
    echo "${exe##*/}"
    return 0
  done
  return 1
}

sessions_busy() { # 最近 15 分鐘有 session 寫過對話紀錄，就當作有人在用
  find "$CFG_DIR/projects" -name '*.jsonl' -mmin -15 2>/dev/null | grep -q .
}

# remote-control 模式下 Claude Code 不會自己更新，由 watchdog 代勞：
# 每天 08:00 後查一次 stable 通道，有新版就安裝並備份到開機碟；沒有 session 在用才重啟套用，否則一小時後再試
AU_DONE="$RUN_DIR/steward.autoupdate.done" # 內容是今天已經處理完的日期
AU_NEXT="$RUN_DIR/steward.autoupdate.next" # 內容是下次可以再試的時間（epoch 秒）
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
  run=$(running_ver) || return 0 # remote-control 正在重試啟動之類的，下次再說
  cur=$(claude_ver)
  if [ "$run" = "$cur" ]; then # 沒有等著套用的版本：查有沒有新版
    latest=$(curl -fsS --max-time 10 https://downloads.claude.ai/claude-code-releases/stable 2>/dev/null) || return 0
    [[ $latest =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 0
    if [ "$(printf '%s\n' "$latest" "$cur" | sort -V | tail -n1)" = "$cur" ]; then # 已經是最新（或比 stable 還新）
      echo "$today" >"$AU_DONE"
      return 0
    fi
    log "自動更新：安裝 Claude Code $latest（目前 $cur）"
    (
      flock -n 8 || exit 75
      timeout 600 "$NATIVE_BIN" install "$latest" </dev/null >"$INSTALL_LOG" 2>&1 # 卡住也不能一直握著下載鎖
    ) 8>"$RUN_DIR/steward.download.lock"
    rc=$?
    if ((rc == 75)); then
      log "自動更新：另一個下載正在進行，一小時後再試"
      return 0
    fi
    if [ "$(claude_ver)" != "$latest" ]; then
      log "自動更新：$latest 沒有裝好（結束碼 $rc），一小時後再試（輸出在 $INSTALL_LOG）"
      return 0
    fi
    cache_binary
    cur=$latest
  fi
  if sessions_busy; then
    log "自動更新：$cur 已裝好，但有 session 正在使用，一小時後再試"
    return 0
  fi
  log "自動更新：重啟服務以套用 $cur（原本 $run）"
  if ! cmd_restart >/dev/null 2>&1 || [ "$(running_ver)" != "$cur" ]; then
    log "自動更新：重啟後服務沒有正常回來，一小時後再試（服務不在時 watchdog 會拉起來）"
    return 0
  fi
  echo "$today" >"$AU_DONE"
  notify_user "Claude Code 已更新到 $cur" "原本 $run。趁沒有 session 在用時重啟了服務，手機上的對話可以接著用" normal
}

cmd_update() {
  claude_ok || die "找不到 Claude Code，請先執行：steward install"
  local before after ver
  before=$(readlink -f "$NATIVE_BIN")
  "$NATIVE_BIN" update # 它自己會顯示進度
  after=$(readlink -f "$NATIVE_BIN")
  ver=${after##*/}
  if [ ! -f "$CACHE/claude-$ver" ]; then
    spin_start "備份 Claude Code $ver 到開機碟"
    cache_binary
    if [ -f "$CACHE/claude-$ver" ]; then
      spin_stop ok "已備份 Claude Code $ver 到開機碟"
    else
      spin_stop fail "沒能備份到開機碟，下次開機會重新下載"
    fi
  fi
  if [ "$before" != "$after" ] && sup_pid >/dev/null; then
    say "版本已更新，重啟服務以套用"
    cmd_restart
  fi
}

rc_opt() { # $1=選項名 $2=沒設時的預設值。從 RC_ARGS 取出該選項的值
  local i
  for ((i = 0; i < ${#RC_ARGS[@]}; i++)); do
    [ "${RC_ARGS[i]}" = "$1" ] && { echo "${RC_ARGS[i + 1]:-$2}"; return 0; }
  done
  echo "$2"
}

cmd_status() {
  local pid v r m="" url arr smb=0
  if pid=$(sup_pid); then
    say "服務　　：執行中（pid $pid，已執行 $(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ')）"
  elif [ -f "$ENABLED" ]; then
    say "服務　　：已啟用但沒在執行（watchdog 會在 5 分鐘內拉起來，或手動 steward start）"
  else
    say "服務　　：未啟用（steward setup 或 steward start）"
  fi
  say "模式　　：permission-mode $(rc_opt --permission-mode default)　spawn $(rc_opt --spawn worktree)　capacity $(rc_opt --capacity 1)"
  spin_start -t "查詢 Claude Code 與登入狀態"
  v=$(claude_ver)
  [ -n "$v" ] && m=$(auth_method)
  boot_shared_over_smb && smb=1
  spin_stop clear
  if [ -n "$v" ]; then
    say "版本　　：$v　開機碟備份：$(find "$CACHE" -maxdepth 1 -name 'claude-*' -printf '%f ' 2>/dev/null | sed 's/claude-//g')"
    if r=$(running_ver) && [ "$r" != "$v" ]; then say "　　　　　執行中的服務還是 $r，重啟後才會用 $v"; fi
    case "$m" in
    claude.ai) say "登入　　：claude.ai" ;;
    "" | none) say "登入　　：尚未登入 → steward setup" ;;
    *) say "登入　　：$m（Remote Control 需要 claude.ai 登入）→ steward setup" ;;
    esac
  elif ! flock -n "$RUN_DIR/steward.download.lock" true 2>/dev/null; then
    say "版本　　：Claude Code 下載中，請稍候"
  else
    say "版本　　：Claude Code 尚未就緒 → steward install"
    if [ -s "$INSTALL_LOG" ]; then
      say "　安裝程式最後的輸出："
      strip_ansi <"$INSTALL_LOG" | grep -v '^[[:space:]]*$' | tail -n 3 | sed 's/^/　　/'
    fi
  fi
  arr=$(sed -n 's/^mdState="\{0,1\}\([A-Z_]*\).*/\1/p' "$P/var/local/emhttp/var.ini" 2>/dev/null)
  say "陣列　　：${arr:-未知}（服務不依賴陣列）"
  say "開機碟　：剩餘 $(df -h --output=avail "$P/boot" 2>/dev/null | tail -n1 | tr -d ' ')"
  if ((PLUGIN)); then
    say "安裝方式：外掛 $STEWARD_VERSION（在 webGUI 的 Plugins 頁管理）"
  else
    say "安裝方式：腳本 $STEWARD_VERSION"
    grep -qsF "$MARK" "$GO" || say "開機掛鉤：$GO 裡沒有 steward 那一行，重開機後不會自動啟動 → steward install"
  fi
  url=$(cat "$LOG.1" "$LOG" 2>/dev/null | grep -a -o 'https://claude\.ai/code[^[:space:][:cntrl:]"]*' | tail -n1)
  [ -n "$url" ] && say "最近連線：$url"
  ((smb)) && warn "開機碟目前有透過 SMB 分享，登入憑證放在開機碟上，建議關閉分享"
  say "最近紀錄："
  tail -n 6 "$LOG" 2>/dev/null | strip_ansi | sed 's/^/　/'
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
  say "已移除掛鉤並停止服務。RAM 裡的執行檔重開機後消失。"
  say "資料（含登入憑證）仍在 $ROOT，確定不用了再手動刪除。"
}

cmd_uninstall() {
  ((PLUGIN)) && die "這是用外掛安裝的：請到 webGUI 的 Plugins 頁移除，或執行 plugin remove steward.plg"
  do_uninstall
}

# ───────────────────────── 外掛（steward.plg）的進入點 ─────────────────────────

webgui_up() { # emhttpd 起來了沒。開機時外掛比 emhttpd 早載入，那個階段不能做要等很久的事
  [ -e "$P/var/local/emhttp/var.ini" ] || return 1
  [ -n "$P" ] || [ -n "$(pgrep --ns $$ -x emhttpd 2>/dev/null)" ]
}

cmd_plugin_install() { # 外掛管理員每次開機都會跑一遍；從 webGUI 安裝或更新外掛時也是
  PLUGIN=1
  local booting=1 changed=0 problem
  webgui_up && booting=0
  if ((booting)); then
    # 開機時不能回報失敗：外掛管理員會把 .plg 移到 plugins-error，之後每次開機都不再載入
    if ! problem=$( (preflight) 2>&1); then
      log "開機：環境檢查沒過，這次不啟動 — $problem"
      notify_user "Claude Code 外掛沒有啟動" "$problem"
      say "steward：$problem"
      return 0
    fi
  else
    preflight
  fi
  migrate_legacy
  mkdir -p "$CFG_DIR" "$WORKSPACE" "$CACHE" "$RUN_DIR" "${LOG%/*}"
  install_self && changed=1
  write_defaults
  drop_go_hook # 之前若用腳本裝過，go 裡會有一行；現在改由外掛在開機時載入
  stop_hook
  ensure_runtime
  if ((booting)); then
    # 還原執行檔要幾秒、沒有備份時還得下載，都丟到背景，不拖住開機
    (
      cd / || exit 1
      close_fds
      exec setsid bash "$SELF" boot </dev/null >/dev/null 2>&1
    ) &
    say "steward $STEWARD_VERSION：已載入，服務在背景啟動"
    return 0
  fi
  say "steward $STEWARD_VERSION：外掛檔案已就位"
  if ! need_binary; then
    warn "外掛已安裝，但 Claude Code 還沒下載成功。確認網路後，到 Settings → Steward 按「啟動」，或在終端機執行 steward install"
    return 0
  fi
  if sup_pid >/dev/null; then
    if ((changed)); then
      say "腳本有更新，重啟服務以套用"
      if [ -n "${STEWARD_SVC:-}" ]; then
        # 外掛管理員是從服務裡的 session 啟動的（帶著服務標記）：直接重啟會把它一起殺掉，
        # 最後一步「把 .plg 複製到 /boot/config/plugins」就做不到。改成脫離標記、等它收尾後再重啟
        (
          cd / || exit 1
          close_fds
          exec env -u "$TAG" setsid bash -c 'sleep 10; exec bash "$0" restart' "$SELF" </dev/null >/dev/null 2>&1
        ) &
        say "（從服務裡的 session 觸發：10 秒後在背景重啟，Remote Control 會中斷一下）"
      else
        cmd_restart
      fi
    else
      say "服務執行中，不需要重啟"
    fi
  elif [ -f "$ENABLED" ]; then
    cmd_start
  elif [ "$(auth_method)" = "claude.ai" ]; then
    say "下一步：到 Settings → Steward 按「啟動」。Remote Control 若還沒做過首次設定，先按「登入與首次設定」"
  else
    say "下一步：到 Settings → Steward 按「登入與首次設定」，或在終端機執行 steward setup"
  fi
  boot_shared_over_smb && warn "開機碟目前有透過 SMB 分享，而登入憑證就放在開機碟上。建議到 Main 頁點開機裝置，把 SMB Security Settings 的 Export 設成 No"
  return 0
}

cmd_plugin_remove() { do_uninstall; }

# 設定頁（Settings → Steward）的後端。按鈕觸發的動作一律丟到背景跑，網頁每秒來問一次進度，
# 所以不會有等到逾時的網頁請求，下載這種要幾分鐘的事也一樣看得到進度。

job_busy() { [ -e "$JOBLOCK" ] && ! flock -n "$JOBLOCK" true 2>/dev/null; }

cmd_gui() {
  local what=${1:-} arg=${2:-} sock p i
  case "$what" in
  status | poll) # 前幾行是給網頁判讀的狀態，接著是工作紀錄；status 會再附上完整狀態
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
    case "$arg" in start | stop | restart) ;; *) die "不支援的動作：$arg" ;; esac
    mkdir -p "$RUN_DIR"
    exec 7>"$JOBLOCK"
    if ! flock -n 7; then
      say "busy"
      return 0
    fi
    : >"$JOBLOG"
    ( # 鎖（7 號 fd）交給背景的工作，它結束時才放開
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
  terminal) # 「登入與首次設定」：開一個只跑 setup 的網頁終端機，網址是 /logterminal/steward/
    sock="$P/var/tmp/steward.sock"
    command -v ttyd-exec >/dev/null 2>&1 || die "這台機器沒有 ttyd-exec，請改在終端機執行 steward setup"
    for p in $(pgrep --ns $$ -x ttyd 2>/dev/null); do # 上次開的視窗若還在，先結束它，等它真的離開再開新的
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
    [ -S "$sock" ] || die "終端機沒有啟動，請改在 Unraid 終端機執行 steward setup"
    say "ok"
    ;;
  setup) # 上面那個終端機視窗裡跑的
    HOLD_WINDOW=1
    cmd_setup
    ;;
  *) return 2 ;;
  esac
}

usage() {
  cat <<'EOF'
steward <指令>
  install      首次安裝或修復：建立目錄與掛鉤、準備 Claude Code（用外掛安裝的不必手動執行）
  setup        登入 claude.ai 並完成 Remote Control 的首次確認（需要互動式終端機）
  start        啟動常駐服務，並設為開機自動啟動
  stop         停止服務，並取消開機自動啟動
  restart      重啟服務（改過 steward.conf 之後用）
  status       服務、登入、版本、最近的連線網址
  logs [-f|N]  查看紀錄
  update       立即更新 Claude Code（平常每天 08:00 後、沒有 session 在用時自動更新）
  uninstall    移除掛鉤並停止服務，資料保留（用外掛安裝的請到 Plugins 頁移除）
EOF
}

cmd=${1:-help}
[ $# -gt 0 ] && shift

# 這些指令會結束服務底下所有行程。若是服務裡的 Claude 自己呼叫的，就改到服務外面去跑，免得做到一半把自己殺掉
if [ -n "${STEWARD_SVC:-}" ]; then
  case "$cmd" in
  start | stop | restart | update | uninstall | watchdog) # watchdog 可能觸發 auto_update 的重啟
    log "服務內部要求執行 $cmd，交給背景處理"
    (
      cd / || exit 1
      close_fds
      exec env -u "$TAG" setsid bash "$SELF" "$cmd" "$@" </dev/null >/dev/null 2>&1
    ) &
    say "已交給背景執行 $cmd。服務若因此重啟，Remote Control 連線會中斷一下。"
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
*) usage ;;
esac
