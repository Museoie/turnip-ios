# Turnip — Tricking Video Auto-Editor + Community Labeling Platform

*Rev 14 · 2026-10-21 · Draft for review.*

*(Rev 1 targeted iOS-only, personal-use. Rev 2 expanded to open-source app + backend + community labeling + continuous ML training. Rev 3 depersonalized for public repo and added the pose-model escalation ladder + motion-signal blur mitigations. Rev 4 swapped GitHub OAuth for Sign in with Apple, added iOS Share Sheet for social-media publishing, and added v2 social features — following relationships + video feed. Rev 5 tightens the Sign in with Apple validation contract (`iss` + `exp` on top of `aud` + signature), adds the videos-side feed indexes, adds a self-follow guard, and pins MoveNet Thunder's quantization variant. Rev 6 resolves the seven open questions into recorded decisions and adds the screen-flow companion doc pointer. Rev 7 records that camera takes run steps 1-3 live during recording and skip the post-recording decode when that covered the take. Rev 8 notes the analysis sample rate is a Settings-screen preference, not a fixed constant, defaulting to the 10/sec this doc otherwise assumes. Rev 9 applies the merged turnip-farm master plan (§8): the backend is rewritten around pose-format blobs (no video upload or storage anywhere), labels become free-text multi-labels with no server crop rects, the ML program is retargeted at trick detection, Decision #2 is reversed and #4 mooted plus a new keypoints-only privacy decision, the two-model OTA story replaces the pose+action language, the label editor moves into the clip confirmation flow (the server labeling queue is dropped), a new video-identity section is added, the social feed is deferred, and the problem statement is restated. Rev 10 replaces the hip-displacement motion signal with whole-body speed in torso lengths per second, measures peaks against the athlete's own activity level, and adds an evaluation against labelled footage. Rev 11 applies the farm's session and unlinking changes (master plan Rev 4). The app signs in once and then uses a farm session token instead of sending the Apple identity token on every request. Contributions are owned through per-source keys held in the Keychain and are linked to the account only until 30 days after their last edit. Accounts can be deleted in-app. Reputation scoring is dropped. Rev 12 applies master plan Rev 5 (§8 item 10): a Profile tab built on an on-device clip library becomes a v2 scope item, naming moves from the contribution path into the core clip flow, Decision #3 is reversed, two decisions are added (no server-side profile; contributions stay unlinked from accounts), and the backend, ML and label-quality sections gain label provenance, the blind sample, the public vocabulary endpoint, impact feedback, and validation leakage as a measured risk. Rev 13 specifies the follow crop's editable form for the editor's Follow mode (UIUX.md Rev 16): a few keyframes of the crop's center on a monotone curve, rendered one transform ramp per frame and previewed through a synchronized layer, with a spike's measurements. Rev 14 plans clips for each person in a video with several people (MULTI_PERSON.md): MoveNet MultiPose Lightning in place of Thunder, then people tracked across a take and steps 4-6 run per person, with a spike's measurements.)*

*Screen-level flow for the v1 app lives in [`UIUX.md`](UIUX.md). Running the pose pass during recording, rather than after, is designed in [`LIVE_POSE.md`](LIVE_POSE.md). The Profile tab and the clip library under it are designed in [`PROFILE_DESIGN.md`](PROFILE_DESIGN.md). Clips for each person in a video with several people are designed in [`MULTI_PERSON.md`](MULTI_PERSON.md).*

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
- Profile tab: a private, on-device training log — achievements per trick, a gallery grouped by trick name, highlight videos — over a local clip library, with naming in the core clip flow. Ships first and needs no network ([`PROFILE_DESIGN.md`](PROFILE_DESIGN.md))
- Pose-blob + confirmed-label contribution (in-app), of clips already named in the clip flow
- Deterministic video identity + reinstall reconciliation
- User accounts via Sign in with Apple, moderation, abuse blocking
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

- **Language**: Swift + SwiftUI, min deployment target **iOS 16** (~98% device coverage as of 2026, drops the iOS 14/15 back-compat testing surface). iOS 17+ features (like `VNDetectHumanBodyPose3DRequest` for depth-aware 3D pose) would be feature-gated via `if #available(iOS 17)`; none of them is used yet.
- **Pose engine**: MoveNet Thunder (Apache 2.0, ~7 MB TFLite int8 · ~12 MB fp16 · ~24 MB fp32) — pretrained on Google's "Active" dataset (yoga/fitness/dance with high motion + self-occlusion), 84% joint accuracy on the ISBS 2024 gymnastics benchmark. int8 is the default bundle; fp16 is the escalation if accuracy on real footage demands it before the model swap. See "Model escalation ladder" below for the fallback path if empirical testing shows Thunder underperforms.
- **Runtime**: TensorFlow Lite iOS OR Core ML (via coremltools conversion of the TFLite → Core ML). Core ML is preferable for Neural Engine acceleration on A11+ devices.
- **Pipeline** (per input video):
  1. Decode frames at native fps, applying the track's rotation transform
  2. Sample ~10 frames/sec of footage — stride derived from the track's nominal frame rate
     (3 at 30 fps, 24 at 240 fps slo-mo) — scaling each kept frame straight to the model's own
     input size (256x256 for Thunder), letterboxed so the frame's aspect ratio survives
  3. Run pose detection on each kept frame
  4. Motion signal = whole-body speed between consecutive frames, in torso lengths per second, median-smoothed
  5. Peak detection against the athlete's own activity level, sustained ≥ 300 ms → list of trick windows
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

