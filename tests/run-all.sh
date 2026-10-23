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
  found=$(grep -n "[^ -~$tab]" "'"$dev"'/steward.sh" "'"$dev"'/steward.plg" "'"$dev"'/README.md" "'"$dev"'/RELEASING.md" "'"$dev"'/LICENSE" "'"$dev"'"/tests/* "'"$dev"'"/.github/workflows/* "'"$dev"'"/plugins/*.xml "'"$dev"'/ca_profile.xml" "'"$dev"'"/images/*.svg "'"$dev"'"/docs/*.md | grep -v "[─⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏✔✘]")
  if [ -n "$found" ]; then printf "%s\n" "$found" | head -n 5 | cut -c1-120; echo "non-ASCII text found (see above)"; exit 1; fi
  echo "ASCII only, apart from the allowed glyphs"'

# Nothing that must not be published: keys, tokens, e-mail addresses, private IPs, MACs, Remote Control or session ids,
# Unraid registration GUIDs, personal names. Scans every tracked text file in the working tree. Run before every commit.
step "secrets and personal data" bash -c '
  cd "'"$dev"'" || exit 1
  pat="[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[a-z]{2,}"
  pat="$pat|(^|[^0-9.])(10|172\.(1[6-9]|2[0-9]|3[01])|192\.168)\.[0-9]+\.[0-9]+([^0-9.]|$)"
  pat="$pat|\b([0-9a-f]{2}:){5}[0-9a-f]{2}\b"
  pat="$pat|\benv_[A-Za-z0-9]{12,}|\bsession_[A-Za-z0-9]{12,}"
  pat="$pat|\bgh[pousr]_[A-Za-z0-9]{20,}|sk-ant-[A-Za-z0-9_-]+|\bAKIA[0-9A-Z]{12,}"
  pat="$pat|BEGIN [A-Z ]*PRIVATE KEY|ssh-(rsa|ed25519|ecdsa) AAAA"
  pat="$pat|csrf_token=.|regGUID=.|flashGUID=.|[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}"
  pat="$pat|\.credentials\.json|hosts\.yml|unraid-api\.key"
  found=$(git ls-files -z | xargs -0 command grep -nIE -i "$pat" 2>/dev/null | command grep -vE "^(README\.md|skills/[^:]+|docs/[^:]+|steward\.(sh|plg)):[0-9]+:.*(\.credentials\.json|unraid-api\.key|hosts\.yml)" )
  if [ -n "$found" ]; then printf "%s\n" "$found" | head -n 10 | cut -c1-140; echo "possible secret or personal data (see above); do not commit"; exit 1; fi
  echo "no secrets or personal data found in tracked files"'

# The hook embedded in the dev script (the HOOK heredoc inside write_defaults)
tmp=$(mktemp /tmp/steward-hook.XXXXXX)
sed -n "/<<'HOOK'$/,/^HOOK$/p" "$dev/steward.sh" | sed '1d;$d' >"$tmp"
step "hook (embedded in dev script)" bash "$here/hook-test.sh" "$tmp"
rm -f "$tmp"
[ -f /boot/steward/hooks/bash-guard.sh ] && step "hook (installed on this machine)" bash "$here/hook-test.sh" /boot/steward/hooks/bash-guard.sh

step "auto_update scenarios" bash "$here/autoupdate-test.sh" "$dev/steward.sh"

step "download and checksum scenarios" bash "$here/download-test.sh" "$dev/steward.sh"

# Version bump and release invariants against main (RELEASING.md), including uncommitted edits. Local runs only:
# CI runs release-check in its own step with the PR's target and source branch.
[ -z "${CI:-}" ] && git -C "$dev" rev-parse -q --verify origin/main >/dev/null &&
  step "release rules (against origin/main)" bash "$here/release-check.sh" origin/main

[ "${1:-}" = --quick ] || step "smoke test (fake root)" bash "$here/smoke-test.sh" "$dev/steward.sh"

((rc == 0)) && echo "all passed" || echo "some tests failed"
exit $rc
