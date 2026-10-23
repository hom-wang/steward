#!/bin/bash
# Run every test. Usage: tests/run-all.sh [--quick]  (--quick skips the smoke test, which takes tens of seconds)
# All of it is safe on a live server: the hook test only feeds JSON, the auto_update test uses fake dependencies,
# and the smoke test runs in a fake root directory and never starts a service.
set -u
here=$(cd "$(dirname "$0")" && pwd)
dev=$here/..
rc=0
step() { echo "-- $1"; shift; "$@" || rc=1; echo; }

step "syntax" bash -c "bash -n '$dev/steward.sh' && echo 'steward.sh syntax OK' && xmllint --noout '$dev/steward.plg' && echo 'steward.plg XML OK'"

# The script embedded in the plg must be identical to steward.sh
step "plg sync" bash -c '
  m=$(grep -n "<!-- 5. Main script" "'"$dev"'/steward.plg" | cut -d: -f1); s=$((m+2))
  e=$(awk -v s=$s "NR>s && /^\]\]><\/INLINE>/ {print NR; exit}" "'"$dev"'/steward.plg")
  if sed -n "$((s+1)),$((e-1))p" "'"$dev"'/steward.plg" | cmp -s - "'"$dev"'/steward.sh"; then echo "embedded script matches steward.sh"; else echo "embedded script differs from steward.sh; re-sync it"; exit 1; fi
  grep -q "\]\]>" "'"$dev"'/steward.sh" && { echo "steward.sh contains ]]>, which would end the CDATA early"; exit 1; }
  v1=$(sed -n "s/.*ENTITY version *\"\([^\"]*\)\".*/\1/p" "'"$dev"'/steward.plg"); v2=$(sed -n "s/^STEWARD_VERSION=\"\(.*\)\"/\1/p" "'"$dev"'/steward.sh")
  [ "$v1" = "$v2" ] && echo "versions match: $v1" || { echo "version mismatch: plg=$v1 sh=$v2"; exit 1; }'

# Everything in the repo is plain ASCII, apart from the box-drawing dividers and spinner glyphs in steward.sh
step "ascii only" bash -c '
  tab=$(printf "\t")
  found=$(grep -n "[^ -~$tab]" "'"$dev"'/steward.sh" "'"$dev"'/steward.plg" "'"$dev"'/README.md" "'"$dev"'/LICENSE" "'"$dev"'"/tests/* "'"$dev"'"/.github/workflows/* | grep -v "[─⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏✔✘]")
  if [ -n "$found" ]; then printf "%s\n" "$found" | head -n 5 | cut -c1-120; echo "non-ASCII text found (see above)"; exit 1; fi
  echo "ASCII only, apart from the allowed glyphs"'

# The hook embedded in the dev script (the HOOK heredoc inside write_defaults)
tmp=$(mktemp /tmp/steward-hook.XXXXXX)
sed -n "/<<'HOOK'$/,/^HOOK$/p" "$dev/steward.sh" | sed '1d;$d' >"$tmp"
step "hook (embedded in dev script)" bash "$here/hook-test.sh" "$tmp"
rm -f "$tmp"
[ -f /boot/steward/hooks/bash-guard.sh ] && step "hook (installed on this machine)" bash "$here/hook-test.sh" /boot/steward/hooks/bash-guard.sh

step "auto_update scenarios" bash "$here/autoupdate-test.sh" "$dev/steward.sh"

[ "${1:-}" = --quick ] || step "smoke test (fake root)" bash "$here/smoke-test.sh" "$dev/steward.sh"

((rc == 0)) && echo "all passed" || echo "some tests failed"
exit $rc
