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

These answers describe v1. The contribution code is now built and the
committed Info.plist points it at the farm (`TURNIP_FARM_ENDPOINT`), so a
build from this tree makes the calls listed under "Contribution" below:
**before such a build is submitted, the label, the manifest's collected data
types, `site/privacy.html` and the Photos usage string ("Nothing leaves your
device") have to change.** Until then, these are the answers for the release
in the store.

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
  reaches the client. The app runs that check on launch and on every
  foreground, but the URL comes from the `TURNIP_MODEL_UPDATE_ENDPOINT`
  Info.plist key, which is empty in the committed plist — so the base URL is
  `nil` and no request is ever made. The client's own test exercises the
  `https` guard without issuing a request.
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
  (`Turnip/Camera/RollTrackRecorder.swift`, format in
  `Turnip/Media/RollTrack.swift`), so the editor can level the clip
  without guessing from the picture; this is the device-motion API, which
  needs no `NSMotionUsageDescription` and raises no prompt (unlike the
  pedometer and activity APIs), and the angles live only inside the user's
  own video file in their Photos library. If the user
  marks the original video for deletion on Name Clips, the original is deleted
  from Photos too — a user-initiated, on-device change to their own library,
  not data leaving the device. Saved clips' trick names, whether each shows
  the user, and the Profile's achievements are kept in an on-device library
  ("The clip library and the Profile" below) and never sent anywhere.
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
| Disk space | No | No volume-capacity resource keys and no `statfs` family call sites. The clip library is written without one. A free-space check before rendering a highlight or writing the library would change this row (see "The clip library and the Profile" below). |
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
  also what lets Name Clips delete the original video (`PhotoAssetDeleter`,
  `PHAssetChangeRequest.deleteAssets`) when the user trashes its tile and
  taps Save Clips — PhotoKit shows its own "Allow Turnip to delete?" system
  confirmation before the deletion happens, on top of the one-time
  read/write grant.
- `NSPhotoLibraryUsageDescription` explains the read side in plain
  language. `NSPhotoLibraryAddUsageDescription` ships alongside it
  because the clip-save path — reachable from Home through Processing and
  Name Clips — calls `requestAuthorization(for: .addOnly)`, and iOS
  terminates the app on that call when the string is absent. A user does
  not normally see the string: reaching a save means the read/write
  grant from Home is already in place, which determines add-only as
  authorized, so the call returns without presenting a second prompt.
- `PHPhotoLibraryPreventAutomaticLimitedAccessAlert` is set: with
  limited access the app shows its own "select more" affordance instead
  of iOS re-prompting on its own schedule.

## Camera and microphone

- The in-app camera requests both when its screen first starts
  (`CameraCaptureViewModel.start()`); a recording needs both, so
  `CameraAccessState` treats them as one grant. `NSCameraUsageDescription`
  and `NSMicrophoneUsageDescription` explain each in plain language.
- Video and audio go only into the take's movie file,
  `tmp/turnip-recording-<uuid>.mov`, which is saved to Photos through
  `ClipPhotosSaver` and then deleted (`RootTabView.handleRecorded`). If
  the save fails, the file stays in `tmp/` rather than destroying the
  user's only copy of the footage.
- Live pose inference reads frames from the same capture session, and
  the roll track reads Core Motion's device motion (both described
  above); neither adds a permission prompt of its own.

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
- **Clip exports.** Tapping "Save Clips" on Name Clips (`ClipListViewModel.save()`)
  stages every non-trashed derived clip in a fresh `tmp/turnip-export-<uuid>/`
  scratch directory, hands each one to Photos through `ClipPhotosSaver`
  (add-only), and deletes the whole directory once the run ends — success or
  failure, since there is no Share action here to keep a file alive for. A
  `save()` call killed mid-run is swept by the next one
  (`sweepStaleExportDirectories`); the `turnip-export-` prefix is what makes
  the sweep recognize only our directories.
- **Thumbnails** are in-memory only — `PHCachingImageManager` for the
  Home grid (`ThumbnailLoader`) and `AVAssetImageGenerator` frames for
  Name Clips' cards (`ClipThumbnailLoader`). There is no on-disk thumbnail
  cache. If one ever lands, it belongs in `Caches/`, never `Documents/`,
  so iOS can evict it and it isn't backed up.
