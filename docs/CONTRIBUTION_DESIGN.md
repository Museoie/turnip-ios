# Turnip iOS — Contribution Design

*Draft · 2026-10-06*

**Scope.** This is a companion to `docs/DESIGN.md`, not a rewrite of it.
`DESIGN.md` specifies the on-device pipeline (capture → pose → clip
detection → crop → export) and the v1 screens; this doc specifies the v2
contribution path layered on top: deterministic video identity, on-device
pose extraction for upload, the clip confirmation + label editor flow, the
contribution upload protocol, reinstall reconciliation, and the OTA
trick-detection model. It does not change the v1 screens or flows in
`docs/UIUX.md` — it names the exact screens and components it extends.

**Authority.** The contract this doc implements is the
[Turnip Farm + ML Master Plan](https://github.com/hoiekim/turnip-farm/blob/main/docs/MASTER_PLAN.md)
(Rev 3). Companion docs: the farm's forthcoming `DATABASE_DESIGN.md` and
`TKP1.md` (the wire-format authority; until they land, master plan §3 is
the TKP1 spec), and `turnip-ml`'s `MODEL_CONTRACT.md` (the trick-model
input/output authority). Where this doc makes a call the master plan
doesn't cover, it says so inline as *(judgment call)*.

**What changed from DESIGN.md.** Per master plan §8, this doc supersedes
the v2 "Labeling UI" section of `DESIGN.md` (there is no server labeling
queue — labeling happens on-device by the clip owner, inside the clip
confirmation flow) and the backend/label/ML sections on the points listed
in §9 below. The "community labeling platform" is now: users label their
own confirmed clips with free-text trick names; the farm trains trick
detection from pose sequences, never from video.

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
with the existing `SelectedVideo` value through Processing → Clip List,
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
  caveat). Farm writes are owner-scoped and source ownership is
  first-writer-wins — a second user registering an already-claimed
  `video_id` receives `409 SOURCE_ALREADY_CLAIMED`, so nobody can
  overwrite another user's source row. The collision is what gives the
  dedup side-benefit on re-contribution.

---

## 2. On-device pose extraction for contribution

### 2.1 Pipeline reuse

Pose comes from the existing bundled MoveNet Thunder path — the same
per-frame `{x, y, confidence}` × 17 keypoints the detector consumes, at
the Settings **analysis granularity** (1–30 fps, default 10;
`TurnipSettingsStore`). No second inference pass: the contribution blob
is encoded from the frame results the analysis already produced. For
camera takes where live inference covered the take (`LIVE_POSE.md`),
those live results are the input — again, no re-decode.

Keypoint order is MoveNet 17 in COCO order, exactly as the farm expects:
`0 nose, 1 left_eye, 2 right_eye, 3 left_ear, 4 right_ear,
5 left_shoulder, 6 right_shoulder, 7 left_elbow, 8 right_elbow,
9 left_wrist, 10 right_wrist, 11 left_hip, 12 right_hip,
13 left_knee, 14 right_knee, 15 left_ankle, 16 right_ankle`.
`x`/`y` are normalized 0–1 relative to source frame dimensions and are
recorded as-is when they fall outside `[0,1]` in letterbox-pad regions
(the existing `DESIGN.md` convention — consistent with the farm spec).

### 2.2 TKP1 encoding

The farm's TKP1 spec (master plan §3; `TKP1.md` when it lands) is the
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
  The detector's gap mitigations (single-frame interpolation, fallback
  anchors, optical flow — `DESIGN.md` "Motion signal robustness") feed
  the *motion signal only*; they must not be written into the training
  blob as if they were detections *(judgment call — training data
  should reflect what the model actually emitted; the farm's resampling
  owns interpolation, and gaps break interpolation by spec).*
- **One blob per source video**: the full pose sequence, encoded once
  per `source_id` into `tmp/turnip-pose-<source_id>.tkp1.gz`, reused
  across re-contributions. Deleted on successful upload and by the
  existing orphan sweep at launch (same `tmp/` hygiene as
  `PRIVACY.md`).

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

