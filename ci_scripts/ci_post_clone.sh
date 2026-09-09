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

step "install xcodegen" install_xcodegen
step "xcodegen generate" xcodegen generate
step "install ruby (homebrew)" install_ruby
step "bundle install (cocoapods 1.17.0)" bundle install
step "pod install" bundle exec pod install
