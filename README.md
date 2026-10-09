# Turnip

**Auto-editor for tricking practice videos.** Take a raw recording of a
tricking session on your phone, and Turnip trims out the setup and wait
time, splits multi-trick recordings into one clip per trick, and
auto-crops each clip to the athlete.

Named for **turn + snip** — the two things it does.

## What it does

You film a tricking session. Turnip:

1. **Detects each trick** — finds the contiguous spans of athletic
   motion inside your recording.
2. **Trims each window** — a configurable 1-second buffer on either
   side, no walk-to-the-spot / wait-for-your-turn dead time.
3. **Auto-crops** — bounding box of the athlete across the trick,
   expanded to a target aspect ratio (9:16 for Reels/Shorts by default).
4. **Exports** — one clip per trick, straight to your Photos library.
   Tap-preview / tap-reject / drag-adjust each in the preview UI before
   export.

All on-device. No server, no data upload for the core auto-edit path.

## Privacy

Turnip v1 never sends your videos anywhere: no accounts, no uploads, no
analytics. The app asks for Photos access only to show your videos and
save the clips you export. The App Store privacy answers, the privacy
manifest, and temp-file hygiene are documented in
[`docs/PRIVACY.md`](docs/PRIVACY.md). Upload and accounts arrive with v2
as an explicit opt-in, and the privacy story will be updated then.

## Status

Very early, but the v1 flow now runs end to end. Home (a grid of every
video in your Photos library — the first of the v1 screens in
[`docs/UIUX.md`](docs/UIUX.md)) pushes `Processing` when you tap a video;
`Processing` runs the detection pipeline and pushes `ClipList`, whose
triage grid opens `ClipEditor` for a derived clip and saves everything
kept straight to Photos when you tap "Save Clips" — no separate export or
confirmation screen.

Steps 4-6 of the pipeline — turning pose keypoints into trick windows and
a crop rect — are library code under `Turnip/TrickDetection/`, unit-tested
and driven by `Processing`'s pipeline rather than by a screen of their own.

The camera runs pose inference on its live frames while a take is being
recorded, draws the skeleton on the preview, and — when live inference
covered the whole take — runs the same trick detection on those results
so the take lands on `ClipList` straight from Stop, with no second decode
(`Turnip/LivePose/`, per [`docs/LIVE_POSE.md`](docs/LIVE_POSE.md)). A take
it could not cover end to end goes through `Processing` like a tapped tile.

Two directories sit outside that flow. `PoseDiagnostic` — the design doc's
"empirical test" first work item, which runs MoveNet Thunder over a video
and overlays per-frame keypoints — is no longer pushed from Home, which
goes to `Processing` instead. It is constructed by its own Xcode preview
and by the `#if DEBUG` screenshot harness that `TurnipUITests` launches
with `-screenshotPoseDiagnostic`. `ModelUpdates` holds an OTA client no
app code constructs. Read those two as tested components, not as features
you can run.

See [`docs/DESIGN.md`](docs/DESIGN.md) for the full architecture plan
including the community labeling + continuous ML training that will
follow the standalone MVP, and [`CONTRIBUTING.md`](CONTRIBUTING.md) for
dev setup.

## Requirements

- iOS 16 or later (covers ~98% of active iPhones as of 2026; the
  Vision framework body-pose API technically landed in iOS 14, but
  targeting iOS 16 drops the iOS 14/15 back-compat surface with
  negligible device-coverage cost)
- No particular chip. Pose inference runs on the CPU through TensorFlow
  Lite — no Core ML or Metal delegate is configured — so every iOS 16
  device and the simulator run the same code path. Neural Engine
  delegation is a possible future option, not a requirement; see
  [`docs/DESIGN.md`](docs/DESIGN.md)
- Xcode 26.3 for building from source — the version CI verifies. Xcode 15
  is the nominal minimum but is not covered by CI; see
  [`CONTRIBUTING.md`](CONTRIBUTING.md)

## Contributing

Contributions welcome. The design doc's "Contribution ramp" section
names the areas most open to new contributors. Standard flow:

1. Fork the repo
2. Branch from `main`
3. Open a PR against `hoiekim/turnip-ios`

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for dev setup, coding style, and
PR conventions.

## License

[Apache 2.0](LICENSE).

## Sibling repos (planned)

- `turnip-farm` — backend service (video upload, labeling,
  moderation, dataset export)
- `turnip-ml` — Python training pipeline (fine-tunes the pose
  model on the community labeled dataset and publishes new Core ML
  versions)

Both are deferred until the standalone MVP proves out on-device
accuracy; see [`docs/DESIGN.md`](docs/DESIGN.md) § "System architecture".
