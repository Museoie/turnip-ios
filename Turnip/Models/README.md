# Models

The app expects a MoveNet Thunder model file here, named exactly:

```
movenet_thunder_int8.tflite
```

This file is **not committed to the repo** (see the root `.gitignore`) — it's a ~7 MB binary
ML artifact, and downloading it automatically without a human confirming provenance/license/
variant isn't something the tooling does on your behalf. The app builds and runs without it;
the pose diagnostic screen will just show a "model not found" error until it's in place.

## Getting the file

1. Go to the Kaggle Models page for MoveNet:
   `https://www.kaggle.com/models/google/movenet/tfLite/singlepose-thunder-tflite-int8`
   (**unverified by this scaffolding** — confirm the page still hosts the int8 singlepose
   Thunder variant under Apache 2.0, per `docs/DESIGN.md`'s licensing claim, before using it.)
2. Download the int8-quantized singlepose Thunder `.tflite` file.
3. Rename/place it at `Turnip/Models/movenet_thunder_int8.tflite`.
4. Confirm you got the right variant: `MoveNetThunderModel` reads the bundled file's input
   and output tensors at load and rejects anything that isn't the Thunder singlepose int8
   shape — `[1, 256, 256, 3]` input, `[1, 1, 17, 3]` output — with a visible error instead of
   silently producing worse keypoints. If the diagnostic fails with an input-shape or
   output-shape error, the file you downloaded is a different variant (Lightning is 192x192)
   — go back to step 1. If it fails with a data-type error like "Model input wants Float32,
   the frame packing writes uInt8", you downloaded the fp16 or fp32 Thunder build instead of
   the int8 one — also go back to step 1.

## Why there is no checksum here

A SHA-256 used to be recorded in this file, but it was removed in #38: it was written by the
scaffolding commit in the same change that disclaimed the source as unverified, and the weights
are gitignored, so nobody could ever check it against anything in the repo. An unbacked hash
invites a verification whose result cannot be interpreted — a disagreeing hash tells the
contributor nothing about whether they grabbed the wrong variant. The load-time shape check in
step 4 is the checkable anchor instead: it fails on the wrong variant rather than silently
degrading.

When the Kaggle source is verified (step 1 above), record here: the resolved download URL,
the date checked, the file size in bytes, and the SHA-256 you computed — and delete the
"unverified by this scaffolding" parenthetical.

## Why a folder reference

`project.yml` references this directory as an XcodeGen **folder reference**, not a group. That
means Xcode picks up the file the moment you drop it in — you don't need to rerun
`xcodegen generate` just because the model file didn't exist yet when the project was first
generated.