- **Partial live pose.** When live inference covers a take only in part,
  the keypoints it did score stay in memory, on the pushed `SelectedVideo`
  and in `VideoLibraryViewModel`'s store of the last eight such takes, so
  Processing analyzes only the rest (`docs/LIVE_POSE.md`). They are never
  written to disk and are gone when the app quits.
- **Everyone in frame.** The pose model finds up to six people per frame, so
  bystanders' keypoints are computed and held in memory alongside the
  athlete's, in either person mode (`docs/MULTI_PERSON.md`). Following
  everyone, the poses of the people who own a clip travel with the clips to Name Clips.
  None of it is written to disk, and all of it is gone when the app quits.
- **Logs** go to `os.Logger` only; nothing is written to log files.
- Nothing is written to `Documents/` anywhere in v1.

## Export compliance

`ITSAppUsesNonExemptEncryption` is `NO`: v1 talks to no Turnip-controlled server,
so TestFlight uploads don't prompt for export-compliance answers. (The only
network is iCloud downloads through PhotoKit, over HTTPS — exempt either way.)
The OTA model-update client now on `main` refuses any scheme but `https`, which
is exempt as well, so the flag stays `NO` once an endpoint is configured.
Revisit only if non-exempt encryption or non-HTTPS networking is introduced.

## Contribution (built; changes the answers above before it ships)

What a build with `TURNIP_FARM_ENDPOINT` set sends to the farm
(`CONTRIBUTION_DESIGN.md` §5, §8), all over HTTPS through an ephemeral
`URLSession` (no cache, no cookies on disk):

- **The vocabulary fetch**, `GET /api/taxonomy/current`, when Name Clips
  opens, at most every six hours. No identifier and no session go with it.
- **Sign in with Apple**, from Settings or the contribution sheet, at the
  user's tap. No name or email scope is requested; the farm sees the
  identity token, whose only claim it keeps is the per-app `sub`.
- **A contribution**, only from the confirmation sheet, only for clips the
  user named and toggled, and only on Confirm: the video's `video_id`
  (SHA-256 of the Photos identifier, never the identifier), its pose
  keypoints as a TKP1 blob, each clip's window in pose frames, its trick
  names with how each was given, the session token and the source's key.
  Never the video, a thumbnail, whether a clip shows the user, or a
  location.
- **Account deletion**, from Settings: `DELETE /api/sources/:id` for every
  source the app holds a key for, then `DELETE /api/account`.

On the device: the session token, the Apple user ID it belongs to (for the
credential-state check) and one random key per contributed source live in
the Keychain, readable after first unlock and never migrated off the device.
The fetched vocabulary is cached in `Application Support/turnip-vocabulary.json`.
Nothing is written to `Documents/`. No required-reason API was added: the
Keychain isn't one, and the vocabulary cache is read and written without
file metadata.

