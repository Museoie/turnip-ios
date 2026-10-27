# Turnip iOS — Contribution Design

*Draft · 2026-10-06 · Revised 2026-10-15 for master plan Rev 5: naming
moves to the core clip flow ([`PROFILE_DESIGN.md`](PROFILE_DESIGN.md) §4)
and contribution uploads clips already named there, from the on-device
clip library; uploads carry label provenance. Revised 2026-10-21: §7.2
and §8 point to on-device personalization
([`PERSONALIZATION_DESIGN.md`](PERSONALIZATION_DESIGN.md)).*

**Scope.** This is a companion to `docs/DESIGN.md`, not a rewrite of it.
`DESIGN.md` specifies the on-device pipeline (capture → pose → clip
detection → crop → export) and the v1 screens; this doc specifies the v2
contribution path layered on top: deterministic video identity, on-device
pose extraction for upload, the clip confirmation step, the
contribution upload protocol, reinstall reconciliation, and the OTA
trick-detection model. Naming clips, which this doc first placed in the
confirmation flow, is now part of the core clip flow and specified in
`docs/PROFILE_DESIGN.md` §4, together with the clip library contribution
reads from. It does not change the v1 screens or flows in
`docs/UIUX.md` — it names the exact screens and components it extends.

**Authority.** The contract this doc implements is the
[Turnip Farm + ML Master Plan](https://github.com/hoiekim/turnip-farm/blob/main/docs/MASTER_PLAN.md)
(Rev 5). Companion docs: the farm's `BACKEND_DESIGN.md` (the API
authority) and `POSE_FORMAT.md` (the wire-format authority), and
`turnip-ml`'s `MODEL_CONTRACT.md` (the trick-model input/output
authority). Where this doc makes a call the master plan
doesn't cover, it says so inline as *(judgment call)*.

**Relationship to DESIGN.md.** Per master plan §8, this doc replaces
DESIGN.md Rev 8's v2 "Labeling UI" section (there is no server labeling
queue — labeling happens on-device by the clip owner, inside the clip
confirmation flow) and its backend/label/ML sections on the points listed
in §9 below; DESIGN.md Rev 9 carries those changes. The "community
labeling platform" means: users label their own confirmed clips with
free-text trick names; the farm trains trick detection from pose
sequences, never from video.

**Status (2026-10-24).** Built, in `Turnip/Contribution/` and
`Turnip/NameClips/`, against the farm at `https://turnip.hoie.kim`:

- **The farm account** (§5.4) in Settings' Contribution section: Sign in
  with Apple with a fresh nonce and no scopes, the session token and every
  source key in the Keychain (`AfterFirstUnlockThisDeviceOnly`), sign-out,
  and account deletion that deletes every keyed source first. The Apple
  credential state is checked on every foreground; a revoked or missing
  credential signs out, and so does any `401`. The simulator skips that
  check: it is never a trusted device, and Apple reports every credential
  there as revoked, a just-issued one included.
- **`video_id`** (§1.1) for Photos-backed videos, `VideoIdentity`.
- **The contribute toggle** on Name Clips and **the confirmation sheet**
  (§3.3), which opens once the save finishes, with the clips and their
  names, the someone-else flag, the disclosure, and the pose-quality gate
  of §2.3 (warn over 30% gaps, refuse over 60%).
- **The upload** (§5.1): register with the source key, PUT the gzipped TKP1
  blob with a `Content-MD5` header (the presigned URL signs only `host`, so
  the unsigned-safe checksum), re-register until the farm's
  ingest (a 30-second sweep) reports `blob_present`, send the clips, then
  `GET /api/sources/:id` and report what the farm holds: the sheet says
  done only when every clip came back with the names it was sent with. The canonical
  `frame_count` is computed exactly as the farm's ingest computes it; a
  window maps to canonical frames start-floor, end-ceiling, clamped inside
  the sequence.
- **The vocabulary fetch** (`GET /api/taxonomy/current`) when Name Clips
  opens, at most every six hours, kept in `Application Support/` and used
  over the bundled seed when its `taxonomy_version` is greater.
