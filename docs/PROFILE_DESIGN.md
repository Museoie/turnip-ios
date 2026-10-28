# Turnip iOS — Profile Design

*Draft · 2026-10-15 · Revised 2026-10-21: on-device personalization
([`PERSONALIZATION_DESIGN.md`](PERSONALIZATION_DESIGN.md)) reads the
library, keeps trashed proposals' windows (§2.3), and adds a tier to
the naming suggestions (§4.2).*

**Scope.** A companion to `docs/DESIGN.md`. This doc specifies the
Profile tab and what it stands on: the on-device clip library, naming
clips in the core clip flow, achievements per trick, the gallery
grouped by trick, highlight videos, how the library survives a
reinstall, and how the Profile hands named clips to contribution and
shows what they did. The parts of the v1 flow it changes — the root
pager and the Name Clips screen an analysis lands on — are specified in
`docs/UIUX.md`; contribution itself in
`docs/CONTRIBUTION_DESIGN.md`.

**Authority.** The contract is the
[Turnip Farm + ML Master Plan](https://github.com/hoiekim/turnip-farm/blob/main/docs/MASTER_PLAN.md)
Rev 5: §1 (no server-side profile; unlinking kept), §5.6 (local clip
library and Profile), §7 (Phase 2a before contribution). The farm's
`BACKEND_DESIGN.md` defines the provenance fields (§1.2.18), the public
vocabulary endpoint (§7.3) and `trained_in` (§1.2.20); `turnip-ml`'s
`MODEL_CONTRACT.md` defines name pre-fill and the blind sample (§3.3)
and `name_metrics` (§1); `TRAINING_DESIGN.md` §6.4 is why provenance
matters. Where this doc makes a call none of those cover, it says so
as *(judgment call)*.

**Status (2026-10-27).** Phase 2a's core is built (`Turnip/Profile/`):
the clip library Name Clips' save writes (§2.1, §2.3, §2.4), the Profile
tab with Needs a name, Achievements and the Gallery (§5.1, §6.1, §6.3–§6.5,
§7), and the Clip view (§5.2). How the build differs from this doc:

- The library is one JSON file, `Application Support/ClipLibrary/library.json`,
  rewritten atomically on every change, with a schema version; a file the
  build can't read is moved aside, never overwritten. Each source keeps its
  asset ID, recording date and duration; each clip its window in seconds,
  saved asset ID, names, `is_me`, `auto_detected` and date. Not stored yet:
  the pose (§2.2), the copied location and spot, the crop and rotation,
  `favorite`, the model provenance fields, and contribution state.
- Not built: the file record and Restore library (§3.2), the achievement
  detail (§6.2), tracking a video deleted in Photos (§2.3: such a clip
  keeps its record and shows a "not in Photos" glyph, with no skeleton),
  Highlights (§8), and everything from Phase 2b on.
- The gallery's tiles show the clip's still rather than looping it, and a
  tile opens the Clip view with a navigation push rather than the expansion
  transition (§7). Achievement cards don't open anything yet.
- Needs a name is its own screen built from Name Clips' naming controls,
  not Name Clips itself, since it has no editor, triage or save; it writes
  each name to the library as it is given.
- An achievement earned is spoken once: with the save's own announcement
  on Name Clips, or as it is earned on the Profile's screens.

---

## 1. Why, and the rules that follow

Turnip's training data needs named clips, and naming a clip is work.
The Profile makes that work pay the person doing it: a training log —
which tricks you do, how often, since when, how they looked a year ago
— that exists only if clips have names. Because the log is the user's
own, a wrong name pollutes their own gallery and their own progress.
That is the property points-for-labels lacks, and it is the reason the
Profile is private rather than social.

Rules (the farm and ML docs rely on 2, 3 and 6):

1. **Private by construction.** Everything in the Profile is computed
   on the device from the device's own library and never sent to the
   farm (master plan §1). No leaderboards, no public profile, no
   achievement state on any server. A user may still share a highlight
   video through the Share Sheet; that is their file, sent by them.
2. **Never gated on contribution.** Every Profile feature works for a
   user who never signs in and never contributes. Contribution stays a
   per-clip opt-in; a feature that required it would make the consent
   a price.
3. **Rewards are outcome-neutral.** Progress depends on which trick a
   clip is counted under and nothing else about its name: not whether
   the name came from the model, not whether the user kept or removed a
   suggestion, not whether the clip was in the blind sample
   (`MODEL_CONTRACT.md` §3.3), not whether it was contributed. A list
   of tricks the model is still learning is information, never a
   bounty: paying for a particular name pulls mislabels into exactly
   the rare tricks that can least absorb them.
4. **Variety over volume.** Levels count distinct sessions with a
   trick, not clips (§6.1). Clip counts exist as reps, the lesser
   reward. Sessions are harder to inflate, and a trick seen across many
   days, angles and spots is what the dataset needs.
5. **Only the user's clips count.** People film friends and students.
   A clip marked as someone else counts toward nothing (§4.3).
6. **Earned stays earned.** A vocabulary update, a rename, or a deleted
   clip never takes an achievement away (§6.4).

---

## 2. Local clip library

### 2.1 What it holds

*(Judgment call on names; the implementation picks the types.)*

- **Source** — one per video that produced at least one saved clip:
  - `source_asset_id`: the original's `PHAsset.localIdentifier` (never
    leaves the device);
  - `recorded_at` (`PHAsset.creationDate`), duration, analysis rate;
  - the pose sequence (§2.2);
  - `location`, copied from `PHAsset.location` when the asset has one,
    because the user may delete the original from Photos later;
  - `spot`, an optional name the user gives the place (§8.1);
  - `source_id`, the contribution identity (`CONTRIBUTION_DESIGN.md`
    §1), computed the first time a clip of it is contributed.