- **Processing (§2)** — analysis runs as today; proposals land on Clip
  List.
- **Clip List (§3, triage)** — proposals appear as derived clip tiles
  exactly as the heuristic's do today. The "+" tile, trash toggles, and
  read-only timelines are unchanged.
- **Clip Detail / Editor (§4)** — window trimming via the scrub-bar
  handles and crop editing are unchanged; this screen additionally
  hosts the label editor (§4).

### 3.2 Automatic detection, two generations

- **Today**: the heuristic (`MotionSignalBuilder`,
  `TrickWindowDetector` in `Turnip/TrickDetection/`) proposes windows.
- **Later**: the OTA trick model (§7) proposes windows *and* suggested
  names. Both generations surface identically in Clip List; the
  proposal source is not a user-facing distinction.

### 3.3 The confirmation step (new)

Confirmation is the farm boundary: **only confirmed clips + labels are
uploaded; nothing else ever is.** Trashed clips and the original tile
can never be confirmed.

- Each derived tile in Clip List gains a **contribute toggle** (persisted
  in the local clip store, default off). Toggling is per-clip opt-in.
- A **"Contribute N clips"** action in Clip List's toolbar opens a
  confirmation sheet listing the clips with their trick-name chips, the
  payload summary ("pose keypoints, clip windows, labels — video never
  leaves your device"), and a Confirm button. *(Judgment call on
  placement: a sheet keeps the v1 Done/export flow untouched — Done
  saves to Photos, Contribute sends to the farm. The exact affordance
  is UI polish; the boundary semantics are not.)*
- The label editor (§4) requires at least one trick name per contributed
  clip; a clip with no names cannot be confirmed (inline hint in the
  sheet).

### 3.4 `auto_detected` semantics

`auto_detected = true` when the clip's current window originated from
automatic detection (heuristic or trick model); any manual trim of the
window clears it to `false` *(judgment call)*. It is provenance for the
training pipeline, not a user-facing badge.

---

## 4. Label editor

Lives in **Clip Detail / Editor** (`UIUX.md` §4), in a "Trick name"
section below the player and trim controls.

- **Free-text entry.** A text field prompting for the trick name
  (placeholder: "What trick is this? e.g. cork"). Committing adds a
  chip; chips are removable. No fixed vocabulary is enforced — free
  text is the contract.
- **Multiple names per clip.** A clip carries an ordered set of
  trick-name chips. A combo is N chips on one clip — no
  sub-segmentation for MVP, matching the farm's
  `trick_names: [...]` / `is_combo` contract. The UI may render a
  "combo" badge when chips > 1; it is cosmetic only.
- **Taxonomy assist.** As the user types, the editor suggests canonical
  names from the vocabulary in the last fetched model manifest
  (`GET /api/models/current` → `vocabulary: [{canonical,
  aliases[]}]`). Picking a suggestion stores the canonical name;
  free-typing stores the raw string. Both are preserved; the farm's
  `label_taxonomy` curates later.
- **`taxonomy_version`.** Stamped server-side at contribution time
  from the farm's current taxonomy — the farm is the authority on which
  vocabulary was in effect when the label landed. The client does not
  send it; it may keep the manifest's version locally for display only.
- **Per-label windows deferred.** The farm schema allows
  `labels.start_frame/end_frame` to tighten a clip window; MVP does not
  expose this — labels inherit the clip window and the fields stay null
  *(judgment call; the API already supports it if a later UI wants it).*

The iOS API payload per clip is `{clip_id, start_frame, end_frame,
auto_detected, labels: ["cork", ...]}` regardless of how the farm
chooses to store the one-to-many Clip → Label relationship (N label
rows vs. one row with `TEXT[]` is `DATABASE_DESIGN.md`'s call; the
wire shape is unchanged either way).

---

## 5. Contribution upload

### 5.1 Payload and endpoints

On Confirm (per-clip opt-in, §3.3), with Sign in with Apple session
(the v1 export flow stays anonymous; contribution is the first
authenticated action — the sheet prompts sign-in when needed):

