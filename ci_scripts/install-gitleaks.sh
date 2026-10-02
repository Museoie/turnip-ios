#!/bin/sh
set -eu

# Usage: ci_scripts/install-gitleaks.sh <prefix>
#
# Installs gitleaks into <prefix>/bin. Callers put <prefix>/bin on their own
# PATH — a child process cannot do it for them.
# .github/workflows/ci.yml calls this; the version and its checksums have
# exactly one home so they cannot drift apart.

VERSION="8.30.1"
# `shasum -a 256` of each release asset. A GitHub release asset is mutable, so
# the version in the URL pins a name; these pin the bytes that get executed.
# Both macOS architectures are listed because CI runs on Apple silicon and a
# contributor reproducing the scan locally may not.
SHA256_ARM64="b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5"
SHA256_X64="dfe101a4db2255fc85120ac7f3d25e4342c3c20cf749f2c20a18081af1952709"

prefix="${1:-}"
if [ -z "$prefix" ]; then
  echo "usage: $0 <prefix>" >&2
  exit 2
fi

case "$(uname -s)/$(uname -m)" in
  Darwin/arm64)  asset="darwin_arm64"; sha256="$SHA256_ARM64" ;;
  Darwin/x86_64) asset="darwin_x64";   sha256="$SHA256_X64" ;;
  *)
    echo "$0: no pinned gitleaks asset for $(uname -s)/$(uname -m)" >&2
    exit 2
    ;;
esac

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

# --fail so an HTTP error page is not silently untarred as if it were the
# archive; --show-error so the reason reaches the build log.
curl --fail --silent --show-error --location \
  -o "$workdir/gitleaks.tar.gz" \
  "https://github.com/gitleaks/gitleaks/releases/download/v${VERSION}/gitleaks_${VERSION}_${asset}.tar.gz"

echo "${sha256}  ${workdir}/gitleaks.tar.gz" | shasum -a 256 -c -

# The archive holds the binary at its root alongside LICENSE and README.
mkdir -p "$workdir/pkg" "$prefix/bin"
tar -xzf "$workdir/gitleaks.tar.gz" -C "$workdir/pkg" gitleaks
cp "$workdir/pkg/gitleaks" "$prefix/bin/gitleaks"
chmod +x "$prefix/bin/gitleaks"
