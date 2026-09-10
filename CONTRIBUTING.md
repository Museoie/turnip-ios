# Contributing to Turnip

Thanks for your interest in contributing. This repo is early — see the
[README](README.md) for current status and [`docs/DESIGN.md`](docs/DESIGN.md)
for the full architecture plan, including the "Contribution ramp" section
that names areas most open to new contributors.

## Development environment

- **Xcode 26.3** — the version both CI pipelines build and test against,
  and the only one verified. Xcode 15 is the nominal minimum, but nothing
  checks it: XcodeGen's emitted project format tracks its own release
  rather than the selected Xcode, so an older Xcode may fail to open the
  generated project. If that happens on a version at or above 15, it's
  worth an issue
- **iOS 16** minimum deployment target
- An A11 Bionic device or later (iPhone 8/X+) if you want to test Neural
  Engine acceleration; the simulator works for everything else

The project uses [XcodeGen](https://github.com/yonaskolb/XcodeGen) to
generate the `.xcodeproj` from `project.yml` (kept as plain, diffable YAML
instead of a merge-conflict-prone `.pbxproj`) and
[CocoaPods](https://cocoapods.org) for `TensorFlowLiteSwift`, which has no
official Swift Package Manager distribution. Setup, in order:

1. **Accept the Xcode license** if you haven't already — `sudo xcodebuild -license`.
   This is interactive and requires sudo, so it can't be scripted; do it once, manually,
   before anything else in this list will work.
2. Install [Homebrew](https://brew.sh) if you don't have it.
3. Install [XcodeGen](https://github.com/yonaskolb/XcodeGen) **2.46.0** — the
   exact version both CI pipelines pin. `brew install xcodegen` floats to
   whatever Homebrew has bottled, and since the `.xcodeproj` is generated
   rather than committed, a mismatched XcodeGen is the difference between the
   project opening and not:

   ```
   curl -fsSL -o /tmp/xcodegen.zip \
     https://github.com/yonaskolb/XcodeGen/releases/download/2.46.0/xcodegen.zip
   unzip -q /tmp/xcodegen.zip -d /tmp/xcodegen-pkg
   mkdir -p "$HOME/.local"
   /tmp/xcodegen-pkg/xcodegen/install.sh "$HOME/.local"
   rm -rf /tmp/xcodegen.zip /tmp/xcodegen-pkg
   ```

   The `mkdir` is load-bearing. XcodeGen's `install.sh` copies with a bare
   `cp -r` and never creates the prefix, so when `~/.local` doesn't already
   exist the first copy *becomes* it and the setting presets land in
   `~/.local/xcodegen` instead of `~/.local/share/xcodegen`. `xcodegen
   generate` then still exits 0, printing only `No "base" settings found`,
   and emits a project missing ~58 build settings — including
   `BUNDLE_LOADER`, without which the test target won't link.

   Put `$HOME/.local/bin` on your `PATH`, then verify both halves landed —
   the version alone doesn't tell you the presets are in the right place:

   ```
   xcodegen --version               # 2.46.0
   ls "$HOME/.local/share/xcodegen" # SettingPresets
   ```

   This version is also pinned in `.github/workflows/ci.yml` and
   `ci_scripts/ci_post_clone.sh`; the three are meant to stay identical
4. `xcodegen generate`
5. `bundle install && bundle exec pod install` — CocoaPods is pinned via the committed
   `Gemfile`/`Gemfile.lock` (both CI pipelines resolve pods the same way) rather than
   whatever `brew install cocoapods` happens to be current; a bare `pod install` uses
   your system CocoaPods and can rewrite `Podfile.lock` to a different version. If
   `bundle install` fails with `Unicode Normalization not appropriate for ASCII-8BIT`,
   your shell has no UTF-8 locale set; run `LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 bundle install`
   instead (known CocoaPods/Ruby issue, unrelated to this project)
6. Download the MoveNet Thunder model per
   [`Turnip/Models/README.md`](Turnip/Models/README.md) — the app builds and runs
   without it, but the pose diagnostic screen needs it to do anything.
7. **Open `Turnip.xcworkspace`, not `Turnip.xcodeproj`.** CocoaPods requires the
   workspace; opening the bare project will fail to resolve `TensorFlowLiteSwift`.

`.xcodeproj`, `.xcworkspace`, and `Pods/` are generated, not committed — if you change
`project.yml` or the `Podfile`, rerun `xcodegen generate` / `pod install` respectively.

(An unofficial SPM wrapper for `TensorFlowLiteSwift` exists but repackages a third-party
prebuilt xcframework with no official support — worse provenance for a dependency running
an ML model in a public repo than Google's own CocoaPods podspec. We're sticking with
CocoaPods.)

## Branching workflow

1. Fork the repo
2. Branch from `main` (`git checkout -b your-feature-name`)
3. Make your changes, with focused commits
4. Open a PR against `hoiekim/turnip-ios` `main`

## Pull request conventions

- Fill out the PR template — summary, screenshots (for UI changes), test
  plan, and linked issues
- Keep PRs scoped to one change. Large, unrelated changes bundled together
  are harder to review and slower to merge
- Reference the issue a PR closes with `Closes #N` in the description
- Squash-friendly commit history is appreciated but not required

## Review process

- At least one reviewer approval is required before merge
- CI must pass before merge — describe how you tested your change in the
  PR's test plan regardless, since CI doesn't cover UI/manual testing
- Be responsive to review feedback — if a thread goes quiet, a ping is fine

## Testing guidance

- New logic (clip detection, crop-rect math, pose-signal processing) should
  ship with unit tests (XCTest)
- UI changes should include a description of manual testing performed
  (device/simulator, iOS version) in the PR's test plan, since UI tests are
  not expected to cover everything

Run the test suite with:

```
xcodebuild test -workspace Turnip.xcworkspace -scheme Turnip \
  -destination 'platform=iOS Simulator,name=iPhone 15'
```

or Cmd+U in Xcode with the `Turnip` scheme selected.

## Lint

SwiftLint runs in CI on every PR (`lint + build + test` — see
`.github/workflows/ci.yml`) and as a step of Xcode Cloud's
`ci_scripts/ci_post_clone.sh`. It is a hard gate: both pipelines run
`swiftlint lint --strict`, so warnings fail the run too.

- **Pinned to 0.65.1.** Both CI pipelines install it from the versioned
  `portable_swiftlint.zip` release archive via
  `ci_scripts/install-swiftlint.sh` (SHA-256-verified, no sudo — the same
  pattern as the XcodeGen pin). Don't `brew install swiftlint`: Homebrew only
  bottles the latest formula, so the version you lint with locally would drift
  from what CI runs.
- **Config lives in `.swiftlint.yml`** at the repo root — the default rule set
  plus a few documented opt-outs (rules that fight SwiftUI views, and short
  geometry names like `x`/`y`/`dx`/`dy`). Each opt-out records why it exists;
  add a reason when you add one.
- **Run it locally** before pushing:

  ```
  sh ci_scripts/install-swiftlint.sh "$HOME/.local"
  export PATH="$HOME/.local/bin:$PATH"
  swiftlint lint --strict
  ```

## Areas of contribution

From the design doc's "Contribution ramp":

- **iOS**: Swift/SwiftUI, AVFoundation, Vision framework, TFLite iOS
- **Backend** (`turnip-farm`, separate repo): TypeScript, Bun, Postgres, Docker
- **ML** (`turnip-ml`, separate repo): Python, TensorFlow, coremltools, model evaluation

Good first issues are tagged as they're identified.

## Contributor License Agreement (CLA)

**No CLA is required.** Turnip is licensed under [Apache 2.0](LICENSE), and
Section 5 of that license already grants the project the necessary rights
to your contributions. This matches the design doc's recommendation
(`docs/DESIGN.md`, "Contribution guide surface"). By submitting a PR, you
agree your contribution is made under the terms of the Apache 2.0 license.

## Code of Conduct

This project follows the [Code of Conduct](CODE_OF_CONDUCT.md). By
participating, you're expected to uphold it.

## Reporting bugs and requesting features

Use the issue templates under `.github/ISSUE_TEMPLATE/` — separate ones
exist for bug reports and feature requests.

## Security issues

Do not open a public issue for security vulnerabilities. See
[SECURITY.md](SECURITY.md) for the responsible disclosure process.
