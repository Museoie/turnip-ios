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

The model is the `singlepose-thunder-tflite-int8` instance of `google/movenet` — a TF Lite
int8 build of `google/movenet/singlepose/thunder/4`, published under **Apache 2.0**, which is
the licensing `docs/DESIGN.md` assumes when it bundles the weights. Its page is:

```
https://www.kaggle.com/models/google/movenet/tfLite/singlepose-thunder-tflite-int8
```

Downloading needs no account. From the repo root:

```
$ curl -L -o /tmp/movenet.tar.gz \
    https://www.kaggle.com/api/v1/models/google/movenet/tfLite/singlepose-thunder-tflite-int8/1/download
$ tar xzf /tmp/movenet.tar.gz -C /tmp
$ mv /tmp/4.tflite Turnip/Models/movenet_thunder_int8.tflite
```

The archive holds a single file named for the source model version (`4.tflite`); the `mv`
gives it the name the bundle lookup expects.

Provenance last checked **2026-09-10**: page live, instance version 1, license Apache 2.0, and
the downloaded bytes match the checksum below.

## Checking you got the right file

Two checks cover this, and they catch different wrong files — run the checksum first, because
it is the one that catches the variant the app cannot detect for itself.

### The checksum and byte count

```
$ shasum -a 256 Turnip/Models/movenet_thunder_int8.tflite
b72fed22707cd6fb94b5a248b9bddb9c062b9f445471b4fa263407cf6d222011
```

The file is **7,126,768 bytes**. Its input tensor is `[1, 256, 256, 3]` uint8 and its output
tensor is `[1, 1, 17, 3]` float32 — the shapes `FramePreprocessor` and `PoseKeypoint.parse`
are built around.

If the checksum disagrees, you have a different artifact. The likely candidates are the
neighbouring MoveNet builds, and the two closest ones are worth knowing about:

| Instance | Bytes | Input tensor | Output tensor |
| --- | --- | --- | --- |
| `singlepose-thunder-tflite-int8` (this one) | 7,126,768 | `[1, 256, 256, 3]` uint8 | `[1, 1, 17, 3]` float32 |
| `singlepose-thunder-tflite-float16` | 12,584,128 | `[1, 256, 256, 3]` uint8 | `[1, 1, 17, 3]` float32 |
| `singlepose-lightning-tflite-int8` | 2,894,840 | `[1, 192, 192, 3]` uint8 | `[1, 1, 17, 3]` float32 |

The Thunder float16 build reports the same shapes and the same element types as the int8
build, so nothing readable at load separates the two: it loads, allocates, and emits keypoints
the parser accepts, and the only difference is the numbers that come out. float16 is also the
escalation `docs/DESIGN.md` names before any model swap, so quietly running it instead would
pre-empt the accuracy comparison that choice exists to decide. The checksum and the byte
count are the only checks that tell them apart, which is why both are recorded here.

(Sizes are the uncompressed artifact sizes the model page reports per instance; the tensor
shapes are read out of the files themselves.)

### The load-time check

`MoveNetThunderModel` reads the bundled file's input and output tensors at load and rejects
anything that isn't the Thunder singlepose int8 shape — `[1, 256, 256, 3]` input, `[1, 1, 17,
3]` output — with a visible error instead of silently producing worse keypoints. If the
diagnostic fails with an input-shape or output-shape error, the file is a different variant
(Lightning is 192x192) — go back to the download step. If it fails with a data-type error like
"Model input wants Float32, the frame packing writes uInt8", it's the fp32 Thunder build
rather than the int8 one — also go back.

This check cannot see the float16 build, whose input tensor is uint8 at the same resolution,
which is what the checksum above is for.

## Why a folder reference

`project.yml` references this directory as an XcodeGen **folder reference**, not a group. That
means Xcode picks up the file the moment you drop it in — you don't need to rerun
`xcodegen generate` just because the model file didn't exist yet when the project was first
generated.
