#!/bin/sh
set -eu

# Usage: ci_scripts/test-check-repo-settings.sh
#
# Exercises ci_scripts/check-repo-settings.sh against a stubbed `gh`. The real
# endpoints answer differently for an admin caller than for anyone else, and a
# live repository cannot be made to answer both ways on demand — nor to have a
# setting drifted while a test watches. So the responses are supplied here
# instead, one case per shape the script has to tell apart.
#
# Exit codes: 0 every case behaved, 1 at least one did not, 2 the test itself
# could not run.

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
subject=$repo_root/ci_scripts/check-repo-settings.sh
repo=owner/name

[ -x "$subject" ] || { echo "test-check-repo-settings: no $subject" >&2; exit 2; }
command -v jq >/dev/null 2>&1 ||
  { echo "test-check-repo-settings: jq is not installed" >&2; exit 2; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/bin"
cat >"$work/bin/gh" <<'STUB'
#!/bin/sh
# Answers from $GH_STUB/<url with / replaced by _>.json, with an optional
# sibling .status file naming the HTTP code to answer with.
[ "${1:-}" = api ] || { echo "gh stub: unexpected invocation: $*" >&2; exit 90; }
shift
key=$(printf '%s' "${1:-}" | tr '/' '_')
body=$GH_STUB/$key.json
code=200
if [ -f "$GH_STUB/$key.status" ]; then
  code=$(cat "$GH_STUB/$key.status")
fi
if [ "$code" -ge 400 ] || [ ! -f "$body" ]; then
  echo "gh stub: HTTP $code for ${1:-}" >&2
  exit 1
fi
cat "$body"
STUB
chmod +x "$work/bin/gh"

failures=0
case_number=0

# Fixtures every case starts from: the required check present, private
# reporting on. A case overwrites whichever of them it is about.
new_case() { # -> echoes a fixture directory
  case_number=$((case_number + 1))
  dir=$work/case$case_number
  mkdir -p "$dir"
  echo '{"default_branch":"main"}' >"$dir/repos_owner_name.json"
  cat >"$dir/repos_owner_name_rules_branches_main.json" <<'JSON'
[{"type":"required_status_checks",
  "parameters":{"required_status_checks":[{"context":"build-and-test"}]}}]
JSON
  echo '{"enabled":true}' >"$dir/repos_owner_name_private-vulnerability-reporting.json"
  # No security_and_analysis by default: that is what every non-admin caller
  # receives, including the token the weekly workflow runs with.
  echo "$dir"
}

# The payload an admin caller receives, which is the only one that reports
# either scanning setting. Pass a push-protection status, or nothing to omit
# the key entirely.
admin_scanning() { # fixture-dir secret-scanning-status [push-protection-status]
  if [ -n "${3:-}" ]; then
    printf '%s\n' '{"default_branch":"main",' \
      ' "security_and_analysis":{"secret_scanning":{"status":"'"$2"'"},' \
      '                          "secret_scanning_push_protection":{"status":"'"$3"'"}}}'
  else
    printf '%s\n' '{"default_branch":"main",' \
      ' "security_and_analysis":{"secret_scanning":{"status":"'"$2"'"}}}'
  fi >"$1/repos_owner_name.json"
}

expect() { # label fixture-dir expected-exit expected-substring
  label=$1
  dir=$2
  want=$3
  needle=$4
  set +e
  output=$(PATH="$work/bin:$PATH" GH_STUB="$dir" "$subject" "$repo" 2>&1)
  got=$?
  set -e
  if [ "$got" -ne "$want" ]; then
    failures=$((failures + 1))
    echo "FAIL $label — expected exit $want, got $got"
    echo "$output" | sed 's/^/       /'
    return 0
  fi
  case $output in
    *"$needle"*) echo "ok   $label" ;;
    *)
      failures=$((failures + 1))
      echo "FAIL $label — exit $got was right but the report never said \"$needle\""
      echo "$output" | sed 's/^/       /'
      ;;
  esac
}

d=$(new_case)
admin_scanning "$d" enabled enabled
expect "an admin caller seeing both features on reports no drift" \
  "$d" 0 "**Push protection** — enabled"

d=$(new_case)
admin_scanning "$d" enabled disabled
expect "push protection off is drift even when scanning is on" \
  "$d" 1 "**Push protection** — \`disabled\`"

d=$(new_case)
admin_scanning "$d" disabled disabled
expect "an admin caller seeing scanning off is drift" \
  "$d" 1 "**Secret scanning** — disabled"

d=$(new_case)
admin_scanning "$d" disabled
expect "and push protection follows it down when the payload omits it" \
  "$d" 1 "**Push protection** — off, because secret scanning is"

# A setting this token cannot read is named in the body and left out of the
# verdict. Reading it as drift would open a tracker over a question nobody
# asked; reading it as clean silently would claim it matches. Exit 0 here is a
# claim about the settings that were readable, which is also what keeps a route
# from drifted back to resolved for them.
d=$(new_case)
expect "a setting this token cannot read is named, not counted as drift" \
  "$d" 0 "**Secret scanning** — not readable with this token"

d=$(new_case)
expect "and push protection with it" \
  "$d" 0 "**Push protection** — not readable with this token"

# The scope of that exit 0 has to be stated where the tracker's reader sees it,
# or a closed tracker reads as every setting having been checked.
d=$(new_case)
expect "an exit 0 with an unread setting says what the verdict covers" \
  "$d" 0 "are outside that verdict"

# An admin payload that reports scanning and omits push protection: the only
# shape in which one of the two is readable and the other is not, so it is the
# only case that can tell whether push protection records itself as unread —
# and the only one that can catch it blaming a token that demonstrably has the
# access.
d=$(new_case)
admin_scanning "$d" enabled
expect "a readable scanning setting does not make push protection readable" \
  "$d" 0 "**Push protection** — not readable. \`repos/owner/name\` reported secret"

# A status that is neither enabled nor disabled came out of the payload, so it
# is a value to act on rather than a question this token could not ask. The
# absent-object arm would blame the token and exit without a tracker over a
# setting the payload proves is not enabled.
d=$(new_case)
admin_scanning "$d" enabled_for_new_repos enabled
expect "an unrecognised scanning status is drift, not an unread setting" \
  "$d" 1 "**Secret scanning** — \`enabled_for_new_repos\`"

# An unread setting is outside the verdict, which must not take a readable
# setting's drift out with it.
d=$(new_case)
echo '{"enabled":false}' >"$d/repos_owner_name_private-vulnerability-reporting.json"
expect "a readable setting's drift still exits 1 alongside an unread one" \
  "$d" 1 "**Secret scanning** — not readable with this token"

d=$(new_case)
admin_scanning "$d" enabled enabled
echo '[]' >"$d/repos_owner_name_rules_branches_main.json"
expect "a branch with no required status check is still drift" \
  "$d" 1 "no rule on \`main\` requires \`build-and-test\`"

d=$(new_case)
admin_scanning "$d" enabled enabled
echo '{"enabled":false}' >"$d/repos_owner_name_private-vulnerability-reporting.json"
expect "private reporting off is still drift" \
  "$d" 1 "**Private vulnerability reporting** — \`SECURITY.md\` offers"

d=$(new_case)
echo '500' >"$d/repos_owner_name_private-vulnerability-reporting.status"
expect "an endpoint that will not answer is a check that could not run" \
  "$d" 2 "could not read repos/owner/name/private-vulnerability-reporting"

if [ "$failures" -eq 0 ]; then
  echo "test-check-repo-settings: all cases behaved."
  exit 0
fi
echo "test-check-repo-settings: $failures case(s) did not behave." >&2
exit 1
