# Turnip privacy compliance notes

The single home for the answers App Store Connect asks for at submission
time, so nobody has to reverse-engineer them later. v1 is the fully
on-device release; anything that changes with v2 (upload, accounts) is
marked as such below.

The plain-language version users and reviewers see is
[`site/privacy.html`](../site/privacy.html), published at
<https://hoiekim.github.io/turnip-ios/privacy.html> and used as the
Privacy Policy URL in App Store Connect. This doc is the technical source
it's summarized from — keep both in sync when data handling changes.

## App Store "nutrition label" answers (v1)

**Data Not Collected.** The v1 app collects no data, full stop:

- No accounts, no sign-in, no identifiers.
- No analytics. No third-party crash-reporting SDK; crash/hang metrics arrive
  Apple-mediated (Xcode Organizer + MetricKit) under the user's own "Share With App
  Developers" opt-in — not declarable as collected data. See `docs/DESIGN.md`
  decision #7.
- No calls to any Turnip-controlled server in the v1 path. A `URLSession` client
  for OTA model updates does exist — `Turnip/ModelUpdates/ModelUpdateClient.swift`,
  the only networking code in `Turnip/` — and it is inert: it refuses any scheme
  but `https`, it takes its endpoint as a parameter rather than holding one, and
  `ModelUpdateService.checkForUpdates` returns on a `nil` base URL before it
  reaches the client. No app code constructs either type, so nothing supplies
  that URL; the service's only callers are unit tests against a mock, and the
  client's own test exercises the `https` guard without issuing a request.
  Bytes do cross the network when PhotoKit downloads an iCloud-only video
  (`isNetworkAccessAllowed` in `PhotoVideoResolver`/`ThumbnailLoader`) — from
  the user's own iCloud, through a system framework. Videos are read from the
  Photos library the user grants access to, processed on-device by the bundled
  MoveNet model, and exported clips are written back to Photos. While the
  in-app camera records, the same model scores the live camera frames
  on-device to draw the skeleton and detect clips; the frames are reduced to
  model input in memory and released immediately, nothing but the recording
  itself is written, and the only trace left behind is per-recording timing
  and count figures in the device's own log. The in-app camera also reads
  the phone's gravity vector from Core Motion while it records and writes
  the resulting roll angle into the recording as a metadata track
  (`Turnip/Media/RollTrack.swift`), so the editor can level the clip
  without guessing from the picture; this is the device-motion API, which
  needs no `NSMotionUsageDescription` and raises no prompt (unlike the
  pedometer and activity APIs), and the angles live only inside the user's
  own video file in their Photos library. If the user
  trashes the original video's tile in Clip List, the original is deleted
  from Photos too — a user-initiated, on-device change to their own library,
  not data leaving the device.
- Nothing is uploaded, shared, or transmitted to any Turnip-controlled server.

## Privacy manifest (`Turnip/Resources/PrivacyInfo.xcprivacy`)

