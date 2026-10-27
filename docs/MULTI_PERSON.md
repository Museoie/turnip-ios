# Several people in one video

*Rev 2 · 2026-10-23 · Built: the model swap, and the choice between following one person and following everyone, made by the user on the camera and on Processing. Rev 1 planned the per-person mode behind a Settings toggle, off by default, until multi-person footage was labelled. A choice the user makes keeps one-person videos exactly as they were, so labels now tune the tracker rather than gate it. A spike ran the multi-person model on the evaluation footage, and its numbers are in "Measurements".*

*Companion to [`DESIGN.md`](DESIGN.md). This doc covers one question: when a video holds several people, how does each person's trick become a clip of its own? Pipeline steps 4-6 (motion signal, trick windows, crop) stay as `DESIGN.md` records them. What changes is the pose they run on.*

## Decision

1. **Swap the model** (built, #238). MoveNet MultiPose Lightning replaces MoveNet Thunder. On the labelled tripod footage it scores better than Thunder (13 tricks caught, none partial, 1 missed, 1 false positive, against 12, 1, 1, 1), most of all on a far athlete.
2. **Let the user choose whose tricks become clips** (built). Following one person, the most confident person in each frame stands in for Thunder's one pose, and nothing downstream changes. Following everyone, detections are linked into people across the take, steps 4-6 run once per person, and each clip belongs to one person: its crop, its follow path and the editor's Auto crop and Auto follow read only that person's pose. The choice is a control on the camera and a picker on Processing ("Screens"). Each mode is better at its own footage. On the labelled single-athlete footage, following everyone scores 12 / 0 / 2 / 1 against following one person's 13 / 0 / 1 / 1. On the gym take it trades about 11 clips of people standing or talking for one ("Measurements"). So nobody's solo videos get worse.
3. **Label multi-person footage**, to tune the tracker. The evaluation can score who did each trick and count duplicate clips (#239). Nothing waits on labels any more, but the open problems below can't be measured without them.

Four problems are still open ("Open problems"). The first two are the design work left, not parameter choices.

## Problem

MoveNet Thunder is a single-pose model: every frame gets exactly one pose, whoever is in it. In a frame with two people it scores one of them, and which one can change from one sample to the next. Everything after it assumes the pose is one person's:

- The motion signal measures how far each joint moved between two samples. A pose that jumps from one person to another reads as the body travelling the distance between them, which is a burst.
- The crop frames the located joints in the window. When those joints belong to two people, the crop is drawn around both.
- When two people trick in turn, a trick becomes a clip only if its person is the one the model picks at that moment.

The evaluation footage has one multi-person take: a 240 s gym session where people trick in turn while others stand, sit and talk; MultiPose finds two or three people in 42% of its samples. On it, Thunder's pipeline cuts 19 clips, and about 11 of them show people standing, sitting or talking ("The gym take", below).

## What was true before this change

- **Model.** `MoveNetThunderModel` loaded `movenet_thunder_int8.tflite` (7 MB, `[1, 256, 256, 3]` uint8 in, `[1, 1, 17, 3]` float32 out) and checked both shapes at load. `PoseInputPreparer` letterboxed each frame into the square input.
- **One pose per sample, everywhere.** `PoseFrameResult` was one pose at one time, and `DetectedClips.poseFrames` one series per video. `ProcessedClip` and `ClipListItem` carried no person. The editor's Auto crop and the Clip List's follow crop both filtered `poseFrames` by the clip's window.
- **Live.** `LivePoseRecording` scored one pose per sample, and the camera overlay drew one skeleton. `PartialPoseFrames` and `PoseBackfill` merged one series by timestamp.

These still hold:
- **The farm's pose format** (`turnip-farm` `docs/POSE_FORMAT.md`, TKP1) is one pose of 17 COCO keypoints per frame.
- **The Profile (planned)** stores a source's pose as one TKP1 blob (`PROFILE_DESIGN.md` §2.2). Whose a clip is (`is_me`, §4.3) is chosen on a video's first clip and carries to its other clips.

## Design

### Model

[MoveNet MultiPose Lightning](https://tfhub.dev/google/lite-model/movenet/multipose/lightning/tflite/float16/1), the TF Lite float16 build, Apache 2.0 like Thunder. The file is 9.6 MB (Thunder's is 7 MB), sha256 `d4489f89e6bd6777a8b9a1a16189832131f84ff90d82fae729e670b84d7948dd`, checked 2026-10-21. It replaces Thunder: one model, one bundled file, one load per camera session and per Processing run, as today.

- **Input:** uint8 `[1, H, W, 3]` with H and W left open in the file. Both must be multiples of 32. The interpreter is resized to the take's own aspect before tensors are allocated: long side 384, the short side scaled and rounded up to 32. A portrait 1080×1920 frame becomes 224×384 and a landscape one 384×224. A run's frames share one render size, so that is one resize per Processing run. Live, it is one resize per recording, since the movie connection's orientation is known when Record is tapped. `FramePreprocessor` already letterboxes into any target size, and the pad goes in the 32-pixel rounding.
- **Long side 384, not 256:** at 256 the far athlete in the evaluation footage is lost entirely, three tricks out of three ("Measurements"). 256 is not a cheaper fallback.
- **Output:** float32 `[1, 6, 56]`, up to six people. For each person: 17 × (y, x, score) in COCO order, then the box (ymin, xmin, ymax, xmax), then the person's score. The keypoints and the box are both in the padded input's normalized space, and one `LetterboxMapping` inverts both. A person scoring below 0.25 is dropped; 0.25 is the reference implementation's default.
- **The 17 keypoints are Thunder's**: same names, same order, and a confidence per joint. `PoseKeypoint`, the 0.3 confidence threshold, the motion signal and TKP1 are unchanged.
- **The load-time checks change.** The file leaves the input size open, so there is no fixed input shape to check. The checks become a rank-4 uint8 input with three channels and a `[1, 6, 56]` output, and the bundled file's checksum in `Turnip/Models/README.md` and `ci_scripts/ci_post_clone.sh` is what tells a wrong variant apart.

### Tracking

The model gives up to six people per frame with no identity. A tracker links them into people. It runs once over a take's sampled frames after sampling (Processing), or over the scored frames at the hand-off (live). The whole take is known, so it never runs per frame on the capture path.

The starting point, which the spike measured:

- **Overlap first.** Each frame's people are matched to the tracks still alive, best match first, by box overlap (intersection over union) of at least 0.15. That is the reference implementation's box tracker.
- **Then reach.** A person nobody claimed by overlap joins the nearest unclaimed track if they are within 0.5 + 3 × Δt body sizes of where that track was last seen, Δt seconds ago. A body size is the longer side of the larger of the two boxes, in pixels. Without this, a flip carries a far athlete further between two samples than their boxes overlap, and every trick of the far athlete in the evaluation footage split into two tracks.
- **A track ends** when its person has gone unseen for longer than the re-link window. The window is open: 1 s splits a person who walks out of frame and back, and 2 s swaps people in a crowd ("Open problems").

A track is a person's pose on the take's own sample grid, from their first sample to their last, with an empty pose wherever they weren't detected. A missed sample stays an unknown sample to the motion signal, and two in a row are a gap. It must never become one longer step, which is what dropping the sample would make it.

### Detection per person

`detectClips` runs once per track, unchanged, and the clips are merged in start order. Each person's speed is measured in their own torso lengths against their own activity level, so someone else's movement can't make a burst in theirs. That is where most of the gym take's false positives go ("The gym take").

Two clips of different people may overlap in time, or cover the same moments. Each has its own crop.

### Data

- `DetectedPerson`: one person in one frame, with score, box and keypoints. `MultiPoseFrame`: everyone found in one sample, plus `primary`, the frame as a one-person consumer reads it (the most confident person's pose, built once so it keeps one identity). This is what the model returns, and what live recording and backfill carry in both modes. The mode is applied at detection, so a take recorded or partly scored in one mode can still be detected in the other.
- `PoseTrack`: an id and the person's `[PoseFrameResult]` from their first sighting to their last, as above. `PoseFrameResult` stays "one person at one time", so steps 4-6, `CropRectCalculator` and `CropPathCalculator` take a track's frames as they take a video's.
- `DetectedClips.poseFrames` keeps its meaning, the `primary` series, in both modes: it's what the original tile and a clip added by hand read. `DetectedClips.people` holds the tracks that own a clip, and only those, since the detection is hashed on every navigation push. `ProcessedClip.personID` and `ClipListItem.personID` name the clip's person, or are `nil` following one person. `DetectedClips.poseFrames(forPerson:)` and the clip list's own lookup give a clip its person's frames, or every scored frame without one.
- `ClipListViewModel.followCrop` and the editor's `ClipEditorSource` read the clip's own person's frames. A trim that drags a handle outward pulls in that person's frames beyond the window. The editor's commit keeps the person.
- `PartialPoseFrames` holds `[MultiPoseFrame]`. `PoseBackfill.merged` merges any timestamped frame, so it is unchanged in substance.
- `ProcessingPipeline.detect(in:people:renderedPixelSize:)` is the one detection both frame sources call: the file run, and the camera's hand-off.

### Screens

- **Camera:** a person control leads the top-right group, one figure for one person and two for everyone (`UIUX.md` §1b). It is read at the Record tap and disabled while recording.
- **Processing:** a segmented picker, "One person | Everyone", sits between the scrub bar and "Analyze clips" (`UIUX.md` §2). A run starts, and a retry restarts, in the mode it shows. A take the camera scored in part is detected in Processing's mode, not the camera's.
- **One setting behind both** (`TurnipSettings.personMode`, default one person), so the choice carries from one screen to the other and to the next session.
- **Name Clips** (Clip List until 2026-10-27): one clip per detected trick in start order, as before. Clips of different people can overlap, and each card's crop shows whose it is. No label or grouping by person: tracks have no stable identity across takes, and nothing in v1 needs one. "No tricks found" is unchanged.
- **Processing's progress overlay and the camera overlay** draw the followed person's skeleton, or everyone's.
- **Editor:** Auto crop and Auto follow frame the clip's own person. A hand-added clip keeps Reset crop (`UIUX.md` Rev 13).

### Live path

Live runs the same model and keeps everyone found per sample. The tracker runs at the hand-off, after the drain, in the mode read at the Record tap, and nothing on the capture path changes. Tracking a take's frames is a pass over a few thousand boxes, small next to the inference already done. The `LIVE_POSE.md` gate passes at the default 10 samples/sec on an iPhone 13 mini, and falls behind at 20/sec on takes over about 50 s ("Results" there). The queued tensor is 258 KB, so the 30-entry queue bound is about 7.7 MB.

### Contribution, Profile and privacy

The contribution and Profile notes are for the PRs that build those features. `PRIVACY.md` already records the last bullet.

- **TKP1 is unchanged.** A contribution carries one track, the clip's person, on the take's grid, and no one else's pose.
- **`is_me` carries per person, not per video** (`PROFILE_DESIGN.md` §4.3). A choice on a person's first clip carries to that person's other clips in the take.
- **Stored pose** (`PROFILE_DESIGN.md` §2.2) should keep only the tracks with a saved clip, not everyone the camera saw.
- Bystanders' keypoints exist in memory, as the athlete's do, and are never written to disk in v1. `PoseResultLogger` logs one line per live sample with the followed person's confidence and no coordinates.

## Measurements

The spike ran MultiPose at long sides 256 and 384 on the six evaluation videos, saved every frame's detections, and fed tracks into `ProcessingPipeline.detectClips` with the same scoring `TrickDetectionEvaluationTests` uses. Thunder's numbers are from the evaluation's saved pose of the same frames, and reproduce its last recorded score. The footage shows real people, so the spike's scripts, outputs and clip strips sit next to it, outside the repository.

### Model

Labelled footage: four tripod videos with 14 tricks, and one handheld video with one.

| | Tripod: caught / partial / missed / false positives | Handheld | Usable pose in trick windows | Far athlete only |
|---|---|---|---|---|
| Thunder | 12 / 1 / 1 / 1 | caught | 76% (288/378) | 46% |
| MultiPose 256, top person | 10 / 0 / 4 / 0 | missed | 84% (319/378) | 58% |
| MultiPose 384, top person | 13 / 0 / 1 / 1 | caught | 90% (339/378) | 79% |

"Usable" is the escalation ladder's own measure (`DESIGN.md`): at least 6 joints above 0.3 confidence. It compares confidences, and the two models may calibrate confidence differently, so the trick score is the stronger evidence. At 256, MultiPose misses all three of the far athlete's tricks.

Inference per frame, iPhone 15 simulator on the development Mac, CPU, no delegate: Thunder 40.6 ms, MultiPose 256 (160×256) 21-24 ms, MultiPose 384 (224×384) 40-43 ms.

### Tracking on single-athlete footage

With the overlap-then-reach tracker, every labelled trick lies inside one track. With overlap alone, each of the far athlete's three tricks splits across two tracks.

| Re-link window | Tripod: caught / partial / missed / false positives | Handheld |
|---|---|---|
| 1 s | 12 / 0 / 2 / 1 | caught |
| 2 s | 13 / 0 / 1 / 1 | caught |

The trick the 1 s window loses is not lost to tracking during the trick. The athlete leaves the frame 0.2 s after landing and comes back 1.6 s later, as a new track. Their quiet walk back then belongs to the second track, so in the first track the trick no longer stands out from the person's own activity level.

### The gym take

Unlabelled. The counts below are read from an 8-frame strip of each clip, cropped to the clip's crop, and are unverified.

| | Clips | Tricks | Same trick again | No trick | Unclear |
|---|---|---|---|---|---|
| Thunder | 19 | 7 | 0 | 11 (people standing, sitting, talking, moving mats) | 1 |
| Per person, 1 s re-link | 10 | 7 | 1 | 1 (a walk) | 1 |

Between them the two find eight tricks. Each misses one the other catches. Thunder misses a flip at 38 s that per-person catches. Per-person misses a flip at 238 s, the last seconds of the take ("Open problems").

With the 2 s window, the tracker merges 20 tracks into 10, and the identity strips show at least five of them switching from one person to another. A switch inside a track counts the jump between two people as speed, and draws the crop around both. With the 1 s window, switches still happen where two people cross or one replaces another at the same spot. Two of the 1 s window's clips frame a second person because of one.

### Colour as identity (measured, not adopted)

The mean colour of a person's torso (shoulders to hips) and thighs (hips to knees), sampled from the frame at the joints' positions, separates the people in the gym take. Between one sample and the next, the same person's colour distance is at most 54 nine times out of ten (RGB, 0-255). Two different people in the same frame have a median distance of 72.

- As a hard gate on every match, it breaks athletes mid-flip, where the joints are upside down and the samples land off the clothes: the tripod score falls from 13 caught to 11.
- As a tie-breaker, only when more than one person could match, with the 2 s window, it keeps the tripod score at 13 / 0 / 1 / 1. On the gym take its identities read as cleaner in the strips. But its clips caught two fewer tricks than the 1 s tracker without colour, and counted a passer-by at the lens as a trick.

Worth trying again against labels; not adopted on this evidence.

## Open problems

1. **A person on screen only while tricking has nothing to stand out from.** Their activity level is the median of their own speed within 5 s, and if all of their own samples are the trick, the trick is the baseline. The gym take's last flip is this: the person is on screen for 3 s, all of it moving. Thunder's single series caught it, because other people's quiet stood in for theirs. A fix changes the activity level for short tracks, which is a detector change measured against labels.
2. **Re-linking a person who leaves and comes back, without swapping people.** A short window splits one person in two, which costs the tripod footage a trick. A long one swaps people in a crowd. Position and size alone can't tell a returning person from someone else arriving at the same spot. Colour can partly, but not while the person is upside down.
3. **A passer-by close to the lens.** Per-person detection measured one in the gym take's first seconds as a trick. `DESIGN.md`'s "a passer-by at the lens reads as walking" holds for a person far enough away that their torso stays in frame. A person right at the lens doesn't fit that.
4. **No labelled multi-person footage.** Every gym-take number above is read from strips. Step 3 of the decision is what makes the other three measurable.

## Rollout

1. **Model swap** (built, #238): `MoveNetMultiPoseModel`, bundling, the load-time checks, and the `LIVE_POSE.md` gate.
2. **The person mode** (built): the setting and its two controls, the tracker, per-person detection in Processing and at the camera's hand-off, clips that carry their person through the Clip List and the editor, and every skeleton on both overlays. The Swift tracker reproduces the spike's tracks and clip windows exactly on its saved detections for all six evaluation videos.
3. **Labels and tuning:** trick windows, and who did each, on the gym take and ideally one more multi-person take, then the open problems against them. `TEST_RUNNER_TURNIP_EVAL_PEOPLE=everyone` runs the evaluation following everyone.
4. **Docs for features not built yet:** `CONTRIBUTION_DESIGN.md` §2.1 and §9 (a contribution carries the clip's own person) and `PROFILE_DESIGN.md` §2.2 and §4.3, when those land.

## Alternatives

- **Thunder on each person's crop**, with MultiPose finding the people. It keeps Thunder's keypoints and zooms in on far people, at the cost of one more inference per person per frame. Not needed: MultiPose at 384 already scores better than Thunder on the labelled footage.
- **Apple Vision's `VNDetectHumanBodyPoseRequest`.** Multi-person, built in, no bundled file. But it returns 19 joints, not COCO's 17, which breaks TKP1 and the trick model's input, and it is untested here on inverted bodies.
- **Following one athlete per take.** Pick the most active person and drop the rest. Smaller: no data or screen changes. Not chosen: a session where several people trick in turn should give each of them clips.
- **BlazePose and RTMPose** from the escalation ladder: single-person, or needing a person detector bundled alongside.
