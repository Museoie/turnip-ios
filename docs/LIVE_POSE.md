# Live pose inference during recording

*Rev 8 · 2026-10-23 · A take goes straight from Stop to the clip list on its live results; Processing is the fallback, and analyzes only what live inference missed. The gate has been run on an iPhone 13 mini at 30 fps and passes at the default rate; it has not been run on an A11 device or at 240 fps. Rev 1 was the design draft, Rev 2 the flag-gated prototype, Rev 3 the preview overlay. Rev 5 notes the 10 samples/sec and 100 ms grid this whole doc otherwise treats as fixed are the shipped default, overridable by the Settings screen's analysis granularity (`docs/UIUX.md` §1a) — every occurrence below describes that default, and every device number below (the queue-size math, the acceptance gate's own samples/sec target) is stated, and was validated, at it. Rev 6 keeps the frames a take that fell short did score and has Processing sample only its gaps ("From results to clips"). Rev 7 records the model swap to MoveNet MultiPose Lightning, whose input takes each recording's own orientation and is a third larger per sample; the gate must be run with it. Rev 8 records that run ("Results", under the gate).*

*Companion to [`DESIGN.md`](DESIGN.md). This doc covers one question: can the pose pass start when recording starts, instead of after the file is written? Pipeline shape, budgets and model choice stay as recorded in `DESIGN.md`.*

## Decision

**Go, gated on one on-device test.** Add an `AVCaptureVideoDataOutput` alongside the existing `AVCaptureMovieFileOutput`, sample the live frames at the same 10 samples/sec the file path uses, and let inference lag behind the recording and finish after it. It runs on every recording, draws the scored skeleton on the camera preview while the take is being filmed, and when it covered the whole take the same trick detection Processing runs is applied to its results and the take lands on the clip list with no second decode. The gate in "Acceptance gate" still has to pass on the oldest supported device at 240 fps; until it does, the recording's own frame count is the thing to watch.

The recorder itself does not change. If the gate fails on the recording side, the fallback is the `AVCaptureVideoDataOutput` + `AVAssetWriter` rewrite described under "Alternatives", not a weaker version of this design.

## Problem

Today the pose pass is strictly post-hoc. `VideoFrameSampler` decodes the finished `.mov` with `AVAssetReader`, keeps every `round(fps / 10)`th frame, and hands each one to `MoveNetThunderModel`. For a 240 fps slo-mo take this means a full HEVC decode of the file after the user taps Stop, before any clip boundaries exist. The user waits for work that could have been done while they were still filming, on frames the ISP had already produced.

The goal is to have inference finish seconds after Stop rather than after a second decode. Deadlines are explicitly relaxed: inference is allowed to lag behind the recording and complete after it. What is not relaxed is the recording itself, which must stay drop-free.

## What was true before this change

These facts, as of Rev 1, shaped the design more than any external reference. Where Rev 2 changed one, the "Design" section says so.

- **Recording** was `AVCaptureMovieFileOutput` only, with no `AVCaptureVideoDataOutput` anywhere in the app. The session runs `sessionPreset = .inputPriority`, formats are filtered to `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange`, and frame rates offered go up to 240. All of that still holds; the data output is the addition. (Since 2026-10-08 the session also carries an `AVCaptureMetadataInput` connected to the movie output, which writes the phone's roll into the take as a metadata track — `RollTrackRecorder`, for the editor's Auto rotate. A third connection on the movie output, so the 240 fps gate below should be re-run with it in place; it appends one small group ~30 times a second and touches no video path.)
- **Inference** is TensorFlow Lite on the CPU: `Interpreter(modelPath:)` with no options, no delegate, default thread count. The video encoder is hardware. So the two workloads share the CPU with the capture session's own CPU work; they do not fight over the GPU or Neural Engine.
- **Preprocessing** is a Core Image letterbox rendered into a 32BGRA target, then an RGB repack into the 256×256×3 uint8 tensor. The 32BGRA guard is on the rendered target, not the source, so a 420v source buffer is fine. It lived on the model actor; Rev 2 moved it to `PoseInputPreparer`.
- **Sampling** is ~10 frames/sec of footage regardless of source fps (stride 3 at 30 fps, 24 at 240 fps on the file path). Inference is "tens of ms per frame" against a 100 ms per-sample budget.
- **Results** are appended to a per-frame array in timestamp order. `MotionSignalBuilder` differences consecutive frames and depends on that order.
- **Minimum iOS is 16.0.** This matters: before iOS 16, a movie file output and a video data output could not both be active on one session. Apple's `AVCaptureVideoDataOutput` documentation states that for apps linking against iOS 16 or later the restriction no longer exists.
- **No thermal handling** existed anywhere; `ProcessInfo.thermalState` was unused. Rev 2 observes it for the duration of a live-pose recording only.
- The file path loads the model via `load()` on every Processing run (`ProcessingPipeline.defaultInference`); the camera screen loads it once.

