#!/bin/bash
# Release rules that can be checked mechanically (see RELEASING.md).
# Usage: tests/release-check.sh [main ref] [target branch] [source branch]
#   main ref       what is released now, default origin/main; versions are compared with it
#   target branch  the branch a PR merges into (CI passes github.base_ref); without it the branch flow is not checked
#   source branch  the PR's branch (CI passes github.head_ref)
# Compares the working tree, uncommitted edits included, with the point where it left main.
# Merging to main is the release, so any change to what ships in steward.plg must raise the version, and
# shipped changes reach main only from release/v<version>.
set -u
here=$(cd "$(dirname "$0")" && pwd)
cd "$here/.." || exit 2
main=${1:-origin/main}
target=${2:-}
src=${3:-}
git rev-parse -q --verify "$main^{commit}" >/dev/null || { echo "main ref $main not found"; exit 2; }
fail=0
bad() { echo "FAIL  $1"; fail=1; }
plg_version() { sed -n 's/.*ENTITY version *"\([^"]*\)".*/\1/p'; }
newer() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | LC_ALL=C sort | tail -n1)" = "$2" ]; } # $2 sorts after $1

changed=$({ git diff --name-only "$(git merge-base "$main" HEAD)"; git ls-files --others --exclude-standard; } | sort -u)
vb=$(git show "$main:steward.plg" | plg_version)
vh=$(plg_version <steward.plg)
# Everything under these paths ends up inside steward.plg, i.e. on users' servers
shipped=0
printf '%s\n' "$changed" | command grep -qE '^(steward\.(plg|sh)$|skills/)' && shipped=1

if ((shipped)); then
  echo "shipped files differ from $main; version $vb -> $vh"
  # Format only: whether the date is the merge date is up to the person merging
  [[ $vh =~ ^[0-9]{4}\.(0[1-9]|1[0-2])\.(0[1-9]|[12][0-9]|3[01])(\.[1-9])?$ ]] || bad "version $vh is not YYYY.MM.DD or YYYY.MM.DD.N (N = 1-9)"
  # Unraid compares versions as plain strings, so the new one must sort after the old one byte by byte
  newer "$vb" "$vh" || bad "version $vh does not sort after $vb, the version on main"
  sed -n '/^<CHANGES>/,/^<\/CHANGES>/p' steward.plg | command grep -m1 '^### ' | command grep -qx "### $vh" \
    || bad "the first CHANGES entry in steward.plg is not \"### $vh\""

  # Flow: shipped changes go into release/v<version> and only that branch brings them to main
  case "$target" in
    main) [ "$src" = "release/v$vh" ] || bad "shipped changes must reach main from release/v$vh, not from ${src:-an unknown branch}" ;;
    release/v*) [ "$target" = "release/v$vh" ] || bad "a PR into $target must set the version to ${target#release/v} (steward.plg has $vh)" ;;
  esac
else
  echo "no shipped files differ from $main; version bump not required"
fi

# A skill whose text changed must carry a skill-version that sorts after the one on main
sv() { sed -n 's/^  skill-version: *"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p'; }
for f in $(printf '%s\n' "$changed" | command grep -E '^skills/[^/]+/SKILL\.md$'); do
  [ -f "$f" ] || continue
  new=$(sv <"$f")
  [ -n "$new" ] || { bad "$f has no readable metadata skill-version"; continue; }
  old=$(git show "$main:$f" 2>/dev/null | sv)
  [ -z "$old" ] || newer "$old" "$new" || bad "$f changed but its skill-version $new does not sort after $old"
done

# The pinned Claude Code binary needs both a version and a well-formed checksum
pv=$(sed -n 's/^CLAUDE_PIN_VERSION="\(.*\)"/\1/p' steward.sh)
ps=$(sed -n 's/^CLAUDE_PIN_SHA256="\(.*\)"/\1/p' steward.sh)
[[ $pv =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || bad "CLAUDE_PIN_VERSION \"$pv\" is malformed"
[[ $ps =~ ^[0-9a-f]{64}$ ]] || bad "CLAUDE_PIN_SHA256 is malformed"

# Installed servers find updates through these; they must never change
url='https://raw.githubusercontent.com/hom-wang/steward/main/steward.plg'
command grep -qF "pluginURL=\"$url\"" steward.plg || bad "pluginURL in steward.plg changed"
if [ -f plugins/steward.xml ]; then
  command grep -qF "<PluginURL>$url</PluginURL>" plugins/steward.xml || bad "PluginURL in plugins/steward.xml changed"
else
  bad "plugins/steward.xml is missing (the CA listing must stay at this path)"
fi
command grep -qF '<!ENTITY name    "steward">' steward.plg || bad "plugin name changed"

((fail == 0)) && echo "release rules OK"
exit $fail
