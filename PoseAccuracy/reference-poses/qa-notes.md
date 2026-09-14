# Reference-label QA notes (2026-09-14)

Reference labels were generated with MediaPipe PoseLandmarker Heavy
(`pose_landmarker_heavy.task`, VIDEO mode, 10fps sampling) and then
human-QA'd frame by frame via skeleton-overlay contact sheets
(`spotcheck/sheet_*.png`). Every labeled frame of every clip was inspected.

## Method

- Auto-flagged: frames with mean joint visibility < 0.5, centroid jumps
  > 0.25 frame-width between adjacent samples (subject-switch detector),
  tiny pose bounding boxes. None of the auto-flags alone decided a drop;
  every flagged frame was viewed.
- Contact sheets rendered for all 6 clips; 3 hardest frames per clip
  (max inter-frame joint motion) viewed at full resolution.

## Decisions

Kept as-is (no manual drops):
- `17931395055382674` (double full), 153 frames — single subject tracked
  continuously through both double-fulls; early frames have lower
  visibility only because the subject is far away (honest labels).
- `17974812225063566` (TDR + gainer), 44 frames — clean throughout.
- `17975344427923074` (floor work), 73 frames — clean throughout,
  including handstand/bridge sequences.
- `18346724083172551` (side flip), 35 frames — frame 60 is a tight,
  motion-blurred tuck where the skeleton collapses into the body ball,
  but the model is confident (mean visibility 0.886) and it is the
  model's honest best effort on a genuinely ambiguous frame. Kept as a
  fair hard frame rather than cherry-picking it out.

Manual drops (added to `dropped_frames.json` with reason):
- `17924553528368727` frame 309 — tangled skeleton on a clearly visible
  standing subject (model failure, neighbors fine).
- `18198525943370276` frame 24 — garbage label, subject behind the
  trampoline net at the frame edge.
- `18198525943370276` frame 69 — wrong subject, tracked a bystander
  instead of the tricking subject (neighbors track the subject).
- `17931395055382674` frames 216, 225, 294 — relabeling (below) found no
  pose in the subject ROI crop.

## Critical fix: dub clip reference relabeled (f114–f300)

Visual QA caught that MediaPipe had locked onto a bystander (person in
blue at frame left) for frames ~114–300 of the double-full clip — including
the first double-full sequence — while the candidate (MoveNet) was
correctly tracking Hoie. A wrong-person reference is a fixture defect, so
those 63 frames were relabeled (`relabel_dub.py`): per-frame ROI crop
centered on the MoveNet detection (which was verified to be on Hoie),
MediaPipe Heavy on the crop, coordinates mapped back to full-frame space.
60 frames relabeled successfully; 3 (216, 225, 294) yielded no pose and
were dropped. The relabeled segment was re-QA'd via contact sheet —
all 60 track Hoie, including the double-full at f186–f210.

Note the asymmetry: in the dub clip the *reference* was wrong (fixed); in
the full-swing clip the *candidate* genuinely tracks bystanders 73% of the
time. The latter is honest model behavior — the reference defines the task
("pose of the tricking subject") and the candidate is scored on it. The
full-swing clip's low score (9.6) is real, not a fixture bug.

## Final counts

497 labeled frames / 548 sampled (51 dropped: 45 no-detection +
3 manual QA + 3 relabel failures). Per-clip: 154 / 150 / 44 / 73 / 41 / 35.

## Baseline (2026-09-14)

MoveNet Thunder int8 (sha256:b72fed22707cd6fb94b5a248b9bddb9c062b9f445471b4fa263407cf6d222011)
scores **35.7360** against these labels. Candidate extraction and scoring
are both byte-identical on re-run (verified).

## Non-determinism note

MediaPipe's VIDEO-mode tracker shows small run-to-run variation (a few
frames' drop/no-drop decisions differ between runs). Labels are therefore
generated once, QA'd, and committed as fixed artifacts — CI never
regenerates them. Only the scorer (verified byte-identical on repeat runs)
needs to be deterministic.
