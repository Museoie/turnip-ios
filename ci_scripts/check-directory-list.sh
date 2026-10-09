#!/bin/sh
set -eu

# Usage: ci_scripts/check-directory-list.sh [repo-root]
#
# Compares the directory list CONTRIBUTING.md prints under "Code organization"
# against the directories that actually exist under Turnip/. The list is prose,
# so nothing ties it to the tree: adding a directory renames nothing and breaks
# no build, and the sentence naming the old set stays green. It has drifted
# once per feature wave.
#
# Exit codes: 0 the list matches the tree, 1 it does not, 2 the check itself
# could not run.

fail() {
  echo "check-directory-list: $*" >&2
  exit 2
}

root=${1:-$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)}
doc=$root/CONTRIBUTING.md
tree=$root/Turnip

[ -f "$doc" ] || fail "no CONTRIBUTING.md at $doc"
[ -d "$tree" ] || fail "no Turnip directory at $tree"

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

# The sentence wraps across lines, so flatten the file before matching. The
# anchor phrase is the contract between the prose and this check: reword it and
# the check reports that it could not run, rather than silently passing.
anchor='named for the domain they own ('
tr '\n' ' ' <"$doc" |
  sed -n "s/.*$anchor\\([^)]*\\)).*/\\1/p" |
  grep -o '`[^`]*`' |
  tr -d '`' |
  sort >"$workdir/documented"

[ -s "$workdir/documented" ] ||
  fail "CONTRIBUTING.md has no backticked list after \"$anchor\" — update this check's anchor to match the document"

find "$tree" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; |
  sort >"$workdir/actual"

[ -s "$workdir/actual" ] || fail "$tree has no subdirectories"

undocumented=$(comm -13 "$workdir/documented" "$workdir/actual")
stale=$(comm -23 "$workdir/documented" "$workdir/actual")

if [ -z "$undocumented" ] && [ -z "$stale" ]; then
  echo "check-directory-list: CONTRIBUTING.md lists every directory under Turnip/."
  exit 0
fi

echo "CONTRIBUTING.md's \"Code organization\" list no longer matches Turnip/." >&2
[ -z "$undocumented" ] || {
  echo "  In the tree, not in the document:" >&2
  echo "$undocumented" | sed 's/^/    /' >&2
}
[ -z "$stale" ] || {
  echo "  In the document, not in the tree:" >&2
  echo "$stale" | sed 's/^/    /' >&2
}
echo "  Update the list in CONTRIBUTING.md under \"Code organization\"." >&2
exit 1
