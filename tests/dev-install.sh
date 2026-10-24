#!/bin/bash
# Build a development copy of steward.plg to install on your own server (see RELEASING.md).
# Usage: tests/dev-install.sh [main ref]
#   main ref   default origin/main; the dev version is based on the version released there
# The copy gets the version <main version>-dev.<commit>[.dirty]. Unraid compares versions with strcmp, so that
# sorts after main's version and before any later release: the server shows the next release as an update.
# Only the copy is changed; the repo keeps its real version. Output: /tmp/steward-dev/steward.plg
# This script does not install anything; it prints the command to do so.
set -u
here=$(cd "$(dirname "$0")" && pwd)
cd "$here/.." || exit 2
main=${1:-origin/main}
git rev-parse -q --verify "$main^{commit}" >/dev/null || { echo "main ref $main not found"; exit 2; }
plg_version() { sed -n 's/.*ENTITY version *"\([^"]*\)".*/\1/p'; }
before() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | LC_ALL=C sort | head -n1)" = "$1" ]; } # $1 sorts before $2

vm=$(git show "$main:steward.plg" | plg_version)
vt=$(plg_version <steward.plg)
dirty=
[ -n "$(git status --porcelain -- steward.plg steward.sh skills)" ] && dirty=.dirty
dv="$vm-dev.$(git rev-parse --short HEAD)$dirty"
# The release this tree becomes must still look like an update to a server running the dev copy
before "$vm" "$dv" || { echo "dev version $dv does not sort after $vm"; exit 1; }
[ "$vt" = "$vm" ] || before "$dv" "$vt" || { echo "dev version $dv does not sort before $vt"; exit 1; }

out=/tmp/steward-dev/steward.plg
mkdir -p "${out%/*}" || exit 1
sed -e "s/^<!ENTITY version .*/<!ENTITY version \"$dv\">/" -e "s/^STEWARD_VERSION=\".*\"/STEWARD_VERSION=\"$dv\"/" \
  steward.plg >"$out" || exit 1
[ "$(plg_version <"$out")" = "$dv" ] && [ "$(command grep -c "^STEWARD_VERSION=\"$dv\"$" "$out")" = 1 ] \
  || { echo "could not set the version in $out"; exit 1; }
xmllint --noout "$out" || exit 1
echo "built $out, version $dv (main has $vm, this tree $vt)"

cur=$(plg_version </boot/config/plugins/steward.plg 2>/dev/null)
[ -n "$cur" ] || exit 0
echo "installed on this server: $cur"
if before "$cur" "$dv"; then
  echo "install with: plugin install $out"
else
  # plugin refuses the same or an older version unless forced, e.g. the first dev copy over a release
  echo "install with: plugin install $out forced   ($cur does not sort before $dv)"
fi
echo "installing restarts the Steward service, which drops Remote Control sessions for a few seconds"