## Prior art

- **Apple's live-pose pattern** (WWDC20 "Detect Body and Hand Pose with Vision", the Action & Vision sample): `AVCaptureVideoDataOutput` on a dedicated serial queue, `alwaysDiscardsLateVideoFrames = true`, inference per delegate callback, frames dropped rather than queued when inference falls behind.
- **Recording plus ML before iOS 16**: because both outputs could not be active, ML camera apps fed a single `AVCaptureVideoDataOutput` stream to both an `AVAssetWriter` and the model. One frame stream, free timestamp alignment, but the app owns encoding, audio muxing, orientation and slo-mo metadata.
- **Recording plus ML on iOS 16+**: both outputs on one session. One format-dependent failure has been reported (ProRes422), which is why the gate below is specific about 420v at 240 fps rather than trusting the general statement.
- **Production practice**: measure inference time and adapt the sample rate instead of assuming a fixed budget; observe `ProcessInfo.thermalState` and back off at `.serious`, stop at `.critical`.

## The constraint that shapes everything

"Start now, finish later" cannot mean "queue raw frames, drain later." `AVCaptureVideoDataOutput` hands the delegate `CMSampleBuffer`s from a small fixed pool. Retain them past the callback and the output stalls or drops. So the only viable shape is to reduce each kept frame to its model input tensor synchronously, inside the callback, and queue the tensor.

The tensor is 224 × 384 × 3 bytes ≈ 258 KB for a portrait take, the same turned on its side for a landscape one. At 10 samples/sec that is ≈ 155 MB per minute if nothing drains, so the queue is bounded and the bound is a safety valve, not steady state. With inference in the tens of milliseconds and a 100 ms budget the queue should sit near empty; it only grows under thermal throttling or CPU contention.

## Design

### Capture side

