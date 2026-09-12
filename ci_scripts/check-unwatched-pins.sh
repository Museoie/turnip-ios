#!/bin/sh
set -eu

# Usage: ci_scripts/check-unwatched-pins.sh
#
# Reports whether the dependency pins that no package-manager updater covers —
# XcodeGen in install-xcodegen.sh, TensorFlowLiteSwift in Podfile.lock — are
# still the newest published release. Writes a markdown report to stdout.
#
# Exit codes: 0 every pin is current, 1 at least one pin has moved, 2 the check
# itself could not run. A caller must distinguish 1 from 2; exit 1 is a result,
# not a failure.

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

fail() {
  echo "check-unwatched-pins: $*" >&2
  exit 2
}

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

pinned_xcodegen=$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$repo_root/ci_scripts/install-xcodegen.sh")
[ -n "$pinned_xcodegen" ] ||
  fail "no VERSION= assignment in ci_scripts/install-xcodegen.sh"

pinned_tflite=$(sed -n 's/^  - TensorFlowLiteSwift (\([0-9][^)]*\)):.*/\1/p' "$repo_root/Podfile.lock" | head -1)
[ -n "$pinned_tflite" ] ||
  fail "no TensorFlowLiteSwift entry in Podfile.lock"

curl --fail --silent --show-error --location \
  -H 'Accept: application/vnd.github+json' \
  -o "$workdir/xcodegen.json" \
  https://api.github.com/repos/yonaskolb/XcodeGen/releases/latest ||
  fail "could not reach the XcodeGen releases API"
latest_xcodegen=$(jq -r '.tag_name // ""' "$workdir/xcodegen.json")
[ -n "$latest_xcodegen" ] || fail "the XcodeGen releases API returned no tag_name"

curl --fail --silent --show-error --location \
  -o "$workdir/tflite.json" \
  https://trunk.cocoapods.org/api/v1/pods/TensorFlowLiteSwift ||
  fail "could not reach the CocoaPods trunk API"
# trunk lists nightlies and prereleases alongside releases, ordered by
# publication rather than by version.
latest_tflite=$(jq -r '
  [ .versions[].name
    | select(test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))
    | { name: ., order: (split(".") | map(tonumber)) }
  ]
  | sort_by(.order)
  | map(.name)
  | last // ""
' "$workdir/tflite.json")
[ -n "$latest_tflite" ] || fail "the CocoaPods trunk API returned no release versions"

drifted=0

report_pin() {
  name="$1"
  pinned="$2"
  latest="$3"
  where="$4"
  if [ "$pinned" = "$latest" ]; then
    echo "- **$name** — \`$pinned\` in \`$where\` is the newest release."
  else
    drifted=1
    echo "- **$name** — \`$where\` pins \`$pinned\`; \`$latest\` is published."
  fi
}

echo "XcodeGen has no package manager and CocoaPods is not a Dependabot"
echo "ecosystem, so these two pins are compared against the newest published"
echo "release on a schedule instead of by an updater."
echo
report_pin XcodeGen "$pinned_xcodegen" "$latest_xcodegen" ci_scripts/install-xcodegen.sh
report_pin TensorFlowLiteSwift "$pinned_tflite" "$latest_tflite" Podfile.lock
echo
echo "Bump steps for each are in the *Dependency updates* section of \`CONTRIBUTING.md\`."

exit "$drifted"