- **Preview UI**: a looping preview tile per detected clip; tapping one opens the clip editor (crop, trim with start/end handles, Auto crop / Auto rotate; Still and Follow framing modes, with Auto follow and keyframes); a per-tile trash button; "Save Clips" saves the rest to Photos. Screens: [`UIUX.md`](UIUX.md).
- **Clip library + Profile** (v2, first): saving — at the end of a Name Clips step after Clip List, or straight from Clip List's "Save without names" — writes each saved clip — its window, names, whose clip it is, the saved Photos asset, and the source's pose sequence — to an on-device library, and the Profile tab (the root pager's third page) is computed from it: achievements per trick counted by sessions and reps, a gallery grouped by canonical trick name, and highlight videos composed on the device. Nothing in it leaves the device, and nothing in it requires an account or contributing. Full design: [`PROFILE_DESIGN.md`](PROFILE_DESIGN.md).
- **Contribution** (v2): opt-in per clip — a "Contribute this clip" toggle on the Name Clips screen and on the Profile's Clip view, never on Clip List or the Clip Editor. Uploads the pose-format keypoint sequence plus the confirmed clip windows, the free-text trick names the clips already carry, and each name's provenance to `turnip-farm` — keypoints only, video never leaves the device. The farm upserts on ID match, so re-contribution is safe and idempotent. Full design: [`CONTRIBUTION_DESIGN.md`](CONTRIBUTION_DESIGN.md).
- **OTA model updates**: two models. Bundled MoveNet Thunder does pose detection (unchanged). The trick-detection model arrives over the air: on launch and foreground, poll `GET /api/models/current` for the manifest (version, URL, checksum, `taxonomy_version`, vocabulary, per-trick `name_metrics`) — a public endpoint, no sign-in; download in background, verify the checksum, atomic-replace. The trick model proposes clip windows *and* trick names, pre-filling only the names it is confident in and none on a random tenth of its clips (the blind sample, `MODEL_CONTRACT.md` §3.3); the heuristic detector stays as the offline fallback. (The old "pose+action model" language is retired.) Built so far (`Turnip/ModelUpdates/`): the manifest client, the sha256 check, the atomic-replace store, and the launch/foreground poll, which stays a no-op until `TURNIP_MODEL_UPDATE_ENDPOINT` names a deployment (it is empty in the committed Info.plist). Still to come: the trick-model loader that reads the staged file, and `taxonomy_version` and the vocabulary in the manifest, which carries only version, download URL, sha256 and file name today.

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

**Step 4 (motion signal):** how fast the whole body moves, in torso lengths per second:
- Keep each frame's keypoints above confidence (`> 0.3`), in pixels — a normalized unit is 1.78x longer down a portrait frame than across it, which would weigh a jump below a walk
- Between consecutive frames, average how far each joint located in both frames moved. Every joint, not one anchor: a kick barely moves the hips, and comparing each joint only with itself means no fixed offset between two body points can read as motion. A pair sharing fewer than 6 joints is unknown. A left/right pair whose labels crossed — pose models swap them when the athlete turns side-on — counts the crossed matching when that is shorter
- Divide by the body scale, the median torso length (shoulder midpoint to hip midpoint) within 2 s, and by the time between the frames. The same trick then reads the same near the camera or far from it, a passer-by at the lens reads as walking, and a body with no torso in view (legs passing the lens) has no scale and stays unknown
- Median over ±0.1 s, one sample either side at 10/sec. A median, not a mean: a mean spreads one glitched frame over its neighbours, enough to pass the 300 ms rule below

**Step 5 (peak detection):** given the speed series, identify sustained bursts:
- Divide each speed by the median speed within 5 s of it — the athlete's own activity level, so bouncing on a sprung floor or walking back to the start sets the bar a trick has to clear. A speed at or below 2.5 torso lengths/s never counts, so a still athlete's keypoint jitter over a near-zero level is not a burst
- A burst starts above 2x that level and holds while above 1.4x, so a trick stays whole through its slower moments; one unknown sample inside it is bridged, a second ends it
- Require ≥ 300 ms of burst (filters out one-frame anomalies)
- Require ≥ 1 s of unbroken quiet between bursts (prevents splitting one trick into two); unknown samples are neither motion nor quiet
- Merge bursts within the minimum gap; expand each window by a 1 s leading buffer and a 3 s trailing buffer — the motion signal reads quiet as soon as the athlete slows on landing, which is consistently earlier than the trick visually reads as complete, so the trailing edge needs more room than the leading edge
- Every threshold is a speed or a duration, so Settings' analysis granularity changes how finely motion is sampled, not how fast it has to be
- Known limit: a burst holding one speed for more than about 5 s raises its own activity level and stops standing out. No labelled footage has one yet; capping the level would keep such bursts

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

Static crop (one rect per clip) is Rev 1's choice — simpler, works well when the athlete stays roughly in one area.

**Follow crop:** `CropPathCalculator` turns the same window into a crop that moves with the athlete — one keyframe per pose sample, all the same size, so the clip never zooms:
- De-spiked first: each located sample's joint box becomes the median, edge by edge, of the boxes of the five located samples centered on it (fewer, still centered, at the window's ends). A misplaced joint or a second person's limb widens one detection's box, and without this the crop jerks toward it for one sample and back. Counted in samples rather than seconds, since what it removes is a single bad detection whatever the analysis granularity
- Size: the largest rect the static calculator would draw around any single sample (same floor, padding and ratio), shrunk to fit the frame
- Center: each sample's athlete center from a line fitted through its neighbours by least squares, weighted by a Gaussian of 0.4 s standard deviation. The whole window is known up front, so the fit looks ahead as far as it looks back and the crop moves with the athlete instead of trailing them; a line rather than an average follows steady motion exactly at the window's ends. The width is in seconds, so the analysis granularity changes how often the athlete is sampled, not how the crop moves
- Still unless moving: when the smoothed centers stay within 10% of the crop's size on both axes, every keyframe takes the static crop's center — keypoint jitter on a standing athlete would otherwise read as camera shake
- A sample with no located keypoint still gets a keyframe, placed by its neighbours; before the first located sample or after the last — the window's lead-in and trailing buffers often hold these — it holds that end's keyframe exactly, since extending the fitted line would turn the last samples' jitter into a pan
- Each keyframe then shifts just far enough to hold that sample's located joints, and slides inside the frame, which wins if the two disagree
- The path is analysis output, one keyframe per pose sample. Nothing draws it directly: Auto follow reduces it to the follow crop below, which is what the editor, the Clip List and export draw