1. `POST /api/sources` with `{video_id, frame_count, sample_rate,
   keypoint_format: "tkp1", sha256}` → `{source_id, r2_key,
   upload_url, upload_expires_at, blob_present}`.
   - `frame_count` / `start_frame` / `end_frame` are indices into the
     **canonical 10 Hz** sequence. The client maps its analysis-rate
     indices through the TKP1 §6 resampling map — the same mapping §7.2
     uses to display inference segments — so storage, validation,
     training, and model output all share one coordinate space.
2. `PUT` the TKP1 blob to `upload_url` (full source pose sequence,
   once per `source_id`; skipped when `blob_present` is true).
3. `POST /api/clips` with `{clips: [{clip_id, source_id,
   start_frame, end_frame, auto_detected, labels: [...]}]}` — batch
   upsert. The farm verifies the blob SHA-256, upserts the clips, and
   replaces each clip's label set atomically.
   - `clip_id` is a UUIDv4 minted once per clip at creation (derived
     tile or "+" tile), persisted in the local clip store, reused on
     every re-contribution, and recovered from the server after
     reinstall (§6).

Label-only edits later use `POST /api/clips/:id/labels` — no blob
re-upload.

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
  blob PUT first, then `POST /api/sources`.
- If the blob PUT succeeded but the POST failed, retry the POST alone —
  the farm dedups the blob by its SHA-256, so a repeated PUT is
  harmless but unnecessary.
- **Re-contribution dedups by construction**: the deterministic
  `video_id` means contributing the same video twice upserts the same
  source row — never duplicate training data.
- **Known gap**: there is no per-clip server delete in the farm API.
  Trashing a clip locally *after* contributing leaves the server copy
  in place; only `DELETE /api/sources/:id` (whole source) exists.
  Whether the farm should add `DELETE /api/clips/:id` is an open
  question for the farm API doc.

---

## 6. Reinstall reconciliation

### 6.1 Flow

On fresh install — auto-run once after Photos permission is granted,
plus a "Restore contributions" row in Settings for later:

1. Enumerate video `PHAsset`s (respecting limited-access grants) and
   recompute `source_id` per §1.1.
2. `GET /api/sources` — list my sources (id, frame_count, clip/label
   counts, updated_at). Match by ID.
3. For each match, `GET /api/sources/:id` — pull confirmed clips +
   labels and **adopt the server's clip IDs** into the rebuilt local
   store (clip IDs are recovered, never recomputed).
4. Rebuild local clip state (windows + labels). If the video is still
   in the library, pose can be re-derived locally on demand; if not,
   skeleton previews render from the pose blob via
   `GET /api/sources/:id/pose` (owner-only presigned R2 GET) —
   keypoints straight to screen, no video needed.

Sign-in is required throughout (all endpoints are owner-scoped).

### 6.2 Videos deleted from the library

Their server data stays — it remains valid training data. The client
cannot relink what it cannot see. *(Judgment call: the reconciliation
UI lists matched sources normally, and groups unmatched server sources
under "no longer on this device" with clip/label counts and a
delete-from-server action (`DELETE /api/sources/:id`).)*

### 6.3 Multi-device

Same Apple account on a second device runs the same flow; clips and
labels restore, the video stays behind (master plan open question #2 —
accepted for v1).

---

## 7. OTA trick model

### 7.1 Delivery (extends the existing OTA path)