1. Add an `AVCaptureVideoDataOutput` to the session next to `movieOutput`, ahead of it, in the same `beginConfiguration` block that builds the session, so the recorder's connection is formed after it. The mirroring policy is applied to both outputs, and re-applied to both on a front/rear flip.
2. Set `videoSettings` to an **empty dictionary**, not nil. Rev 1 said nil; the header says nil asks for a default *uncompressed* format and the empty dictionary asks for the device's native format. The device format is 420v, and forcing a conversion would make the ISP convert all 240 frames/sec for the 10 that are kept. `CIImage(cvPixelBuffer:)` accepts 420v; `PoseInputPreparerTests` checks that on a 420v buffer.
3. `alwaysDiscardsLateVideoFrames = true`. A dedicated serial queue with `.userInitiated` QoS, separate from `sessionQueue`. Session mutations and frame delivery must not block each other.
4. In `captureOutput(_:didOutput:from:)`, keep frames by **presentation time**, not by counting them: a frame is kept when it is at or past the next 100 ms slot on a grid anchored at the first kept frame (`LivePoseFrameGate`). Rev 1 said to reuse the file path's frame-count stride, but with late frames discarded the callback never sees the frames that arrive while a kept one is being letterboxed, so counting would undersample by however many were skipped. Time cannot be skipped. A gap longer than one slot re-anchors the grid rather than admitting a burst. Non-kept frames return after one lock and a compare.
5. For kept frames: read the presentation timestamp, run the letterbox to the model's input tensor, push `(timestamp, tensor)` to the per-recording queue, return. Never retain the sample buffer or the pixel buffer. The letterbox runs outside the lock.
6. Frames arrive only while the movie output is recording. The data output delivers whenever the session runs; gate on the recording state so preview-only time costs nothing. The tap is armed on the Record tap and starts counting at `fileOutput(_:didStartRecordingTo:from:)`.
7. The data output delivers buffers in the sensor's orientation; the movie output writes its orientation as a track matrix, and the file path renders through it before the model ever sees a frame — MoveNet is trained on upright subjects and degrades on a sideways one. The live path matches that instead of correcting for it afterward: the letterbox composes the angle between the two connections (`LivePoseKeypointRotation.relativeDegrees`, read at record start) into its `CGAffineTransform` (`FramePreprocessor.uprightTransform`), so every kept frame is uprighted before it is scaled and centered, and the resulting keypoints are already in the movie connection's orientation with nothing left to rotate at the consumer. Rotating the data output's connection instead would physically rotate every buffer. The sign convention (clockwise, `videoRotationAngle` terms) is unit-tested but the pairing with what the two connections actually report needs the device run.
8. The overlay takes a different route to the screen. Each result is rotated back into capture-device coordinates (the movie connection's rotation undone) and handed to `AVCaptureVideoPreviewLayer.layerPointConverted(fromCaptureDevicePoint:)`, which folds in the preview's own rotation, the front camera's mirroring and the aspect-fit letterbox. That is why the skeleton is drawn in UIKit, as shape layers on the preview view, rather than in a SwiftUI canvas that cannot see any of those. Only joints above the confidence threshold are drawn; on a live preview a hollow "guess" reads as a wrong detection.

### Inference side

1. `MoveNetMultiPoseModel` is loaded once, when the camera first starts, and reused across recordings. A take that starts before it has loaded records normally without live pose; a load failure is a build problem (the `.tflite` is not bundled) and is logged, never shown as a recording error. Processing's file path loads its own model per run.
2. The letterbox and RGB repack live in `PoseInputPreparer`, a synchronous function callable from the capture queue and exposed off the actor as `MoveNetMultiPoseModel.inputPreparer`. The preparer sizes each input to the uprighted frame: a long side of 384, the short side rounded up to a multiple of 32, so a portrait recording's inputs are 224×384 and a landscape one's 384×224. The actor takes a `PoseModelInput` (tensor plus letterbox mapping) and resizes its interpreter when an input arrives at a new size, which is the first sample after the orientation changes between recordings. It returns every person it found, and the recording keeps them all: which of them the take is cut into clips for (`PersonMode`, `docs/MULTI_PERSON.md`) is read at the Record tap and applied at the hand-off, and the overlay draws the followed person or everyone. The pixel-buffer overload the file path calls delegates to the same preparer, so there is one preprocess implementation.
3. A per-recording queue (`LivePoseSampleChannel` over `BoundedSampleQueue`), bounded to 30 entries ≈ 3 s ≈ 7.7 MB. Drop-oldest on overflow; drops and the high-water mark are counted. `LivePoseRecording` drains it through the model actor and appends results in dequeue order, which is timestamp order because the queue is FIFO and the capture callback is serial.
4. The queue is created on the Record tap and owned by the recording, not the screen. Stop finishes the producer, waits for the consumer to drain — one inference in steady state, at most the queue bound — then logs the recording's metrics and hands the file on together with the take's clips. The record button is disabled for that wait so a new take cannot cancel it. Leaving the camera tab and session teardown cancel a drain still in progress, and the file is still handed on, without clips. A consumer that outlives the recording is always the one for that recording, never a shared one.
5. Results reach the overlay through the recording's result handler as each one is scored, so the skeleton lags the picture by one inference plus whatever is queued — tens of milliseconds when the queue sits empty. The overlay clears when the recording ends.
6. Per-sample preprocess time and inference time are recorded separately (`LivePoseMetrics`). A Debug build runs the letterbox loop unoptimized, so when the gate is read from a Debug run the two must not be conflated.

### From results to clips

The live results are the same shape the file sampler produces — frame-normalized keypoints in the file's display orientation, file-relative timestamps, ten per second — so steps 4-6 (motion signal, trick windows, crop rects) run on them unchanged, through the one `ProcessingPipeline.detect` both routes call, in the take's person mode. The crop step measures against the sensor's dimensions transposed for a portrait movie connection, the live equivalent of the file path's composition render size.

A take only skips Processing when live inference covered it end to end at the normal rate (`LivePoseCoverage`): no inference error, not cancelled, no thermal stop, no time under `.serious` (a stretch at half the rate is coarser than the file path samples), no queue drops, no preprocess failures, every kept sample scored, and the scored count within two of the grid's count over the recording's duration. Anything short of that hands the file on with no clips, and Home goes to Processing as it does for a tapped tile, but with the frames live inference did score (`PartialPoseFrames`) when there are any: a shed sample, a stretch at the halved rate, a thermal stop, a drain cut short and a model failure partway all leave valid frames behind.

"Analyze clips" then samples only the stretches those frames miss (`PoseBackfill`). A gap is two consecutive live samples more than 1.5 intervals apart, which live jitter of up to a capture frame never reaches and the halved rate always does. It is filled at the live pass's own spacing, not at Processing's granularity setting, from one interval after the sample before it to more than half an interval short of the one after it; a gap at the head is filled backward from the first sample, the tail forward to the end of the file. `VideoFrameSampler` reads those times with readers started mid-file, one per run of times no more than a second apart, since each reader decodes forward from the keyframe before its start, and hands over the first frame at or after each time. A file frame that lands within half an interval of a live sample is dropped: the motion signal divides displacement by the time between samples, and keypoint jitter over a few milliseconds reads as a burst. The merged frames go through the same `detectClips`, so the user never gets a worse clip list than the file path gives, only a faster one.

The frames ride on the pushed `SelectedVideo` and in a per-session store in `VideoLibraryViewModel` (the last eight takes), so a take backed out of Processing and opened again later still analyzes only its gaps. They are never written to disk: v1 persists no pose data (`docs/PRIVACY.md`).

A take with complete coverage and zero detected windows still lands on the clip list (the original tile and the add tile) rather than falling back to Processing: a second decode would find nothing, and the clip list is where a clip can be added by hand. This is the same place a zero-trick *file* analysis lands too — Processing has no empty-result state of its own; the clip list's dismissible "No tricks found" notice covers both routes.

The clips are attached to the `SelectedVideo` Home pushes, so the windows are applied to the asset PhotoKit hands back for the saved take. That asset is a plain file on the recording's real timeline: the saved take carries no slow-motion adjustment, so PhotoKit does not answer with the retimed composition it builds for the Camera app's slo-mo videos, and the live timestamps line up with it. If the saver ever writes that adjustment, this is the assumption that breaks.

### Timestamps

Live presentation timestamps are on the session clock. The written file's timeline starts at approximately zero, at the first video sample the movie output wrote. The trick windows detected from the results are applied to the saved file's timeline, so results need a file-relative time.

Anchor on the presentation timestamp of the first data-output frame delivered after `fileOutput(_:didStartRecordingTo:from:)` fires, and subtract it. This is off by at most one or two frames, which at 240 fps is under 10 ms. That is fine for clip-boundary detection at the 10 samples/sec resolution the pipeline already works at. If a later consumer needs sub-frame alignment, the tightening is to compare the first live timestamp against the file's first sample after recording ends, and re-offset the results once.

### Thermal policy

Observe `ProcessInfo.thermalStateDidChangeNotification` for the duration of a recording.

- `.nominal`, `.fair`: the normal 100 ms sample interval.
- `.serious`: double the interval (5 samples/sec), from the last kept frame onward. Count the seconds spent here.
- `.critical`: stop sampling for this recording; the consumer still drains what was queued. The recording is never touched.

Coverage under backoff is not deterministic. Processing fills the time that was skipped or dropped from the file ("From results to clips").

### Where it lives

The camera screen. `CameraCaptureViewModel` owns the tap and the model, arms a recording on each Record tap, publishes the latest pose for `CameraPreviewView` to draw, and on Stop waits for the drain, logs the recording's metrics (`LivePoseLogger`, log category `LivePose`), and hands the file on with the take's clips when coverage was complete, or with the frames that were scored when it was not. `RootTabView` saves the file to Photos and selects the saved asset with whichever it got; `VideoLibraryViewModel.select` carries them onto the pushed `SelectedVideo`, and Home's destination lands a video that has clips on the clip list and one that does not on Processing. There is no flag and no review screen: the metrics line is the gate's readout, collected from the device log.

Everything live-specific is in `Turnip/LivePose/`; the shared changes are the preprocess seam in `Turnip/Pose/` and `detectClips` on `ProcessingPipeline`. The live path did not need a second `FrameSampling` source: the pipeline's detection step is separable from its sampling step, so the live results go in after sampling rather than through it.

## Acceptance gate

The unverified combination is a movie file output and a video data output both active **at 240 fps in 420v**. Apple's statement about iOS 16 is general and one format-dependent failure exists, so the general statement is not enough. Run on an A11 device (iPhone 8), 240 fps, a take of at least three minutes, then collect the device log (`log collect` or Console.app, subsystem `com.hoiekim.turnip`, category `LivePose`). All three must pass:

1. **The recording has no dropped frames.** `AVCaptureMovieFileOutput` does not report drops. Read the saved file's video track (`ffprobe -count_frames`, or `AVAssetReader` in passthrough) and compare its sample count against duration × nominal frame rate. The baseline to compare against is the same take on a build with the data output's `addOutput` line removed.
2. **Inference sustains about 10 samples/sec** with the queue near empty. The "Live:" log line reports samples/sec, queue drops, maximum queue depth, late-frame discards, and preprocess and inference times separately.
3. **Thermal state stays at or below `.fair`** for the whole take, and the recording keeps its frame rate under `.serious` if it is reached. The "Live:" line reports seconds spent at `.serious` and whether `.critical` stopped sampling.

Also check on the device, since no test here can: that the skeleton lands on the athlete on the preview in portrait, on both the rear and the mirrored front camera (the keypoint rotation's sign pairing and the preview layer's device-point mapping); that a clean take lands on the clip list with its windows on the tricks; and that the "Live:" line for a take that fell back to Processing names why.

Fail (1): the recorder is the constraint; move to the `AVAssetWriter` alternative. Fail (2) or (3) only: the model is the constraint; try `Interpreter.Options.threadCount` first, then the Core ML delegate, and rerun the gate. The Core ML delegate brings the Neural Engine into play and has its own op-support risk for MoveNet, so it is the second lever, not the first. On an A15, two threads did not hold up over longer takes ("Results"), so check it the same way before relying on it.

### Results

**iPhone 13 mini (A15), iOS 27.0.1, Release build, 2026-10-21 and 2026-10-23.** MoveNet MultiPose Lightning at a long side of 384 (Rev 7), rear camera, 1080p at 30 fps, portrait. Turnip's format menu offers nothing above 60 fps on this phone, so the 240 fps condition was not run. No single take reached three minutes.

At the default 10 samples/sec with one inference thread, which is what ships, two takes, the second started about a minute and a half after the first ended:

| Take | Length | Scored | Queue drops (max depth) | Inference avg / max | At `.serious` | After Stop |
|---|---|---|---|---|---|---|
| 1 | 73.1 s | 732 of 732 | 0 (1) | 45.7 / 59.3 ms | 0 s | clip list |
| 2 | 81.2 s | 813 of 813 | 0 (1) | 45.9 / 92.5 ms | 0 s | clip list |

All three checks pass for this device and format:
1. Each file holds exactly duration × 30 frames. Nothing dropped, so no baseline build was needed.
2. Every kept sample was scored, with the queue at most one deep.
3. No time at `.serious`.

Preprocess averaged 1.6–1.7 ms.

At 20 samples/sec, a Settings choice that halves the budget to 50 ms, the two shorter takes kept up and the three longer ones fell behind:

| Threads | Started | Length | Scored | Queue drops | Inference avg / max | After Stop |
|---|---|---|---|---|---|---|
| 1 | first that day | 18.1 s | 362 of 362 | 0 | 44.8 / 51.7 ms | clip list |
| 1 | 19 min after it | 56.4 s | 1,104 of 1,128 | 24 | 51.6 / 70.6 ms | Processing |
| 1 | 3 min after that | 50.3 s | 973 of 1,006 | 33 | 52.5 / 106.5 ms | Processing |
| 2 | first that day | 38.3 s | 766 of 766 | 0 | 28.3 / 42.3 ms | clip list |
| 2 | 24 s after it | 66.5 s | 1,112 of 1,331 | 219 | 61.4 / 111.6 ms | Processing |

None of these spent time at `.serious`, and every file had all its frames. Sustained load moved inference time more than the second thread did: two threads was the fastest in the 38-second take and the slowest in the 66-second take after it. These runs can't tell apart the take's own length and the phone's state after the take before. At 10 samples/sec the model is busy about half the time instead of nearly all of it, and the 73- and 81-second takes held at 46 ms. A take that falls behind goes to Processing with the frames it did score, which fills only the gaps. If 20 samples/sec has to stay live, two levers are left: the Core ML delegate, or halving the rate when the queue fills, the way `.serious` already does.

Not covered by these runs:
- an A11 device or 240 fps;
- a single three-minute take;
- the front camera;
- whether the skeleton lands on the athlete on the preview, and whether a clean take's windows land on the tricks.

The phone was paired over Wi-Fi, where `log collect` needs root and a console attached through `devicectl` dropped within about half an hour. So the runs used a scratch build that also wrote each "Live:" line to a file in the app's container, read off the phone with `devicectl device copy from`.

## Alternatives

**`AVCaptureVideoDataOutput` + `AVAssetWriter`, replacing the movie file output.** One frame stream feeds the encoder and the model; timestamps align for free; this is the pre-iOS 16 pattern and what most ML camera apps do. Rejected for now because it re-implements audio muxing, orientation, HEVC settings and slo-mo metadata in app code, and risks regressing a recorder that works. It is the fallback if the gate fails on the recording side.

**Read the file while it is being written.** With `movieFragmentInterval` set the file is readable mid-recording in principle, but `AVAssetReader` over a growing file is not a supported path. Rejected.

**Keep it post-hoc and speed up the decode.** Lower cost, no concurrency risk, but the decode is the floor: a 240 fps HEVC take still has to be decoded once after Stop. Kept as the baseline the gate compares against.

**Queue raw pixel buffers and preprocess later.** Simpler on paper. Not viable: the capture pool is small and retaining buffers stalls delivery. See "The constraint that shapes everything".

## Tradeoffs recorded

- Results are ready within one inference of Stop, and the post-hoc decode of a 240 fps file is skipped for a take with complete coverage.
- Coverage is not deterministic under thermal backoff or drops. A take with incomplete coverage goes through Processing, which samples only the gaps in what live inference scored instead of decoding the whole file again.
- Two frame sources feed one model and one detection step. The preprocess and detection steps are shared; the sampling step is not, and does not need to be.
- A lagging consumer has an explicit lifecycle. Stop finishes its queue and lets it drain; every path that abandons a recording cancels it.
- The simulator has no camera. Every change on the capture side needs a device run; `LivePoseTests` covers the frame gate, the queue bound and drop policy, the channel hand-off, the drain loop's endings, the timestamp offset, the thermal policy, the keypoint rotation, the overlay geometry and the coverage rule as pure functions; `PoseInputPreparerTests` covers the shared preprocess on 420v and BGRA buffers; `ProcessingPipelineRunTests` pins `detectClips` to what `run` produces for the same frames; and `VideoLibrarySelectionTests` covers clips travelling with the pushed video.

## Out of scope

On-screen inference metrics for users, and changing the recording format or codec.
