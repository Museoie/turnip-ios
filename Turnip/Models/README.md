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
4. Confirm you got the right variant, in this order. First the checksum and byte count —
   this is the check that distinguishes the int8 build from the adjacent fp16 build on the
   same Kaggle page (`singlepose-thunder-tflite-float16`, 12,584,128 bytes), which reports
   the same input shape, output shape, and element types as int8, so the load-time check
   below cannot tell them apart. The int8 build is 7,126,768 bytes:

```
$ shasum -a 256 Turnip/Models/movenet_thunder_int8.tflite
b72fed22707cd6fb94b5a248b9bddb9c062b9f445471b4fa263407cf6d222011
```

   A disagreeing checksum means you grabbed the wrong file — go back to step 1. Then the
   load-time check: `MoveNetThunderModel` reads the bundled file's input and output tensors
   at load and rejects anything that isn't the Thunder singlepose int8 shape — `[1, 256,
   256, 3]` input, `[1, 1, 17, 3]` output — with a visible error instead of silently
   producing worse keypoints. If the diagnostic fails with an input-shape or output-shape
   error, the file you downloaded is a different variant (Lightning is 192x192) — go back
   to step 1. If it fails with a data-type error like "Model input wants Float32, the frame
   packing writes uInt8", you downloaded the fp32 Thunder build instead of the int8 one —
   also go back to step 1. (The fp16 build's input tensor is uint8 too, so it does not fail
   this data-type check — which is why the checksum above is the check that catches it.)

When the Kaggle source is verified (step 1 above), record here: the resolved download URL
and the date checked — and drop the "unverified by this scaffolding" parenthetical.

## Why a folder reference

`project.yml` references this directory as an XcodeGen **folder reference**, not a group. That
means Xcode picks up the file the moment you drop it in — you don't need to rerun
`xcodegen generate` just because the model file didn't exist yet when the project was first
generated.