- **Clip** — one per saved clip:
  - `clip_id`: a UUIDv4 minted when the clip is created (derived tile
    or "+" tile), the same ID contribution sends;
  - the window, in source seconds and in canonical 10 Hz frames;
  - the crop and rotation export used;
  - `export_asset_id`: the saved clip's `localIdentifier`, as
    `ClipPhotosSaver.saveVideo` returns it;
  - `names`: an ordered list of `{name, origin}`, `origin` one of
    `typed | vocabulary | model` (`BACKEND_DESIGN.md` §1.2.18);
  - `is_me` (§4.3);
  - provenance: `auto_detected`, `proposal_model_version`,
    `suggested_names`, `suggestions_withheld` (`MODEL_CONTRACT.md`
    §3.3);
  - `favorite`, an in-app star;
  - contribution state: `contributed_at` and the dirty flag
    (`CONTRIBUTION_DESIGN.md` §5.2).
- **Earned achievement** — trick, kind, level, `earned_at` (§6.4).

### 2.2 Pose kept per source

- The source's pose sequence is stored as the TKP1 blob contribution
  would upload: encoded once at the analysis rate, gap frames as all
  zeros (`CONTRIBUTION_DESIGN.md` §2.2), gzip-compressed.
- Why keep it: the user can delete the original from Photos once its
  clips are saved, and with it any way to re-run pose. Without the
  stored pose a clip named today could never be contributed later.
  The same pose aligns "then and now" highlights (§8.1) and draws
  skeleton previews for clips whose video is gone.
- Cost: about 2 KB per second of source at 10 frames/sec, scaling with
  the analysis rate — a five-minute session is about 600 KB at the
  default rate, and 200 of them about 120 MB.
- A source's pose is deleted when its last clip leaves the library.
- Sources reached by "Clip manually" (UIUX §2) have no pose. Their
  clips are stored and nameable but cannot be contributed, as today
  (`CONTRIBUTION_DESIGN.md` §2.3).

### 2.3 When it is written

- **Saving writes it** — Name Clips' "Save Clips" (UIUX §3a). Each saved derived clip
  gets a clip record with its `export_asset_id` and whatever names it
  was given; its source gets a source record and its pose. Trashed clips
  are not stored. The one exception is on-device personalization: a
  trashed trick-model proposal on a saved source leaves its window's
  two frame indices behind, and nothing else
  (`PERSONALIZATION_DESIGN.md` §3).
- Backing out of Name Clips without saving stores nothing.
- A saved clip can later have its names, `is_me` and `favorite`
  changed from the Clip view (§5.2). Its window and crop cannot: the
  export is what it is. *(Judgment call; re-cutting from the source
  is an open question, §12.)*
