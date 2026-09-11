#!/bin/sh
set -eu

# Usage: ci_scripts/install-swiftlint.sh <prefix>
#
# Installs SwiftLint into <prefix>/bin. Callers put <prefix>/bin on their own
# PATH — a child process cannot do it for them.
# .github/workflows/ci.yml and ci_scripts/ci_post_clone.sh both call this, so
# the version and its checksum have exactly one home and cannot drift apart.

VERSION="0.65.1"
# `shasum -a 256` of the release asset. A GitHub release asset is mutable, so
# the version in the URL pins a name; this pins the bytes that get executed.
SHA256="c1e429b0599cf1b516f369a2d9ec04eaf0e436f3c12b637df8851fa52ff694d0"

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
  -o "$workdir/swiftlint.zip" \
  "https://github.com/realm/SwiftLint/releases/download/${VERSION}/portable_swiftlint.zip"

echo "${SHA256}  ${workdir}/swiftlint.zip" | shasum -a 256 -c -

# The portable archive holds the universal macOS binary at its root — no
# installer, no sudo, which is what Xcode Cloud's build environment requires.
unzip -q "$workdir/swiftlint.zip" -d "$workdir/pkg"
mkdir -p "$prefix/bin"
cp "$workdir/pkg/swiftlint" "$prefix/bin/swiftlint"
chmod +x "$prefix/bin/swiftlint"