Declares: no tracking (`NSPrivacyTracking` false, no tracking domains),
no collected data types, and three required-reason API categories —
`NSPrivacyAccessedAPICategoryFileTimestamp` with approved reason `C617.1`
(the orphan sweep in `PhotoVideoResolver` reads `.creationDateKey` on files
inside the app's own `tmp/` container),
`NSPrivacyAccessedAPICategorySystemBootTime` with approved reason `35F9.1`
(elapsed time between in-app progress reports, measured via `systemUptime`),
and `NSPrivacyAccessedAPICategoryUserDefaults` with approved reason `CA92.1`
(`TurnipSettingsStore` persists the settings screen's four keys, readable only
by the app itself). See the audit table below.

Required-reason API audit. `ci_scripts/check-privacy-manifest.sh` enforces it
on every pull request: it matches a table of API spellings — which lives in
the script, since the categories and evidence below are not themselves
greppable — against everything under `Turnip/`, and fails when a hit has no
matching `NSPrivacyAccessedAPIType` in the manifest. So a `No` row whose
category is undeclared is a claim CI re-checks: a call site landing behind it
fails the build. The other direction is a note rather than a failure — a
declared category nothing references is reported without failing, because
Apple rejects undeclared usage, not an unused declaration.

| API category | Used? | Evidence |
|---|---|---|
| UserDefaults | Yes — CA92.1 | `TurnipSettingsStore` reads four keys in `init` and writes through to `UserDefaults` on every published change; `TurnipSettingsStore.shared` takes the `.standard` suite. All four keys are app-local — no app group, no shared suite outside the screenshot and preview harnesses — which is what CA92.1 approves. |
| File timestamps | Yes — C617.1 | `PhotoVideoResolver.deleteOrphanedTemporaryExports` reads `.creationDateKey` via `resourceValues(forKeys:)` on files in the app's own `tmp/` container — in-container metadata reads, declared with approved reason C617.1. (`PHAsset.creationDate` is PhotoKit metadata on user-granted assets, not a file-timestamp API.) |
| System boot time | Yes — 35F9.1 | `ProgressReportClock.shouldReport` (in `ProcessingPipeline.swift`) defaults its clock to `ProcessInfo.processInfo.systemUptime` to measure elapsed time between in-app progress reports; `LivePoseRecording` and `LivePoseFrameTap` read the same clock for inference timing and thermal accounting. All in-app elapsed-time measurement — declared with approved reason 35F9.1. |
| Disk space | No | No volume-capacity resource keys and no `statfs` family call sites. |
| Active keyboards | No | The category covers querying `UITextInputMode.activeInputModes`, which nothing does. `SettingsView` has one `TextField` for the album name; presenting a keyboard is not the declarable access. |

Third-party SDKs: the only dependency is `TensorFlowLiteSwift`
(`Podfile.lock` resolves its `Privacy` subspec, which carries the pod's
own `PrivacyInfo.xcprivacy`), and it is not on Apple's list of SDKs that
require a manifest/signature. If a dependency is added, check both.

## Photos access

- Home requests `.readWrite` for the gallery. PhotoKit offers no
  read-only level — the choices are add-only (can't enumerate the
  library) or read/write — and exporting clips back to Photos needs the
  write half anyway, so one honest prompt covers both. The write half is
  also what lets Clip List delete the original video (`PhotoAssetDeleter`,
  `PHAssetChangeRequest.deleteAssets`) when the user trashes its tile and
  taps Save Clips — PhotoKit shows its own "Allow Turnip to delete?" system
  confirmation before the deletion happens, on top of the one-time
  read/write grant.
- `NSPhotoLibraryUsageDescription` explains the read side in plain
  language. `NSPhotoLibraryAddUsageDescription` ships alongside it
  because the clip-save path — reachable from Home through Processing and
  the clip list — calls `requestAuthorization(for: .addOnly)`, and iOS
  terminates the app on that call when the string is absent. A user does
  not normally see the string: reaching a save means the read/write
  grant from Home is already in place, which determines add-only as
  authorized, so the call returns without presenting a second prompt.
- `PHPhotoLibraryPreventAutomaticLimitedAccessAlert` is set: with
  limited access the app shows its own "select more" affordance instead
  of iOS re-prompting on its own schedule.

## Temp-file and cache hygiene

- **Composition exports.** Slow-motion/edited videos come back from
  PhotoKit as compositions with no file URL, so `PhotoVideoResolver`
  exports them to `tmp/` (`turnip-composition-export-<uuid>.mov`).
  The owning screen (`VideoLibraryViewModel`, which owns the navigation `path`)
  deletes the export when its `SelectedVideo` leaves the path (back-out or a new
  selection) and also when a resolution is cancelled after the export finished
  but before the push — so browse-and-back-out, the dominant interaction,
  never accumulates files. `TurnipApp` sweeps orphans left by crashed sessions
  at launch. The prefix is what makes both the delete and the sweep recognize
  only our files.
- **Clip exports.** Tapping "Save Clips" in Clip List (`ClipListViewModel.save()`)
  stages every non-trashed derived clip in a fresh `tmp/turnip-export-<uuid>/`
  scratch directory, hands each one to Photos through `ClipPhotosSaver`
  (add-only), and deletes the whole directory once the run ends — success or
  failure, since there is no Share action here to keep a file alive for. A
  `save()` call killed mid-run is swept by the next one
  (`sweepStaleExportDirectories`); the `turnip-export-` prefix is what makes
  the sweep recognize only our directories.
- **Thumbnails** are in-memory only (`PHCachingImageManager`), in both
  the Home grid and the clip-list work — there is no on-disk thumbnail
  cache. If one ever lands, it belongs in `Caches/`, never `Documents/`,
  so iOS can evict it and it isn't backed up.
- **Logs** go to `os.Logger` only; nothing is written to log files.
- Nothing is written to `Documents/` anywhere in v1.

## Export compliance

`ITSAppUsesNonExemptEncryption` is `NO`: v1 talks to no Turnip-controlled server,
so TestFlight uploads don't prompt for export-compliance answers. (The only
network is iCloud downloads through PhotoKit, over HTTPS — exempt either way.)
The OTA model-update client now on `main` refuses any scheme but `https`, which
is exempt as well, so the flag stays `NO` once an endpoint is configured.
Revisit only if non-exempt encryption or non-HTTPS networking is introduced.

## Deferred to v2 / later

- Server-side data handling for uploaded clips (retention, deletion
  requests, GDPR/CCPA) — belongs to `turnip-farm`; see `docs/DESIGN.md`
  decision #4 (retention: keep forever, user-deletable).
- Analytics / crash-reporting consent — `docs/DESIGN.md` decision #7:
  none in v1; crash/hang metrics arrive Apple-mediated under the user's
  own opt-in.
