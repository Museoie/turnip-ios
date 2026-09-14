#!/bin/sh
set -eu

# Usage: ci_scripts/check-repo-settings.sh [owner/repo]
#
# Reports whether the two repository settings this project's own documents
# describe are actually in force: the status check CONTRIBUTING.md requires
# before merge, and the private reporting route SECURITY.md offers as an
# alternative to email. Neither is a file, so neither appears in a diff and no
# review can catch one being absent. Writes a markdown report to stdout.
#
# The repository defaults to $GH_REPO, then to whatever `gh` resolves for the
# working directory.
#
# Exit codes: 0 both settings match the documents, 1 at least one does not, 2
# the check itself could not run. A caller must distinguish 1 from 2; exit 1 is
# a result, not a failure.

required_check=build-and-test

fail() {
  echo "check-repo-settings: $*" >&2
  exit 2
}

command -v gh >/dev/null 2>&1 || fail "gh is not installed"
command -v jq >/dev/null 2>&1 || fail "jq is not installed"

repo=${1:-${GH_REPO:-}}
if [ -z "$repo" ]; then
  repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)
fi
[ -n "$repo" ] || fail "no repository: pass owner/repo, or set GH_REPO"

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

# Never inside a command substitution: fail() would exit only the subshell and
# leave the caller reading an empty response as if it were an answer.
api() { # url outfile
  gh api "$1" >"$2" 2>"$workdir/err" ||
    fail "could not read $1: $(tr '\n' ' ' <"$workdir/err")"
}

api "repos/$repo" "$workdir/repo.json"
branch=$(jq -r '.default_branch // ""' "$workdir/repo.json")
[ -n "$branch" ] || fail "repos/$repo returned no default_branch"

# Every rule in force on the default branch, from every ruleset that matches
# it — a rule can live in any of them, so asking the branch is more durable
# than naming one ruleset.
api "repos/$repo/rules/branches/$branch" "$workdir/rules.json"
required_contexts=$(jq -r '
  [ .[]
    | select(.type == "required_status_checks")
    | .parameters.required_status_checks[]?.context
  ]
  | unique
  | join(" ")
' "$workdir/rules.json")

api "repos/$repo/private-vulnerability-reporting" "$workdir/reporting.json"
private_reporting=$(jq -r '
  if .enabled == true then "enabled"
  elif .enabled == false then "disabled"
  else "" end
' "$workdir/reporting.json")
[ -n "$private_reporting" ] ||
  fail "private-vulnerability-reporting returned no enabled flag"

drifted=0

echo "Both settings below are promised by a document in this repository and"
echo "configured outside it, where no diff and no review can see them."
echo

case " $required_contexts " in
  *" $required_check "*)
    echo "- **Required status check** — \`$branch\` requires \`$required_check\` to pass,"
    echo "  as \`CONTRIBUTING.md\` says under *Review process*."
    ;;
  *)
    drifted=1
    echo "- **Required status check** — \`CONTRIBUTING.md\` says CI must pass before"
    echo "  merge, but no rule on \`$branch\` requires \`$required_check\`. A pull request"
    echo "  whose run is red, cancelled, or never started is mergeable on one approval;"
    echo "  a check that never started reads as nothing blocking rather than as a"
    echo "  failure. Fix under *Settings, Rules*: edit the ruleset covering \`$branch\`,"
    echo "  turn on *Require status checks to pass*, and add \`$required_check\`."
    ;;
esac

if [ "$private_reporting" = enabled ]; then
  echo "- **Private vulnerability reporting** — enabled, so the alternative to email"
  echo "  that \`SECURITY.md\` offers exists."
else
  drifted=1
  echo "- **Private vulnerability reporting** — \`SECURITY.md\` offers this as an"
  echo "  alternative to email, and it is disabled, so there is no *Report a"
  echo "  vulnerability* button to find. A reporter who wants a tracked advisory"
  echo "  instead falls back to a public issue, which is what the policy exists to"
  echo "  prevent. Fix under *Settings, Code security*: enable *Private vulnerability"
  echo "  reporting*."
fi

if [ "$drifted" -eq 1 ]; then
  echo
  echo "Every fix above is a repository setting, and changing one needs admin"
  echo "access to this repository."
fi

exit "$drifted"
