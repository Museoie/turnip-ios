#!/bin/sh
set -eu

# Usage: ci_scripts/install-xcodegen.sh <prefix>
#
# Installs XcodeGen into <prefix>/bin and <prefix>/share. Callers put
# <prefix>/bin on their own PATH — a child process cannot do it for them.
# .github/workflows/ci.yml and ci_scripts/ci_post_clone.sh both call this, so
# the version and its checksum have exactly one home and cannot drift apart.

VERSION="2.46.0"
# `shasum -a 256` of the release asset. A GitHub release asset is mutable, so
# the version in the URL pins a name; this pins the bytes that get executed.
SHA256="4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806"

prefix="${1:-}"
if [ -z "$prefix" ]; then
  echo "usage: $0 <prefix>" >&2
  exit 2
fi

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

# --fail so an HTTP error page is not silently unzipped as if it were the
# archive; --show-error so the reason reaches the build log.
curl --fail --silent --show-error --location \
  -o "$workdir/xcodegen.zip" \
  "https://github.com/yonaskolb/XcodeGen/releases/download/${VERSION}/xcodegen.zip"

echo "${SHA256}  ${workdir}/xcodegen.zip" | shasum -a 256 -c -

unzip -q "$workdir/xcodegen.zip" -d "$workdir/pkg"

# install.sh's `cp -r` misplaces files when the destination does not already
# exist as a directory.
mkdir -p "$prefix"
"$workdir/pkg/xcodegen/install.sh" "$prefix"
