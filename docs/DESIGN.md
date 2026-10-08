# Turnip — Tricking Video Auto-Editor + Community Labeling Platform

*Rev 9 · 2026-10-06 · Draft for review.*

*(Rev 1 targeted iOS-only, personal-use. Rev 2 expanded to open-source app + backend + community labeling + continuous ML training. Rev 3 depersonalized for public repo and added the pose-model escalation ladder + motion-signal blur mitigations. Rev 4 swapped GitHub OAuth for Sign in with Apple, added iOS Share Sheet for social-media publishing, and added v2 social features — following relationships + video feed. Rev 5 tightens the Sign in with Apple validation contract (`iss` + `exp` on top of `aud` + signature), adds the videos-side feed indexes, adds a self-follow guard, and pins MoveNet Thunder's quantization variant. Rev 6 resolves the seven open questions into recorded decisions and adds the screen-flow companion doc pointer. Rev 7 records that camera takes run steps 1-3 live during recording and skip the post-recording decode when that covered the take. Rev 8 notes the analysis sample rate is a Settings-screen preference, not a fixed constant, defaulting to the 10/sec this doc otherwise assumes. Rev 9 applies the merged turnip-farm master plan (§8): the backend is rewritten around pose-format blobs (no video upload or storage anywhere), labels become free-text multi-labels with no server crop rects, the ML program is retargeted at trick detection, Decision #2 is reversed and #4 mooted plus a new keypoints-only privacy decision, the two-model OTA story replaces the pose+action language, the label editor moves into the clip confirmation flow (the server labeling queue is dropped), a new video-identity section is added, the social feed is deferred, and the problem statement is restated.)*

*Screen-level flow for the v1 app lives in [`UIUX.md`](UIUX.md). Running the pose pass during recording, rather than after, is designed in [`LIVE_POSE.md`](LIVE_POSE.md).*

## Problem

Someone films their tricking practice on a phone or camera on tripod. A recording session produces one long video with:

- **Idle head**: walk from camera to starting spot, wait for turn (5-60s)
- **The trick**: 1-5s of intense motion (spins, kicks, flips, mid-air rotations)
- **Idle tail**: land, walk back to camera
- **Multiple tricks per recording** is common
- **Wasted frame space** — the trick uses only a subset of the frame

Manually clipping and re-cropping every practice video is tedious enough that most clips never get saved. Automating it makes every practice session archivable in one tap.

The app is open source, and doubles as a **community labeling + continuous training platform**: users can opt in to contribute their confirmed clips with free-text trick names, the labeled pose dataset feeds a continuously-improving trick-detection model, and new model versions ship to the app as over-the-air updates. No video pixels ever leave the device — the farm receives pose keypoint sequences, opaque source IDs, and labels only. (Honest footnote: pose keypoint sequences, labels, and the Apple `sub` do leave per explicit opt-in, and gait-from-keypoints re-identification is real research; storing the minimum viable representation is the mitigation.)

## Product scope

**v1 (personal use)**:
- Auto-clip + auto-crop + multi-trick split (iOS-only, off-the-shelf MoveNet Thunder)
- Preview UI, export to Photos

**v2 (community + backend)**:
- Pose-blob + confirmed-label contribution (in-app); label editor in the clip confirmation flow
- Deterministic video identity + reinstall reconciliation
- User accounts via Sign in with Apple, moderation, reputation, abuse blocking
- iOS Share Sheet integration for one-tap publish to Instagram / TikTok / YouTube Shorts / Photos (in-app social feed deferred — see § "Social — following + feed")
- Backend + database + object storage (pose blobs, never video)
- Continuous trick-detection training pipeline (nightly; runs when 50+ new labels land; fixture-regression quarantine; champion/challenger promote)
- OTA trick-model updates delivered to installed clients

## License

**Apache 2.0** for all repos. Reasons:
1. Matches upstream — MoveNet Thunder, MediaPipe BlazePose, most Core ML tooling all ship Apache 2.0. Zero license-compatibility friction when bundling weights or fine-tuning.
2. Explicit patent grant. Better than MIT for an ML project where a contributor might hold a relevant patent.
3. Contributor-friendly: no viral obligations, commercial forks allowed.

## Repo structure

Three public repos, Apache 2.0:

- **`turnip-ios`** — Swift/SwiftUI iOS app. Bundles MoveNet Thunder TFLite. Handles capture, on-device clip detection, preview UI, export, and (v2) contribution of pose-format keypoints + confirmed clips/labels to the backend training dataset (video never leaves the device).
- **`turnip-farm`** — Bun + TypeScript + Postgres backend. Grows the labeled dataset. Serves pose-blob ingest, confirmed clip/label upserts, user accounts, moderation, quality scoring, dataset export for the training pipeline, and the trick-model manifest. No video anywhere in the stack.
- **`turnip-ml`** — Python + TensorFlow training pipeline. Fetches the labeled pose dataset from turnip-farm, trains the trick-detection model (pose sequence → trick segments + names), evaluates on a held-out set, exports to Core ML, and publishes through the farm's model manifest endpoint that the app polls.

Polyrepo chosen over monorepo because open-source contributors typically only want to touch one layer — an iOS contributor should not have to clone a 5 GB ML checkpoint tree, and vice versa.

## System architecture

### iOS app (`turnip-ios`)

- **Language**: Swift + SwiftUI, min deployment target **iOS 16** (~98% device coverage as of 2026, drops the iOS 14/15 back-compat testing surface). iOS 17+ features (like `VNDetectHumanBodyPose3DRequest` for depth-aware 3D pose) feature-gated via `if #available(iOS 17)`.
- **Pose engine**: MoveNet Thunder (Apache 2.0, ~7 MB TFLite int8 · ~12 MB fp16 · ~24 MB fp32) — pretrained on Google's "Active" dataset (yoga/fitness/dance with high motion + self-occlusion), 84% joint accuracy on the ISBS 2024 gymnastics benchmark. int8 is the default bundle; fp16 is the escalation if accuracy on real footage demands it before the model swap. See "Model escalation ladder" below for the fallback path if empirical testing shows Thunder underperforms.
- **Runtime**: TensorFlow Lite iOS OR Core ML (via coremltools conversion of the TFLite → Core ML). Core ML is preferable for Neural Engine acceleration on A11+ devices.
- **Pipeline** (per input video):
  1. Decode frames at native fps, applying the track's rotation transform
  2. Sample ~10 frames/sec of footage — stride derived from the track's nominal frame rate
     (3 at 30 fps, 24 at 240 fps slo-mo) — scaling each kept frame straight to the model's own
     input size (256x256 for Thunder), letterboxed so the frame's aspect ratio survives
  3. Run pose detection, extract hip-midpoint per frame
  4. Motion signal = frame-to-frame hip displacement, smoothed (3-sample moving average)
  5. Peak detection with sustained-above-threshold logic → list of trick windows
  6. Crop rect = union of 17 keypoints across window (confidence-filtered), expanded 10%, snapped to aspect ratio
  7. Export N clips per input

  See "Interpreting pose output" below for the concrete algorithm turning pose keypoints into `(start_time, end_time)[]` clip ranges and `(min_x, max_x, min_y, max_y)` crop rects.

  For a take recorded in the app, steps 1-3 run on the camera's live frames while it is being
  recorded — a video data output beside the movie output, sampled at the same ~10 frames/sec
  by presentation time, with the skeleton drawn on the preview — and steps 4-6 run on those
  results the moment recording stops, so the take lands on the clip list with no decode of
  the file. A take live inference could not cover end to end (model still loading, thermal
  backoff, shed samples) goes through the file path above like a picked video. Steps 4-6 are
  one implementation for both sources. Design and acceptance gate: [`LIVE_POSE.md`](LIVE_POSE.md).

- **Preview UI**: thumbnail per detected clip, tap-preview, drag-adjust start/end, keep/discard toggles.
- **Contribution** (v2): opt-in per clip. "Contribute to the training dataset" toggle. Uploads the pose-format keypoint sequence plus the confirmed clip windows and free-text trick names to `turnip-farm` — keypoints only, video never leaves the device. The farm upserts on ID match, so re-contribution is safe and idempotent. Full design: [`CONTRIBUTION_DESIGN.md`](CONTRIBUTION_DESIGN.md).
- **OTA model updates**: two models. Bundled MoveNet Thunder does pose detection (unchanged). The trick-detection model arrives over the air: on launch and foreground, poll `GET /api/models/current` for the manifest (version, URL, checksum, `taxonomy_version`, vocabulary); download in background, verify the checksum, atomic-replace. The trick model proposes clip windows *and* trick names; the heuristic detector stays as the offline fallback. (The old "pose+action model" language is retired.)

### Performance targets

Budgets the v1 pipeline is held to (issue #21). The numbers are initial targets to be validated
by on-device profiling on the oldest supported hardware (iPhone 8 / A11, iOS 16).

- **Sample rate**: ~10 frames/sec of footage regardless of source fps, by default. The decode
  stride is `round(nominalFrameRate / sampleRate)`, so 240 fps slo-mo (the recommended
  recording mode) costs the same inferences per second of footage as 30 fps — not 8×. The
  live path keeps the same rate on a presentation-time grid rather than a frame count, since it
  never sees the frames the capture output discards while a kept one is being preprocessed. The
  rate itself (`sampleRate`, and the grid's interval, both `1 / sampleRate`) is the Settings
  screen's analysis granularity (`docs/UIUX.md` §1a), 1-30, defaulting to the 10 assumed
  throughout the rest of this section.
- **Live inference budget**: one inference must fit inside the sample interval (100 ms at the
  default rate) with the queue between capture and model sitting near empty; the encoder is
  hardware and the model is CPU, so the two do not contend for the GPU. The per-recording
  metrics (samples/sec, queue drops, max queue depth, preprocess and inference times, seconds
  under thermal `.serious`) go to the device log under the `LivePose` category.
- **Cancellation**: the sampler loop checks `Task.isCancelled` per decoded frame, and the owning
  view model cancels its run task when the screen goes away, so an abandoned run stops decoding
  instead of burning the device with no consumer.

### Interpreting pose output

Pose detection gives us, per processed frame, 17 keypoints — each `{x, y, confidence}` with x/y normalized 0-1 relative to the source frame (nominally — a keypoint landing in the letterbox pad region honestly reports a value outside [0, 1] instead of being clamped to the edge). Turning that into concrete clip ranges and crop rects:

**Step 4 (motion signal):** collapse 17 points per frame into one anchor via **hip midpoint** = average of `left_hip` and `right_hip`. Frame-to-frame displacement is `sqrt((hip_x[t] − hip_x[t−1])² + (hip_y[t] − hip_y[t−1])²)`. Smooth with a 3-sample moving average to kill per-frame confidence jitter.

**Step 5 (peak detection):** given the 1D `motion[t]` time-series, identify sustained peaks:
- Threshold at ≈ 0.05 normalized units per sample at the default 10 samples/sec rate (roughly —
  the achieved rate is quantized to the source fps' nearest whole-frame stride, so it can differ
  slightly from the configured one) — `motion[t]` is a per-sample-pair *positional* delta, not a
  velocity, so above the default rate this threshold scales down as Settings' granularity rises:
  unscaled, a higher sample rate would silently raise the effective speed a trick needs to clear
  the bar, since the same real motion covers less ground between denser samples. Below the
  default rate the threshold stays fixed rather than also scaling up, unlike the sample counts
  below — real trick footage doesn't reliably clear the larger per-sample displacement a
  symmetric scale-up would demand
- Require ≥ 3 consecutive samples above threshold (≥ 300 ms of sustained motion — filters out one-frame anomalies)
- Require ≥ 10 samples of quiet between peaks (≥ 1 s — prevents splitting one trick into two)
- Merge peaks within the minimum gap; expand each window by a 1 s leading buffer and a 3 s trailing buffer — the motion signal reads quiet as soon as the athlete's translation slows on landing, which is consistently earlier than the trick visually reads as complete, so the trailing edge needs more room than the leading edge

Output: list of `(start_time, end_time)` in seconds.

**Step 6 (crop rect):** for each trick window, compute the tightest rect containing the athlete across the whole window:
- Per-frame bounding box = min/max of confidence-filtered (`> 0.3`) keypoints
- Union across all frames in the window
- Grow a box smaller than 5% of the rendered frame's shorter axis around its own center: a one-keypoint or tight-cluster window is not a located athlete, and without the floor it collapses to a zero-area (or near-zero-area) rect the export then upscales to the full output size
- Expand 10% each side: the keypoints are joints, so the box stops at the eyes, wrists and ankles, and a tenth reaches the top of the head, the hands and the feet with a little air (25% framed the athlete loosely enough to read as the crop missing them)
- Snap to target aspect ratio (9:16 for Reels default): grow the shorter axis around the box center. The ratio is measured on the box's *pixel* size, not its normalized size — a normalized unit is a fraction of its own axis, so a normalized 9:16 rect on a 1080x1920 source is 9:16 twice over
- Keypoints the model places past the frame's edge count as on the edge: the crop can't show them anyway, and they would pull the box out past the frame
- Slide back inside `[0, 1]` if expansion pushes past a frame edge, which keeps the ratio; an axis longer than the frame first shrinks the rect uniformly about its center until it fits, then slides. The rect is always the target ratio — the editor's fixed crop marker and the export's output size both rely on that — and it never reaches past the frame: the crop shows video in every part of it (UIUX.md § "Clip Detail / Editor"), so an athlete crossing more of a landscape frame than a 9:16 crop of its height can hold is cut rather than letterboxed
- Denormalize by multiplying by source video's pixel dimensions → final `(min_x, max_x, min_y, max_y)`

Static crop (one rect per clip) is Rev 1's choice — simpler, works well when the athlete stays roughly in one area. Dynamic crop (Ken Burns-style, rect changes per frame) is a v2 nice-to-have.

Everything above is ~150 lines of Swift on top of the pose output. The pose model does the heavy lifting; this code just interprets it.

Steps 4, 5 and 6 are implemented in `Turnip/TrickDetection/` as `MotionSignalBuilder`, `TrickWindowDetector` and `CropRectCalculator`, each with a test file under `TurnipTests/`. The types are library code and not yet driven by a screen, so start from them rather than from the prose above.

### Model escalation ladder

MoveNet Thunder is the MVP pick because it's the leanest option with independent evidence on acrobatic footage (84% joint accuracy on the ISBS 2024 gymnastics study). If empirical testing on real tricking footage shows it underperforms (< 70% frames with usable pose during aerial phases), escalate in this order:

1. **MediaPipe BlazePose Heavy** (Apache 2.0, ~29 MB, 33 keypoints incl. feet) — MediaPipe iOS SDK, no conversion. Google's benchmarks: 96.4% PCK on yoga, 97.2% on dance. Larger than Thunder but purpose-built for fitness/dance/yoga.
2. **Fine-tune Thunder on tricking data** — collect 200-500 labeled clips (~4-6 hours of labeling), fine-tune the pretrained weights. The AthletePose3D paper (CVPRW 2025) found sports-specific fine-tuning cuts pose error > 69%. Same 7 MB bundle, better accuracy on the target distribution.
3. **RTMPose-m** (Apache 2.0, ~27 MB fp16) — best raw accuracy per FLOP (75.8 AP on COCO). No sports pretraining, so pair with fine-tuning if used. Needs a bundled person detector (RTMDet-nano, also Apache).
4. **ViTPose or PoseC3D** — SOTA family but larger. Reach for these only if the top three fail. PoseC3D fine-tuned on FineGym is 2 M params and 93.5% mean top-1 across 99 gymnastics classes — the natural bridge to v2's automatic trick classification.

**Escalation trigger**: the 2-hour Swift-playground empirical test on 5-10 representative recordings, measuring per-frame pose confidence + keypoint count during the aerial phase of each trick.

**Standing note (Rev 9):** the ladder now guards pose *input quality* for the trick-detection model, not the pose model as an end in itself. Fine-tuning MoveNet is off the table unless this ladder fires on the empirical trigger above — the ML program trains trick detection on whatever pose the (possibly escalated) detector emits.

### Motion signal robustness on blurry frames

Fast acrobatic motion produces motion-blurred frames (a body spinning at 720°/s smears ~24° across a 33 ms exposure at 30 fps). Pose models degrade gracefully on blur — they still emit `(x, y, confidence)` for each keypoint, but confidence drops and some keypoints may be missing.

The pipeline handles this at multiple layers:

1. **Confidence filtering** — drop keypoints with `confidence < 0.3` before averaging. If both hips fail on frame t, mark that frame as a gap in the motion series.
2. **Interpolation across single-frame gaps** — if frame t has no hip but frames t-1 and t+1 do, estimate `hip[t] = (hip[t-1] + hip[t+1]) / 2`.
3. **Fallback anchor keypoint** — if hips fail but shoulders / nose / torso survive (bigger targets, more resistant to blur), use their midpoint instead.
4. **Optical-flow fallback** — `VNGenerateOpticalFlowRequest` returns per-pixel motion magnitude between two frames with no pose needed. On frames where pose fails entirely, substitute optical-flow magnitude for the motion signal.
5. **3-sample moving average** — a single-frame dropout is 33 ms at 30 fps; surrounding frames still carry the signal.
6. **Peak-detection sustained-above-threshold logic** — requires ≥ 300 ms of high motion, so a single-frame anomaly can't create a false peak.
7. **Partial-group anchor reconstruction** — a frame where only part of a keypoint group clears confidence (e.g. one hip lost to blur) reconstructs the full-group midpoint from the most recent full-group frame, at most 3 frames back: the offset between the full midpoint and the usable subset's mean is measured there and applied now, so the anchor stays on the body centerline instead of jumping to the lone point. Past that bound the frame keeps its partial identity and its displacement stays unknown, rather than measuring a fixed body offset as motion.

**Recording-side lever (biggest single improvement)**: default to **240 fps slo-mo mode** on the phone. Exposure is ~4 ms instead of 33 ms → **8× less motion blur per frame**. Pose confidence stays > 0.7 through the aerial phase and mitigations 2-4 rarely need to fire. The app processes at native frame rate (30 or 240) and can export at whichever the user picks. Slo-mo is a shooting-technique change users adopt once and forget, not a per-clip decision.

### Backend (`turnip-farm`)

- **Stack**: Bun + TypeScript + Postgres. Standard modern TypeScript backend.
- **Object storage**: **Cloudflare R2** (S3-compatible, **$0 egress**, $15/TB storage). pose-format blobs (`.tkp1.gz`, ~2 KB/s at 10 Hz) and trained model artifacts live here, not on the droplet FS — the droplet doesn't grow with content volume. No video anywhere: no video bytes in any table, blob, log, or error payload.
- **Auth**: **Sign in with Apple** — iOS-native, one-tap Face ID / Touch ID, no browser bounce. The iOS app sends the Apple identity token as `Authorization: Bearer <token>` on every request; the server verifies it per Apple's server-side validation guidance — signature against Apple's public JWKS (`appleid.apple.com/auth/keys`) with the correct `kid`; `iss == "https://appleid.apple.com"`; `aud` matches the app bundle id; `exp > now` (reject expired / replayed tokens) — and only then creates or looks up a `users` row keyed by the token's `sub` claim. Stateless verification per request (no session cookie). Matches App Store guideline 4.8; no email/password fallback keeps the auth surface minimal. The training pipeline authenticates with a pre-shared service key instead.
- **Endpoints (v2 MVP)** — every write upserts on ID match (the IDs *are* the idempotency keys):
  - **Contribution:**
    - `POST /api/sources` — register a source (`video_id`, `frame_count`, `sample_rate`, `keypoint_format`, `sha256`) → presigned R2 PUT URL for the `.tkp1.gz` blob
    - `POST /api/clips` — batch upsert clips + replace their label sets (blob SHA-256 verified server-side)
    - `POST /api/clips/:id/labels` — label-only update (re-label without re-uploading)
  - **Reconciliation + owner reads:**
    - `GET /api/sources` — list my sources (id, frame_count, clip/label counts) for the reinstall reconciliation UI
    - `GET /api/sources/:id` — source with its confirmed clips + labels
    - `GET /api/sources/:id/pose` — owner-only presigned R2 GET of the pose-format blob (skeleton restore on a device without the video)
    - `DELETE /api/sources/:id` — owner-only hard delete (row + R2 blob); the retention policy is "keep forever, user-deletable" (see § "Decisions" #4)
  - **Models:**
    - `GET /api/models/current` — trick-model manifest (version, URL, checksum, `taxonomy_version`, vocabulary)
    - `POST /api/models` — training pipeline publishes the champion (service-key scoped)
  - **Training + moderation:**
    - `GET /api/labels/export?since=` — training pipeline pull (labels + pose blob refs; excludes quarantined sources)
    - `POST /api/reports` — report a bad label/clip
  - Dropped from earlier drafts: `GET /api/labels/pending` — there is no labeling queue; labeling happens on-device by the clip owner.
- **Database schema (v2, additive-only)** — full design in `turnip-farm`'s `BACKEND_DESIGN.md`:
  - `users` — id (Apple `sub`, TEXT PK — no name, no email), reputation, is_blocked, created_at
  - `sources` — id CHAR(64) (deterministic SHA-256 hex `video_id`, PK), user_id FK, frame_count (canonical 10 Hz), sample_rate (as-sent, provenance), keypoint_format, r2_key (`poses/<id>.tkp1.gz`), sha256 (blob integrity)
  - `clips` — id UUID (client-minted once, PK), source_id FK, start_frame, end_frame (canonical 10 Hz indices), auto_detected
  - `labels` — id, clip_id FK, trick_name (free text), taxonomy_version — one row per (clip, trick name); re-submission replaces the clip's whole label set in one transaction
  - `label_taxonomy` — raw → canonical mapping, taxonomy_version (monotonic int)
  - `models` — id, version, model_type (`trick-detection`), taxonomy_version, r2_key, sha256, val_metrics (JSONB), promoted_at
  - `data_quarantine` — id, source_id FK, user_id FK (attribution), reason, metrics (JSONB), quarantined_at, resolved_at, resolution (`released` | `purged`)
  - `reports` — id, reporter_user_id, target_type (`source` | `clip` | `label`), target_id, reason, status
  - No `videos` table, no `follows` table, no thumbnails, no PII columns.
- **Migrations**: `dbmate` from day 1. Numbered SQL files, forward-only, additive-first. Never drop a column in the same PR that stops writing to it — two PRs.

### Video identity

The farm never mints source identities. Every contribution references a `source_id` the device derives deterministically, so the ID survives app reinstalls and re-contributing the same video upserts instead of duplicating training data:

- **Photos-backed videos** (gallery picks and in-app camera takes, which are saved to Photos): `source_id = SHA-256 hex of ("turnip:phasset:" + PHAsset.localIdentifier)`. The `localIdentifier` belongs to the Photos library, not the app, so it is stable across reinstalls. The raw identifier never leaves the device — only its one-way digest.
- **Imported files** (document-picker / Files-app imports with no `PHAsset`): `source_id = SHA-256 hex of the file bytes`.

No local ID↔asset mapping to lose: the ID is recomputed on demand, which is the whole point.

**Reinstall reconciliation:** on a fresh install, enumerate the Photos library → recompute `source_id`s → `GET /api/sources` (list my sources) → `GET /api/sources/:id` (pull confirmed clips + labels) → adopt the server's clip IDs into the rebuilt local state. (`clip_id`s are client-minted UUIDv4 once per clip — recovered from the server, never re-derived.) Videos deleted from the library stay on the farm as training data; the client cannot relink what it cannot see. Full design: [`CONTRIBUTION_DESIGN.md`](CONTRIBUTION_DESIGN.md) §1 and §6.

### Label editor (in the clip confirmation flow)

Labeling lives inside the iOS app, in the Clip Detail / Editor screen — there is no server labeling queue and no `GET /api/labels/pending`:

1. The user is prompted for the trick name — a free-text field ("What trick is this? e.g. cork"). Committing adds a chip; chips are removable. No fixed vocabulary is enforced.
2. A clip carries multiple trick-name chips (a combo is N chips on one clip — no sub-segmentation for MVP). The editor suggests canonical names from the vocabulary in the latest trick-model manifest as the user types; picking a suggestion stores the canonical name, free-typing stores the raw string.
3. Labels inherit the clip window (labeler-settable via the existing trim handles); the farm stores one label row per (clip, trick name).
4. A clip with no trick names cannot be contributed. The Contribute confirmation sheet lists each clip with its name chips; only confirmed clips + labels are uploaded — proposals are never auto-confirmed.

Full design: [`CONTRIBUTION_DESIGN.md`](CONTRIBUTION_DESIGN.md) §4. Web labeling UI remains out of scope — iOS-only keeps the surface small.

### Publishing to social media (iOS Share Sheet)

Every exported clip has a "Share" button that opens the native iOS share sheet — `UIActivityViewController` (or SwiftUI's `ShareLink` on iOS 16+). Turnip hands the file URL to the system; iOS enumerates every installed app that accepts a video and the user picks the destination — Instagram, TikTok, YouTube (via Photos → Shorts), Messages, Photos, AirDrop, etc. When Instagram is selected, Instagram's own picker offers Reel / Post / Story.

**Zero server involvement in the share flow.** No OAuth, no per-platform integration, no CDN staging — the video is on the device, the OS moves it to the target app.

**Why not a direct server-side publish flow to Instagram (Instagram Graph API)?**

Meta's content-publishing endpoints only accept **Business or Creator** accounts — personal Instagram accounts cannot be posted to via any official API in 2026 (the Basic Display API that once supported them is deprecated). Even for eligible accounts, the flow requires a Meta App Review approval for the `instagram_content_publish` permission (weeks-long) plus per-user OAuth plumbing. That buys a half-tap UX improvement over the Share Sheet for the subset of users on professional accounts. Not worth the surface. The Share Sheet works for every account type on every target with zero server work.

### Social — following + feed: deferred

The in-app social feed is **deferred**, explicitly. A server video feed cannot exist without server video: the privacy contract (§ "Decisions" #8, master plan §1) means the farm never holds footage to serve, so the `follows` table and the feed endpoints described in earlier revisions are removed, not postponed.

What stays: the iOS Share Sheet integration (§ "Publishing to social media") already covers one-tap publishing to Instagram / TikTok / YouTube Shorts / Photos with zero server involvement — that is the social story for v2. The only feed-compatible future is client-rendered skeleton previews: keypoint sequences re-animated on-device from pose-format blobs, no pixels involved. Revisit when and if a concrete product need demands it.

### ML pipeline (`turnip-ml`)

- **Language**: Python + TensorFlow + `coremltools` for export.
- **Task**: trick detection + naming. Input: pose key sequence (`T × 17 × 3`, canonical 10 Hz pose format). Output per source: trick segments in source-frame coordinates, each with `trick_names: [...]` and derived `is_combo` (`len > 1`); a combo is one segment with N names — no sub-segmentation for MVP.
- **Trigger**: cron (nightly) or on-demand via GitHub Actions workflow_dispatch. Only runs if new labels since the last watermark exceed a threshold (start: 50).
- **Steps**:
  1. Fetch the labeled dataset from turnip-farm (`GET /api/labels/export?since=<last>`) — pose blob refs, clip windows, free-text labels. Quarantined sources are excluded by construction.
  2. Resolve the pose-format blobs from R2.
  3. Canonicalize raw label strings via `label_taxonomy` (combo strings like `"hook - scoot - gainer - cartfull (combo)"` split into N canonical names on one window); raw strings are never discarded.
  4. Split 80/10/10 train/val/holdout, stratified by user_id so no user's clips leak across splits (bootstrap guard: unstratified random splits until ~20 contributors or 50 clips per split).
  5. Train the trick-detection candidate — baseline: temporal encoder (dilated TCN or small Transformer) over the keypoint sequence with a segment-proposal head and a per-segment multi-label classification head; sliding-window classifier + NMS is an acceptable MVP.
  6. Evaluate on holdout: segment quality (mAP at tIoU thresholds) **and** name accuracy, reported separately.
  7. **Fixture regression gate (anti-poisoning)**: run the candidate over the fixture suite (pose-accuracy fixtures + trick-labeled fixtures) and compare against the champion. On regression: fire a Discord webhook alert (metrics delta, affected source/user IDs), quarantine that day's ingested sources (`data_quarantine`), and skip promotion.
  8. **Champion/challenger**: promote only if the candidate beats the champion by ≥1% on validation. Otherwise archive and try again next cycle.
  9. Export to Core ML with `coremltools`, upload to R2, call `POST /api/models` with the `taxonomy_version` it trained on. The app picks it up via the OTA poll.
- **Runs where**: same droplet during MVP (Python installed alongside Bun). Move to a separate GPU worker (RunPod / Lambda Labs on-demand, ~$0.50-1/hr) when training time exceeds ~30 min.
- **What stays**: the `PoseAccuracy` harness and CI gate now guard the *input* to the trick model (pose quality on real footage). Fine-tuning MoveNet itself is off the table unless the pose escalation ladder fires on empirical grounds.

### Label quality + abuse

- **Reputation score per user** — starts at 0, +1 per accepted label, -5 per reported+confirmed bad label. Users with reputation ≥ threshold become "trusted" and their labels bypass moderation review.
- **Spot checks** — every Nth label from a non-trusted user is queued for a trusted user to review.
- **Inter-labeler agreement** — ~~v2.5 enhancement: same clip goes to 3 labelers, compare, quality signal = how similar their labels are. Elegant but requires N > 1 labelers per clip so hard at low volume.~~ Superseded (Rev 9): with owner-only labeling there is no second labeler for the same clip; agreement signal replaced by the fixture-regression gate (§ "Data poisoning defense").
- **Abuser blocking** — admin action (`UPDATE users SET is_blocked = true`) revokes upload rights. Automated triggers: N reports in T time, N labels rejected, upload rate spike. All actions logged to `moderation_events` table.
- **Data poisoning defense** — the nightly fixture-regression gate is the primary defense: on regression, that day's ingested sources are quarantined (`data_quarantine`), a Discord alert fires, and promotion is skipped. Never train on quarantined sources, labels from users with reputation < 0, or blocked users. Held-out validation set is admin-curated and never touched by user labels.

## Deployment (DigitalOcean cheapest viable)

**MVP stack**:
- **1× Basic Droplet** — $6/mo (1 GB RAM, 25 GB SSD, 1 TB transfer). Runs turnip-farm (Bun), Postgres, and the ML pipeline (nightly). Nginx/Caddy fronts everything.
- **Cloudflare R2 bucket** — pose-format blobs + trained model artifacts. First 10 GB free, then $0.015/GB/mo storage, **$0 egress**. Two zeros: no bandwidth bill for pose-blob downloads, no bandwidth bill for the app fetching the model.
- **Domain**: ~$15/yr on Namecheap/Porkbun.
- **Managed Postgres** ($15/mo) OR **self-hosted Postgres on the droplet** ($0). Start self-hosted; migrate to managed when you cross 1 GB of DB or 10 QPS sustained.
- **Object storage costs** — pose blobs run ~2 KB/s at the canonical 10 Hz: 100 contributed sessions × ~120 KB ≈ 12 MB → free tier. 10,000 sessions ≈ 1.2 GB → still free tier. 1M sessions ≈ 120 GB ≈ $1.65/mo.
- **Cloudflare in front** — free tier — for the app-facing DNS + basic DDoS + edge caching of static assets.

**MVP total: ~$15-30/mo** depending on Postgres choice and storage volume.

**Scaling seams built in from day 1**:
- **Stateless API** — all state in Postgres + R2. Adding a second droplet behind a load balancer is a config change, not a rewrite.
- **Pose blobs on R2, not the droplet FS** — droplet doesn't grow with content.
- **Managed Postgres upgrade path** — swap the DSN, no schema changes.
- **Background jobs (training) already run out-of-process** — moving to a dedicated GPU worker is one variable change.
- **Migration tool from day 1** — schema changes are additive, forward-only, versioned. Zero-downtime deploys become possible when we care.

**Beyond MVP**:
- DO App Platform ($12/mo for a small autoscale) or fly.io for stateless-API layer
- DO Managed Postgres ($15+/mo cheapest, autoscales up)
- DO Load Balancer ($12/mo) if we ever put 2+ API droplets behind one URL
- Full-time GPU (RunPod A10G ~$0.35/hr = $250/mo if left on 24/7; ~$0/mo if only spun up during training) for ML training

## Continuous migration strategy

- **Tool**: `dbmate` (Go binary, zero-dependency, works well with Postgres). Migration files live in `turnip-farm/db/migrations/NNNN_description.sql` (up + down).
- **Rules**:
  1. Migrations are forward-only in production (no `down` in prod).
  2. Always additive first — new column, new table. Never drop or rename in the same PR that stops writing to the old field.
  3. Two-PR pattern for destructive changes: PR A adds new + double-writes; deploy; verify; PR B drops old.
  4. Migration runs as part of the deploy script, before the API restart.
- **App-schema compatibility**: the API should tolerate its schema being one migration ahead OR behind briefly. During the migration window we're running old code against new schema (that's why additive-first matters).

## Contribution guide surface

Every repo ships (at repo root, standard OSS conventions):
- **`LICENSE`** — Apache 2.0
- **`README.md`** — what the repo is, how to run locally, how to contribute
- **`CONTRIBUTING.md`** — dev setup, PR conventions, review process, coding style
- **`CODE_OF_CONDUCT.md`** — Contributor Covenant 2.1 (standard, widely adopted)
- **`.github/`**:
  - `ISSUE_TEMPLATE/bug.md`, `ISSUE_TEMPLATE/feature.md`
  - `PULL_REQUEST_TEMPLATE.md`
  - `workflows/ci.yml` (lint + build + test on every PR)
  - `workflows/cd.yml` (deploy on push to main — turnip-farm only)
- **`SECURITY.md`** — how to responsibly disclose vulnerabilities
- **`CLA.md`** *(optional, decide upfront)* — do we require contributors to sign a CLA? Apache 2.0's Individual Contributor License Agreement is standard but adds friction; most permissive-license OSS projects skip it.

**Recommendation**: skip the CLA. Apache 2.0's Section 5 already grants the project the necessary license from contributions. CLAs are more common in projects that plan to relicense later or that need corporate contributor rights.

## Cost analysis

### One-time
- Apple Developer Program: $99 (required to publish to App Store; not required for TestFlight or self-install)
- Domain registration: $15
- Design / branding assets: $0 (DIY)

### Recurring
| item | MVP ($/mo) | scale-to-1000-users ($/mo) |
|---|---|---|
| DO droplet (API + self-hosted Postgres + training runner) | 6 | 12-24 |
| Cloudflare R2 (pose blobs + models) | 0-2 | 10-30 |
| Cloudflare DNS + edge (free tier) | 0 | 0 |
| Managed Postgres (optional) | 0 (skip for MVP) | 15 |
| Domain amortized | 1.25 | 1.25 |
| Apple Developer Program amortized | 8.25 | 8.25 |
| **Total** | **~15/mo** | **~50-80/mo** |

R2's $0 egress is what keeps this cheap even as pose-blob and model-download volume grows. AWS S3 would triple the bill at 1000 users due to egress fees.

## Contribution ramp

- **Good first issues** tagged in each repo — small, well-scoped
- **Areas of contribution** documented in each README:
  - iOS: Swift/SwiftUI, AVFoundation, Vision framework, TFLite iOS
  - Backend: TypeScript, Bun, Postgres, Docker
  - ML: Python, TensorFlow, coremltools, model evaluation
- **PR review flow**: reviewer approval; use a small `.github/CODEOWNERS` to auto-request the right reviewer per subdirectory
- **CI on PRs**: lint + build + unit tests. Nothing gates review, but red CI slows merges.

## Decisions (formerly open questions)

Resolved 2026-09-04. Each records the decision, the reason, and the trigger that would reopen it.

1. **Model bundling vs OTA-only → Bundle.** The int8 model is ~7 MB against the App Store's 200 MB cellular download limit, so "saving 7 MB" buys nothing, and OTA-only breaks first launch offline. OTA updates (§ "OTA model updates") layer on top of the bundled model as a replacement path, never a prerequisite. *Reopen if:* the escalation ladder lands on a model > ~50 MB.
2. **Trick classification in v2 → REVERSED 2026-10-06: the detector IS the ML program.** The v2 pipeline trains a trick-detection model (pose sequence → trick segments + names) from the contributed dataset from day one — detection and naming are the program, not a future phase. (Reversal of the Rev 6 decision, per the merged master plan.) *Reopen if:* contribution volume never reaches the training threshold and the program stalls.
3. **Labeling incentive → Reputation score + a "your contributions" stats screen. Defer badges and notifications.** Reputation is already required for moderation (§ "Label quality + abuse"), so surfacing it is free. Badges are a design project with no evidence they're needed at v2 volumes. *Reopen if:* labeling throughput stalls with active users who aren't labeling.
4. **Storage retention → MOOT 2026-10-06: there are no videos to keep.** The farm stores pose-format blobs (~2 KB/s) and labels, never video — 10,000 contributed sessions are ~1.2 GB, still inside R2's free tier. The retention posture transfers to sources: keep forever, user-deletable via `DELETE /api/sources/:id` (owner-only) from day 1. (Mooted by the no-video privacy contract, per the merged master plan.) *Reopen if:* pose-blob storage passes ~1 TB.
5. **Moderation model → Single admin at launch.** The `moderation_events` log and trusted-user spot checks already in § "Label quality + abuse" are the on-ramp. Add a moderator role when the open report queue exceeds what one person clears in a week — a measurable trigger, not a guess.
6. **CLA → Skip.** Decided in issue #4; Apache 2.0 § 5 covers contributions. `CONTRIBUTING.md` already states this.
7. **Analytics → None in v1.** Crash reports and hang/launch metrics come from Xcode Organizer + MetricKit, which are opt-in through iOS's own "Share With App Developers" setting — no SDK, no consent UI, and the "nothing leaves your device" claim in the README stays literally true. If v2 needs product analytics, prefer TelemetryDeck (Swift-native, anonymous signals, no consent prompt) over self-hosted PostHog, which is a full platform to operate on a $6 droplet. *Reopen when:* v2 backend ships and there's a product question only usage data can answer.
8. **Privacy: keypoints + opaque IDs only, never pixels (adopted 2026-10-06).** The farm receives pose keypoint sequences, deterministic source IDs, confirmed clip windows, and labels — never video pixels, audio, location, photo-library identifiers, device identifiers, contacts, or thumbnails. Reopenable only by deliberate product decision, never convenience. (From the merged master plan §1.)

## Empirical test — the first work item

Once this document is agreed, the immediate next step is scaffolding `turnip-ios` with SwiftUI + AVFoundation + TFLite MoveNet Thunder integration, plus a small Swift file that runs pose detection on a sample video from Photos and logs per-frame confidence + keypoint count. That result — pose accuracy during the aerial phase of real tricking clips — is the definitive answer to whether MoveNet Thunder is enough or the escalation ladder needs to fire early.

## Alternatives considered and rejected

- **Monorepo**: raises contribution barrier for OSS contributors. Rejected.
- **AWS S3 for object storage**: $0.09/GB egress kills the economics. Rejected in favor of R2.
- **MIT license**: fine but Apache 2.0's patent grant is worth having for an ML project.
- **Serverless API** (Vercel / Cloudflare Workers): cheap for low traffic but harder to run Postgres migrations against, and the Bun + droplet stack is straightforward to operate at MVP scale. Rejected for MVP; reconsider for scale.
- **Fine-tuning from day 1**: expensive labeling effort + zero validated need until we measure MoveNet Thunder accuracy on real footage. Rejected — start with pretrained, escalate only if empirical testing says otherwise.
- **Web-only labeling UI**: adds a whole frontend surface. iOS-only labeling keeps v2 tight. Add web when a labeler asks for it.
- **GitHub OAuth for authentication**: fine mechanics, but Sign in with Apple is one-tap on iOS, matches App Store guideline 4.8, and doesn't require the user to have a GitHub account. Rejected in favor of Sign in with Apple.
- **Direct server-side Instagram publish** (Instagram Graph API): only works on Business/Creator accounts, requires Meta App Review, adds per-user OAuth plumbing. The iOS Share Sheet delivers the same UX for every account type on every target with zero server work. Rejected.
- **Timeline / feed fan-out cache from day 1**: unnecessary until feed reads become the bottleneck. A well-indexed join + cursor pagination scales past MVP volumes. Rejected as premature; add if measured feed latency demands it.
