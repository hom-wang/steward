#!/bin/bash
# 用案例檔測 bash-guard hook。用法：hook-test.sh <hook 腳本> [案例檔]
# 案例檔格式：want<TAB>command，want = deny | ask | pass；# 開頭與空行略過。
# hook 只讀 stdin 的 JSON 並印出判定，不會執行案例裡的指令。
set -u
here=$(cd "$(dirname "$0")" && pwd)
hook=${1:?用法：hook-test.sh <hook 腳本> [案例檔]}
cases=${2:-$here/hook-cases.tsv}
[ -f "$hook" ] || { echo "找不到 hook：$hook" >&2; exit 2; }
[ -f "$cases" ] || { echo "找不到案例檔：$cases" >&2; exit 2; }

n=0 fail=0
while IFS=$'\t' read -r want cmd _comment; do # 第三欄起是註解
  case "$want" in '' | '#'*) continue ;; esac
  n=$((n + 1))
  out=$(jq -cn --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}' | bash "$hook" 2>/dev/null)
  got=$(jq -r '.hookSpecificOutput.permissionDecision // empty' <<<"$out" 2>/dev/null)
  got=${got:-pass}
  if [ "$got" = "$want" ]; then
    [ -n "${VERBOSE:-}" ] && printf 'ok    %-5s %s\n' "$want" "$cmd"
  else
    printf 'FAIL  want=%-4s got=%-4s  %s\n' "$want" "$got" "$cmd"
    fail=$((fail + 1))
  fi
done <"$cases"
echo "hook-test：$((n - fail))/$n 通過（$hook）"
((fail == 0))