**Follow crop in the editor (UIUX.md Rev 16 § "Clip Detail / Editor"):** the path above is not what the user edits, and not what export draws:
- Model: a crop center that moves over time, interpolated from a few keyframes (source time in seconds; the center as a position in the source video's displayed pixels), and one scale and one rotation for the whole clip, applied about the moving center. The editor can only keep the picture and the pan in step if the pan is drawn into the frames themselves (editor preview, below), so the translation lives in source space and the scale and rotation stay outside it, which is the order the path export already uses (`ClipExportTransform.make(cropPath:…)`). Still mode keeps its own order, the offset applied on screen after the scale and rotation; the mode switch converts one framing into the other
- Auto follow takes the path's rect centers as keyframe positions, with the scale that fits the path's rect size to the marker, at the current rotation
- Reduction, measured by a spike on the 34 trick windows in the evaluation footage (all portrait, plus the same poses placed in a 1920×1080 frame as a landscape proxy): fitting keyframes so the curve stays within 2–5% of the crop's width of every sample leaves a median of 14 to 19 keyframes per window, with almost no window under seven. The paths turn often, and `CropPathCalculator`'s per-sample shift chased single outlying joints in one-sample spikes. Built (`AutoFollow`): keyframes where the path starts and stops moving, then one at the worst sample until the curve keeps every joint the path kept inside the crop (first) and strays from no sample's center by more than 10% of the crop's width. On the path as it was, that left a median of 11 keyframes per window (8 to 16, at most 25). With the de-spike above, adopted after comparing both on video, it leaves a median of 8 (5 to 10, at most 13), and 13 of the 34 windows have six or fewer. The cost: the crop cuts raw joints in a median of 5 samples per window, the deepest by a median of 38% of the crop's width — mostly a second person crossing, or a joint placed on one, which the crop now leaves alone instead of chasing
- Curve: a monotone cubic Hermite (Fritsch–Carlson) per axis through the keyframe positions. Speed is zero at the first and last keyframes, since the crop holds still before and after them, and at a keyframe where an axis turns back; elsewhere the curve passes through a keyframe at speed instead of stopping, which an ease per stretch between keyframes would do. It never overshoots a keyframe, so at zero rotation a crop whose keyframes all lie inside the frame stays inside between them. With two keyframes it is the ease-in-out cubic
- Rendering: the curve sampled at the track's frame rate, one transform ramp per frame. Scale and rotation are the same at every sample, so only the translation changes between two samples and the composition's linear interpolation of the matrix is exact; a rotation that changed between keyframes would shear, one more reason rotation stays the whole clip's
- Editor preview: the pan is drawn into the frames. An `AVVideoComposition` on the editor's item places each source frame, at its own presentation time, shifted by the pan for that frame (`FollowPreviewComposition`), on a canvas padded by as far as a pan can move the picture; the zoom and turn stay SwiftUI transforms about the marker. The canvas depends on the frame and the crop, and Still plays through it unshifted, so a mode switch or an edit swaps the composition without re-laying the video out; it only grows, for a pan that reaches past the frame, and past 4,096 px it draws scaled down. Every pan that moves smoothly between frames sits about half a frame off the picture, because it moves on every refresh while the picture changes once per frame (spike, iPhone 15 simulator: up to 10 pt of shake at 30 fps). The first build stepped a discrete `CAKeyframeAnimation` of the video layer's position inside an `AVSynchronizedLayer`, one value per source frame. That held on the simulator but not on an iPhone 13 mini (iOS 27): there the pan landed a display refresh behind the picture for whole playback passes, set afresh at each seek or loop, with the editor opened alone (96 of 121 source frames off) as much as from the Clip List, and no constant lead fixed every pass. With the pan in the frames, every pass is locked on that device and on the simulator, in both flows: the follow harness (`-screenshotClipEditorFollow`, `-screenshotClipListFollow`, a bar crossing a 30 fps take with its frame index drawn on it) recorded frame by frame, the bar at one screen position per source frame. On that iPhone a 60 fps take holds too, and so does a 4K source, whose canvas draws at 4,096 by 2,304: in steady playback every source frame sits at one position in every pass and none is dropped mid-loop. A 4K source's costs show around seeks: the loop's wrap holds the picture for 100 to 180 ms (17 ms at 640 by 360) and can show up to seven frames past the clip's end, an ease that starts while a 60 fps take plays skips 8 to 10 frames as its seek lands, and a slow scrub on the lane freezes for up to 1.4 s, as long without the composition as with it
- Preview eases (automatic changes and mode switches, `docs/UIUX.md` § "An automatic change moves, it never cuts") are in the frames too (`PreviewPan`): a layer animation and a video frame can't be put on the same display refresh, so handing the picture from one to the other shows one frame wrong. While playing, the new composition blends from the frames' old pan onto the new one over 0.4 s of item time from the frame on screen, so its first frame is the one already showing, and a seek drops the frames drawn ahead with the old one. While paused, the item's clock stands still, so each display refresh puts the blend further along on the frame on screen, which a paused player redraws in 2 to 8 ms (1080p HEVC, simulator). A seek or a loop ends the ease on its target, and only then does a steady composition replace an ease that arrived while playing: past its end the eased one draws the target's frames anyway, and replacing a playing item's composition without a seek flashes a frame from up to ten source frames ahead for one display refresh (iPhone 13 mini). A Follow drag's live move is drawn into the frames the same way, so the keyframe it sets as the finger lifts lands on the picture already on screen. While playing, an ease's pan moves once per source frame while the zoom and turn, still view animations, move every display refresh: on a 30 fps take an ease whose zoom and pan pull the picture opposite ways (Reset follow, the mode switch) judders by up to about 10 pt for its 0.4 s; on a 60 fps take they step together. A video frame and a view animation's step reach the display by different paths, though, and the pan runs ahead of the zoom: on an iPhone 13 mini by one to two display refreshes while paused and two to four while playing, at 30 and 60 fps alike (about one, paused, on the simulator). Within one ease the lead barely changes, so the picture's path bends, by up to about 25 pt, rather than shaking
- A drag sets its keyframe when it ends, and is dropped if the pinch or rotation reported anything during the gesture: SwiftUI's drag reports nothing while two fingers are down, but real fingers land at different moments
- Per clip, the framing is a still adjustment or a follow crop (scale, rotation, and keyframes each marked as Auto follow's or the user's), and the clip keeps both modes' framings so the editor's switch can go back to either. This replaces `isFramedByDetection`
- Settings' Follow the athlete is the mode a detected clip starts in. The editor keeps either mode, so a reframe no longer drops a clip to its static rect. A clip in Follow that has no follow crop of its own yet draws Auto follow's for its window, worked out the same way wherever it is drawn. A trim leaves the user's keyframes where they are; a follow crop that is still all Auto follow's re-tracks the new window, positions only and at the same zoom

Everything above is ~400 lines of Swift on top of the pose output. The pose model does the heavy lifting; this code just interprets it.

Steps 4, 5 and 6 are implemented in `Turnip/TrickDetection/` as `MotionSignalBuilder`, `TrickWindowDetector` and `CropRectCalculator` (with `CropPathCalculator` for the follow crop), each with a test file under `TurnipTests/`. `ProcessingPipeline` drives all three (the camera's live path runs the same steps on its own results), and the clip editor's Auto crop reuses `CropRectCalculator`. Start from these types rather than from the prose above.

`TrickDetectionEvaluationTests` runs the whole pipeline on hand-labelled footage and scores the clips — tricks caught, partly caught and missed, and clips that hold no trick. The footage and labels are recordings of real people, so they live outside the repository; the test skips unless a run names their directory, and its doc comment has the layout. Tune a threshold against it, not against the prose above.

### Model escalation ladder

MoveNet Thunder is the MVP pick because it's the leanest option with independent evidence on acrobatic footage (84% joint accuracy on the ISBS 2024 gymnastics study). If empirical testing on real tricking footage shows it underperforms (< 70% frames with usable pose during aerial phases), escalate in this order:

1. **MediaPipe BlazePose Heavy** (Apache 2.0, ~29 MB, 33 keypoints incl. feet) — MediaPipe iOS SDK, no conversion. Google's benchmarks: 96.4% PCK on yoga, 97.2% on dance. Larger than Thunder but purpose-built for fitness/dance/yoga.
2. **Fine-tune Thunder on tricking data** — collect 200-500 labeled clips (~4-6 hours of labeling), fine-tune the pretrained weights. The AthletePose3D paper (CVPRW 2025) found sports-specific fine-tuning cuts pose error > 69%. Same 7 MB bundle, better accuracy on the target distribution.
3. **RTMPose-m** (Apache 2.0, ~27 MB fp16) — best raw accuracy per FLOP (75.8 AP on COCO). No sports pretraining, so pair with fine-tuning if used. Needs a bundled person detector (RTMDet-nano, also Apache).
4. **ViTPose or PoseC3D** — SOTA family but larger. Reach for these only if the top three fail. PoseC3D fine-tuned on FineGym is 2 M params and 93.5% mean top-1 across 99 gymnastics classes — the natural bridge to v2's automatic trick classification.

**Escalation trigger**: the 2-hour Swift-playground empirical test on 5-10 representative recordings, measuring per-frame pose confidence + keypoint count during the aerial phase of each trick.

**Standing note (Rev 9):** the ladder now guards pose *input quality* for the trick-detection model, not the pose model as an end in itself. Fine-tuning MoveNet is off the table unless this ladder fires on the empirical trigger above — the ML program trains trick detection on whatever pose the (possibly escalated) detector emits.

**Planned (Rev 14):** MoveNet MultiPose Lightning replaces Thunder, off the ladder: the reason is videos with several people, not the ladder's trigger. It keeps the 17 COCO keypoints, and at a long side of 384 it scored better than Thunder on the labelled footage ([`MULTI_PERSON.md`](MULTI_PERSON.md) "Measurements").

### Motion signal robustness on blurry frames

Fast acrobatic motion produces motion-blurred frames (a body spinning at 720°/s smears ~24° across a 33 ms exposure at 30 fps). Pose models degrade gracefully on blur — they still emit `(x, y, confidence)` for each keypoint, but confidence drops and some keypoints may be missing.

The pipeline handles this at multiple layers:

1. **Confidence filtering** — drop keypoints with `confidence < 0.3`. A frame pair sharing fewer than 6 located joints is a gap in the motion series.
2. **Single-frame dropout bridging** — a frame that loses its pose on its own takes the speed measured straight across it from its neighbours, the joint-by-joint form of interpolating it. Two missing frames in a row stay a gap.
3. **Whole-body signal** — every located joint counts, so the blur-prone ones (wrists, ankles) dropping out leaves the torso and head to carry the measurement rather than the frame going dark.
4. **Optical-flow fallback** *(planned, not implemented)* — `VNGenerateOpticalFlowRequest` returns per-pixel motion magnitude between two frames with no pose needed. On frames where pose fails entirely, substitute optical-flow magnitude for the motion signal.
5. **Median smoothing** — one bad frame cannot survive it, where a moving average would spread it over its neighbours.
6. **Peak-detection sustained-above-threshold logic** — requires ≥ 300 ms of high motion, so a single-frame anomaly can't create a false peak.
7. **Per-joint identity** — each joint is compared only with itself, so a partial pose never measures the fixed offset between two different body points, and a left/right label swap is matched crossed rather than read as both joints jumping.

**Recording-side lever (biggest single improvement)**: default to **240 fps slo-mo mode** on the phone. Exposure is ~4 ms instead of 33 ms → **8× less motion blur per frame**. Pose confidence stays > 0.7 through the aerial phase and mitigations 2-4 rarely need to fire. The app processes at native frame rate (30 or 240) and can export at whichever the user picks. Slo-mo is a shooting-technique change users adopt once and forget, not a per-clip decision.

### Backend (`turnip-farm`)

- **Stack**: Bun + TypeScript + Postgres. Standard modern TypeScript backend.
- **Object storage**: **Cloudflare R2** (S3-compatible, **$0 egress**, $15/TB storage). pose-format blobs (`.tkp1.gz`, ~2 KB/s at 10 Hz) and trained model artifacts live here, not on the droplet FS — the droplet doesn't grow with content volume. No video anywhere: no video bytes in any table, blob, log, or error payload.
- **Auth**: **Sign in with Apple**, iOS-native: one-tap Face ID / Touch ID, no browser bounce. The app signs in once. It sends the identity token, the authorization code, and the raw nonce to `POST /api/auth/apple`. The farm verifies the token (signature against Apple's JWKS with the matching `kid`, `iss`, `aud`, `exp`, `nonce`), exchanges the code with Apple, upserts the `users` row keyed by `sub`, and returns an opaque farm **session token**. Every later request sends `Authorization: Bearer <session token>`. This follows Apple's guidance ("After verifying the identity token, your app is responsible for managing the user session"): identity tokens expire in minutes and can't be refreshed without user interaction. The session token lives in the Keychain, and the app checks `getCredentialState(forUserID:)` on launch. Account deletion is in-app (`DELETE /api/account`, App Review 5.1.1(v)). Full contract: `turnip-farm`'s `BACKEND_DESIGN.md` §7.1. The model manifest and vocabulary endpoints need no sign-in, so the Profile and model updates work for users who never sign in. Matches App Store guideline 4.8; no email/password fallback keeps the auth surface minimal. The training pipeline authenticates with a pre-shared service key instead.
- **Endpoints (v2 MVP)** — every write upserts on ID match (the IDs *are* the idempotency keys):
  - **Account:**
    - `POST /api/auth/apple` — sign in once; returns a farm session token
    - `POST /api/auth/signout` — end this session
    - `DELETE /api/account` — delete the account (the app first deletes every source it holds a key for)
    - `POST /api/auth/apple/notifications` — Apple's server-to-server account events
  - **Contribution** (session + the source's key):
    - `POST /api/sources` — register a source (`video_id`, `source_key`, `frame_count`, `sample_rate`, `keypoint_format`) → presigned R2 PUT URL for the `.tkp1.gz` blob
    - `POST /api/clips` — batch upsert clips + replace their label sets, with each label's `origin` and each clip's provenance (blob SHA-256 verified server-side)
    - `POST /api/clips/:id/labels` — label-only update (re-label without re-uploading)
  - **Reconciliation + owner reads** (the source key proves ownership; there is no "list my sources", since the farm doesn't know whose a source is):
    - `GET /api/sources/:id` — source with its confirmed clips + labels, plus `trained_in` (the promoted models it trained)
    - `GET /api/sources/:id/pose` — owner-only presigned R2 GET of the pose-format blob (skeleton restore on a device without the video)
    - `DELETE /api/sources/:id` — owner-only hard delete (row + R2 blob); the retention policy is "keep forever, user-deletable" (see § "Decisions" #4)
  - **Models + vocabulary** (public, no sign-in):
    - `GET /api/models/current` — trick-model manifest (version, URL, checksum, `taxonomy_version`, vocabulary, `name_metrics`)
    - `GET /api/taxonomy/current` — the current vocabulary, independent of any model
    - `POST /api/models` — training pipeline publishes the champion with its `name_metrics` and training source list (service-key scoped)
  - **Training + moderation:**
    - `GET /api/labels/export?since=` — training pipeline pull (labels + provenance + pose blob refs; excludes quarantined sources)
    - `POST /api/reports` — report a bad label/clip
  - Dropped from earlier drafts: `GET /api/labels/pending` — there is no labeling queue; labeling happens on-device by the clip owner.
- **Database schema (v2, additive-only)** — full design in `turnip-farm`'s `BACKEND_DESIGN.md`:
  - `users` — id (Apple `sub`, TEXT PK — no name, no email), is_blocked, created_at, encrypted Apple refresh token (kept only to revoke on account deletion)
  - `sessions` — hashed farm session tokens, 90-day idle expiry
  - `sources` — id CHAR(64) (deterministic SHA-256 hex `video_id`, PK), source_key_hash (ownership; no account column), frame_count (canonical 10 Hz), sample_rate (as-sent, provenance), keypoint_format, r2_key (`poses/<id>.tkp1.gz`), sha256 (blob integrity)
  - `source_attribution` — source → the account that last wrote it, deleted 30 days after that write: the only link between a contribution and an account (anti-poisoning)
  - `clips` — id UUID (client-minted once, PK), source_id FK, start_frame, end_frame (canonical 10 Hz indices), auto_detected, proposal_model_version, suggested_names, suggestions_withheld (provenance: which model proposed it, the names it pre-filled, the blind sample)
  - `labels` — id, clip_id FK, trick_name (free text), origin (`typed` | `vocabulary` | `model`), taxonomy_version — one row per (clip, trick name); re-submission replaces the clip's whole label set in one transaction
  - `label_taxonomy` — raw → canonical mapping, taxonomy_version (monotonic int)
  - `models` — id, version, model_type (`trick-detection`), taxonomy_version, r2_key, sha256, val_metrics (JSONB), name_metrics (JSONB), promoted_at
  - `model_training_sources` — model_version, source_id: which sources trained each promoted model (source-level, no account)
  - `data_quarantine` — id, source_id FK, reason, metrics (JSONB), quarantined_at, resolved_at, resolution (`released` | `purged`)
  - `reports` — id, reporter_user_id, target_type (`source` | `clip` | `label`), target_id, reason, status
  - No `videos` table, no `follows` table, no thumbnails, no PII columns, and no profile, achievement or score table (Decision #9).
- **Migrations**: `dbmate` from day 1. Numbered SQL files, forward-only, additive-first. Never drop a column in the same PR that stops writing to it — two PRs.

### Video identity

The farm never mints source identities. Every contribution references a `source_id` the device derives deterministically, so the ID survives app reinstalls and re-contributing the same video upserts instead of duplicating training data:

- **Photos-backed videos** (gallery picks and in-app camera takes, which are saved to Photos): `source_id = SHA-256 hex of ("turnip:phasset:" + PHAsset.localIdentifier)`. The `localIdentifier` belongs to the Photos library, not the app, so it is stable across reinstalls. The raw identifier never leaves the device — only its one-way digest.
- **Imported files** (document-picker / Files-app imports with no `PHAsset`): `source_id = SHA-256 hex of the file bytes`.

No local ID↔asset mapping to lose: the ID is recomputed on demand, which is the whole point.

**Reinstall reconciliation:** on a fresh install, read the source keys left in the Keychain (stored per `video_id`) → enumerate the Photos library and recompute `source_id`s → for each match, `GET /api/sources/:id` with its key (pull confirmed clips + labels) → adopt the server's clip IDs into the rebuilt local state. (`clip_id`s are client-minted UUIDv4 once per clip — recovered from the server, never re-derived.) Videos deleted from the library stay on the farm as training data; the client cannot relink what it cannot see. This restores contributed clips only — the Profile's own library is restored from the device ([`PROFILE_DESIGN.md`](PROFILE_DESIGN.md) §3). Full design: [`CONTRIBUTION_DESIGN.md`](CONTRIBUTION_DESIGN.md) §1 and §6.

### Naming (in the core clip flow)

Naming lives inside the iOS app, on a Name Clips screen between Clip List and the save (Clip List's main button becomes "Next: name clips", with "Save without names" under it), and again from the Profile's "Needs a name" for clips saved without names — there is no server labeling queue and no `GET /api/labels/pending`. Clip List's tiles and the Clip Editor stay as they are; they are already full. It is part of making a clip, not of contributing one: every saved clip can carry names, because the Profile is built from them.

1. The user is prompted for the trick name — a free-text field ("What trick is this? e.g. cork"). Committing adds a chip; chips are removable. No fixed vocabulary is enforced, and naming is optional — unnamed clips wait in the Profile's "Needs a name".
2. A clip carries multiple trick-name chips (a combo is N chips on one clip — no sub-segmentation for MVP). The editor suggests canonical names from the newest vocabulary the app holds — the seed bundled with the app, `GET /api/taxonomy/current`, or the active model manifest's — as the user types; picking a suggestion stores the canonical name, free-typing stores the raw string, and each name records which it was (its `origin`).
3. Each clip also records whether it shows the user or someone else; only the user's own clips count in the Profile.
4. Labels inherit the clip window (set via the editor's existing trim handles); the farm stores one label row per (clip, trick name).
5. A clip with no trick names cannot be contributed. The Contribute confirmation sheet lists each clip with its name chips; only confirmed clips + labels are uploaded — proposals are never auto-confirmed.

Full design: [`PROFILE_DESIGN.md`](PROFILE_DESIGN.md) §4 (naming) and [`CONTRIBUTION_DESIGN.md`](CONTRIBUTION_DESIGN.md) §3 (the contribution boundary). Web labeling UI remains out of scope — iOS-only keeps the surface small.

### Publishing to social media (iOS Share Sheet)

*Planned, not built: the app has no Share action today; "Save Clips" saves to Photos.* Every exported clip gets a "Share" button that opens the native iOS share sheet — `UIActivityViewController` (or SwiftUI's `ShareLink` on iOS 16+). Turnip hands the file URL to the system; iOS enumerates every installed app that accepts a video and the user picks the destination — Instagram, TikTok, YouTube (via Photos → Shorts), Messages, Photos, AirDrop, etc. When Instagram is selected, Instagram's own picker offers Reel / Post / Story.

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
  1. Fetch the labeled dataset from turnip-farm as a full pull of `GET /api/labels/export` (`since=<last>` only to detect new labels). The export carries pose blob refs, clip windows, free-text labels and their provenance, and no account identifier. Quarantined sources are excluded by construction, and deleted ones simply stop appearing.
  2. Resolve the pose-format blobs from R2.
  3. Canonicalize raw label strings via `label_taxonomy` (combo strings like `"hook - scoot - gainer - cartfull (combo)"` split into N canonical names on one window); raw strings are never discarded.
  4. Split 80/10/10 train/val/holdout by source: all clips of a source land in one split. There is no account identifier to stratify on (Decision #10), so one person's videos can straddle train and val; that leakage is measured rather than assumed small: the admin-curated holdout is footage of people outside the contributor pool, and every run reports the val − holdout gap (`TRAINING_DESIGN.md` §2.6).
  5. Train the trick-detection candidate — baseline: temporal encoder (dilated TCN or small Transformer) over the keypoint sequence with a segment-proposal head and a per-segment multi-label classification head; sliding-window classifier + NMS is an acceptable MVP. Classes are sampled in balance rather than in proportion to how often the Profile gets them named (`TRAINING_DESIGN.md` §2.7).
  6. Evaluate on holdout: segment quality (mAP at tIoU thresholds) **and** name accuracy, reported separately, plus per-name precision/recall (published as `name_metrics`) and quality by label origin. Label provenance and the blind sample measure how often users keep model suggestions they would not have given unprompted (`TRAINING_DESIGN.md` §6.4).
  7. **Fixture regression gate (anti-poisoning)**: run the candidate over the fixture suite (pose-accuracy fixtures + trick-labeled fixtures) and compare against the champion. On regression: fire a Discord webhook alert (metrics delta, affected source IDs, never account IDs), quarantine that day's ingested sources (`data_quarantine`), and skip promotion. The maintainer finds the responsible account from the farm's 30-day `source_attribution`.
  8. **Champion/challenger**: promote only if the candidate beats the champion by ≥1% on validation. Otherwise archive and try again next cycle.
  9. Export to Core ML with `coremltools`, upload to R2, call `POST /api/models` with the `taxonomy_version` it trained on, its `name_metrics`, and the ids of the sources it trained on (each owner's `trained_in`). The app picks it up via the OTA poll.
- **Runs where**: same droplet during MVP (Python installed alongside Bun). Move to a separate GPU worker (RunPod / Lambda Labs on-demand, ~$0.50-1/hr) when training time exceeds ~30 min.
- **What stays**: the `PoseAccuracy` harness and CI gate now guard the *input* to the trick model (pose quality on real footage). Fine-tuning MoveNet itself is off the table unless the pose escalation ladder fires on empirical grounds.

### Label quality + abuse

- **Reputation score per user** — ~~starts at 0, +1 per accepted label, -5 per reported+confirmed bad label. Users with reputation ≥ threshold become "trusted" and their labels bypass moderation review.~~ Dropped (Rev 11): contributions keep no lasting account link (master plan Rev 4), so labels can't be scored per account.
- **Spot checks** — ~~every Nth label from a non-trusted user is queued for a trusted user to review.~~ Dropped with reputation (Rev 11); the fixture-regression gate is the quality check.
- **The Profile's incentive** — the reason most users name clips at all is their own private training log. It is outcome-neutral — a clip counts under its trick, and how the name was given, whether a model suggestion was kept, and whether the clip was contributed never change what it earns — and private, so nobody gains anything by mislabeling ([`PROFILE_DESIGN.md`](PROFILE_DESIGN.md) §1).
- **Label provenance + blind sample** — every name records how it was given (typed, picked from the vocabulary, or kept from the model's pre-fill), every model-proposed clip records the model and the names it pre-filled, and a random tenth of model-proposed clips get no pre-filled names. Training uses them to measure and limit the model learning from its own suggestions (`TRAINING_DESIGN.md` §6.4).
- **Inter-labeler agreement** — ~~v2.5 enhancement: same clip goes to 3 labelers, compare, quality signal = how similar their labels are. Elegant but requires N > 1 labelers per clip so hard at low volume.~~ Superseded (Rev 9): with owner-only labeling there is no second labeler for the same clip; agreement signal replaced by the fixture-regression gate (§ "Data poisoning defense").
- **Abuser blocking** — admin action (`UPDATE users SET is_blocked = true`) revokes upload rights. Automated triggers: N reports in T time, N labels rejected, upload rate spike. All actions logged to `moderation_events` table.
- **Data poisoning defense** — the nightly fixture-regression gate is the primary defense: on regression, that day's ingested sources are quarantined (`data_quarantine`), a Discord alert fires, and promotion is skipped. Never train on quarantined sources; blocked accounts can't contribute, and the 30-day attribution identifies them. Held-out validation set is admin-curated from people outside the contributor pool and never touched by user labels.

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
3. **Labeling incentive → REVERSED 2026-10-15 (Rev 12): a private Profile with achievements.** ~~A "your contributions" stats screen; defer badges and notifications.~~ Reopened before its trigger fired, because naming has to be worth doing before contribution ships, not after throughput stalls. The incentive is the Profile tab ([`PROFILE_DESIGN.md`](PROFILE_DESIGN.md)): a training log whose achievements count sessions and reps per trick, built only from the user's own named clips, on the device. Its rules: private (Decision #9), never gated on contributing, outcome-neutral (a clip counts under its trick, and how its name was given — typed, picked, kept from the model's suggestion, or in the blind sample — never changes what it earns), variety over volume, earned achievements never revoked. No notifications. *Reopen if:* named clips per active user stay flat after the Profile ships, or the rubber-stamp measure (`TRAINING_DESIGN.md` §6.4) shows the Profile buying names users don't stand behind.
4. **Storage retention → MOOT 2026-10-06: there are no videos to keep.** The farm stores pose-format blobs (~2 KB/s) and labels, never video — 10,000 contributed sessions are ~1.2 GB, still inside R2's free tier. The retention posture transfers to sources: keep forever, user-deletable via `DELETE /api/sources/:id` (whoever holds the source key) from day 1. (Mooted by the no-video privacy contract, per the merged master plan.) *Reopen if:* pose-blob storage passes ~1 TB.
5. **Moderation model → Single admin at launch.** The on-ramp is the `moderation_events` log (§ "Label quality + abuse") and the open queue of reports filed through `POST /api/reports`; trusted-user spot checks went with reputation (Rev 11). Add a moderator role when the open report queue exceeds what one person clears in a week — a measurable trigger, not a guess.
6. **CLA → Skip.** Decided in issue #4; Apache 2.0 § 5 covers contributions. `CONTRIBUTING.md` already states this.
7. **Analytics → None in v1.** Crash reports and hang/launch metrics come from Xcode Organizer + MetricKit, which are opt-in through iOS's own "Share With App Developers" setting — no SDK, no consent UI, and the "nothing leaves your device" claim in the README stays literally true. If v2 needs product analytics, prefer TelemetryDeck (Swift-native, anonymous signals, no consent prompt) over self-hosted PostHog, which is a full platform to operate on a $6 droplet. *Reopen when:* v2 backend ships and there's a product question only usage data can answer.
8. **Privacy: keypoints + opaque IDs only, never pixels (adopted 2026-10-06).** The farm receives pose keypoint sequences, deterministic source IDs, confirmed clip windows, and labels — never video pixels, audio, location, photo-library identifiers, device identifiers, contacts, or thumbnails. Reopenable only by deliberate product decision, never convenience. (From the merged master plan §1.)
9. **The Profile is on-device only (adopted 2026-10-15).** Achievements, levels, progress, the gallery, highlights, favorites, spots and whether a clip shows the user are computed on the device and never sent to the farm, which has no table for them. No leaderboards, no public profiles, no public view of achievements: a server-side profile would need to know whose contributions are whose, which Decision #10 removes, and an audience would give people a reason to mislabel that a private log doesn't. Highlights are composed on the device with AVFoundation and leave it only when the user shares one. (Master plan §1.) *Reopen if:* a social feature is put on the roadmap — designed as opt-in linking, never as a default.
10. **Contributions stay unlinked from accounts (adopted 2026-10-12, re-weighed and kept 2026-10-15).** A contribution is owned by a per-source key the app holds and linked to an account only through `source_attribution`, for 30 days after its last write, for anti-poisoning. Linking was weighed again for the Profile: it would buy complete account deletion, splits by person, per-labeler reliability and restore on any device, and cost one re-identified video identifying every other video of the same account, plus a "linked to you" privacy label. The Profile needs none of it, and the keys keep an opt-in re-link possible later. (Master plan §1; `BACKEND_DESIGN.md` §1.2.17.) *Reopen if:* counsel answers that unlinked pose sequences are personal data anyway (`BACKEND_DESIGN.md` §9 Q9), or a social feature is put on the roadmap; a reversal lands before the farm's first deployment.

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