- **Where the farm is**: the `TURNIP_FARM_ENDPOINT` Info.plist key. It is
  apart from `TURNIP_MODEL_UPDATE_ENDPOINT`, so pointing contribution at
  the farm doesn't also start the model poll, which waits on a promoted
  model. Blank, every farm control is hidden and no farm call is made.

Until the clip library lands ([`PROFILE_DESIGN.md`](PROFILE_DESIGN.md) §2),
the built flow differs from this doc:

- The pose is encoded when the sheet opens, from the analysis still in
  memory, not read from the library. So a clip can be contributed only in
  the save that names it: no "Contribute named clips" on the Profile and no
  toggle on a Clip view yet.
- No outbox (§5.3). A failed upload is retried from the sheet ("Try
  Again") while it is open; closing it drops the upload. No
  `contributed_at` or dirty flag (§5.2), so an edit after contributing is
  not re-sent, and no label-only update (`POST /api/clips/:id/labels`).
- One pose sequence per source, the first contributed clip's person's
  (`MULTI_PERSON.md`); a clip of another person in the same video stays
  behind, marked so in the sheet. *(Judgment call, until the farm holds
  more than one track per video.)*
- Not built: reinstall reconciliation (§6), `video_id` for file imports
  (§1.1), an observer for `credentialRevokedNotification` (the foreground
  check stands in), and the OTA trick model (§7).

---

## 1. Deterministic video identity

The farm never mints source identities. Every contribution references a
`source_id` the device derives deterministically, so the ID survives app
reinstalls and re-contribution of the same video upserts instead of
duplicating training data.

### 1.1 Derivation rules

- **Photos-backed videos** (gallery picks and in-app camera takes, which
  are saved to Photos and re-enter the flow as `PHAsset`s):
  `source_id = SHA-256 hex of ("turnip:phasset:" + PHAsset.localIdentifier)`.
  The `localIdentifier` belongs to the Photos library, not the app, so it
  is stable across reinstalls. CryptoKit's `SHA256` (available since
  iOS 13) covers the hash; no new dependency.
- **Imported files** (document-picker / Files-app imports with no
  `PHAsset`): `source_id = SHA-256 hex of the file bytes`, streamed in a
  single pass during the pose-analysis decode so a multi-hundred-MB file
  is never read twice *(judgment call — implementation detail, but the
  no-double-read property is a requirement, not a suggestion).*

One `PHAsset` yields one ID even if it appears in several albums. The ID
is computed once per asset and cached in memory keyed by
`localIdentifier` for the session; it is never the persisted source of
truth — it is recomputed on demand, which is the whole point.

### 1.2 Where it is computed

A small `VideoIdentityResolver` (new, beside the existing
`PhotoVideoResolver`) called from the video-select path
(`VideoLibraryViewModel.select(_:)`). The resulting `source_id` travels
with the existing `SelectedVideo` value through Processing → Name Clips,
so every downstream screen can reference it without recomputing.

### 1.3 Edge cases

- **Edited assets.** PhotoKit's `localIdentifier` is stable across
  non-destructive edits, so a trimmed/filtered video keeps its ID. The
  pose sequence is always derived from the *currently rendered* version;
  an edit made after contributing effectively describes a new source
  under the old ID — accepted as known behavior, not handled.
- **Duplicated videos** get a new `PHAsset` and therefore a new ID.
- **Re-encoded imports**: new bytes → new ID → new source row. The old
  row stays on the farm as training data. Accepted.
- **iCloud-only videos**: the `localIdentifier` is available from asset
  metadata without downloading, so the ID is computable before the
  download; pose analysis still waits on the download as today.
- **Limited Photos access**: IDs are computed only for granted assets;
  reconciliation (§6) only sees what the grant sees.
- **Composition exports** (`tmp/turnip-composition-export-<uuid>.mov`):
  identity comes from the `PHAsset`, never from the derived export file.
  Hashing the tmp export would mint a new ID per export — a bug, not a
  feature.
