"""Reference outputs of the smoke model over two smoke samples, for TrickModelTests.

The fixtures beside this script come from a turnip-ml checkout, with its
Training/requirements-export.txt installed:

    python Training/train.py --config Training/config/smoke.toml
    (cd Training && python export_coreml.py --model ../runs/smoke/model.npz \
        --out <here>/TrickDetectorSmoke.mlpackage.zip)
    python make_trick_model_reference.py <turnip-ml> <turnip-ml>/runs/smoke/model.npz \
        <here>/TrickModelReference.json <here>/TrickDetectorSmoke.mlpackage.zip

The reference is numpy's float64 math, train.py's own featurization and
decoding; given the zip, the script also prints how far macOS Core ML's
fp16 run of the export lands from it.

Usage: make_trick_model_reference.py <turnip-ml checkout> <model.npz> <out.json> [mlpackage.zip]
"""
import json
import sys
from pathlib import Path

ml = Path(sys.argv[1])
sys.path.insert(0, str(ml / "Training"))
import numpy as np  # noqa: E402
import train  # noqa: E402

ckpt = train.load_checkpoint(Path(sys.argv[2]))
W, S = int(ckpt["window_frames"]), int(ckpt["window_stride"])
classes = [str(c) for c in ckpt["classes"]]

samples = [json.load(open(ml / f"Training/fixtures/smoke/samples/{sid}.json")) for sid in ("smoke-005", "smoke-006")]
kps = np.concatenate([np.asarray(s["keypoints"], dtype=np.float64) for s in samples])  # [T, 17, 3]
T = kps.shape[0]
gap = np.zeros((T, 1))
# One gap frame, all zeros with the indicator set, as the canonical blob carries it.
kps[40] = 0
gap[40] = 1
pose = np.concatenate([kps.reshape(T, 51), gap], axis=1).astype(np.float32)

starts = list(range(0, T - W + 1, S))
feats = np.stack([train.featurize_window(np, pose[s:s + W, :51].reshape(W, 17, 3).astype(np.float64)) for s in starts])
emb = (feats - ckpt["feat_mean"]) / ckpt["feat_std"]
logits = emb @ ckpt["W"] + ckpt["b"]
probs = np.exp(logits - logits.max(axis=1, keepdims=True))
probs /= probs.sum(axis=1, keepdims=True)
pred = [classes[i] for i in probs.argmax(axis=1)]
prov = [("x", s, "") for s in starts]
segments = [
    {"start_frame": seg["start_frame"], "end_frame": seg["end_frame"], "name": seg["name"]}
    for seg in train.decode_segments(prov, pred, W)
]

out = {
    "source": "turnip-ml Training/fixtures/smoke samples smoke-005 + smoke-006, frame 40 a gap",
    "classes": classes,
    "window_frames": W,
    "window_stride": S,
    "pose": pose.round(6).tolist(),
    "window_probs": probs.round(6).tolist(),
    "window_embeddings": emb.round(6).tolist(),
    "segments": segments,
}
Path(sys.argv[3]).write_text(json.dumps(out, separators=(",", ":")) + "\n")
print(T, "frames", len(starts), "windows", segments)

if len(sys.argv) > 4:
    import tempfile
    import zipfile
    import coremltools as ct
    with tempfile.TemporaryDirectory() as tmp:
        zipfile.ZipFile(sys.argv[4]).extractall(tmp)
        model = ct.models.MLModel(str(Path(tmp) / "TrickDetector.mlpackage"), compute_units=ct.ComputeUnit.CPU_ONLY)
        res = model.predict({"pose": pose})
        print("coreml probs max err", np.abs(res["window_probs"] - probs).max(),
              "emb max err", np.abs(res["window_embeddings"] - emb).max())
        print("userDefined", dict(model.user_defined_metadata))
