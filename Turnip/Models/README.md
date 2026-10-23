# Models

The app expects a MoveNet MultiPose Lightning model file here, named exactly:

```
movenet_multipose_lightning_float16.tflite
```

This file is **not committed to the repo** (see the root `.gitignore`) — it's a ~9.6 MB binary
ML artifact. Release builds (Xcode Cloud → TestFlight) download and checksum-verify it in
`ci_scripts/ci_post_clone.sh`, so it is always inside the archived app bundle. For local
development, fetch it yourself with the steps below. The app builds and runs without it,
but nothing pose-related works: the camera records without live pose (it logs the load
failure under the `LivePose` category and every take goes through Processing), and
Processing's analysis fails with a "model not found" error.

Every file in this folder is copied into the app bundle ("Why a folder reference", below). A
`movenet_thunder_int8.tflite` left over from before the app used MultiPose is bundled too and
never loaded, so delete it.

## Getting the file

The model is the TF Lite float16 build of `google/movenet/multipose/lightning/1`, published
under **Apache 2.0**, which is the licensing `docs/DESIGN.md` assumes when it bundles the
weights. Download it from TF Hub — no account needed, and the URL serves the raw `.tflite`
directly. From the repo root:

```
$ curl -L -o Turnip/Models/movenet_multipose_lightning_float16.tflite \
    "https://tfhub.dev/google/lite-model/movenet/multipose/lightning/tflite/float16/1?lite-format=tflite"
$ shasum -a 256 Turnip/Models/movenet_multipose_lightning_float16.tflite
```

The second command must print the checksum recorded below.

Provenance last checked **2026-10-21**: the TF Hub URL serves bytes matching the checksum
below, and Kaggle's model API (`https://www.kaggle.com/api/v1/models/google/movenet/get`)
lists the `multipose-lightning-tflite-float16` instance under Apache 2.0.

## Checking you got the right file

Two checks cover this, and they catch different wrong files.

### The checksum and byte count

```
$ shasum -a 256 Turnip/Models/movenet_multipose_lightning_float16.tflite
d4489f89e6bd6777a8b9a1a16189832131f84ff90d82fae729e670b84d7948dd
```

The file is **9,585,276 bytes**. Its input tensor is uint8 with its height and width left open
(`[1, -1, -1, 3]`; it reads `[1, 1, 1, 3]` until resized), and its output tensor is
`[1, 6, 56]` float32: up to six people, each 17 keypoints of (y, x, score), then a box and the
person's score. `PoseInputPreparer` sizes each frame's input to the frame's own aspect, a long
side of 384 with the short side rounded up to a multiple of 32, and `MoveNetMultiPoseModel`
resizes the interpreter to match; `DetectedPerson.parse` reads the output.

If the checksum disagrees, you have a different artifact. The likely candidates are the
neighbouring MoveNet builds, which are single-pose:

| Instance | Bytes | Input tensor | Output tensor |
| --- | --- | --- | --- |
| `multipose-lightning-tflite-float16` (this one) | 9,585,276 | `[1, -1, -1, 3]` uint8 | `[1, 6, 56]` float32 |
| `singlepose-thunder-tflite-int8` | 7,126,768 | `[1, 256, 256, 3]` uint8 | `[1, 1, 17, 3]` float32 |
| `singlepose-thunder-tflite-float16` | 12,584,128 | `[1, 256, 256, 3]` uint8 | `[1, 1, 17, 3]` float32 |
| `singlepose-lightning-tflite-int8` | 2,894,840 | `[1, 192, 192, 3]` uint8 | `[1, 1, 17, 3]` float32 |

(The tensor shapes are read out of the files themselves.)

### The load-time check

`MoveNetMultiPoseModel` resizes the bundled file's input to 384×384 at load, allocates it, and
rejects anything whose output isn't `[1, 6, 56]`, with a visible error naming both shapes. A
single-pose build takes the same resize and allocates without complaint, so the output shape
is what catches it: if Processing's analysis fails with an output-shape error, the file is a
single-pose MoveNet — go back to the download step. If it fails with a data-type error like
"Model input wants Float32, the frame packing writes uInt8", the file wants float input — also
go back.

## Why a folder reference

`project.yml` references this directory as an XcodeGen **folder reference**, not a group. That
means Xcode picks up the file the moment you drop it in — you don't need to rerun
`xcodegen generate` just because the model file didn't exist yet when the project was first
generated.
