#!/bin/sh
set -eu

# Usage: sh ci_scripts/resolve-simulator.sh
#
# Picks the UDID of the first available iOS simulator device and writes it to
# the CI environment, so the workflow never hardcodes a device name.
#
# Naming a concrete device (`-destination "name=iPhone 17"`) silently pins
# the CI config to the runner image's current default: it fails on a runner
# whose simulator runtime is missing or not yet registered, and it will
# start failing on *every* runner the day the image ships a newer default
# device. Resolving at run time removes both.
#
# Prints the chosen device to the log, and exits with a message naming the
# runner image when none is available — an infrastructure failure should not
# read as a code failure fifteen lines deep in the log.
#
# Called by .github/workflows/ci.yml before the Test step. The Build step
# uses the generic simulator destination instead, since building needs no
# device at all.

# `|| json='{}'`: if simctl itself errors out (sick runner, daemon hiccup),
# `set -e` would abort here and the runner-image message below would never
# print — the one infrastructure failure this script's header promises to
# label. An empty devices object trips the explicit no-device path instead.
json=$(xcrun simctl list devices available --json) || json='{}'

# `|| true`: a python exit of 1 means "no device found", which the explicit
# check below reports. Without it, `set -e` would abort the script here and
# the loud infrastructure-failure message would never print.
udid=$(printf '%s' "$json" | python3 -c '
import json, sys

data = json.loads(sys.stdin.read())
devices = data.get("devices", {})
runtimes = sorted(
    (r for r in devices if r.startswith("com.apple.CoreSimulator.SimRuntime.iOS-")),
    reverse=True,
)
for runtime in runtimes:
    for device in devices[runtime]:
        if device.get("isAvailable"):
            print(device["udid"])
            raise SystemExit(0)
raise SystemExit(1)
' || true)

if [ -z "$udid" ]; then
  echo "::error::No available iOS simulator device on this runner." >&2
  echo "This is a runner-image problem (missing or unregistered simulator" >&2
  echo "runtime), not a code failure. Runner: ${RUNNER_NAME:-unknown}," >&2
  echo "image: ${ImageOS:-unknown}. Re-running on a healthy runner is the" >&2
  echo "expected fix; see xcrun simctl list devices above for the full list." >&2
  exit 1
fi

name=$(printf '%s' "$json" | python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
for runtime in data.get('devices', {}).values():
    for device in runtime:
        if device.get('udid') == '$udid':
            print(device.get('name', '?'))
            raise SystemExit(0)
")

echo "Resolved simulator device: $name ($udid)"

# $GITHUB_ENV is set when running as a workflow step; the fallback covers
# local invocation, where the caller reads the UDID from stdout instead.
if [ -n "${GITHUB_ENV:-}" ]; then
  echo "SIMULATOR_UDID=$udid" >> "$GITHUB_ENV"
else
  echo "$udid"
fi