- **Photos changes.** The app already observes the library
  (`PhotoLibraryChangeForwarder`). When a saved clip's asset is deleted
  in Photos, the clip record stays, marked "video deleted": it keeps
  its names and date, still counts (the trick happened), and shows a
  skeleton from the source's pose when there is one. The user can
  delete the record from the Clip view. *(Judgment call: the app
  cannot tell "freeing space" from "didn't want it", and rule 6 says
  progress isn't silently lost.)*

### 2.4 Where it lives

- In `Application Support/`: kept across app updates, included in
  iCloud and Finder device backups, invisible in the Files app. Not
  `Documents/`, which PRIVACY.md keeps empty; not `Caches/`, which iOS
  may evict and which would lose the only copy of the pose.
- The deployment target is iOS 16, so SwiftData (iOS 17) is out. Core
  Data or plain SQLite fit; a new dependency (e.g. GRDB) needs the
  usual review. Requirements, whatever the store: atomic writes, and a
  schema version with migrations.

---

## 3. Identity and recovery

### 3.1 Identifiers

| ID | What it is | Minted | Leaves the device |
|---|---|---|---|
| `clip_id` | UUIDv4 | by the app, at clip creation | only when the clip is contributed |
| `export_asset_id` | the saved clip's `localIdentifier` | by Photos, at save | never |
| `source_asset_id` | the original's `localIdentifier` | by Photos | never |
| `source_id` | SHA-256 per `CONTRIBUTION_DESIGN.md` §1 | by the app, on first contribution | when contributed |

The Profile needs only the first two; `source_id` is contribution's.
Whether `source_id` (the farm's `video_id`) should derive from an
identifier shared across a user's devices has to be settled before the
first contribution ships (master plan §9 Q2).

### 3.2 Surviving a reinstall

The farm cannot restore the library and must not be able to: it does
not know whose clips are whose (master plan §1), and only contributed
clips are there at all. Recovery comes from the device, in two layers:

1. **Device backup.** The library is in `Application Support/`, so an
   iCloud or Finder backup and restore brings it back whole, IDs
   included. Whether `localIdentifier`s still resolve after a restore
   to a *new* device is unverified; when one does not, layer 2's match
   relinks the clip.
2. **A Turnip record in each exported clip file.** At export the clip's
   movie gets one movie-level QuickTime metadata item,
   `mdta/com.hoiekim.turnip.clip` — the key space the camera's roll
   track already uses (`RollTrack`) — with the JSON value
   `{"v": 1, "clip_id": "…", "names": ["gainer"], "is_me": true}`, and is
   named `turnip-clip-<clip_id>.mov`, which Photos keeps as the asset
   resource's original filename. After a reinstall with no backup,
   Settings' "Restore library" enumerates the granted video assets,
   matches the filename prefix from resource metadata (no download),
   reads the record from each match, and rebuilds the clip: ID, names
   (as `origin: typed` — the original origin is not in the file),
   `is_me`, and `recorded_at` from the asset. Not rebuilt: the window in
   its source, the pose (unless the original is still in the library and
   is re-analyzed), provenance, and contribution state, which comes back
   separately for sources whose keys survived in the Keychain
   (`CONTRIBUTION_DESIGN.md` §6).
   - The record is a snapshot at export, so it carries the names given
     on Name Clips before the save. Names given later — from "Needs a
     name", or a rename — update the library, not the file: changing
     an asset's metadata means saving the video again. A clip saved
     without names and named afterwards therefore has its names only in
     the library and recovers them only from a device backup.
     *(Judgment call: accepted. CloudKit, §3.3, is the way out if that
     proves too weak.)*
   - It holds no photo-library identifier, no `source_id`, no
     location.
   - **Unverified; probe before relying on it:** that Photos and iCloud
     Photos keep a custom metadata item in the asset's original
     resource, and that `PHAssetResource.originalFilename` survives
     iCloud sync and a restore. If either fails, §3.3 is the fallback.

The Share Sheet, when it lands (DESIGN.md "Publishing to social
media"), hands out a copy without the record and with a neutral
filename. A clip shared from the Photos app, outside Turnip, carries
both — its trick names and Turnip clip ID go with the file (PRIVACY.md).

### 3.3 Considered, not adopted: CloudKit

A CloudKit private database would sync the library across the user's
devices and survive a reinstall without the file record, in the user's
own iCloud where the developer cannot read it. Not adopted for the
first release: it needs an iCloud entitlement and container, CloudKit's
model constraints, gives users with iCloud off nothing, and is a second
sync path to reason about beside iCloud Photos. Revisit if a Profile
shared across devices becomes a goal, or if the §3.2 probes fail.

A side effect of layer 2, also unverified: iCloud Photos carries
exported clips and their records to the user's other devices, so
"Restore library" there rebuilds their names.

---

## 4. Naming in the core flow

Naming moves out of the contribution path, where
`CONTRIBUTION_DESIGN.md` §4 first placed it, into the clip flow itself:
every saved clip can carry names, contributed or not. It gets a screen
of its own rather than space on the Clip Editor, which is already full
with trimming and framing controls. *(Since 2026-10-27 that screen is
also where an analysis lands: Clip List's triage moved onto it, UIUX
§3.)*

### 4.1 Where names are given

- **Name Clips** (UIUX §3a) is where an analysis lands, before the
  save. It shows one clip at a time, larger, with a free-text
  field ("What trick is this? e.g. cork"); committing adds a chip;
  chips are removable; a combo is N chips on one clip (no
  sub-segmentation, matching the model's `trick_names`). "Save Clips",
  on every clip, saves them all, which is how a user saves without
  naming.
- The same screen names clips saved without names, opened from the
  Profile's "Needs a name" (§5.1), ending in "Done" instead of a save.
- The Clip Editor is unchanged.
- Naming is optional. Nothing blocks on it (a swipe moves on); unnamed
  clips land in the Profile's "Needs a name".
- No batch naming in v1: one name applied to a whole video's clips
  makes one mistake N times. *(Judgment call.)*

### 4.2 Suggestions and origin

- **Vocabulary.** Suggestions come from the newest vocabulary the app
  holds — the seed bundled with the app, `GET /api/taxonomy/current`
  (from Phase 2b), or the active model manifest's, whichever has the
  greatest `taxonomy_version` (`MODEL_CONTRACT.md` §5).
- Names already used on this video come first: a session is mostly
  repeats of a few tricks.
- **Did you mean.** A typed name close to a canonical name or alias
  (small edit distance, case-insensitive) offers the canonical name as
  a one-tap replacement. *(Judgment call: it fixes the gallery grouping
  for the user and saves curation work for the farm.)*
- **Origin**, recorded per name as it is given: picking a suggestion
  or a "did you mean" is `vocabulary`; typing is `typed`, even when
  the typed text matches a canonical name; a chip the model pre-filled
  and the user kept is `model`.
- **Model pre-fill (Phase 4)** follows `MODEL_CONTRACT.md` §3.3:
  confident names only, provenance recorded, and a blind tenth of
  model-proposed clips that get a window but no names. The user is
  never told which clips are blind, and the Profile treats them like
  any other (rule 3).
- **Personal ranking (after Phase 4)** follows the names already used
  on this video: the user's own names closest to the clip being named,
  learned on the device. It only ranks: it never pre-fills, is
  withheld on blind clips, and leaves origin as above
  (`PERSONALIZATION_DESIGN.md` §4.2).

### 4.3 Whose clip

- Each clip has `is_me`, default on. On Name Clips, the choice made on
  a video's first clip ("me" / "someone else") carries to its other
  clips, and any clip can change it.
- `is_me` never leaves the device. Clips marked someone else appear in
  the gallery under its filter (§7) and count toward nothing (§6).
- When such a clip is in a contribution, the confirmation sheet shows
  the consent reminder `BACKEND_DESIGN.md` §7.1 requires: contribute
  only clips of people who agreed.

### 4.4 Grouping names by trick

A name resolves to a canonical trick through the naming vocabulary with
the same deterministic pipeline training uses (`TRAINING_DESIGN.md`
§2.2): normalize, look the whole label up, and only on a miss split it
on `-`, `/`, `+`, `,`. A name with no mapping groups under its
normalized text until a vocabulary update maps it, then moves, and its
progress merges into the canonical trick's. A clip with several names
counts once under each distinct canonical trick.

---

## 5. The Profile tab

### 5.1 Layout

- The root pager's third page, after Home: Camera | Home | Profile
  (UIUX "Root navigation"). Reached by swiping left from Home or by the
  floating bar's third icon, which plays the same slide.
- One scrolling page, top to bottom:
  - **Needs a name** — a row with the count of unnamed saved clips,
    shown only when it is above zero; opens them in Name Clips
    (UIUX §3a).
  - **Achievements** (§6) — cards such as "Gainer · Level 2" and
    "Gainer · 100 reps".
  - **Gallery** (§7) — one row per trick.
  - **Highlights** (§8).
- Empty state (no saved clips yet): what the tab will show once clips
  are saved and named, and that it stays on this iPhone.
- Privacy copy on the page itself: "Your Profile stays on this iPhone."

### 5.2 Pushed screens

Achievement detail (§6.2), a trick's gallery (§7), a highlight's
player (§8), and the **Clip view**: plays the saved clip; shows its
names and `is_me` (editable), date and spot; holds the clip's
Contribute toggle once contribution ships; and deletes the clip from
the library, asking whether to delete its video from Photos too. While
one of these is pushed, `PageSwipeLock` keeps the root pager from
taking horizontal drags, as it does for Processing, Name Clips and the
editor.

---

## 6. Achievements

### 6.1 Kinds

Every canonical trick in the naming vocabulary, and every unmapped name
the user has given (it is still their trick), has the same two ladders.
Both count only saved clips with `is_me` on.

- **Level** — counts **sessions**: distinct local calendar days on
  which the user has at least one clip of the trick, dated by the
  source's `recorded_at` plus the clip's offset into it. Level 1 at 1
  session, 2 at 3, 3 at 10, 4 at 25, 5 at 50.
- **Reps** — counts clips of the trick. Milestones at 10, 50, 100, 250,
  500.

A combo clip counts one rep, and its day one session, for each distinct
canonical trick in it. *(Judgment call on every threshold, and on the
calendar day as the session: a session past midnight counts as two.)*

### 6.2 Achievement detail

Opened from a card: the trick's clips (newest first, the gallery tile
grid of §7), a progress bar toward the next step, the current count and
the target ("7 of 10 sessions"), and the date of the first clip.

### 6.3 What counts, and what doesn't

The count is a function of the clip's canonical trick, its `is_me`, and
its date — nothing else. Origin, the blind sample, kept or removed
suggestions, favorites and contribution state do not enter it.
Contributing earns nothing in the Profile (rule 2 keeps the consent
free; rule 3 keeps the provenance honest).

### 6.4 Earned stays earned

- Reaching a level or milestone writes an earned record with
  `earned_at`. It is never deleted by the app.
- Counts are recomputed from the library whenever it changes. A
  vocabulary update that merges two names merges their counts; a
  canonical rename resolves forward through its aliases
  (`BACKEND_DESIGN.md` §3, "Renames resolve forward").
- If the count later drops (a clip renamed or deleted), an earned level
  still shows as earned, and progress toward the next one reads from
  the current count.

### 6.5 Catalog

The ladders are a static table bundled with the app. A per-trick catalog
served over the air can come later if a reason appears.

### 6.6 Tricks the model is still learning

From Phase 3, the active manifest's `name_metrics` (`MODEL_CONTRACT.md`
§1) can list the tricks with few training examples — "Turnip is still
learning these tricks". It is shown as information. Naming or
contributing those tricks earns nothing extra (rule 3).

---

## 7. Gallery

- Saved clips grouped by canonical trick (§4.4): one row per trick on
  the Profile page with its clip count, opening a grid of that trick's
  clips, newest first. A combo clip appears under each of its tricks.
- Tiles loop their clip inline like Name Clips' card, accessibility
  permitting (ACCESSIBILITY.md). A tile opens the Clip view (§5.2) with
  the tile-to-screen expansion transition the app already uses
  (`EXPANSION_TRANSITIONS.md`), the card being the clip's own player.
- A filter switches between the user's clips (default) and everyone
  filmed, which includes clips marked someone else.

---

## 8. Highlights

Highlights are videos composed on the device from the user's own saved
clips with AVFoundation — not generative AI, and nothing is rendered or
stored on a server.

### 8.1 Kinds, and what each needs

| Highlight | Needs | Shows |
|---|---|---|
| **Then and now** | Two of the user's clips of one trick at least 6 months apart | The earliest and the latest side by side, aligned at takeoff |
| **Same trick, different spots** | The user's clips of one trick at two or more spots | One clip per spot, in sequence |
| **Best of a month** | Three or more favorited clips of the user's in that month | The favorites, in sequence |

- **Takeoff alignment** uses the stored pose: both clips start where
  their motion burst starts (the same burst detection as
  `TrickWindowDetector`). Without pose for both, they align at clip
  start.
- **Spots** come from `PHAsset.location` where the source has one,
  clustered within 200 m, or from the spot name the user gives a
  source. Turnip's own camera records no location — there is no
  location code and no `NSLocationWhenInUseUsageDescription` — so its
  takes have a spot only when the user names one. No location
  permission is added for this (decided 2026-10-15).
- **Best** means favorited: the in-app star, or the saved clip's
  Photos favorite (`PHAsset.isFavorite`, read only). No computed
  quality score.
- *(Judgment call on 6 months, 200 m and three favorites.)*

### 8.2 Locked highlights

A highlight without enough material shows what it is missing — "Name
one more gainer from before April" — which is the Profile's prompt to
name the backlog. It never asks the user to contribute.

### 8.3 Rendering

The preview plays the composition live, with no file written. Save and
Share render to `tmp/turnip-highlight-<uuid>.mov`, hand it to Photos or
the Share Sheet, and delete it; the launch-time orphan sweep learns the
prefix like the other `tmp/` prefixes. No render cache in the first
version; if one lands, it goes in `Caches/`. A free-space check before
rendering is a required-reason API (PRIVACY.md).

---

## 9. Contribution and impact feedback

- **Contributing (Phase 2b).** Settings' Contribute named clips switch
  for Name Clips' save (UIUX §1a, §3a), a per-clip contribute toggle on
  the Clip view, and a "Contribute named clips" action on the Profile
  page, feed `CONTRIBUTION_DESIGN.md`'s flow
  (§3.3), which uploads the library's stored pose and each clip's names
  and provenance. The Clip Editor carries no contribution
  controls. Nothing in the Profile depends on contributing.
- **Asking.** At most one dismissible card on the Profile page, never a
  modal, and not again for a week once dismissed. *(Judgment call.)*
- **Impact feedback (Phase 3).** What closes the loop for the user:
  - From the active manifest's `name_metrics`: "Turnip recognizes
    gainers 84% of the time — up from 71%", comparing with the
    previous manifest's figures, which the app keeps. A `null` recall
    reads "not enough data yet".
  - From `trained_in` on `GET /api/sources/:id` (`BACKEND_DESIGN.md`
    §7.3), read for the sources the app holds keys for, at most daily:
    "14 of your gainer clips helped train the current model".
  - Never more than the data says.

---

## 10. Privacy

`PRIVACY.md` is the submission source; in short:

- **Phase 2a makes no network call.** Suggestions come from the bundled
  seed, so the app keeps "Data Not Collected" and PRIVACY.md's "no
  calls to any Turnip-controlled server" literally true. Phase 2b adds
  the public vocabulary fetch (no identifiers, no session) and opt-in
  contribution; Phase 3 adds `trained_in` reads, which carry the source
  key of a source the user already contributed.
- **New data on the device:** the library — names, `is_me`, favorites,
  spots, dates, copied locations, pose sequences — in
  `Application Support/` and therefore in device backups. After Phase
  4, personalization adds trashed proposals' windows to it and keeps
  a rebuildable cache in `Caches/` (`PERSONALIZATION_DESIGN.md` §7).
- **New data in the user's files:** each exported clip's Turnip record
  and `turnip-clip-<clip_id>` filename (§3.2).
- **New reads,** under the existing Photos grant with no new prompt:
  `PHAsset.creationDate`, `location`, `isFavorite`, and
  `PHAssetResource.originalFilename`.

---

## 11. Phasing

The iOS side of master plan §7:

- **2a** — library (§2), identity and recovery (§3), naming (§4), the
  Profile tab with Needs a name, Achievements and Gallery (§5–§7). No
  network.
- **2b** — contribution from the library; the vocabulary fetch.
- **3** — impact feedback (§9) and the tricks-still-learning list (§6.6).
- **4** — model pre-fill and the blind sample in naming (§4.2). After
  it, on-device personalization (`PERSONALIZATION_DESIGN.md` §10),
  which needs no farm change.
- **5** — Highlights (§8).

---

## 12. Open questions

1. **The tab's name.** "Profile" reads as public to many people. Keep it
   and say "stays on this iPhone" in the copy, or rename it (e.g.
   "Progress", "Log").
2. **Landed or bailed** (master plan §9 Q4). If clips gain an optional
   outcome, reps could count landed clips only and the gallery could
   show a landing rate per trick.
3. **`video_id` (`source_id`) derivation** before the first contribution
   ships (master plan §9 Q2).
4. **Thresholds** — the level ladder and rep milestones (§6.1); 6
   months, 200 m and three favorites (§8.1).
5. **Pose storage** (§2.2) — whether Settings shows the library's size
   and offers a cleanup.
6. **Recovery probes** (§3.2) — the metadata item, the original
   filename, and `localIdentifier`s after a restore to a new device.
7. **Re-cutting a saved clip** (§2.3) — whether a saved clip's window
   or crop can be edited again while its source is still in Photos.
