#!/bin/bash
# Test the bash-guard hook against a case file. Usage: hook-test.sh <hook script> [case file]
# Case file format: want<TAB>command, where want = deny | ask | pass; lines starting with # and blank lines are skipped.
# The hook only reads JSON from stdin and prints its decision; the commands in the cases are never executed.
set -u
here=$(cd "$(dirname "$0")" && pwd)
hook=${1:?usage: hook-test.sh <hook script> [case file]}
cases=${2:-$here/hook-cases.tsv}
[ -f "$hook" ] || { echo "hook not found: $hook" >&2; exit 2; }
[ -f "$cases" ] || { echo "case file not found: $cases" >&2; exit 2; }

n=0 fail=0
while IFS=$'\t' read -r want cmd _comment; do # third column onward is a comment
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
echo "hook-test: $((n - fail))/$n passed ($hook)"
((fail == 0))
