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
- No particular device. Pose inference runs on the CPU through TensorFlow
  Lite with no Core ML or Metal delegate configured, so the simulator and
  any iOS 16 device run the same code path

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

   Both CI pipelines install this exact version through
   `ci_scripts/install-xcodegen.sh`, which is where the version and its
   archive checksum live — see [Dependency updates](#dependency-updates)
   for how it gets bumped
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
   without it, but nothing pose-related does: live pose on the camera and
   Processing's analysis both need it.
7. **Open `Turnip.xcworkspace`, not `Turnip.xcodeproj`.** CocoaPods requires the
   workspace; opening the bare project will fail to resolve `TensorFlowLiteSwift`.

`.xcodeproj`, `.xcworkspace`, and `Pods/` are generated, not committed — if you change
`project.yml` or the `Podfile`, rerun `xcodegen generate` / `pod install` respectively.

(An unofficial SPM wrapper for `TensorFlowLiteSwift` exists but repackages a third-party
prebuilt xcframework with no official support — worse provenance for a dependency running
an ML model in a public repo than Google's own CocoaPods podspec. We're sticking with
CocoaPods.)

## Dependency updates

Everything this project pins has a named updater, so no pin rots unnoticed:

| pin | where | updater |
| --- | --- | --- |
| GitHub Actions commit SHAs | `.github/workflows/` | Dependabot (`github-actions`, weekly) |
| CocoaPods and the gems it resolves | `Gemfile.lock` | Dependabot (`bundler`, weekly) |
| `TensorFlowLiteSwift` | `Podfile.lock` | `dependency-check.yml` (weekly) |
| XcodeGen and its archive checksum | `ci_scripts/install-xcodegen.sh` | `dependency-check.yml` (weekly) |
| SwiftLint and its archive checksum | `ci_scripts/install-swiftlint.sh` | `dependency-check.yml` (weekly) |
| gitleaks and its archive checksums | `ci_scripts/install-gitleaks.sh` | `dependency-check.yml` (weekly) |

Dependabot has no CocoaPods ecosystem, and no notion of a shell script that
downloads a release asset, so the last four are watched by
[`.github/workflows/dependency-check.yml`](.github/workflows/dependency-check.yml)
instead. It runs `ci_scripts/check-unwatched-pins.sh`, which compares the four pins
against the newest published release and opens a tracking issue when one has
moved — refreshing that issue's body on later runs, and closing it once all four
pins are current again. The same check runs locally:

```
ci_scripts/check-unwatched-pins.sh
```

Every bump arrives as an ordinary reviewable PR; nothing automerges.

### Bumping XcodeGen

`VERSION` and `SHA256` in `ci_scripts/install-xcodegen.sh` are the only copies
CI reads. Regenerate the checksum from the asset the new release publishes,
since the version in the URL pins a name and the checksum pins the bytes:

```
curl -fsSL -o /tmp/xcodegen.zip \
  https://github.com/yonaskolb/XcodeGen/releases/download/<version>/xcodegen.zip
shasum -a 256 /tmp/xcodegen.zip
```

The setup steps above pin the same version for local development; update those
too, and re-run `xcodegen generate` to confirm the emitted project still opens.

### Bumping SwiftLint

`VERSION` and `SHA256` in `ci_scripts/install-swiftlint.sh` are the only copies
CI reads. Regenerate the checksum from the asset the new release publishes,
since the version in the URL pins a name and the checksum pins the bytes:

```
curl -fsSL -o /tmp/swiftlint.zip \
  https://github.com/realm/SwiftLint/releases/download/<version>/portable_swiftlint.zip
shasum -a 256 /tmp/swiftlint.zip
```

`swiftlint lint --strict` is a hard merge gate, so install the new version
locally and confirm the repo still lints clean before pushing the bump.

### Bumping gitleaks

`VERSION` and both `SHA256_*` values in `ci_scripts/install-gitleaks.sh` are the
only copies CI reads. gitleaks publishes one archive per platform, so each
architecture has its own checksum and both belong to the same version:

```
for asset in darwin_arm64 darwin_x64; do
  curl -fsSL -o "/tmp/gitleaks_$asset.tar.gz" \
    "https://github.com/gitleaks/gitleaks/releases/download/v<version>/gitleaks_<version>_$asset.tar.gz"
  shasum -a 256 "/tmp/gitleaks_$asset.tar.gz"
done
```

A new version can recognise patterns the old one did not, so run
`ci_scripts/scan-secrets.sh` over the working tree with the new binary before
pushing the bump — a version that starts matching something already committed
turns every open pull request red at once, and that is worth finding on the
bump rather than on someone else's branch.

### Bumping TensorFlowLiteSwift

The `Podfile` allows `~> 2.17.0`, so anything past 2.17.x needs that constraint
widened before `bundle exec pod install` can re-resolve `Podfile.lock`. Both
files are committed; they change together.

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

The setting behind *CI must pass before merge* — a required `build-and-test`
check on `main` — is repository configuration rather than a file, as is the
private reporting route [`SECURITY.md`](SECURITY.md) offers alongside email,
and as are secret scanning and its push protection. None of them shows up in a
diff, so
[`ci_scripts/check-repo-settings.sh`](ci_scripts/check-repo-settings.sh)
reports on all four — weekly from
[`.github/workflows/repo-settings-check.yml`](.github/workflows/repo-settings-check.yml),
which opens a tracking issue while one is missing and closes it once they are
all in place. The scanning settings are readable only by a caller with admin
access; run with any other token the check says so rather than guessing. The
same check runs locally:

```
ci_scripts/check-repo-settings.sh
```

## Testing guidance

- New logic (clip detection, crop-rect math, pose-signal processing) should
  ship with unit tests (XCTest)
- UI changes should include a description of manual testing performed
  (device/simulator, iOS version) in the PR's test plan, since UI tests are
  not expected to cover everything

Run the test suite with:

```
UDID=$(ci_scripts/resolve-simulator.sh | tail -1)
xcodebuild test -workspace Turnip.xcworkspace -scheme Turnip \
  -destination "id=$UDID"
```

or Cmd+U in Xcode with the `Turnip` scheme selected.

`ci_scripts/resolve-simulator.sh` picks an available iPhone device from
the newest installed iOS runtime, and is the same script CI runs before
its own test step — so the destination is resolved by one rule instead of
a device name here that can drift from the one CI uses. Run outside CI it
prints the device it chose and then the UDID on its own line, hence the
`tail -1`.

## Lint

SwiftLint runs in CI on every PR (the `build-and-test` job's `Lint` step —
see `.github/workflows/ci.yml`) and as a step of Xcode Cloud's
`ci_scripts/ci_post_clone.sh`. It is a hard gate: both pipelines run
`swiftlint lint --strict`, so warnings fail the run too.

- **Pinned — the version lives in `ci_scripts/install-swiftlint.sh` only.**
  Both CI pipelines install SwiftLint from the versioned
  `portable_swiftlint.zip` release archive via that script (SHA-256-verified,
  no sudo — the same pattern as the XcodeGen pin). The script is the single
  source of truth for both the version and its checksum, so a future bump
  edits one file and the docs can't drift. Don't `brew install swiftlint`:
  Homebrew only bottles the latest formula, so the version you lint with
  locally would drift from what CI runs.
- **Config lives in `.swiftlint.yml`** at the repo root — the default rule set
  plus a few documented opt-outs (rules that fight SwiftUI views, and short
  geometry names like `x`/`y`/`dx`/`dy`). Each opt-out records why it exists;
  add a reason when you add one. When a rule is right for the codebase but
  wrong at one site, use a scoped `// swiftlint:disable`/`enable` pair with a
  reason instead of a config entry; when the rule is wrong for this codebase,
  disable it in `.swiftlint.yml`.
- **Run it locally** before pushing:

  ```
  ci_scripts/install-swiftlint.sh "$HOME/.local"
  export PATH="$HOME/.local/bin:$PATH"
  swiftlint lint --strict
  ```
## Code organization

`Turnip/` is a single Xcode target; its subdirectories are flat, one per
domain, named for the domain they own (`App`, `Camera`, `ClipEditor`,
`ClipList`, `DesignSystem`, `Home`, `LivePose`, `Media`, `ModelUpdates`,
`Models`, `Photos`, `Pose`, `Processing`, `Resources`,
`Settings`, `TrickDetection`).
`ci_scripts/check-directory-list.sh` compares that list against the tree on
every PR, so adding a directory without naming it here fails CI.

- A new screen or feature adds a new top-level directory. A directory named
  for a screen keeps only that screen's view, view model, and screen-private
  helpers.
- Shared pipeline infrastructure lives in its own domain directory — never
  under a feature screen's directory. The v1 pose pipeline's model types,
  the keypoint overlay and the per-frame pose logger live in `Turnip/Pose/`
  rather than under the screen that draws the overlay (`Turnip/Processing/`),
  so deleting or reworking a screen never strands load-bearing code.
  Likewise the live capture-side pose path lives in `Turnip/LivePose/`,
  not `Turnip/Camera/`: the camera screen drives it, but the frame gate,
  queue, thermal policy and coverage rule are pipeline code with their own
  tests, and only the preview overlay's drawing sits with the camera.
- `project.yml` takes `Turnip/` (and `TurnipTests/`) wholesale, so a
  subdirectory rename is picked up by `xcodegen generate` with no
  `project.yml` change.

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

### Credentials

This repository is public, so a credential committed to it is compromised the
moment it is pushed — rewriting the history afterwards does not un-publish it.
Two things guard against that, and neither replaces reading your own diff:

- `ci_scripts/scan-secrets.sh` runs in CI on every pull request over the
  commits the branch adds, so a credential added and then deleted before review
  is still caught. Run it locally the same way CI does:

  ```
  ci_scripts/install-gitleaks.sh "$HOME/.local"
  PATH="$HOME/.local/bin:$PATH" ci_scripts/scan-secrets.sh origin/main
  ```

- `.gitignore` covers the code-signing and API credential material an iOS
  project accumulates — `*.p12`, `*.mobileprovision`, `AuthKey_*.p8`,
  `ExportOptions.plist`, `.env` and their siblings — so `git add -A` does not
  stage one by accident.

If a credential does reach a branch, treat it as leaked: rotate it first, and
only then worry about the history.