- **Cross-user collision on identical imports**: two users importing the
  byte-identical file compute the identical `source_id` (master plan §1
  caveat). Farm writes require the source's key (§5.4) and source
  ownership is first-writer-wins — a second user registering an
  already-claimed `video_id` without its key receives
  `409 SOURCE_ALREADY_CLAIMED`, so nobody can overwrite another user's
  source row. The collision is what gives the
  dedup side-benefit on re-contribution.

---

## 2. On-device pose extraction for contribution

### 2.1 Pipeline reuse

Pose comes from the existing bundled MoveNet path — the same
per-frame `{x, y, confidence}` × 17 keypoints the detector consumes, at
the Settings **analysis granularity** (1–30 fps, default 10;
`TurnipSettingsStore`). No second inference pass: the contribution blob
is encoded from the frame results the analysis already produced. For
camera takes where live inference covered the take (`LIVE_POSE.md`),
those live results are the input — again, no re-decode. The encoding
happens once, when saving writes the source to the clip library
(`PROFILE_DESIGN.md` §2.2), so a clip saved today can be contributed
later even after the save has deleted its original from Photos.

Keypoint order is MoveNet 17 in COCO order, exactly as the farm expects:
`0 nose, 1 left_eye, 2 right_eye, 3 left_ear, 4 right_ear,
5 left_shoulder, 6 right_shoulder, 7 left_elbow, 8 right_elbow,
9 left_wrist, 10 right_wrist, 11 left_hip, 12 right_hip,
13 left_knee, 14 right_knee, 15 left_ankle, 16 right_ankle`.
`x`/`y` are normalized 0–1 relative to source frame dimensions and are
recorded as-is when they fall outside `[0,1]` in letterbox-pad regions
(the existing `DESIGN.md` convention — consistent with the farm spec).

### 2.2 pose-format encoding

The farm's pose format spec (master plan §3; `POSE_FORMAT.md` when it lands) is the
authority. iOS-side rules:

- Encode at the **analysis rate** (the rate the frames were actually
  sampled at). The farm resamples to canonical 10 Hz on ingest; the
  header's `source_sample_rate_hz` records the as-sent rate for
  provenance. *(Judgment call: the client does not pre-resample — the
  farm is the resampling authority. If a future revision moves
  resampling client-side, the header fields already support it.)*
- **Gap representation**: a frame with no usable pose is an all-zero
  frame (`x=0, y=0, confidence=0` for all 17 keypoints). A frame counts
  as a gap when no keypoint clears the confidence floor used by the
  detector.
- **Raw, not reconstructed**: the blob records raw per-frame detections.
  The detector's gap mitigations (single-frame dropout bridging, optical
  flow — `DESIGN.md` "Motion signal robustness") feed
  the *motion signal only*; they must not be written into the training
  blob as if they were detections *(judgment call — training data
  should reflect what the model actually emitted; the farm's resampling
  owns interpolation, and gaps break interpolation by spec).*
- **One blob per source video**: the full pose sequence, encoded once
  per source when saving writes it to the clip library
  (`PROFILE_DESIGN.md` §2.2), stored there in `Application Support/`,
  and uploaded from there on every (re-)contribution. No `tmp/` copy is
  made, so there is nothing for the orphan sweep to learn. The library
  deletes it when the source's last clip leaves the library — not on
  upload, since the Profile and later re-contributions still need it.

### 2.3 Skeleton-fallback UX (pose failure)

Contribution needs pose; labels without a pose sequence are useless for
training. When pose quality is poor:

