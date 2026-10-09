#!/bin/sh
set -eu

# Usage: ci_scripts/scan-secrets.sh [base-ref]
#
# Scans for committed credential material with gitleaks. Given a base ref, it
# scans the commits HEAD adds on top of it — what a pull request proposes,
# including material a later commit on the same branch deletes before a
# reviewer ever sees the diff. Given nothing, it scans the working tree.
#
# Exit codes: 0 nothing found, 1 at least one credential found, 2 the check
# itself could not run. A caller must distinguish 1 from 2.

# gitleaks answers 1 both for "found a credential" and for "could not read the
# target", and a --log-opts it cannot parse makes it scan zero commits and
# then report no leaks with exit 0. Neither answer is safe at face value, so
# the range is resolved before the scan and the leak verdict is moved off 1.
LEAK_EXIT=7

fail() {
  echo "scan-secrets: $*" >&2
  exit 2
}

command -v gitleaks >/dev/null 2>&1 ||
  fail "gitleaks is not on PATH — install it with ci_scripts/install-gitleaks.sh"

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"

base=${1:-}
set +e
if [ -n "$base" ]; then
  base_sha=$(git rev-parse --verify --quiet "$base^{commit}")
  [ -n "$base_sha" ] ||
    fail "cannot resolve '$base' — a shallow clone does not contain it, and a range that does not exist scans nothing while looking clean"
  commits=$(git rev-list --count --no-merges "$base_sha..HEAD")
  [ "$commits" -gt 0 ] ||
    fail "HEAD adds no commits on top of $base, so there is nothing to scan — which is not the same answer as nothing found"
  echo "scan-secrets: scanning $commits commit(s) that HEAD adds on top of $base"
  gitleaks git . --log-opts="--no-merges $base_sha..HEAD" \
    --redact --no-banner --exit-code "$LEAK_EXIT"
else
  echo "scan-secrets: scanning the working tree"
  gitleaks dir . --redact --no-banner --exit-code "$LEAK_EXIT"
fi
status=$?
set -e

case "$status" in
  0) exit 0 ;;
  "$LEAK_EXIT")
    echo "scan-secrets: gitleaks matched credential material above. Rotate anything" >&2
    echo "  real before rewriting history — a value pushed to a public repository is" >&2
    echo "  compromised whether or not the commit survives." >&2
    exit 1
    ;;
  *) fail "gitleaks exited $status without reaching a verdict" ;;
esac
