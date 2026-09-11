#!/bin/sh
set -eu

# Usage: ci_scripts/resolve-simulator.sh
#
# Picks the UDID of the first available iOS simulator device and writes it to
# the CI environment, so the workflow never hardcodes a device name.
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
resolved=$(printf '%s' "$json" | python3 -c '
import json, sys

data = json.loads(sys.stdin.read())
devices = data.get("devices", {})

# Version-tuple ordering, not lexicographic: "iOS-9-0" sorts above "iOS-18-4"
# as a plain string ("9" > "1"), so sorting the raw keys could pick the wrong
# newest runtime. Parse the numeric components out of
# com.apple.CoreSimulator.SimRuntime.iOS-<major>-<minor> instead.
def runtime_version(runtime):
    version = runtime.rsplit("iOS-", 1)[1]
    return tuple(map(int, version.split("-")))

runtimes = sorted(
    (r for r in devices if r.startswith("com.apple.CoreSimulator.SimRuntime.iOS-")),
    key=runtime_version,
    reverse=True,
)
for runtime in runtimes:
    for device in devices[runtime]:
        # The app targets iPhone only (project.yml pins TARGETED_DEVICE_FAMILY
        # to iPhone), so skip the iPad entries simctl lists alongside them.
        if device.get("isAvailable") and "iPhone" in device.get("deviceTypeIdentifier", ""):
            print(device["udid"])
            print(device.get("name", "?"))
            raise SystemExit(0)
raise SystemExit(1)
' || true)

udid=$(printf '%s\n' "$resolved" | sed -n '1p')
name=$(printf '%s\n' "$resolved" | sed -n '2p')

if [ -z "$udid" ]; then
  echo "::error::No available iOS simulator device on this runner." >&2
  echo "This is a runner-image problem (missing or unregistered simulator" >&2
  echo "runtime), not a code failure. Runner: ${RUNNER_NAME:-unknown}," >&2
  echo "image: ${ImageOS:-unknown}. Re-running on a healthy runner is the" >&2
  echo "expected fix; the full device list follows for diagnosis." >&2
  xcrun simctl list devices available || true
  exit 1
fi

echo "Resolved simulator device: $name ($udid)"

# $GITHUB_ENV is set when running as a workflow step; the fallback covers
# local invocation, where the caller reads the UDID from stdout instead.
if [ -n "${GITHUB_ENV:-}" ]; then
  echo "SIMULATOR_UDID=$udid" >> "$GITHUB_ENV"
else
  echo "$udid"
fi