- If **>60% of frames inside the confirmed clip windows are gaps**,
  contribution of that source is blocked with an explanatory empty
  state ("pose tracking couldn't follow this video well enough to
  contribute it"), suggesting a re-record in slo-mo. The local
  clip/export flow is unaffected — contribution is opt-in and separate.
- If **>30%** are gaps, contribution is allowed but the confirmation
  sheet (§5) shows a quality warning.
- Thresholds are starting points, tunable without a schema change
  *(judgment call)*.

---

## 3. Clip confirmation flow

### 3.1 Screen mapping (no redesign)

The flow rides the existing screens from `UIUX.md`:

- **Processing (§2)** — analysis runs as today; proposals land on Name
  Clips.
- **Name Clips** (`UIUX.md` §3a, `PROFILE_DESIGN.md` §4) — the screen an
  analysis lands on, one clip at a time, where clips are triaged (open
  in the editor, discard, add), named, contributed or not, and saved.
  Each clip there carries its contribute toggle (§3.3). It took over
  Clip List's triage on 2026-10-27 (`UIUX.md` §3).
- **Clip Detail / Editor (§4)** — window trimming via the scrub-bar
  handles and crop editing are unchanged.
- **The Profile's Clip view** (`PROFILE_DESIGN.md` §5.2) — a saved
  clip's contribute toggle, and a "Contribute named clips" action on
  the Profile page, for clips saved before the user chose to
  contribute.

### 3.2 Automatic detection, two generations

- **Today**: the heuristic (`MotionSignalBuilder`,
  `TrickWindowDetector` in `Turnip/TrickDetection/`) proposes windows.
- **Later**: the OTA trick model (§7) proposes windows *and* suggested
  names. Both generations surface identically on Name Clips; the
  proposal source is not a user-facing distinction.

### 3.3 The confirmation step (new)

Confirmation is the farm boundary: **only confirmed clips + labels are
uploaded; nothing else ever is.** Discarded clips and the original
video can never be confirmed.

- Each clip on Name Clips, and each saved clip's Clip view in the
  Profile, gains a **contribute toggle** ("Contribute this clip",
  persisted in the clip library, default off, disabled until the clip
  has a name). Toggling is per-clip opt-in. The Clip Editor gets none.
- The **confirmation sheet** opens in two ways: by itself when the user
  finishes Name Clips with any clip toggled — once the save has
  finished, so saving and contributing stay separate steps — or from
  the Profile's **"Contribute named clips"**, a list of named clips not
  yet contributed, each chosen individually. The sheet lists the clips
  with their trick-name chips, the payload summary ("pose keypoints,
  clip windows, labels — video never leaves your device"), and a
  Confirm button. Cancelling sends nothing; the clips stay saved and
  can be contributed later from the Profile. *(Judgment call on
  placement: contribution never sits on the editor, which is already
  full. The exact affordance is UI polish; the boundary
  semantics are not.)*
- The sheet also carries the disclosure the farm requires
  (`BACKEND_DESIGN.md` §7.1):
  - contributions stay linked to the user's account for 30 days after
    their last edit, then are kept without any link to it;
  - deleting the account removes every contribution this app can still
    find, and the rest can't be traced back to the user and remain in
    the training data;
  - contribute only clips of yourself, or of people who agreed: the
    person in a clip may not be the account holder. A clip marked as
    someone else (`PROFILE_DESIGN.md` §4.3) is flagged next to this
    line.
- A contributed clip needs at least one trick name, given in the core
  flow (`PROFILE_DESIGN.md` §4); a clip with no names cannot be
  confirmed (inline hint in the sheet).
- Nothing in the app is gated on contributing, the Profile included
  (`PROFILE_DESIGN.md` §1).

### 3.4 `auto_detected` semantics

`auto_detected = true` when the clip's current window originated from
automatic detection (heuristic or trick model); any manual trim of the
window clears it to `false` *(judgment call)*. It is provenance for the
training pipeline, not a user-facing badge.

---

## 4. Labels in a contribution

The label editor this section first specified — free-text chips,
multiple names per clip, vocabulary suggestions — now lives in the core
clip flow, because the Profile needs names on every saved clip,
contributed or not: `PROFILE_DESIGN.md` §4 is its design. What stays
here is what contribution adds:

- **Free text is the contract.** No fixed vocabulary is enforced; the
  farm stores raw strings and its `label_taxonomy` curates later.
- **Origin.** Each name is sent with the `origin` the clip library
  recorded when it was given: `typed`, `vocabulary` (picked from the
  suggestions), or `model` (pre-filled by the trick model and kept)
  (`BACKEND_DESIGN.md` §1.2.18).
- **`taxonomy_version`.** Stamped server-side at contribution time
  from the farm's current taxonomy — the farm is the authority on which
  vocabulary was in effect when the label landed. The client does not
  send it; it may keep the manifest's version locally for display only.
- **No per-label windows.** The farm schema stores one label row per
  `(clip_id, trick_name)` with no window columns — a label names the
  trick for the clip's whole window (`BACKEND_DESIGN.md` §1.1). The
  editor does not expose per-label window tightening; a later UI that
  wants it needs a farm schema change first.
- **Never sent:** whether the clip shows the user (`is_me`), favorites,
  spots, or anything else the Profile keeps (master plan §1).

The iOS API payload per clip is `{clip_id, source_id, source_key,
start_frame, end_frame, auto_detected, proposal_model_version,
suggested_names, suggestions_withheld, labels: [{name, origin}]}`; the
farm stores one label row per `(clip_id, trick_name)`
(`BACKEND_DESIGN.md` §1.1, §7.3).

---

## 5. Contribution upload

### 5.1 Payload and endpoints

On Confirm (per-clip opt-in, §3.3), with a farm session (§5.4). The v1
export flow and the Profile stay anonymous; contribution is the first
authenticated action, and the sheet prompts sign-in when needed. Every
contribution request also carries the source's key (§5.4).

1. `POST /api/sources` with `{video_id, source_key, frame_count,
   sample_rate, keypoint_format: "tkp1"}` → `{source_id, r2_key,
   upload_url, upload_expires_at, blob_present}`. The client never
   sends a blob digest; the farm computes the stored digest at ingest.
   `409 SOURCE_ALREADY_CLAIMED` means the video is already contributed
   under another key (a byte-identical import from someone else, or
   this app's key was lost); the clip stays local-only.
   - `frame_count` / `start_frame` / `end_frame` are indices into the
     **canonical 10 Hz** sequence. The client maps its analysis-rate
     indices through the POSE_FORMAT.md §6 resampling map — the same mapping §7.2
     uses to display inference segments — so storage, validation,
     training, and model output all share one coordinate space.
2. `PUT` the pose-format blob to `upload_url` (full source pose sequence,
   once per `source_id`, read from the clip library; skipped when
   `blob_present` is true).
3. `POST /api/clips` with `{clips: [{clip_id, source_id, source_key,
   start_frame, end_frame, auto_detected, proposal_model_version,
   suggested_names, suggestions_withheld, labels: [{name, origin}]}]}`
   — batch upsert (§4). The farm verifies the blob SHA-256, upserts
   the clips, and replaces each clip's label set atomically.
   - `clip_id` is a UUIDv4 minted once per clip at creation (derived
     tile or "+" tile), persisted in the clip library, reused on
     every re-contribution, and recovered from the server after
     reinstall (§6).
   - The provenance fields come from the clip library as the naming
     flow recorded them (`MODEL_CONTRACT.md` §3.3): `null`, `[]` and
     `false` for a heuristic or manual clip.

Label-only edits later use `POST /api/clips/:id/labels` with the
source's key — no blob re-upload.

### 5.2 Upsert semantics

Every write upserts on ID match: re-confirming the same clip overrides
its labels server-side. Locally, each clip carries `contributed_at` and
a dirty flag; editing labels or windows after contribution marks it
dirty, and the next Contribute run re-sends it. This is what makes
re-confirmation safe and idempotent.

### 5.3 Retry, offline, dedup

- An **outbox queue** in the app's local persistence holds pending
  uploads across app restarts. Failed attempts retry with exponential
  backoff; the user can cancel a pending upload. Order per source:
  `POST /api/sources` first (it returns the presigned `upload_url`),
  then PUT the blob, then `POST /api/clips` (§5.1).
- If the PUT succeeded but a later step failed, retry from the failed
  step — the PUT targets the same staging key, so a repeated PUT
  overwrites identical bytes and is harmless but unnecessary
  (BACKEND_DESIGN.md §7.3).
- **Re-contribution dedups by construction**: the deterministic
  `video_id` means contributing the same video twice upserts the same
  source row — never duplicate training data.
- **Known gap**: there is no per-clip server delete in the farm API.
  Trashing a clip locally *after* contributing leaves the server copy
  in place; only `DELETE /api/sources/:id` (whole source) exists.
  Whether the farm should add `DELETE /api/clips/:id` is an open
  question for the farm API doc.

### 5.4 Sign-in, source keys, and account deletion

The client half of `BACKEND_DESIGN.md` §7.1. Contributions are owned
through keys, not through the account, so the farm keeps no lasting
record of whose a contribution is.

- **Sign-in.** Generate a random raw nonce per attempt, and set
  `ASAuthorizationAppleIDRequest.nonce` to its lowercase hex SHA-256.
  Send the raw nonce, `identityToken`, and `authorizationCode` to
  `POST /api/auth/apple` right away (the code is single-use and valid
  five minutes). Store the returned session token in the Keychain
  (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, so background
  uploads can read it) and send it as `Authorization: Bearer` on every
  call.
- **Session checks.** On launch, call `getCredentialState(forUserID:)`.
  On `.revoked` or `.notFound`, call `POST /api/auth/signout`, delete
  the session token, and show the signed-out state; also observe
  `credentialRevokedNotification`. On any `401`, delete the token and
  sign in again.
- **Source keys.** The first time a source is contributed, generate 32
  random bytes as its key and store it in the Keychain under its
  `video_id`, with the same accessibility as the session token. The key
  goes with every request about that source. Keychain items survive
  app deletion and reinstall on current iOS, but Apple doesn't
  guarantee it, so a missing key is an expected state: the source is
  contributed but unmanageable from this install.
- **Account deletion** (Settings): delete every source the app holds a
  key for (`DELETE /api/sources/:id`), call `DELETE /api/account`, then
  delete the local keys and session token. Before confirming, repeat the
  §3.3 disclosure: contributions this app can no longer find stay in
  the training data, unlinked from the account.

---

## 6. Reinstall reconciliation

### 6.1 Flow

This restores **contributed** clips, and only on a device that still
holds their source keys. It is not how the Profile's library comes
back: the farm does not know whose clips are whose, and most saved
clips are never contributed. The library restores from the device —
device backups and the record in each exported clip file
(`PROFILE_DESIGN.md` §3.2). When both run, a clip present in both is
matched by `clip_id`, and the server's windows and labels win only for
fields the library lost.

On fresh install — auto-run once after Photos permission is granted,
plus a "Restore contributions" row in Settings for later:

1. Read the source keys left in the Keychain (§5.4); each is stored
   under its `video_id`. The farm keeps no list of a user's sources,
   so these keys are the record of what this app contributed.
2. Enumerate video `PHAsset`s (respecting limited-access grants) and
   recompute `source_id` per §1.1. Match against the keys by ID.
3. For each match, `GET /api/sources/:id` with its key — pull confirmed
   clips + labels and **adopt the server's clip IDs** into the rebuilt
   local store (clip IDs are recovered, never recomputed).
4. Rebuild local clip state (windows + labels). If the video is still
   in the library, pose can be re-derived locally on demand; if not,
   skeleton previews render from the pose blob via
   `GET /api/sources/:id/pose` (owner-only presigned R2 GET) —
   keypoints straight to screen, no video needed.

A session and the source's key are required throughout
(`BACKEND_DESIGN.md` §7.2).

### 6.2 Videos deleted from the library

Their server data stays — it remains valid training data. The client
cannot relink what it cannot see. *(Judgment call: the reconciliation
UI lists matched sources normally. Keys whose video is no longer in
the library are grouped under "no longer on this device"; their
clip/label counts come from `GET /api/sources/:id` with the key, and
each has a delete-from-server action (`DELETE /api/sources/:id`).)*

### 6.3 Multi-device

Source keys stay on the device that contributed
(`ThisDeviceOnly`), and a `video_id` from one device's Photos library
doesn't resolve on another. A second device signed in to the same
Apple account therefore restores nothing; contributions are managed
from the device that made them (master plan open question #2 —
accepted for v1). Whether `video_id` should derive from an identifier
shared across the user's devices has to be settled before the first
contribution ships, since changing it later orphans every source.

---

## 7. OTA trick model

### 7.1 Delivery (extends the existing OTA path)

`Turnip/ModelUpdates/` already ships a manifest client, a version
store with atomic replace, and the launch/foreground poll, which stays a
no-op until an endpoint is configured. Nothing loads the staged file
yet: the trick-model loader (§7.2) is the missing consumer. The trick
model rides the same mechanism: `GET /api/models/current` — public, so
the app polls it signed in or not — returns the trick-detection manifest
— version, URL, checksum, `taxonomy_version`, the `vocabulary` list, and
`name_metrics` (the Profile's impact feedback, `PROFILE_DESIGN.md` §9).
Download via background `URLSession`, verify SHA-256 against the
manifest, atomic-replace into the version store; activate only after
verification. The heuristic detector remains the offline fallback when
no model is present (first launch, failed download) — the UI never
distinguishes proposal sources.

### 7.2 On-device inference integration

- **Input**: the pose-format pose sequence the pipeline already produced —
  no re-decode, no second inference pass over video.
- **Model**: Core ML (exported via `coremltools` per the master plan),
  run once per analysis on the existing background queue (not per
  frame; thermal cost is bounded by construction).
- **Output** (`MODEL_CONTRACT.md` authority): segments in
  **source-frame coordinates** (canonical 10 Hz indices) with
  `trick_names`, per-name `name_scores`, and `is_combo`.
- **Mapping to the UI**: convert segment frames → seconds at canonical
  10 Hz, then onto the local analysis-rate timeline for Name Clips' cards
  *(judgment call)*. Names the model is confident in arrive as
  **pre-filled chips** on Name Clips — editable and
  removable, recorded as `origin: model` if kept — and a random tenth
  of model-proposed clips get none: the blind sample. Both rules, and
  the provenance the clip records, are `MODEL_CONTRACT.md` §3.3's.
  **Labels are never auto-confirmed**: a proposed name still requires
  the user's Confirm (§3.3) before anything is uploaded.
- The manifest's `vocabulary` is one of the sources of the naming
  suggestions (`PROFILE_DESIGN.md` §4.2), which use whichever
  vocabulary the app holds is newest; the farm stamps
  `taxonomy_version` at contribution time (§4).
- **On-device personalization** (`PERSONALIZATION_DESIGN.md`,
  bounded by `MODEL_CONTRACT.md` §3.5) sits on top of this model. It
  re-ranks name suggestions and decides segments scoring 0.3–0.7 from
  the user's own library. It never pre-fills a name and adds nothing to
  the upload: provenance stays the central model's. Its rebuild after
  a model update is the one other pass over pose, a background task on
  external power, so the once-per-analysis rule above still holds for
  analysis.

---

## 8. Privacy notes

Consistent with `docs/PRIVACY.md` (which remains the App Store
submission source; `site/privacy.html` must be updated in step with any
change here):

**Never leaves the device** — video pixels, audio, location,
photo-library identifiers (the raw `localIdentifier` — only its
one-way SHA-256 derivative, the `video_id`, ever leaves), device
identifiers, contacts, thumbnails, the video file itself, and the
on-device personal layer with everything it learns from
(`PERSONALIZATION_DESIGN.md` §7, §9).

**Leaves only on explicit per-clip opt-in** (the Contribute
confirmation, §3.3):
- `video_id` — opaque deterministic ID (§1)
- pose-format keypoint sequence — stick figures, no face, no background,
  no identity (residual honesty per the master plan: gait-from-keypoints
  re-identification is real research; minimization is the mitigation)
- confirmed clip windows + free-text trick names
- label provenance — each name's `origin`, and the proposing model
  version, its pre-filled names, and the blind-sample flag per clip:
  how a label was made, never who made it
- Sign in with Apple subject — per-app opaque pseudonym, for sign-in,
  rate limiting, and blocking. The farm links it to a contribution
  only until 30 days after the contribution's last edit (anti-poisoning
  attribution), then the contribution has no account link.
- Source key — random per-source secret proving ownership; the farm
  stores only its hash

**Never leaves the device, even on opt-in** — the Profile: whether a
clip shows the user, favorites, spots, achievements and progress
(`PROFILE_DESIGN.md` §10).

**Local hygiene** (extends `PRIVACY.md`'s rules): the pose blob is read
from the clip library in `Application Support/` (§2.2) — no `tmp/` copy;
source keys and the session token live in the Keychain; thumbnails stay
in-memory only; nothing is written to `Documents/`.

**Submission-time consequences** (open question): the v1 "Data Not
Collected" nutrition label changes the moment contribution ships. The
new disclosures must cover the Apple `sub` identifier, its 30-day link
to contributions, and the pose keypoints; the precise App Store label
taxonomy for pose keypoints
needs a call at submission time. `ITSAppUsesNonExemptEncryption` stays
`NO` (HTTPS only, exempt).

---

## 9. Relationship to DESIGN.md

Per master plan §8, these are the deltas against `docs/DESIGN.md` Rev 8;
DESIGN.md Rev 9 applies them:

1. **Backend section** → superseded by master plan §2–§4: pose blobs
   and upserts replace video upload / R2 video storage; every "upload
   the video" sentence is dead. R2 stays for pose blobs and model
   artifacts.
2. **Labels** → superseded: free-text, multiple per clip, labeler-set
   windows; `crop_rects` dropped from the server label model (crop is a
   client rendering concern; the athlete's location is in the
   keypoints).
3. **ML section** → superseded: the pipeline trains *trick detection*
   (pose sequence → segments + names), not a fine-tuned pose model. The
   model escalation ladder now guards *pose input quality* instead.
4. **Decisions** → #2 (*no classifier at launch*) is reversed: the
   detector **is** the ML program. #4 (*keep videos forever*) is moot:
   there are no videos to keep. New standing decision: *keypoints +
   opaque IDs only, never pixels* — reopenable only by deliberate
   product decision, never convenience.
5. **OTA models** → extended to the two-model story: bundled MoveNet
   (pose, unchanged) + OTA trick-detection model. The
   `Turnip/ModelUpdates/` machinery, with its launch/foreground polling,
   is the delivery path; the old "pose+action model" language is retired.
6. **Clip editor / labeling** → the label editor lives in the clip
   confirmation flow (§3–§4 of this doc). The v2 "Labeling UI" section
   (server pending-queue tab) is superseded — labeling happens
   on-device by the clip owner. *(Since DESIGN.md Rev 12: naming lives
   in the core clip flow, `PROFILE_DESIGN.md` §4, and confirmation
   uploads names already given.)*
7. **New: video identity** → §1 of this doc; no local ID↔asset mapping
   to lose.
8. **Social feed** → deferred. The planned Share Sheet (`DESIGN.md`
   "Publishing to social media") covers sharing;
   the only feed-compatible future is client-rendered skeleton
   previews.
9. **Problem statement** → the community trains *trick detection*, and
   the privacy claim reads "no video pixels ever leave the device" —
   with the honest footnote that pose sequences, labels, and the Apple
   `sub` do leave per explicit opt-in.

---

## Open questions (for the maintainer)

1. ~~**Clip → Label cardinality.**~~ Resolved: one label row per
   `(clip_id, trick_name)` (`BACKEND_DESIGN.md` §1.1); re-contribution
   replaces a clip's whole label set atomically (§5.2).
2. **Per-clip server delete.** No `DELETE /api/clips/:id` exists;
   post-contribution local trash leaves the server copy. Add the
   endpoint, or declare server copies immutable-by-design?
3. **App Store taxonomy for pose keypoints.** The nutrition-label
   category for a keypoint sequence needs a call at submission time
   (§8).
4. ~~**Upload coordinate space.**~~ Resolved during review: the client
   sends canonical 10 Hz indices (§5.1) — one coordinate space across
   storage, validation, training, and model output.
5. **Contribution quality thresholds** (§2.3: block >60% gaps, warn
   >30%) are starting points — tune from real footage.
6. **Multi-device** (master plan open question #2): source keys are
   this-device-only, so contributions restore only on the device that
   made them (§6.3), and the `video_id` derivation has to be settled
   before the first contribution ships. Accepted for v1?
