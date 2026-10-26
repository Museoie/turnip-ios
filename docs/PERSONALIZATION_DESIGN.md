# Turnip iOS — On-Device Personalization Design

*Draft · 2026-10-21 · Revised 2026-10-26: the model's embedding
output is built (turnip-ml#58).*

**Scope.** A companion to `docs/DESIGN.md`. The trick-detection model
the app downloads (the central model, turnip-ml's champion, trained on
everyone's contributions) is the same for every user. This doc
specifies how each device adapts it to its own user: a small personal
layer, trained on the device from that user's clip library, that
re-ranks name suggestions and decides borderline clip proposals. It
covers what the layer learns from, its two parts, the gate that decides
whether it is used, when it trains, what it stores, and its privacy
posture. The only screen change is one Settings toggle (§8).

**Authority.** `turnip-ml`'s `MODEL_CONTRACT.md` §3.5 is the contract
this doc implements: it bounds what a personal layer may change, and
§3.2.2 defines the embedding output the layer reads. §3.3 is the
postprocessing the layer works inside (the step-1 band, the step-4
ranking, the step-5 blind sample, the step-6 provenance).
`TRAINING_DESIGN.md` §6.4 is why pre-fills and the blind sample must
stay the central model's. `PROFILE_DESIGN.md` defines the clip library
and naming this doc reads from, and `CONTRIBUTION_DESIGN.md` §7 the
trick-model loader. Nothing here crosses the network, so neither the
farm nor the master plan changes. Where this doc makes a call none of
those cover, it says so as *(judgment call)*.

**Status.** Nothing here is built. Of what it stands on, only the
model's embedding output exists: `Training/export_coreml.py` emits
`window_embeddings` for the baseline (`MODEL_CONTRACT.md` §3.2.2).
The trick-model loader (`CONTRIBUTION_DESIGN.md` §7.2) and the clip
library (`PROFILE_DESIGN.md` §2) are not built yet. This lands after
Phase 4 (master plan §7) and is iOS-only.

---

## 1. Rules

1. **On the device only.** Training, the data it reads, and what it
   learns never leave the device. It adds no field to any upload and
   makes no network call. This is not federated learning, which would
   upload model updates.
2. **On top of the central model, never inside it.** The central model
   runs as published. The personal layer reads its outputs: per-window
   embeddings and segment scores.
3. **Bounded.** It ranks name suggestions and decides segments scoring
   inside `[0.3, 0.7)`. It never pre-fills or confirms a name, never
   hides a segment the central model is sure of (`score ≥ 0.7`), and
   never shows one scoring below 0.3.
4. **Falls back to the central model.** Each part is used only while it
   beats the central model on the user's own recent clips (§5). The
   app behaves exactly as `MODEL_CONTRACT.md` §3.3 says in every other
   case: the toggle off, too few clips, a rebuild in progress, or a
   model without embeddings.
5. **Keep data, derive weights.** What the layer learns from is stored;
   the layer itself is derived from that data and rebuilt whenever the
   active model version changes (§6.2).
6. **Outcome-neutral.** It never changes what a clip earns or how the
   Profile counts it (`PROFILE_DESIGN.md` rules 3 and 6).

---

## 2. Shape, and what was considered

**Why a layer on embeddings, not a fine-tuned model:**

- **Names are free text** (`CONTRIBUTION_DESIGN.md` §4). A user's own
  name for a trick may not be in the central vocabulary at all. A
  fine-tuned classification head over the central vocabulary can never
  output it. Comparing a clip to the user's own named clips can,
  from a handful of examples, with no training loop.
- **A user has dozens of clips, not thousands.** Fine-tuning a model of
  up to 2 M parameters (`TRAINING_DESIGN.md` §4.2) on that overfits.
  Per-name averages plus at most 130 learned parameters, pulled toward
  the central model's behavior, stay where the central model is until
  the user's data says otherwise.
- **Every model update replaces the embedding space**
  (`MODEL_CONTRACT.md` §3.2.2). Personal weights trained against one
  version are meaningless against the next, so the layer has to be
  cheap to rebuild from stored data.
- **Pre-fills feed the farm's rubber-stamp measure**
  (`TRAINING_DESIGN.md` §6.4), and the farm cannot reproduce a
  personal model. Ranking suggestions and deciding borderline
  proposals leave that measure intact. Pre-filling would not.

**Considered, not adopted:**

- **Core ML's `MLUpdateTask`.** Its documented on-device training path
  is the older `neuralnetwork` format, with updatable fully connected
  and convolution layers and cross-entropy or mean-squared-error loss.
  turnip-ml exports an fp16 ML Program (`TRAINING_DESIGN.md` §4.3),
  and an update over the central classes still could not learn a
  user's own names. This design does not depend on it.
- **A full on-device fine-tune** with a training runtime (MLX Swift,
  TensorFlow Lite training signatures). That is a new dependency or a
  second runtime to train fewer than 130 parameters, and it overfits on
  one user's data.
- **Federated learning.** It uploads model updates, and a personal
  model encodes how its user moves. That reopens the standing decision
  that only keypoints and opaque IDs leave the device, on explicit
  per-clip opt-in (`CONTRIBUTION_DESIGN.md` §9 item 4). That is a
  product decision, not part of this design.

---

## 3. What it learns from

Almost everything is already in the clip library (`PROFILE_DESIGN.md`
§2.1). This doc adds one record.

- **Saved clips with a pose.** For each saved clip whose source has a
  stored pose sequence (`PROFILE_DESIGN.md` §2.2), the library holds:
  its window in canonical 10 Hz frames, its names with their `origin`,
  and its provenance (`auto_detected`, `proposal_model_version`,
  `suggested_names`, `suggestions_withheld`). A clip marked "video
  deleted" still counts, since its source's pose remains. Sources
  reached by "Clip manually" have no pose and contribute nothing.
- **Dismissed windows (new).** For each source a save writes to the
  library, one record per trick-model proposal shown on Clip List and
  trashed there: the source, the proposed `start_frame` and
  `end_frame` in canonical 10 Hz frames, and nothing else. Kept
  proposals and "+" clips need no new record, because they are saved
  clips already.
  *(Judgment call, and a carve-out from `PROFILE_DESIGN.md` §2.3's
  "Trashed clips are not stored": a trashed tile leaves two frame
  indices behind, not a clip, an export or a name. It does so only on
  a source whose pose the library already keeps. A source with nothing
  saved stores nothing, and backing out of Clip List stores nothing, as
  today.)* A source's dismissed windows are deleted with its pose,
  when its last clip leaves the library (`PROFILE_DESIGN.md` §2.2).
- **Name weights by origin:** `typed` and `vocabulary` names count 1,
  `model` names (a pre-fill the user kept) count 0.5. The rubber-stamp
  measure exists because kept pre-fills are the weakest evidence
  (`TRAINING_DESIGN.md` §6.4). *(Judgment call on 0.5.)*
- **Whose clip.** Clips marked someone else (`is_me` off) count like the
  user's own. The names are still the user's naming, and §4.2 ranks
  names, not people. *(Judgment call; §11.)*
- **Several people in one video.** Following everyone, each clip
  belongs to one person ([`MULTI_PERSON.md`](MULTI_PERSON.md)). The
  trick model then runs on each person's stored track, and a clip's
  embedding comes from its own person's track. A dismissed window
  belongs to its person's track too, and is kept only while the library
  stores that track. Following one person, there is one pose per take,
  as above.

---

## 4. The personal layer

### 4.1 Clip embeddings

A clip's embedding follows `MODEL_CONTRACT.md` §3.5. It is the mean of
the `window_embeddings` rows whose windows lie wholly inside the clip's
window (the single most-overlapping row when none do), L2-normalized.
A segment's embedding is the same rule over the segment's frames.

- **At save,** embeddings cost nothing extra. Analysis already ran the
  model once over the whole source (`CONTRIBUTION_DESIGN.md` §7.2), and
  its `window_embeddings` are still in memory when Save Clips writes
  the library.
- **At rebuild,** the model runs again over every library source
  (§6.2).

### 4.2 Name ranking

- **Prototypes.** Each name the user has given resolves to a key: the
  canonical trick it maps to, or its normalized text when it maps to
  none (`PROFILE_DESIGN.md` §4.4). A prototype is the origin-weighted
  mean (§3) of the embeddings of the user's clips carrying that key,
  renormalized. A key needs at least three clips to have one. A combo
  clip adds its embedding to each of its names' prototypes.
  *(Judgment call on three.)*
- **Ranking.** For the clip being named, the layer computes cosine
  similarity to every prototype. The suggestions of `PROFILE_DESIGN.md`
  §4.2 then come in this order:
  1. names already used on this video (the existing rule), ordered
     among themselves by similarity;
  2. the three most similar prototypes not already listed, shown as
     the canonical name, or for a name that maps to none, the user's
     most recent spelling of it;
  3. the model's below-bar names (`MODEL_CONTRACT.md` §3.3 step 4);
  4. the rest of the vocabulary.

  *(Judgment call on three, and on placing tier 2 below the video's
  own names: a session is mostly repeats.)*
- **Origin is unchanged.** Picking a suggestion is `vocabulary`, typing
  is `typed` (`PROFILE_DESIGN.md` §4.2). The farm sees a pick from tier
  2 as any other pick.
- **Withheld on blind clips** (`suggestions_withheld`): tiers 2 and 3
  are dropped and tier 1 keeps its plain order (`MODEL_CONTRACT.md`
  §3.3 step 5).
- **Never pre-fills.** A clip's pre-filled chips are the central
  model's confident names and nothing else.
- **Which clips get it:** any clip with an embedding. That means
  model-proposed clips that are not blind, and "+" clips on a source
  the trick model analyzed. Under the heuristic detector there are no
  embeddings, so there is no personal ranking.

### 4.3 Keep layer

- **What it decides.** Whether a segment with central `score` in
  `[0.3, 0.7)` is proposed (`MODEL_CONTRACT.md` §3.3 step 1). Segments
  at or above 0.7 are always proposed; those below 0.3 never are. NMS
  and merging then run as written.
- **Model.** Logistic regression, `p(keep) = σ(a · logit(s) + b + w · e)`.
  Here `s` is the segment's central score, clamped to `[0.01, 0.99]`,
  and `e` is its embedding (§4.1). That is `D + 2` parameters: 70 for
  the baseline, at most 130 for the production model. A segment in the
  band is proposed when `p ≥ 0.5`.
- **It starts as the central model.** The prior `a = 1, b = 0, w = 0`
  gives `p = s`, which is exactly §3.3's 0.5 threshold. The fit
  penalizes distance from that prior (`λ‖θ − θ₀‖²`), so with little
  data the layer stays the central model. The `a, b` terms learn how
  picky this user is; the `w` term learns what they are picky about.
  *(Judgment call on λ; §11.)*
- **Examples.** Every band segment of every library source under the
  active model. A segment matches a window when their overlap covers
  at least half of the shorter of the two *(judgment call)*. It is
  labeled 1 if it matches a saved clip's window, which covers both
  kept proposals and "+" clips, and 0 if it matches a dismissed window
  (§3). A segment that matches neither has no label and is left out.
- **Fit.** Newton's method on the weighted log loss plus the penalty.
  Each step solves one `(D + 2) × (D + 2)` system with Accelerate's
  LAPACK. That takes milliseconds on a few thousand examples, with no
  new dependency.
- **Minimum data:** 20 labeled band segments, at least five of each
  label. *(Judgment call.)*
- **The feedback loop.** A segment the layer hides gets no outcome
  unless the user adds that trick with "+". The added clip then labels
  it 1. So the layer can learn that it hid something wrongly, but only
  through the user's own correction. The band bounds what it can hide
  meanwhile. *(§11: exploration.)*

### 4.4 What it never does

- Pre-fill or confirm a name, or move the pre-fill bar
  (`name_score ≥ 0.5`).
- Touch the blind draw, which is made on every model-proposed clip
  however it passed step 1 (`MODEL_CONTRACT.md` §3.3 step 5).
- Change provenance: `proposal_model_version` stays the active central
  version, and `suggested_names` stay the central pre-fills
  (`MODEL_CONTRACT.md` §3.3 step 6).
- Move a clip's window. Boundaries stay the model's (§11).
- Change what the Profile counts or awards (rule 6).

---

## 5. The gate

Each part is used only while it beats the central model on the user's
own newest clips, ordered by their source's `recorded_at`. The gate
re-runs after every save and every rebuild.

- **Name ranking.** Leave-one-out over the newest 50 named clips that
  have an embedding, with at least 10. For each held-out clip, the
  prototypes are rebuilt without it. That is cheap: subtract its
  embedding from its names' sums. Both sides are cut at three names.
  The personal side is tier 2's three. The central side is the central
  model's three highest-scoring names for the clip, which is
  `MODEL_CONTRACT.md` §3.3 step 4's ranking with combos split into
  their names. A held-out clip is a hit for a side when any of its
  names is among that side's three, and each clip counts once,
  however many names it has. A name the central model cannot output,
  such as one outside the vocabulary, can never be a central hit.
  Tier 1 is left out of both sides, since it is the same with or
  without the layer. Tier 2 is used when its hit rate is higher than
  the central side's; a tie leaves it off, because it would add
  nothing. *(Judgment call on the cutoff and on counting a clip
  once.)*
- **Keep layer.** Hold out the newest 20% of labeled band segments, at
  least five, and fit on the rest. The layer passes when its log loss
  on the held-out segments is lower than the central prior's (`p = s`).
  Once it passes, it is refit on every example. *(Judgment call on the
  metric and the split.)*
- **Failing either check** leaves that part off and the app on the
  central behavior, with nothing shown to the user.

---

## 6. When it trains

### 6.1 After each save

The saved clips' embeddings, and the band segments of the source just
saved, come from the analysis that just ran (§4.1). They join the
cache (§7), which already holds every earlier source's band segments.
Prototypes update, the keep layer refits on the cache, and the gate
re-runs, with no model run over earlier sources.
That is milliseconds of work on the existing background queue, never
on the main thread.

### 6.2 On a model update

- Activating a new model version turns the personal layer off
  (`MODEL_CONTRACT.md` §4). The app runs as §3.3 says until the
  rebuild finishes.
- **The rebuild.** Decode each library source's stored pose, resample
  it to canonical 10 Hz, and run the new model over it. Then recompute
  the clip embeddings and band segments, refit, and re-gate. The work
  resumes per source, so an interrupted rebuild picks up where it
  stopped.
- **It is bounded, because it is a second pass.** It runs over pose,
  not video (the library holds no video), as a `BGProcessingTask` that
  requires external power. It is deferrable, and skipped while the
  thermal state is serious or worse, as live pose already does
  (`LivePoseThermalPolicy`). `CONTRIBUTION_DESIGN.md` §7.2's "once per
  analysis" still holds for analysis itself.
- **Cost:** against the model's unmeasured budget of < 100 ms per 60 s
  of pose (`TRAINING_DESIGN.md` §4.2), a library of 200 five-minute
  sessions is about 100 s of inference.
- **Build notes:** the deployment target is iOS 16, so BackgroundTasks
  and Accelerate are available. The app gains a `processing`
  background mode and a `BGTaskSchedulerPermittedIdentifiers` entry in
  `project.yml`'s Info.plist. Neither is a required-reason API.

---

## 7. What it stores, and where

| Data | Where | Backed up | Lifetime |
| --- | --- | --- | --- |
| Dismissed windows (§3) | the clip library, `Application Support/` | yes, with the library | deleted with its source's pose, or when the toggle is turned off |
| Personal cache: clip embeddings, prototypes, each source's band segments (frames, score, embedding, label), keep-layer parameters, gate results, keyed by model version | `Caches/` | no | rebuilt on a model update, or after iOS evicts it |

- The dismissed windows are the only copy of what they record, so they
  live with the library. The cache is derived and rebuildable, so it
  stays out of backups. A restore to a new device brings the library
  back, and the first rebuild there remakes the cache.
- **Size:** an embedding is 512 bytes at `D = 128`, kept per clip and
  per band segment. 200 clips with a few band segments per source come
  to a few hundred KB. A dismissed window is two integers.
- **Never** uploaded, never in a contribution, never in an exported
  clip's metadata item, and never logged beyond counts.
- **Per device.** A second device has its own library and so its own
  layer (`CONTRIBUTION_DESIGN.md` §6.3).

---

## 8. Settings

- One new toggle, **"Learn from my clips"**, with the footnote
  "Proposals and name suggestions adapt to the clips you save. This
  stays on this iPhone." It is on by default. *(Judgment call:
  nothing leaves the device, and when the layer has nothing to offer
  it falls back to the central behavior. §11.)*
- **Turning it off** deletes the personal cache and the dismissed
  windows and stops recording them. **Turning it back on** rebuilds
  from the library: names and saved clips are still there, and
  dismissed windows start again from empty.
- `UIUX.md` §1a gains the toggle when this is built. Its current
  revision covers five preferences.
- No other UI. The app never marks a suggestion or a proposal as
  personal, just as it never marks a blind clip (`PROFILE_DESIGN.md`
  §4.2).

---

## 9. Privacy

`PRIVACY.md` is the submission source; in short:

- **Nothing leaves the device**, so the App Store answers do not move:
  "Data Not Collected" while Phase 2a's posture holds, and
  contribution's own disclosures (`CONTRIBUTION_DESIGN.md` §8)
  unchanged.
- **New data on the device:** the dismissed windows, in
  `Application Support/` and therefore in device backups, and the
  personal cache in `Caches/`, outside backups (§7).
- **Deleting it:** the toggle (§8), or deleting the app. The farm holds
  none of it, so account deletion has nothing to add.
- **Why it stays local:** a personal layer encodes how its user moves
  (§2, federated learning).
- `site/privacy.html` changes when this ships, not before.

---

## 10. Phasing

- **Needs:** the clip library (Phase 2a), the trick-model loader with
  pre-fill and the blind sample (Phase 4), and a published model whose
  export carries `window_embeddings` (`MODEL_CONTRACT.md` §3.2.2).
- **First, name ranking** (§4.2). It reads only what the library
  already holds.
- **Then the keep layer** (§4.3), with dismissed windows recorded from
  the same release. Recording them earlier would keep data with no
  use yet.
- **The farm changes nothing.** turnip-ml's only change, its export,
  is built.

---

## 11. Open questions

1. **Exploration** (§4.3) — whether to show a small random share of the
   band segments the keep layer hides, so its mistakes surface without
   waiting for a "+" clip, at the cost of more tiles to trash.
2. **Personal boundaries** — learning leading and trailing offsets from
   the user's trims. A moved window would still read `auto_detected`
   to the farm while no longer being the model's, so it waits on a
   provenance field (`MODEL_CONTRACT.md` §6 item 9).
3. **Whose clip** (§3) — whether clips marked someone else should count
   less in the prototypes.
4. **Before the trick model** — fitting `TrickWindowDetector`'s buffers
   to the user's trims while the heuristic is still the detector. It
   has the same boundary question as 2.
5. **Constants** — three clips per prototype, three tier-2 names, 20
   labeled band segments, the 20% holdout, λ, the 0.5 weight on kept
   pre-fills, and the band itself (`MODEL_CONTRACT.md` §6 item 8).
6. **The toggle's default** (§8) — on, as written, or off until the user
   opts in.
