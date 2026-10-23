#!/bin/bash
# Release rules that can be checked mechanically (see RELEASING.md).
# Usage: tests/release-check.sh [main ref] [target branch] [source branch]
#   main ref       what is released now, default origin/main; versions are compared with it
#   target branch  the branch a PR merges into (CI passes github.base_ref); default: none, skip that check
#   source branch  the PR's branch (CI passes github.head_ref); default: the current branch
# Merging to main is the release, so any change to what ships in steward.plg must raise the version, and
# shipped changes reach main only from release/v<version>.
set -u
here=$(cd "$(dirname "$0")" && pwd)
cd "$here/.." || exit 2
main=${1:-origin/main}
target=${2:-}
source=${3:-$(git rev-parse --abbrev-ref HEAD)}
git rev-parse -q --verify "$main^{commit}" >/dev/null || { echo "main ref $main not found"; exit 2; }
fail=0
bad() { echo "FAIL  $1"; fail=1; }
plg_version() { sed -n 's/.*ENTITY version *"\([^"]*\)".*/\1/p'; }

changed=$(git diff --name-only "$main"...HEAD)
vb=$(git show "$main:steward.plg" | plg_version)
vh=$(plg_version <steward.plg)
# Everything under these paths ends up inside steward.plg, i.e. on users' servers
shipped=0
printf '%s\n' "$changed" | command grep -qE '^(steward\.plg|steward\.sh|skills/)' && shipped=1

if ((shipped)); then
  echo "shipped files differ from $main; version $vb -> $vh"
  [[ $vh =~ ^[0-9]{4}\.[0-9]{2}\.[0-9]{2}(\.[1-9])?$ ]] || bad "version $vh is not YYYY.MM.DD or YYYY.MM.DD.N (N = 1-9)"
  # Unraid compares versions as plain strings, so the new one must sort after the old one byte by byte
  if [ "$vh" = "$vb" ]; then bad "version not raised (still $vb)"
  elif [ "$(printf '%s\n%s\n' "$vb" "$vh" | LC_ALL=C sort | tail -n1)" != "$vh" ]; then bad "version $vh does not sort after $vb"
  fi
  sed -n '/^<CHANGES>/,/^<\/CHANGES>/p' steward.plg | command grep -m1 '^### ' | command grep -qx "### $vh" \
    || bad "the first CHANGES entry in steward.plg is not \"### $vh\""
else
  echo "no shipped files differ from $main; version bump not required"
fi

# Flow: feature PRs go into release/v<version>; only that branch brings shipped changes to main
case "$target" in
  main)
    ((shipped)) && [ "$source" != "release/v$vh" ] && bad "shipped changes must reach main from release/v$vh, not from $source" ;;
  release/v*)
    [ "$target" = "release/v$vh" ] || bad "a PR into $target must set the version to ${target#release/v} (steward.plg has $vh)" ;;
esac
case "$source" in
  release/v*) [ "$source" = "release/v$vh" ] || bad "branch $source carries version $vh" ;;
esac

# A skill whose text changed must carry a new skill-version
sv() { sed -n 's/^  skill-version: *"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p'; }
for f in $(printf '%s\n' "$changed" | command grep -E '^skills/[^/]+/SKILL\.md$'); do
  [ -f "$f" ] || continue
  old=$(git show "$main:$f" 2>/dev/null | sv)
  new=$(sv <"$f")
  [ -z "$old" ] || [ "$old" != "$new" ] || bad "$f changed but skill-version is still $old"
done

# The pinned Claude Code binary needs both a version and a well-formed checksum
pv=$(sed -n 's/^CLAUDE_PIN_VERSION="\(.*\)"/\1/p' steward.sh)
ps=$(sed -n 's/^CLAUDE_PIN_SHA256="\(.*\)"/\1/p' steward.sh)
[[ $pv =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || bad "CLAUDE_PIN_VERSION \"$pv\" is malformed"
[[ $ps =~ ^[0-9a-f]{64}$ ]] || bad "CLAUDE_PIN_SHA256 is malformed"

# Installed servers find updates through these; they must never change
url='https://raw.githubusercontent.com/hom-wang/steward/main/steward.plg'
command grep -q "pluginURL=\"$url\"" steward.plg || bad "pluginURL in steward.plg changed"
command grep -q "<PluginURL>$url</PluginURL>" plugins/steward.xml || bad "PluginURL in plugins/steward.xml changed"
command grep -q '<!ENTITY name    "steward">' steward.plg || bad "plugin name changed"

((fail == 0)) && echo "release rules OK"
exit $fail
