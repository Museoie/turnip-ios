# Turnip privacy compliance notes

The single home for the answers App Store Connect asks for at submission
time, so nobody has to reverse-engineer them later. v1 is the fully
on-device release; anything that changes with v2 (upload, accounts) is
marked as such below.

## App Store "nutrition label" answers (v1)

**Data Not Collected.** The v1 app collects no data, full stop:

- No accounts, no sign-in, no identifiers.
- No analytics. No third-party crash-reporting SDK; crash/hang metrics arrive
  Apple-mediated (Xcode Organizer + MetricKit) under the user's own "Share With App
  Developers" opt-in — not declarable as collected data. See `docs/DESIGN.md`
  decision #7.
- No calls to any Turnip-controlled server in the v1 path (verified by inspection:
  no `URLSession`/`URLRequest` usage in `Turnip/`). Bytes do cross the network when
  PhotoKit downloads an iCloud-only video (`isNetworkAccessAllowed` in
  `PhotoVideoResolver`/`ThumbnailLoader`) — from the user's own iCloud, through a
  system framework. Videos are read from the Photos library the user grants access
  to, processed on-device by the bundled MoveNet model, and exported clips are
  written back to Photos.
- Nothing is uploaded, shared, or transmitted to any Turnip-controlled server.

## Privacy manifest (`Turnip/Resources/PrivacyInfo.xcprivacy`)

Declares: no tracking (`NSPrivacyTracking` false, no tracking domains),
no collected data types, and no required-reason API categories.

Required-reason API audit (re-run if these change):

| API category | Used? | Evidence |
|---|---|---|
| UserDefaults | No | No `UserDefaults` references in `Turnip/` |
| File timestamps | No | `creationDate` appears only as `PHAsset.creationDate` — PhotoKit metadata on assets the user granted access to, not the file-timestamp APIs (`attributesOfItem`, `getResourceValue`) the category covers |
| System boot time | No | No `systemUptime` usage |
| Disk space | No | No volume-capacity queries |
| Active keyboards | No | No text fields anywhere in the app |

Third-party SDKs: the only dependency is `TensorFlowLiteSwift`
(`Podfile.lock` resolves its `Privacy` subspec, which carries the pod's
own `PrivacyInfo.xcprivacy`), and it is not on Apple's list of SDKs that
require a manifest/signature. If a dependency is added, check both.

## Photos access

- Home requests `.readWrite` for the gallery. PhotoKit offers no
  read-only level — the choices are add-only (can't enumerate the
  library) or read/write — and exporting clips back to Photos needs the
  write half anyway, so one honest prompt covers both.
- `NSPhotoLibraryUsageDescription` explains the read side in plain
  language. `NSPhotoLibraryAddUsageDescription` ships with the export
  work (PR #55, issue #10), which is the first code path that writes.
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
v2's OTA model-update polling uses HTTPS only, which is exempt — the flag stays
`NO` then too. Revisit only if non-exempt encryption or non-HTTPS networking is
introduced.

## Deferred to v2 / later

- Server-side data handling for uploaded clips (retention, deletion
  requests, GDPR/CCPA) — belongs to `turnip-farm`; see `docs/DESIGN.md`
  decision #4 (retention: keep forever, user-deletable).
- Analytics / crash-reporting consent — `docs/DESIGN.md` decision #7:
  none in v1; crash/hang metrics arrive Apple-mediated under the user's
  own opt-in.
- Temp-export cleanup for the clip-export path (issue #10, PR #55):
  exported clips staged at a temp URL must be deleted after the Photos
  save succeeds or fails — tracked in issue #81, verified when #55 merges.
