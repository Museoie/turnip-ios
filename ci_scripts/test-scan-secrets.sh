#!/bin/sh
set -eu

# Usage: ci_scripts/test-scan-secrets.sh
#
# Exercises ci_scripts/scan-secrets.sh against throwaway repositories. A gate
# that never fails is indistinguishable from no gate, so every case below
# plants a credential and requires the scan to say so — and the two error
# cases require it to report that it could not run rather than that it found
# nothing, which is the failure gitleaks makes easy: an unparseable range
# scans zero commits and then reports no leaks.
#
# Exit codes: 0 every case behaved, 1 at least one did not, 2 the test itself
# could not run.

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
subject=$repo_root/ci_scripts/scan-secrets.sh

[ -x "$subject" ] || { echo "test-scan-secrets: no $subject" >&2; exit 2; }
command -v gitleaks >/dev/null 2>&1 ||
  { echo "test-scan-secrets: gitleaks is not on PATH" >&2; exit 2; }

# Assembled from fragments because this file sits in the tree the real scan
# covers: written whole, the token would match the rule it is here to test.
pat_prefix=ghp
pat_body=A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8
token="${pat_prefix}_${pat_body}"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

failures=0

new_repo() { # name -> echoes the repo path
  path=$work/$1
  mkdir -p "$path/ci_scripts"
  cp "$subject" "$path/ci_scripts/scan-secrets.sh"
  git -C "$path" init --quiet
  git -C "$path" config user.email ci@example.invalid
  git -C "$path" config user.name "scan-secrets test"
  git -C "$path" config commit.gpgsign false
  echo "$path"
}

commit() { # repo message
  git -C "$1" add -A
  git -C "$1" commit --quiet --no-verify -m "$2"
}

expect() { # label expected-exit repo [base]
  label=$1
  want=$2
  path=$3
  shift 3
  set +e
  output=$("$path/ci_scripts/scan-secrets.sh" "$@" 2>&1)
  got=$?
  set -e
  if [ "$got" -eq "$want" ]; then
    echo "ok   $label"
  else
    failures=$((failures + 1))
    echo "FAIL $label — expected exit $want, got $got"
    echo "$output" | sed 's/^/       /'
  fi
}

r=$(new_repo clean)
echo "nothing to see" >"$r/README.md"
commit "$r" "seed"
base=$(git -C "$r" rev-parse HEAD)
echo "still nothing" >>"$r/README.md"
commit "$r" "more prose"
expect "a range with no credential passes" 0 "$r" "$base"

r=$(new_repo leaked)
echo "nothing to see" >"$r/README.md"
commit "$r" "seed"
base=$(git -C "$r" rev-parse HEAD)
printf 'token = "%s"\n' "$token" >"$r/config.txt"
commit "$r" "add a credential"
expect "a credential in the range fails" 1 "$r" "$base"
expect "and the working tree it leaves behind fails too" 1 "$r"

r=$(new_repo transient)
echo "nothing to see" >"$r/README.md"
commit "$r" "seed"
base=$(git -C "$r" rev-parse HEAD)
printf 'token = "%s"\n' "$token" >"$r/config.txt"
commit "$r" "add a credential"
git -C "$r" rm --quiet config.txt
commit "$r" "delete it again"
# The whole reason the pull request path scans a commit range rather than the
# tree: this history reaches a public remote with the credential in it, and
# the tree that arrives with it is spotless.
expect "a credential deleted later in the range still fails" 1 "$r" "$base"
expect "even though its working tree is clean" 0 "$r"

r=$(new_repo unresolvable)
echo "nothing to see" >"$r/README.md"
commit "$r" "seed"
expect "a base ref that does not resolve is an error, not a pass" 2 "$r" "no/such/ref"
expect "an empty range is an error, not a pass" 2 "$r" "HEAD"

if [ "$failures" -eq 0 ]; then
  echo "test-scan-secrets: all cases behaved."
  exit 0
fi
echo "test-scan-secrets: $failures case(s) did not behave." >&2
exit 1
