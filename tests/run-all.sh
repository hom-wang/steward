#!/bin/bash
# 跑全部測試。用法：tests/run-all.sh [--quick]（--quick 跳過要幾十秒的煙霧測試）
# 全部都是安全的：hook 測試只餵 JSON；auto_update 測試全用假依賴；煙霧測試在假根目錄、不啟動服務。
set -u
here=$(cd "$(dirname "$0")" && pwd)
dev=$here/..
rc=0
step() { echo "── $1"; shift; "$@" || rc=1; echo; }

step "語法" bash -c "bash -n '$dev/steward.sh' && echo 'steward.sh 語法 OK' && xmllint --noout '$dev/steward.plg' && echo 'steward.plg XML OK'"

# plg 內嵌的腳本必須和 steward.sh 完全一樣
step "plg 同步" bash -c '
  m=$(grep -n "<!-- 5. 主腳本" "'"$dev"'/steward.plg" | cut -d: -f1); s=$((m+2))
  e=$(awk -v s=$s "NR>s && /^\]\]><\/INLINE>/ {print NR; exit}" "'"$dev"'/steward.plg")
  if sed -n "$((s+1)),$((e-1))p" "'"$dev"'/steward.plg" | cmp -s - "'"$dev"'/steward.sh"; then echo "plg 內嵌腳本與 steward.sh 相同"; else echo "plg 內嵌腳本與 steward.sh 不同，請重新同步"; exit 1; fi
  grep -q "\]\]>" "'"$dev"'/steward.sh" && { echo "steward.sh 含 ]]>，會提早結束 CDATA"; exit 1; }
  v1=$(sed -n "s/.*ENTITY version *\"\([^\"]*\)\".*/\1/p" "'"$dev"'/steward.plg"); v2=$(sed -n "s/^STEWARD_VERSION=\"\(.*\)\"/\1/p" "'"$dev"'/steward.sh")
  [ "$v1" = "$v2" ] && echo "版號一致：$v1" || { echo "版號不一致：plg=$v1 sh=$v2"; exit 1; }'

# dev 內嵌的 hook（write_defaults 裡 HOOK heredoc）
tmp=$(mktemp /tmp/steward-hook.XXXXXX)
sed -n "/<<'HOOK'$/,/^HOOK$/p" "$dev/steward.sh" | sed '1d;$d' >"$tmp"
step "hook（dev 內嵌版）" bash "$here/hook-test.sh" "$tmp"
rm -f "$tmp"
[ -f /boot/steward/hooks/bash-guard.sh ] && step "hook（這台已安裝版）" bash "$here/hook-test.sh" /boot/steward/hooks/bash-guard.sh

step "auto_update 情境" bash "$here/autoupdate-test.sh" "$dev/steward.sh"

[ "${1:-}" = --quick ] || step "煙霧測試（假根目錄）" bash "$here/smoke-test.sh" "$dev/steward.sh"

((rc == 0)) && echo "全部通過" || echo "有測試失敗"
exit $rc