What changes before release, and is not decided here: the nutrition label
(the Apple `sub` and pose keypoints, linked to the account for 30 days after
a contribution's last edit), `NSPrivacyCollectedDataTypes` in the manifest,
`site/privacy.html`, and the Photos usage string. `ITSAppUsesNonExemptEncryption`
stays `NO`: HTTPS only.

## The clip library and the Profile (core built; the rest planned)

The first v2 release (master plan Phase 2a; [`PROFILE_DESIGN.md`](PROFILE_DESIGN.md))
changes on-device data handling only. Nothing below is collected in the App
Store sense: it is processed and stored on the device, and none of it is sent
to a Turnip-controlled server.

Built (`Turnip/Profile/`):

- **No network of its own.** The library and the Profile make no call. The
  vocabulary naming suggests from arrived with contribution (above): it
  carries no identifier and no session, and the farm's access logs, kept 30
  days at most (`BACKEND_DESIGN.md` §8), are its only record. The Profile
  reads the vocabulary already held and fetches nothing.
- **The first persistent user data.** `ClipLibrary` keeps one JSON file,
  `Application Support/ClipLibrary/library.json`, written by Name Clips' save
  and by naming on the Profile: for each video that produced a saved clip,
  its Photos identifier, recording date and duration; for each saved clip,
  its clip ID, window in seconds, its own Photos identifier, trick names,
  whether it shows the user, whether detection found it, and its date; and
  the levels and rep milestones earned. Not `Documents/`, which stays empty,
  and not `Caches/`: it is in the user's iCloud and Finder device backups,
  which is how it survives a reinstall today. A file the app can't read is
  renamed `library-unreadable-<date>.json` beside it rather than overwritten.
  Deleting the app deletes it.
- **New read, no new prompt.** `PHAsset.creationDate` of the video a save
  came from, under the existing Photos grant, to date its clips. The Profile
  also shows each saved clip's thumbnail and plays it from Photos by its
  identifier, and the Clip view can delete a clip's video through the same
  `PHAssetChangeRequest.deleteAssets` path (and system confirmation) Name
  Clips uses for an original.
- **Required-reason APIs.** None added: the library is written with
  `Data.write(options: .atomic)` and read back whole; it reads no file
  timestamps and checks no free space.

Planned:

- **More in the library.** Each source's pose keypoint sequence, a copy of
  the source video's location when it has one, spot names and favorites
  join the same file's directory in `Application Support/`: not `Caches/`,
  since the pose there is the only copy once the save has deleted an
  original.
- **Data written into the user's own files.** Each clip Save Clips exports
  carries a small Turnip metadata item (its clip ID, trick names, and whether
  it shows the user) and is named `turnip-clip-<clip_id>.mov`, the same
  pattern as the roll track in camera takes. A clip shared from the Photos
  app carries both; Turnip's own Share action, when it lands, strips them. No
  photo-library identifier, `source_id` or location is written into a file.
- **New reads, no new prompt.** Under the existing Photos grant:
  `PHAsset.location`, `PHAsset.isFavorite`, and
  `PHAssetResource.originalFilename` (`creationDate` is read already). No
  location permission is requested: Turnip's own camera records no
  location, so its takes get a place only when the user names one.
- **Temp files.** Highlight videos render to `tmp/turnip-highlight-<uuid>.mov`
  only for Save or Share and are deleted afterwards; the launch-time orphan
  sweep (`PhotoVideoResolver.deleteOrphanedTemporaryExports`) has to learn
  the prefix. No render cache; if one lands, it goes in `Caches/`.
- **Required-reason APIs.** Recheck the audit table and
  `ci_scripts/check-privacy-manifest.sh` when this lands. A free-space check
  before rendering or writing the library is
  `NSPrivacyAccessedAPICategoryDiskSpace` (approved reason E174.1) and needs a
  manifest entry, or CI fails. Metadata reads on the library's own files fall
  under the file-timestamp category already declared (C617.1 covers files in
  the app's container).
- **`site/privacy.html`** changes when this ships, not before: it describes
  what the shipped app does.

## Planned: on-device personalization (not built)

After the on-device trick model (master plan Phase 4), the app adapts it
to its user on the device ([`PERSONALIZATION_DESIGN.md`](PERSONALIZATION_DESIGN.md)).
Nothing below is collected in the App Store sense.

- **No network.** Training runs on the device from the user's own clip
  library. Nothing it learns or reads is uploaded, and it adds no field
  to a contribution, so no App Store answer changes.
- **New data on the device.**
  - Each trashed trick-model proposal on a source the library keeps
    leaves two frame indices behind, in the clip library in
    `Application Support/`, so it is in device backups.
  - A derived, rebuildable cache (clip embeddings, per-name prototypes,
    a small keep-layer model) lives in `Caches/`, outside backups.
- **Deleting it.** Settings' "Learn from my clips" toggle deletes both
  when turned off; deleting the app deletes both. The farm holds none of
  it.
- **Background work.** A rebuild after each model update runs as a
  `BGProcessingTask` on external power. BackgroundTasks is not a
  required-reason API, so the privacy manifest is unchanged.
- **`site/privacy.html`** changes when this ships, not before.

## Deferred to v2 / later

- Server-side data handling for uploaded clips (retention, deletion
  requests, GDPR/CCPA) — belongs to `turnip-farm`; see `docs/DESIGN.md`
  decision #4 (retention: keep forever, user-deletable). In outline:
  - Contributions are linked to the account only until 30 days after
    their last edit, then kept with no account link.
  - The account can be deleted in-app; that removes every contribution
    the app still holds a key for.
  - The contribution sheet discloses both, and asks users to contribute
    only clips of themselves or of people who agreed (`turnip-farm`
    `BACKEND_DESIGN.md` §1.2.17, §7.1, §8; `CONTRIBUTION_DESIGN.md` §5.4).
  - `site/privacy.html` needs the same update when contribution ships.
- Analytics / crash-reporting consent — `docs/DESIGN.md` decision #7:
  none in v1; crash/hang metrics arrive Apple-mediated under the user's
  own opt-in.
