# Turnip — Tricking Video Auto-Editor + Community Labeling Platform

*Rev 6 · 2026-09-04 · Draft for review.*

*(Rev 1 targeted iOS-only, personal-use. Rev 2 expanded to open-source app + backend + community labeling + continuous ML training. Rev 3 depersonalized for public repo and added the pose-model escalation ladder + motion-signal blur mitigations. Rev 4 swapped GitHub OAuth for Sign in with Apple, added iOS Share Sheet for social-media publishing, and added v2 social features — following relationships + video feed. Rev 5 tightens the Sign in with Apple validation contract (`iss` + `exp` on top of `aud` + signature), adds the videos-side feed indexes, adds a self-follow guard, and pins MoveNet Thunder's quantization variant. Rev 6 resolves the seven open questions into recorded decisions and adds the screen-flow companion doc pointer.)*

*Screen-level flow for the v1 app lives in [`UIUX.md`](UIUX.md).*

## Problem

Someone films their tricking practice on a phone or camera on tripod. A recording session produces one long video with:

- **Idle head**: walk from camera to starting spot, wait for turn (5-60s)
- **The trick**: 1-5s of intense motion (spins, kicks, flips, mid-air rotations)
- **Idle tail**: land, walk back to camera
- **Multiple tricks per recording** is common
- **Wasted frame space** — the trick uses only a subset of the frame

Manually clipping and re-cropping every practice video is tedious enough that most clips never get saved. Automating it makes every practice session archivable in one tap.

The app is open source, and doubles as a **community labeling + continuous training platform**: users can opt in to publish + label their clips, the labeled dataset feeds a continuously-improving pose+action model, and new model versions ship to the app as over-the-air updates.

## Product scope

**v1 (personal use)**:
- Auto-clip + auto-crop + multi-trick split (iOS-only, off-the-shelf MoveNet Thunder)
- Preview UI, export to Photos

**v2 (community + backend + social)**:
- Video upload + labeling UI (in-app)
- User accounts via Sign in with Apple, moderation, reputation, abuse blocking
- Following relationships + reverse-chronological video feed (in-app social)
- iOS Share Sheet integration for one-tap publish to Instagram / TikTok / YouTube Shorts / Photos
- Backend + database + object storage
- Continuous ML training pipeline (retrain when N new labels land, champion/challenger promote)
- OTA model updates delivered to installed clients

## License

**Apache 2.0** for all repos. Reasons:
1. Matches upstream — MoveNet Thunder, MediaPipe BlazePose, most Core ML tooling all ship Apache 2.0. Zero license-compatibility friction when bundling weights or fine-tuning.
2. Explicit patent grant. Better than MIT for an ML project where a contributor might hold a relevant patent.
3. Contributor-friendly: no viral obligations, commercial forks allowed.

## Repo structure

Three public repos, Apache 2.0:

- **`turnip-ios`** — Swift/SwiftUI iOS app. Bundles MoveNet Thunder TFLite. Handles capture, on-device clip detection, preview UI, export, and (v2) upload to the backend for the community dataset.
- **`turnip-farm`** — Bun + TypeScript + Postgres backend. Grows the labeled dataset. Serves video upload, labeling UI (or hosts labeling data for the iOS app to render), user accounts, moderation, quality scoring, and dataset export for the training pipeline.
- **`turnip-ml`** — Python + TensorFlow training pipeline. Fetches labeled dataset from turnip-farm, fine-tunes MoveNet Thunder (or the current champion), evaluates on a held-out set, exports to Core ML, uploads to the model CDN endpoint the app polls.

Polyrepo chosen over monorepo because open-source contributors typically only want to touch one layer — an iOS contributor should not have to clone a 5 GB ML checkpoint tree, and vice versa.

## System architecture

### iOS app (`turnip-ios`)

- **Language**: Swift + SwiftUI, min deployment target **iOS 16** (~98% device coverage as of 2026, drops the iOS 14/15 back-compat testing surface). iOS 17+ features (like `VNDetectHumanBodyPose3DRequest` for depth-aware 3D pose) feature-gated via `if #available(iOS 17)`.
- **Pose engine**: MoveNet Thunder (Apache 2.0, ~7 MB TFLite int8 · ~12 MB fp16 · ~24 MB fp32) — pretrained on Google's "Active" dataset (yoga/fitness/dance with high motion + self-occlusion), 84% joint accuracy on the ISBS 2024 gymnastics benchmark. int8 is the default bundle; fp16 is the escalation if accuracy on real footage demands it before the model swap. See "Model escalation ladder" below for the fallback path if empirical testing shows Thunder underperforms.
- **Runtime**: TensorFlow Lite iOS OR Core ML (via coremltools conversion of the TFLite → Core ML). Core ML is preferable for Neural Engine acceleration on A11+ devices.
- **Pipeline** (per input video):
  1. Decode frames at native fps, applying the track's rotation transform
  2. Sample ~10 frames/sec of footage — stride derived from the track's nominal frame rate
     (3 at 30 fps, 24 at 240 fps slo-mo) — downsampling each kept frame to 480p
  3. Run pose detection, extract hip-midpoint per frame
  4. Motion signal = frame-to-frame hip displacement, smoothed (3-sample moving average)
  5. Peak detection with sustained-above-threshold logic → list of trick windows
  6. Crop rect = union of 17 keypoints across window (confidence-filtered), expanded 25%, snapped to aspect ratio
  7. Export N clips per input

  See "Interpreting pose output" below for the concrete algorithm turning pose keypoints into `(start_time, end_time)[]` clip ranges and `(min_x, max_x, min_y, max_y)` crop rects.

### Performance targets

Budgets the v1 pipeline is held to (issue #21). The numbers are initial targets to be validated
by on-device profiling on the oldest supported hardware (iPhone 8 / A11, iOS 16).

- **Sample rate**: ~10 frames/sec of footage regardless of source fps. The decode stride is
  `round(nominalFrameRate / 10)`, so 240 fps slo-mo (the recommended recording mode) costs the
  same inferences per second of footage as 30 fps — not 8×.
- **Cancellation**: the sampler loop checks `Task.isCancelled` per decoded frame, and the owning
  view model cancels its run task when the screen goes away, so an abandoned run stops decoding
  instead of burning the device with no consumer.
- **Preview UI**: thumbnail per detected clip, tap-preview, drag-adjust start/end, keep/discard toggles.
- **Optional upload** (v2): opt-in per clip. "Send this to the community dataset for labeling" toggle. Uploads to `turnip-farm` with the auto-detected labels (window, crop rect) as a first-pass suggestion the community can accept/refine.
- **OTA model updates**: on launch, poll `GET /api/models/current` for a new Core ML version; download in background, atomic-replace, use next launch.

### Interpreting pose output

Pose detection gives us, per processed frame, 17 keypoints — each `{x, y, confidence}` with x/y normalized 0-1 relative to the source frame (nominally — a keypoint landing in the letterbox pad region honestly reports a value outside [0, 1] instead of being clamped to the edge). Turning that into concrete clip ranges and crop rects:

**Step 4 (motion signal):** collapse 17 points per frame into one anchor via **hip midpoint** = average of `left_hip` and `right_hip`. Frame-to-frame displacement is `sqrt((hip_x[t] − hip_x[t−1])² + (hip_y[t] − hip_y[t−1])²)`. Smooth with a 3-sample moving average to kill per-frame confidence jitter.

**Step 5 (peak detection):** given the 1D `motion[t]` time-series, identify sustained peaks:
- Threshold at ≈ 0.05 normalized units per sample
- Require ≥ 3 consecutive samples above threshold (≥ 300 ms of sustained motion — filters out one-frame anomalies)
- Require ≥ 10 samples of quiet between peaks (≥ 1 s — prevents splitting one trick into two)
- Merge peaks within the minimum gap; expand each window by ±1 s of buffer

Output: list of `(start_time, end_time)` in seconds.

**Step 6 (crop rect):** for each trick window, compute the tightest rect containing the athlete across the whole window:
- Per-frame bounding box = min/max of confidence-filtered (`> 0.3`) keypoints
- Union across all frames in the window
- Expand 25% each side for breathing room + pose undershoot at edges
- Snap to target aspect ratio (9:16 for Reels default): grow the shorter axis around the box center. The ratio is measured on the box's *pixel* size, not its normalized size — a normalized unit is a fraction of its own axis, so a normalized 9:16 rect on a 1080x1920 source is 9:16 twice over
- Slide back inside `[0, 1]` if expansion pushes past a frame edge, which keeps the ratio; an axis longer than the frame takes the frame's full extent instead and the clip letterboxes on that axis rather than cropping tighter
- Denormalize by multiplying by source video's pixel dimensions → final `(min_x, max_x, min_y, max_y)`

Static crop (one rect per clip) is Rev 1's choice — simpler, works well when the athlete stays roughly in one area. Dynamic crop (Ken Burns-style, rect changes per frame) is a v2 nice-to-have.

Everything above is ~150 lines of Swift on top of the pose output. The pose model does the heavy lifting; this code just interprets it.

### Model escalation ladder

MoveNet Thunder is the MVP pick because it's the leanest option with independent evidence on acrobatic footage (84% joint accuracy on the ISBS 2024 gymnastics study). If empirical testing on real tricking footage shows it underperforms (< 70% frames with usable pose during aerial phases), escalate in this order:

1. **MediaPipe BlazePose Heavy** (Apache 2.0, ~29 MB, 33 keypoints incl. feet) — MediaPipe iOS SDK, no conversion. Google's benchmarks: 96.4% PCK on yoga, 97.2% on dance. Larger than Thunder but purpose-built for fitness/dance/yoga.
2. **Fine-tune Thunder on tricking data** — collect 200-500 labeled clips (~4-6 hours of labeling), fine-tune the pretrained weights. The AthletePose3D paper (CVPRW 2025) found sports-specific fine-tuning cuts pose error > 69%. Same 7 MB bundle, better accuracy on the target distribution.
3. **RTMPose-m** (Apache 2.0, ~27 MB fp16) — best raw accuracy per FLOP (75.8 AP on COCO). No sports pretraining, so pair with fine-tuning if used. Needs a bundled person detector (RTMDet-nano, also Apache).
4. **ViTPose or PoseC3D** — SOTA family but larger. Reach for these only if the top three fail. PoseC3D fine-tuned on FineGym is 2 M params and 93.5% mean top-1 across 99 gymnastics classes — the natural bridge to v2's automatic trick classification.

**Escalation trigger**: the 2-hour Swift-playground empirical test on 5-10 representative recordings, measuring per-frame pose confidence + keypoint count during the aerial phase of each trick.

### Motion signal robustness on blurry frames

Fast acrobatic motion produces motion-blurred frames (a body spinning at 720°/s smears ~24° across a 33 ms exposure at 30 fps). Pose models degrade gracefully on blur — they still emit `(x, y, confidence)` for each keypoint, but confidence drops and some keypoints may be missing.

The pipeline handles this at multiple layers:

1. **Confidence filtering** — drop keypoints with `confidence < 0.3` before averaging. If both hips fail on frame t, mark that frame as a gap in the motion series.
2. **Interpolation across single-frame gaps** — if frame t has no hip but frames t-1 and t+1 do, estimate `hip[t] = (hip[t-1] + hip[t+1]) / 2`.
3. **Fallback anchor keypoint** — if hips fail but shoulders / nose / torso survive (bigger targets, more resistant to blur), use their midpoint instead.
4. **Optical-flow fallback** — `VNGenerateOpticalFlowRequest` returns per-pixel motion magnitude between two frames with no pose needed. On frames where pose fails entirely, substitute optical-flow magnitude for the motion signal.
5. **3-sample moving average** — a single-frame dropout is 33 ms at 30 fps; surrounding frames still carry the signal.
6. **Peak-detection sustained-above-threshold logic** — requires ≥ 300 ms of high motion, so a single-frame anomaly can't create a false peak.

**Recording-side lever (biggest single improvement)**: default to **240 fps slo-mo mode** on the phone. Exposure is ~4 ms instead of 33 ms → **8× less motion blur per frame**. Pose confidence stays > 0.7 through the aerial phase and mitigations 2-4 rarely need to fire. The app processes at native frame rate (30 or 240) and can export at whichever the user picks. Slo-mo is a shooting-technique change users adopt once and forget, not a per-clip decision.

### Backend (`turnip-farm`)

- **Stack**: Bun + TypeScript + Express (or Bun native) + Postgres. Standard modern TypeScript backend.
- **Object storage**: **Cloudflare R2** (S3-compatible, **$0 egress**, $15/TB storage). Videos and models live here, not on the droplet FS — the droplet doesn't grow with content volume.
- **Auth**: **Sign in with Apple** — iOS-native, one-tap Face ID / Touch ID, no browser bounce. iOS app hands the identity token to the backend; server verifies the token per Apple's server-side validation guidance — signature against Apple's public JWKS (`appleid.apple.com/auth/keys`) with the correct `kid`; `iss == "https://appleid.apple.com"`; `aud` matches the app bundle id; `exp > now` (reject expired / replayed tokens); and only then creates or looks up a `users` row keyed by the token's `sub` claim. Session state via signed HTTP-only cookie (`express-session` or Bun's native session helper). Matches App Store guideline 4.8; no email/password fallback keeps the auth surface minimal.
- **Endpoints (v2 MVP)**:
  - **Auth + upload + labels:**
    - `POST /api/auth/apple` — exchange Apple identity token → session cookie
    - `POST /api/videos/upload` — presigned R2 URL, returns video ID
    - `POST /api/videos/:id/labels` — submit label (trick windows + crop rects + trick class if any)
    - `DELETE /api/videos/:id` — owner-only hard delete (row + R2 object); the retention policy is "keep forever, user-deletable" (see § "Decisions" #4)
    - `GET /api/labels/pending` — return N unlabeled clips (for labeling UI)
    - `POST /api/reports` — user reports abuse/bad label
    - `GET /api/models/current` — current Core ML manifest (version, URL, checksum)
    - `POST /api/models` — training pipeline publishes new champion (admin-scoped)
  - **Social — following + feed:**
    - `GET /api/users/:id` — public profile (display name, video count, follower/following counts)
    - `GET /api/users/:id/videos` — cursor-paginated public videos from one user
    - `POST /api/follows/:followee_id` — start following (follower = session user; 400 if `followee_id == session user`, enforced by the table `CHECK` too)
    - `DELETE /api/follows/:followee_id` — unfollow
    - `GET /api/users/:id/followers` — cursor-paginated followers
    - `GET /api/users/:id/following` — cursor-paginated followees
    - `GET /api/feed` — reverse-chronological public videos from users the session user follows, cursor-paginated by `(uploaded_at DESC, video_id)`
- **Database schema (v2, additive-only)**:
  - `users` — id, apple_subject (unique), display_name, reputation, is_blocked, created_at
  - `videos` — id, user_id, r2_key, duration_ms, uploaded_at, moderation_state, visibility (`public` | `private`, default `private`). Indexes: `(user_id, uploaded_at DESC)` for `GET /api/users/:id/videos`, and `(visibility, uploaded_at DESC, id)` — a partial index on `WHERE visibility='public'` — for the feed's index-only scan side of `follows → videos`.
  - `labels` — id, video_id, user_id, trick_windows (JSONB), crop_rects (JSONB), quality_score, created_at
  - `reports` — id, target_type, target_id, reporter_id, reason, created_at, resolved_by
  - `models` — id, version, r2_key, val_metrics (JSONB), promoted_at
  - `follows` — id, follower_id, followee_id, created_at, `UNIQUE (follower_id, followee_id)`, `CHECK (follower_id <> followee_id)` (a user can't follow themselves — the DB refuses it and the endpoint returns 400 rather than silently succeeding). Indexes: `(follower_id, created_at DESC)` for "who I follow" and `(followee_id, created_at DESC)` for "who follows me". No mutual/friend-request semantics — following is public and one-directional.
- **Migrations**: `dbmate` from day 1. Numbered SQL files, forward-only, additive-first. Never drop a column in the same PR that stops writing to it — two PRs.

### Labeling UI

Lives inside the iOS app (v2) — a Labeling tab that:
1. Fetches a pending clip from `GET /api/labels/pending`
2. Plays the clip, lets user drag start/end handles, adjust the crop rect, optionally tag the trick class
3. Submits back to `POST /api/videos/:id/labels`

Web labeling UI is out of scope for MVP — iOS-only keeps the surface small. A web UI can be added as a `turnip-web` repo later if desktop labelers want in.

### Publishing to social media (iOS Share Sheet)

Every exported clip has a "Share" button that opens the native iOS share sheet — `UIActivityViewController` (or SwiftUI's `ShareLink` on iOS 16+). Turnip hands the file URL to the system; iOS enumerates every installed app that accepts a video and the user picks the destination — Instagram, TikTok, YouTube (via Photos → Shorts), Messages, Photos, AirDrop, etc. When Instagram is selected, Instagram's own picker offers Reel / Post / Story.

**Zero server involvement in the share flow.** No OAuth, no per-platform integration, no CDN staging — the video is on the device, the OS moves it to the target app.

**Why not a direct server-side publish flow to Instagram (Instagram Graph API)?**

Meta's content-publishing endpoints only accept **Business or Creator** accounts — personal Instagram accounts cannot be posted to via any official API in 2026 (the Basic Display API that once supported them is deprecated). Even for eligible accounts, the flow requires a Meta App Review approval for the `instagram_content_publish` permission (weeks-long) plus per-user OAuth plumbing. That buys a half-tap UX improvement over the Share Sheet for the subset of users on professional accounts. Not worth the surface. The Share Sheet works for every account type on every target with zero server work.

### Social — following + feed

The follows table + feed endpoints described above form a lightweight social layer on top of the labeled-clip corpus:

- **Follows** is a plain join table. Following is public, one-directional, no friend-request handshake.
- **`GET /api/feed`** joins `follows` → `videos` where `visibility='public'`, ordered by `(uploaded_at DESC, video_id)` for stable cursor pagination under concurrent uploads.
- **Video visibility** defaults to `private`; the exporter picks whether each clip goes public before it can appear in a feed. Community labeling is orthogonal — a `public` video is feed-eligible; the "opt in to community dataset" toggle is per-clip and independent of visibility.
- **Tenant boundary**: every video-read query is scoped to `visibility='public' OR user_id = $session_user`. Followee list is public; the followee cannot enumerate their own followers outside the `/followers` endpoint the system exposes. Blocked users don't appear in feed or profile queries.
- **No fan-out on write.** No timeline caches. One indexed join + `LIMIT N` handles the feed read. When feed load exceeds what a single query serves, add a fan-out cache — never before.

### ML pipeline (`turnip-ml`)

- **Language**: Python + TensorFlow + `coremltools` for export.
- **Trigger**: cron (nightly) or on-demand via GitHub Actions workflow_dispatch. Only runs if `SELECT COUNT(*) FROM labels WHERE created_at > last_train_at` exceeds a threshold (say 50).
- **Steps**:
  1. Fetch labeled dataset from turnip-farm (`GET /api/labels/export?since=<last>`)
  2. Fetch corresponding videos from R2
  3. Split 80/10/10 train/val/holdout (stratified by user_id so no user's clips leak across splits)
  4. Fine-tune MoveNet Thunder or the current champion
  5. Evaluate on holdout: PCK, joint-detection rate, clip-detection precision/recall
  6. **Champion/challenger**: only promote new model if it beats current champion by ≥1% on validation. Otherwise archive and try again next cycle
  7. Export to Core ML with `coremltools.convert(...)`, quantize to fp16
  8. Upload to R2, call `POST /api/models` to publish
- **Runs where**: same droplet during MVP (Python installed alongside Bun). Move to a separate GPU worker (RunPod / Lambda Labs on-demand, ~$0.50-1/hr) when training time exceeds ~30 min.

### Label quality + abuse

- **Reputation score per user** — starts at 0, +1 per accepted label, -5 per reported+confirmed bad label. Users with reputation ≥ threshold become "trusted" and their labels bypass moderation review.
- **Spot checks** — every Nth label from a non-trusted user is queued for a trusted user to review.
- **Inter-labeler agreement** — v2.5 enhancement: same clip goes to 3 labelers, compare, quality signal = how similar their labels are. Elegant but requires N > 1 labelers per clip so hard at low volume.
- **Abuser blocking** — admin action (`UPDATE users SET is_blocked = true`) revokes upload rights. Automated triggers: N reports in T time, N labels rejected, upload rate spike. All actions logged to `moderation_events` table.
- **Data poisoning defense** — never train on labels from users with reputation < 0 or blocked. Held-out validation set is admin-curated and never touched by user labels.

## Deployment (DigitalOcean cheapest viable)

**MVP stack**:
- **1× Basic Droplet** — $6/mo (1 GB RAM, 25 GB SSD, 1 TB transfer). Runs turnip-farm (Bun), Postgres, and the ML pipeline (nightly). Nginx/Caddy fronts everything.
- **Cloudflare R2 bucket** — videos + trained model artifacts. First 10 GB free, then $0.015/GB/mo storage, **$0 egress**. Two zeros: no bandwidth bill for video downloads, no bandwidth bill for the app fetching the model.
- **Domain**: ~$15/yr on Namecheap/Porkbun.
- **Managed Postgres** ($15/mo) OR **self-hosted Postgres on the droplet** ($0). Start self-hosted; migrate to managed when you cross 1 GB of DB or 10 QPS sustained.
- **Object storage costs** — 100 videos × 100 MB = 10 GB → free tier. 1000 videos = $1.50/mo. 10 000 videos = $15/mo.
- **Cloudflare in front** — free tier — for the app-facing DNS + basic DDoS + edge caching of static assets.

**MVP total: ~$15-30/mo** depending on Postgres choice and video volume.

**Scaling seams built in from day 1**:
- **Stateless API** — all state in Postgres + R2. Adding a second droplet behind a load balancer is a config change, not a rewrite.
- **Videos on R2, not the droplet FS** — droplet doesn't grow with content.
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
| Cloudflare R2 (video + models) | 0-2 | 10-30 |
| Cloudflare DNS + edge (free tier) | 0 | 0 |
| Managed Postgres (optional) | 0 (skip for MVP) | 15 |
| Domain amortized | 1.25 | 1.25 |
| Apple Developer Program amortized | 8.25 | 8.25 |
| **Total** | **~15/mo** | **~50-80/mo** |

R2's $0 egress is what keeps this cheap even as video volume grows. AWS S3 would triple the bill at 1000 users due to egress fees.

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
2. **Trick classification in v2 → No classifier at launch, but capture the field from day 1.** The `labels` table already carries an optional trick class; expose it in the labeling UI as an optional free-text/enum tag so training data accrues from the first label. Train a classifier (PoseC3D-FineGym starting point) only once there's volume to train on. Zero ML cost now, no data lost.
3. **Labeling incentive → Reputation score + a "your contributions" stats screen. Defer badges and notifications.** Reputation is already required for moderation (§ "Label quality + abuse"), so surfacing it is free. Badges are a design project with no evidence they're needed at v2 volumes. *Reopen if:* labeling throughput stalls with active users who aren't labeling.
4. **Storage retention → Keep forever, user-deletable.** Uploads are already-trimmed clips (the app trims before upload), so 1,000 clips ≈ 10 GB ≈ $1.50/mo on R2. A purge policy isn't worth building until roughly 1 TB (~$15/mo). Ship a `DELETE /api/videos/:id` (owner-only) from day 1 so deletion requests are honored without an admin. *Reopen if:* R2 storage passes ~1 TB.
5. **Moderation model → Single admin at launch.** The `moderation_events` log and trusted-user spot checks already in § "Label quality + abuse" are the on-ramp. Add a moderator role when the open report queue exceeds what one person clears in a week — a measurable trigger, not a guess.
6. **CLA → Skip.** Decided in issue #4; Apache 2.0 § 5 covers contributions. `CONTRIBUTING.md` already states this.
7. **Analytics → None in v1.** Crash reports and hang/launch metrics come from Xcode Organizer + MetricKit, which are opt-in through iOS's own "Share With App Developers" setting — no SDK, no consent UI, and the "nothing leaves your device" claim in the README stays literally true. If v2 needs product analytics, prefer TelemetryDeck (Swift-native, anonymous signals, no consent prompt) over self-hosted PostHog, which is a full platform to operate on a $6 droplet. *Reopen when:* v2 backend ships and there's a product question only usage data can answer.

## Empirical test — the first work item

Once this document is agreed, the immediate next step is scaffolding `turnip-ios` with SwiftUI + AVFoundation + TFLite MoveNet Thunder integration, plus a small Swift file that runs pose detection on a sample video from Photos and logs per-frame confidence + keypoint count. That result — pose accuracy during the aerial phase of real tricking clips — is the definitive answer to whether MoveNet Thunder is enough or the escalation ladder needs to fire early.

## Alternatives considered and rejected

- **Monorepo**: raises contribution barrier for OSS contributors. Rejected.
- **AWS S3 for video storage**: $0.09/GB egress kills the economics. Rejected in favor of R2.
- **MIT license**: fine but Apache 2.0's patent grant is worth having for an ML project.
- **Serverless API** (Vercel / Cloudflare Workers): cheap for low traffic but harder to run Postgres migrations against, and the Bun + droplet stack is straightforward to operate at MVP scale. Rejected for MVP; reconsider for scale.
- **Fine-tuning from day 1**: expensive labeling effort + zero validated need until we measure MoveNet Thunder accuracy on real footage. Rejected — start with pretrained, escalate only if empirical testing says otherwise.
- **Web-only labeling UI**: adds a whole frontend surface. iOS-only labeling keeps v2 tight. Add web when a labeler asks for it.
- **GitHub OAuth for authentication**: fine mechanics, but Sign in with Apple is one-tap on iOS, matches App Store guideline 4.8, and doesn't require the user to have a GitHub account. Rejected in favor of Sign in with Apple.
- **Direct server-side Instagram publish** (Instagram Graph API): only works on Business/Creator accounts, requires Meta App Review, adds per-user OAuth plumbing. The iOS Share Sheet delivers the same UX for every account type on every target with zero server work. Rejected.
- **Timeline / feed fan-out cache from day 1**: unnecessary until feed reads become the bottleneck. A well-indexed join + cursor pagination scales past MVP volumes. Rejected as premature; add if measured feed latency demands it.
