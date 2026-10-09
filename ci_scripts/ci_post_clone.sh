#!/bin/zsh
set -euo pipefail

# Xcode Cloud clones the bare repo; Turnip.xcodeproj / Turnip.xcworkspace / Pods/
# are gitignored generated artifacts (see CONTRIBUTING.md), so they must be
# recreated here before Xcode Cloud looks for the workspace.

export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

# Skip brew's formula-index sync (the slow part of `brew install` on CI);
# only install what isn't already on the Xcode Cloud image.
export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_INSTALL_CLEANUP=1

cd "$CI_PRIMARY_REPOSITORY_PATH"

step() {
  local label="$1"; shift
  local start=$SECONDS
  "$@"
  echo "[ci_post_clone] $label took $((SECONDS - start))s"
}

# Runs a command up to N times with a growing pause between attempts. For steps
# whose only failure mode worth surviving is the network: a real error still
# fails the build once the attempts run out, just later.
retry() {
  local attempts="$1"; shift
  local attempt=1
  until "$@"; do
    if (( attempt >= attempts )); then
      echo "[ci_post_clone] '$*' failed on attempt $attempt of $attempts; giving up"
      return 1
    fi
    echo "[ci_post_clone] '$*' failed on attempt $attempt of $attempts; retrying in $((attempt * 15))s"
    sleep $((attempt * 15))
    attempt=$((attempt + 1))
  done
}

# Shared with GitHub Actions CI (see .github/workflows/ci.yml) so the two
# pipelines can't silently drift — Homebrew only bottles the latest formula,
# so `brew install xcodegen`/`cocoapods` here would float independently.
# Unconditional, matching ci.yml: Xcode Cloud provisions a fresh VM per
# build, so there's nothing to skip.
#
# Installed to a user-writable prefix, not /usr/local: Xcode Cloud's build
# environment has no passwordless sudo, so a `sudo ./install.sh` here just
# hangs on a password prompt that can never be answered.
install_xcodegen() {
  local prefix="$HOME/.local"
  ./ci_scripts/install-xcodegen.sh "$prefix"
  export PATH="$prefix/bin:$PATH"
}

# Pinned the same way as XcodeGen (see .github/workflows/ci.yml): a floating
# `brew install swiftlint` would let Xcode Cloud's formula index drift away
# from what Actions runs.
install_swiftlint() {
  local prefix="$HOME/.local"
  ./ci_scripts/install-swiftlint.sh "$prefix"
  export PATH="$prefix/bin:$PATH"
}

# Xcode Cloud's image only ships macOS's system Ruby 2.6 (/usr/bin/bundle),
# which Apple has deprecated and which can't run Gemfile.lock: the lockfile
# was resolved on a modern Ruby, so its BUNDLED WITH Bundler 4.x and gems
# like activesupport 7.2 need Ruby >= 3.2. System `bundle` fails with
# "Could not find 'bundler' (4.0.16) required by your Gemfile.lock".
# Install Homebrew's Ruby and put it ahead of /usr/bin on PATH. GitHub
# Actions' runner image already ships a modern Ruby, so ci.yml needs no
# equivalent step.
install_ruby() {
  brew install ruby
  export PATH="$(brew --prefix ruby)/bin:$PATH"
  # RubyGems auto-installs the locked Bundler on modern Rubies, but do it
  # explicitly so a mismatch fails here, loudly, rather than mid-`bundle`.
  local bundler_version
  bundler_version=$(awk '/^BUNDLED WITH/ { getline; print $1 }' Gemfile.lock)
  gem install --no-document bundler -v "$bundler_version"
  echo "[ci_post_clone] using $(ruby --version), bundler $(bundle --version)"
}

# Xcode Cloud clones the bare repo and movenet_thunder_int8.tflite is
# gitignored (see Turnip/Models/README.md), so without this step the archived
# app ships with no model and "Run diagnostic" fails on TestFlight with
# "MoveNet Thunder model not found" (issue #123). DESIGN.md's bundle-vs-OTA
# decision says the model ships inside the app bundle, so a file that fails to
# download or verify must fail the build here, loudly — never ship a TestFlight
# build that can't run pose inference.
#
# The SHA-256 is recorded in Turnip/Models/README.md and pins the exact bytes
# the app loads: TFHub serves the raw .tflite behind a redirect, curl follows
# it, and shasum verifies what actually landed on disk. Keep the URL and the
# checksum in sync with the README — they are the same file.
download_model() {
  local target="Turnip/Models/movenet_thunder_int8.tflite"
  local sha256="b72fed22707cd6fb94b5a248b9bddb9c062b9f445471b4fa263407cf6d222011"
  if [ -f "$target" ] \
    && echo "${sha256}  ${target}" | shasum -a 256 --check --status -; then
    echo "[ci_post_clone] model already present and checksum-verified, skipping download"
    return 0
  fi
  local workdir
  workdir="$(mktemp -d)"
  # --fail so an HTTP error page is never written to disk as if it were the
  # model; --retry for transient network failures on the CI VM. The shasum
  # check fails the build under `set -euo pipefail` rather than letting a
  # wrong or truncated file through.
  curl --fail --silent --show-error --location --retry 3 --retry-all-errors \
    --output "$workdir/movenet_thunder_int8.tflite" \
    "https://tfhub.dev/google/lite-model/movenet/singlepose/thunder/tflite/int8/4?lite-format=tflite"
  echo "${sha256}  ${workdir}/movenet_thunder_int8.tflite" | shasum -a 256 --check -
  mv "$workdir/movenet_thunder_int8.tflite" "$target"
  rmdir "$workdir"
}

step "install swiftlint" install_swiftlint
# --strict matches ci.yml: warnings fail the run here too, so Xcode Cloud and
# Actions agree on the gate. Lint needs no generated project, so it runs first.
step "swiftlint lint --strict" swiftlint lint --strict
step "download movenet model" download_model
step "install xcodegen" install_xcodegen
step "xcodegen generate" xcodegen generate
step "install ruby (homebrew)" install_ruby
step "bundle install (cocoapods 1.17.0)" bundle install
# CocoaPods' CDN source fetches every candidate podspec for a dependency with
# its own request to raw.githubusercontent.com, and one timeout among them fails
# the whole install ("CDN: trunk Repo update failed - N error(s) ... Timeout was
# reached"). The Xcode Cloud VM hits that intermittently; pod install is
# idempotent, so a retry is safe.
step "pod install" retry 3 bundle exec pod install
