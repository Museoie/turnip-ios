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

## Status

Very early. As of 2026-09-06 the repo has initial app scaffolding: the
Home screen (a grid of every video in your Photos library — the first of
the v1 screens in [`docs/UIUX.md`](docs/UIUX.md)) and a pose-detection
diagnostic screen (tap a video, run MoveNet Thunder on it, log per-frame
confidence + keypoint count) — the latter is the design doc's "empirical
test" first work item, not the auto-edit pipeline itself. See
[`docs/DESIGN.md`](docs/DESIGN.md) for the full architecture plan
including the community labeling + continuous ML training that will
follow the standalone MVP, and [`CONTRIBUTING.md`](CONTRIBUTING.md) for
dev setup.

## Requirements

- iOS 16 or later (covers ~98% of active iPhones as of 2026; the
  Vision framework body-pose API technically landed in iOS 14, but
  targeting iOS 16 drops the iOS 14/15 back-compat surface with
  negligible device-coverage cost)
- A11 Bionic or later gives Neural Engine acceleration
  (iPhone 8/X and newer — all iOS 16-capable devices qualify)
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