`Turnip/ModelUpdates/` already ships a manifest client, a version store
with atomic replace, and launch/foreground polling (PR #117). The trick
model rides the same mechanism: `GET /api/models/current` returns the
trick-detection manifest — version, URL, checksum,
`taxonomy_version`, and the `vocabulary` list. Download via background
`URLSession`, verify SHA-256 against the manifest, atomic-replace into
the version store; activate only after verification. The heuristic
detector remains the offline fallback when no model is present (first
launch, failed download) — the UI never distinguishes proposal sources.

### 7.2 On-device inference integration

- **Input**: the TKP1 pose sequence the pipeline already produced —
  no re-decode, no second inference pass over video.
- **Model**: Core ML (exported via `coremltools` per the master plan),
  run once per analysis on the existing background queue (not per
  frame; thermal cost is bounded by construction).
- **Output** (`MODEL_CONTRACT.md` authority): segments in
  **source-frame coordinates** (canonical 10 Hz indices) with
  `trick_names` and `is_combo`.
- **Mapping to the UI**: convert segment frames → seconds at canonical
  10 Hz, then onto the local analysis-rate timeline for Clip List tiles
  *(judgment call)*. Suggested names arrive as **pre-filled chips** in
  the label editor — editable and removable. **Labels are never
  auto-confirmed**: a proposed name still requires the user's Confirm
  (§3.3) before anything is uploaded.
- The manifest's `vocabulary` feeds the label editor's suggestions
  (§4); the manifest's `taxonomy_version` is what labels record at
  label time.

---

## 8. Privacy notes

Consistent with `docs/PRIVACY.md` (which remains the App Store
submission source; `site/privacy.html` must be updated in step with any
change here):

**Never leaves the device** — video pixels, audio, location,
photo-library identifiers (the raw `localIdentifier` — only its
one-way SHA-256 derivative, the `video_id`, ever leaves), device
identifiers, contacts, thumbnails, the video file itself.

**Leaves only on explicit per-clip opt-in** (the Contribute
confirmation, §3.3):
- `video_id` — opaque deterministic ID (§1)
- TKP1 pose keypoint sequence — stick figures, no face, no background,
  no identity (residual honesty per the master plan: gait-from-keypoints
  re-identification is real research; minimization is the mitigation)
- confirmed clip windows + free-text trick names
- Sign in with Apple subject — per-app opaque pseudonym, for
  attribution and quarantine

**Local hygiene** (extends `PRIVACY.md`'s temp-file rules):
`tmp/turnip-pose-<source_id>.tkp1.gz` blobs are deleted after upload
and swept at launch like other `tmp/` artifacts; thumbnails stay
in-memory only; nothing is written to `Documents/`.

**Submission-time consequences** (open question): the v1 "Data Not
Collected" nutrition label changes the moment contribution ships. The
new disclosures must cover the Apple `sub` identifier and the pose
keypoints; the precise App Store label taxonomy for pose keypoints
needs a call at submission time. `ITSAppUsesNonExemptEncryption` stays
`NO` (HTTPS only, exempt).

---

## 9. Relationship to DESIGN.md

Per master plan §8, this doc records the following deltas against
`docs/DESIGN.md` (Rev 8) without rewriting that file:

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
   `Turnip/ModelUpdates/` machinery and PR #117's launch/foreground
   polling are the delivery path; the old "pose+action model" language
   is retired.
6. **Clip editor / labeling** → the label editor lives in the clip
   confirmation flow (§3–§4 of this doc). The v2 "Labeling UI" section
   (server pending-queue tab) is superseded — labeling happens
   on-device by the clip owner.
7. **New: video identity** → §1 of this doc; no local ID↔asset mapping
   to lose.
8. **Social feed** → deferred. The Share Sheet already covers sharing;
   the only feed-compatible future is client-rendered skeleton
   previews.
9. **Problem statement** → the community trains *trick detection*, and
   the privacy claim reads "no video pixels ever leave the device" —
   with the honest footnote that pose sequences, labels, and the Apple
   `sub` do leave per explicit opt-in.

---

## Open questions (for the maintainer)

1. **Clip → Label cardinality.** The master plan's prose says
   one-to-many at every level; its schema sketch says
   `labels.clip_id UNIQUE` (one label-set row per clip, names in
   `TEXT[]`). The iOS wire shape (`labels: [...]` per clip) is
   identical either way — this doc takes no position beyond that —
   but `DATABASE_DESIGN.md` must resolve it before implementation.
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
6. **Multi-device video gap** (master plan open question #2): clips +
   labels restore cross-device, video stays behind. Accepted for v1?
