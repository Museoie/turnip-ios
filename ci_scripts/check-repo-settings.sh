#!/bin/sh
set -eu

# Usage: ci_scripts/check-repo-settings.sh [owner/repo]
#
# Reports whether the repository settings this project relies on are actually
# in force: the status check CONTRIBUTING.md requires before merge, the private
# reporting route SECURITY.md offers as an alternative to email, and the secret
# scanning and push protection that stand between a credential and a public
# commit. None of them is a file, so none appears in a diff and no review can
# catch one being absent. Writes a markdown report to stdout.
#
# The repository defaults to $GH_REPO, then to whatever `gh` resolves for the
# working directory.
#
# Exit codes: 0 every setting this caller could read is as it should be, 1 at
# least one is not, 2 the check itself could not run. The verdict covers the
# settings that were readable and no others: a setting this token cannot read
# is reported as unread in the body and left out of the exit code, so a caller
# never has to choose between reading an unanswered question as clean and
# having no route from drifted back to resolved.

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

# repos/$repo carries both scanning settings, but only for a caller with admin
# access: every other token receives the same payload with security_and_analysis
# omitted. Nothing else reports either setting — the secret-scanning alerts
# endpoint answers 404 to every non-admin caller whatever the setting is,
# including against repositories that demonstrably have scanning on — so an
# absent object is reported as unread rather than read as disabled.
secret_scanning=$(jq -r '
  .security_and_analysis.secret_scanning.status // ""
' "$workdir/repo.json")
push_protection=$(jq -r '
  .security_and_analysis.secret_scanning_push_protection.status // ""
' "$workdir/repo.json")

drifted=0
unreadable=0

echo "Every setting below is configured outside this repository, where no diff"
echo "and no review can see it."
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

case "$secret_scanning" in
  enabled)
    echo "- **Secret scanning** — enabled, so a credential that reaches this"
    echo "  repository is reported rather than sitting in public history unnoticed."
    ;;
  disabled)
    drifted=1
    echo "- **Secret scanning** — disabled. This repository is public, so a credential"
    echo "  that lands here is readable by anyone the moment it is pushed and nothing"
    echo "  raises a hand. The CI scan covers what a pull request proposes; this is"
    echo "  the half that covers everything else, including a direct push to"
    echo "  \`$branch\`. Fix under *Settings, Code security*: turn on *Secret scanning*."
    ;;
  "")
    unreadable=1
    echo "- **Secret scanning** — not readable with this token. \`repos/$repo\` omits"
    echo "  \`security_and_analysis\` for a caller without admin access, and no other"
    echo "  endpoint reports the setting, so this run cannot tell enabled from"
    echo "  disabled. Re-run with a token that has admin read on the repository."
    ;;
  *)
    drifted=1
    echo "- **Secret scanning** — \`$secret_scanning\`, which is neither \`enabled\` nor"
    echo "  \`disabled\`. The payload did carry the setting, so this is a value to act on"
    echo "  rather than a question this token cannot ask, and nothing here establishes"
    echo "  that a credential reaching \`$branch\` would be reported. Fix under"
    echo "  *Settings, Code security*: turn on *Secret scanning*."
    ;;
esac

case "$push_protection" in
  enabled)
    echo "- **Push protection** — enabled, so a push carrying a recognized credential"
    echo "  is rejected instead of reported after the fact."
    ;;
  "")
    if [ "$secret_scanning" = disabled ]; then
      echo "- **Push protection** — off, because secret scanning is: nothing can reject"
      echo "  a push over a credential it is not looking for."
    elif [ -z "$secret_scanning" ]; then
      unreadable=1
      echo "- **Push protection** — not readable with this token, for the reason above:"
      echo "  only \`security_and_analysis\` reports it, and only an admin caller"
      echo "  receives that object."
    else
      unreadable=1
      echo "- **Push protection** — not readable. \`repos/$repo\` reported secret"
      echo "  scanning and omitted \`secret_scanning_push_protection\`, so this caller"
      echo "  has the access the setting needs and the payload still does not carry it."
      echo "  Nothing else reports it, so this run cannot tell enabled from disabled."
    fi
    ;;
  *)
    drifted=1
    echo "- **Push protection** — \`$push_protection\`. Secret scanning reports a"
    echo "  credential once it is already public, which is after the point where"
    echo "  rotating it stops being optional; push protection is the half that"
    echo "  refuses the push. Fix under *Settings, Code security*: enable *Push"
    echo "  protection* under *Secret scanning*."
    ;;
esac

if [ "$drifted" -eq 1 ]; then
  echo
  echo "Every fix above is a repository setting, and changing one needs admin"
  echo "access to this repository."
  exit 1
fi

if [ "$unreadable" -eq 1 ]; then
  echo
  echo "Every setting this token could read is as the documents describe. The ones"
  echo "above reported as not readable are outside that verdict — this run claims"
  echo "nothing about them either way, and only a token with admin read on the"
  echo "repository can settle them."
fi

exit 0
