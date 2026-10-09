# Photos-style expansion transitions

*Rev 13 · 2026-10-08.* The editor's surround is frosted glass, and the flight
shows the crop alone: the card is laid out at the marker again, the window
uncrops from the tile to the marker, and the editor's edge-to-edge surface
with the frosted frame around the crop appears with the landing and leaves
with the first frame of any close, Delete included. The card is composited
before Delete's fade, or its video spills past the window's clip. See "Rev
13" near the end.

*Rev 12 · 2026-10-07.* The editor's crop marker is now one fixed rectangle
on screen and its video runs edge to edge under the chrome, so the card is
laid out as the whole screen — the same `ClipEditorVideoSurface` placement
the editor's stage uses — and the measured value is the marker's frame
(`ClipEditorCropMarkerFramePreferenceKey`), which is where the window starts:
it uncrops from the marker's center square to the whole screen. See "Rev 12"
near the end.

*Rev 11 · 2026-10-07.* The editor's swipe-to-dismiss now commits the edit the
way its back chevron does (it closed without handing the draft back). Every
bar-less screen's header — the editor's top row, Processing's chevron,
Camera's corner controls — sits where the system inline bar lays its items
(`ScreenHeaderBand`, measured on both iOS 26 and pre-26), and the clip list's
chevron is the same 44 pt glass circle as the others rather than the bar's
wider pill, so the list and editor headers land on each other through the
cross-fade. See "Rev 11" near the end.

*Rev 10 · 2026-10-07.* The cross-fade has its own curve. The flight's geometry
is unchanged (250ms ease-in-out); the destination's chrome and the scrim each
fade on an ease-in-out of the card's *travel* whose inflection point — where
the fade crosses half — and steepness are set per layer. Tuned by hand to
chrome `0.99` / power `4` and scrim `0.6` / power `3`: the controls join only
as the card lands and are the first thing to go on a close, while the grid or
list under the scrim is half covered at 60% of the way out. Applied per frame
by an `Animatable` modifier keyed on `progress`, so a swipe and the back
button play the same cross-fade. See "Rev 10" near the end, including the
three measured shapes it replaced.

*Rev 9 · 2026-10-05.* The flight is 250ms. The destination's chrome now
cross-fades in *over* the flying card for the whole flight instead of appearing
whole at the end: the destination sits above the card at `.opacity(progress)`,
its navigation container made see-through (`containerBackground(.clear)`, iOS
18), and only its backdrop and video surface stay hidden — behind
`expansionVideoSurface()`, keyed on a plain `expansionHasLanded` flag the
container flips with animations disabled, which also flips the card off in the
same update. (Home's open used to flicker: the tapped tile's slot went empty
for the few frames the cover took to present, and the tap's own PhotoKit
resolve disabled — and so dimmed — every grid tile and raised the "Preparing
video…" banner, both of which snapped back when the resolve landed mid-flight.
All three are gone.) The clip list's back action now slides the page off
sideways (`slideClose()`) rather than shrinking into the video's tile, and the
editor draws its own top row instead of a navigation bar so a downward drag
anywhere above the video dismisses. See "Rev 9" near the end for the
mechanisms, the one approach that was tried and reverted (an animated
`expansionProgress` environment value — it never interpolates for a destination
that mounts mid-flight), and the verification.

*Rev 8 · 2026-10-05.* The flight is now 350ms. The card no longer stretches: it
is laid out at the destination and shown through a window that uncrops from what
the tile showed to the whole frame, scaled uniformly (`ExpansionFlightGeometry`,
shared by both containers). For Clip List → Clip Editor the card is no longer a
still thumbnail at all but the editor's own video surface, drawing the *same*
`AVPlayer` the editor draws, scrubbed alongside the geometry: opening starts on
the frame the tile was showing and plays back to the clip's first frame; closing
starts on the frame the editor is showing and scrubs to the frame the tile will
show again. The back-button close's one-frame flash of the whole editor shrunk
and pinned at the tile was the editor's body-level `.scaleEffect`/`.offset`
snapping under `CrossfadeCut`'s animation-suppressing transaction — that
transform is gone. See "Rev 8" near the end for mechanisms, scope (Home got the
duration, the uncropping card and a live-player close; its open side was
already poster-continuous), and the verification, which for the first time can
read the *video frame* a card is showing off a recording.

*Rev 7 · 2026-10-05.* Rev 6 below was reported, correctly, as having fixed
neither the duration nor the gap. Two root causes, both in plain sight and both
missed by every earlier verification: the card/content cut fired at `progress =
0.85`, i.e. with the card still 15% short of the destination — a hard size pop
at the end of every open, which *was* the "gap" — and a critically-damped
spring does most of its travel in the first ~0.65s, so the growth never read
as a second long. The flight is now an explicit 1s timing curve and the cut
happens at `progress ≈ 1`. See "Rev 7" near the end for the mechanism and,
more importantly, for the redesigned verification that measures what a user
sees instead of what the code computes.

*Rev 6 · 2026-10-04.* The open/close spring's `response` moved from `0.3`/`0.29`
to `1` (a ~1s flight, measured — not assumed — to actually be what that value
produces), and the card's geometry (`rect`, driving its `.frame`/`.position`)
now comes from *live* `progress` via a `GeometryEffect`, so a destination
retarget mid-flight (the real measurement replacing the fallback guess) is
absorbed as a continuous lerp instead of causing a visible jump. Getting there
took three attempts, two of which hung — see "Rev 6: the live-geometry fix,
three attempts in" near the end of this doc.

*Rev 4 · 2026-10-04.* Rev 2 (below) believed it had replaced the card/destination
cross-fade with an instant cut. It hadn't, for every `withAnimation`-driven flight
(tap-to-open, back-button-close, the cancel-spring) — see "Rev 4: the cut Rev 2
thought it shipped was still a fade" near the end of this doc for the mechanism,
how it was confirmed, and the actual fix.

*Rev 2 · 2026-10-03.* Rev 1 described a cross-*fade* between the card and the
real destination, and a destination measurement that — for
`ClipExpansionContainer` — only ever locked in once `progress` had already
settled. Both turned out to be bugs, not just simplifications: the fade was
visibly a fade (never asked for), and the locking left the *open* flight
targeting a placeholder square and the *close* flight starting from an
approximation of the real frame rather than the frame itself, for every
Clip List → Clip Editor transition. `HomeExpansionContainer`'s open side had
a parallel bug — its own destination measurement can't even start loading
until well after the open spring begins, so it reliably lost that race and
grew toward the full screen instead of the real letterboxed video rect. See
"Shared design: a two-layer hard cut over one `progress` clock" and
"Measuring the destination without a race or a feedback loop" below for
what changed.

Companion to [`UIUX.md`](UIUX.md), which specifies *that* a tile tap opens its
destination and a back action returns to the grid. This doc specifies *how*:
the custom tap-to-expand / swipe-or-back-to-collapse animation that replaced a
plain system push/sheet for two navigations —

- **Clip List → Clip Editor** (`Turnip/ClipList/ClipExpansionContainer.swift`)
- **Home → Processing** (and Home → Clip List directly, for a camera take
  live inference already covered) (`Turnip/Home/HomeExpansionContainer.swift`)

Both replicate the real Photos app: tapping a tile grows it smoothly into the
full-screen destination; the back control, or a swipe down, shrinks it back
into the same tile. Neither container is literally reused as the other — they
share a design, not a type — because what differs between them (a one-shot
source frame vs. a live one that can retarget; who owns the dismiss gesture)
was more than a generic parameter could absorb cleanly. See each file's own
doc comment for the specific divergence.

## Why not the system's own tools

Three off-the-shelf options were considered and rejected before building a
custom container:

- **`NavigationStack` push** — SwiftUI has no public hook to customize a
  push/pop transition's geometry at all.
- **iOS 18's `.navigationTransition(.zoom(sourceID:in:))`** — researched in
  depth before any code was written (see "Research" below). It gets
  interactivity and interruptibility for free, but flies the *whole
  destination view*, aspect-filled, with a corner radius that morphs to the
  display's own corners and a scale-and-dim treatment on the covered page —
  none of which matches what Photos actually does, and it has a shipping iOS
  26.0–26.4 regression where the source view goes blank after an interactive
  (not button) dismiss. Apple's own WWDC24 session (10145) frames it as
  general-purpose, not a Photos reproduction.
- **`fullScreenCover`/`sheet` with no customization** — the system's default
  slide-up/down is exactly the motion this feature replaces.

The approach taken instead: a custom `ZStack` overlay presented via
`fullScreenCover` (so it still benefits from a real modal presentation —
input blocking, a window-level z-order, environment dismissal), but with the
system's own presentation *animation* suppressed and the actual motion driven
by a hand-built `progress: CGFloat` clock, animated on an explicit-duration
ease-in-out curve.

## Research

Before building either container, a research pass (prompted with `model:
fable` via the `Agent` tool) characterized the real Photos app's behavior
frame-by-frame from a recorded simulator session, and cross-referenced it
against Apple's own zoom-transition documentation and WWDC24 material. Key
findings that shaped the design:

- Photos flies the *tapped image itself* (center-crop → aspect-fit,
  "uncropping" as it grows), not the whole page — the system zoom transition
  flies the whole destination page instead.
- The covered grid is **not** scaled or dimmed during the flight; what
  visibly covers it is the one-up's own background fading in underneath the
  growing image.
- Chrome (nav bar, bottom bar) cross-fades in *after* the geometry has mostly
  landed, not throughout the whole flight.
- The interactive dismiss has **no real distance threshold**: almost any
  downward release commits, including a handful of points of travel; only a
  release that's still moving *upward* cancels back to fully open. This is
  notably more eager than Apple's own 2016 `PhotoTransitioning` sample code
  (⅓ fractional threshold or a flick) or the measured system zoom transition
  (commits once scale drops below ~0.905).
- Pan during the dismiss shrinks the image (~0.6–0.67 scale lost per full
  screen height of travel) while trailing the finger with increasing lag, not
  tracking it 1:1.

Both containers' dismiss constants (`ExpansionFlightGeometry.dismissTravel`
and the "almost any downward release commits" rule,
`ExpansionFlightGeometry.dismissCommits`) are this research's measurements,
not arbitrary tuning. The drag maps linearly
(`progress = 1 - travel / dismissTravel`, with `dismissTravel = 420`); the
animated flights are an explicit-duration ease-in-out, not a spring (see
below).

## Shared design: a two-layer hard cut over one `progress` clock

Both containers share one structure, independently implemented:

```
progress: CGFloat        // 0 = exactly at the source tile, 1 = fully open
```

- A **card** layer, laid out once at the destination's size and position and
  never resized. What flies is a *window* onto it: `ExpansionFlightGeometry`
  (shared, `Turnip/DesignSystem/ExpansionFlight.swift`) lerps the card's
  on-screen `rect` between the tile's frame and the destination (center and
  size separately, so it grows from its own middle), and a `region` of the
  card's content from the part the tile showed (`focus`, aspect-filled by the
  tile, so the window starts on its largest centered sub-rect at the tile's
  aspect: for a clip the focus is the whole crop marker and the window starts
  on the marker's center square; for a Home tile, the frame's center square)
  to the whole content, mapped onto `rect` by one uniform
  `scale`. Applied as an animatable `.clipShape(ExpansionFlightClip)` plus a
  `GeometryEffect` (`ExpansionFlightEffect`), both render-time. Width and height never scale apart, so the picture is
  cropped as it grows and never stretched (through Rev 7 the card was scaled
  non-uniformly to the destination's aspect ratio, which stretched it). What
  the card *draws* differs per container: for Clip it is the editor's own
  `ClipEditorVideoSurface` — the same `AVPlayer`, same crop-adjustment
  transform — over the tile's poster at the crop rect; for Home it is the
  tile's square thumbnail at the frame's center square, the full-frame poster
  where cached, and `ProcessingView`'s live player once it reports one
  (`ProcessingPlayerPreferenceKey`).
- The **real destination content**. On iOS 18+
  (`ExpansionFlightGeometry.destinationChromeCrossfades`) it sits *above* the
  card, its navigation container made see-through, and its chrome fades in
  over the flight with `.expansionCrossfade` (chrome inflection `0.99`,
  steepness `4`; see Rev 10), so the controls effectively arrive as the card
  lands and are the first thing to go on a close. Only its backdrop and video
  surface (`expansionVideoSurface()`) wait for `expansionHasLanded`: a flag
  written with animations disabled when the opening flight's animation
  completes and cleared on the first frame of any close, which flips the card
  off and those surfaces on in one atomic, unanimated frame, at the one point
  where the card's rect equals the content's settled frame, so nothing pops.
  Before iOS 18 the whole destination sits *under* the card, hidden behind the
  same flag. (Through Rev 6 the cut fired at `progress = 0.85`, with the card
  still 15% short, which was the "sizing gap" bug — see Rev 7.) Neither
  container transforms its real content — only the visibility swap and the
  chrome's fade. (Through Rev 7
  `ClipExpansionContainer` also scaled/offset the real `ClipEditorView` toward
  the card's rect; under a hard cut that transform was never visible at a
  non-identity value and only ever produced the Rev 8 flash.) Home's
  *destination rect* still isn't reliably the full screen: see "Matching the
  destination's real content rect, not just its view bounds" below.
- Only the card layer, the scrim, and the two destinations' own real content
  are ever faded/cut at all — the *source* tile sitting in the grid/list
  underneath is hidden outright, not faded, the instant the opening flight
  starts moving: each container calls its `onFlightStarted`, which sets
  `HomeView`'s `hidesSourceTile` (read by `VideoGalleryView` as
  `hiddenAssetIdentifier`) or `ClipListView`'s `hiddenItemID` (read by
  `ClipCardView.isHidden`). Not at presentation: the cover takes a few frames
  to present, and `ClipExpansionContainer` also waits for its card's video
  surface to show the tile's frame (or a 0.3s timeout) before it starts the
  flight, and until then the tile itself is what's on screen.
- `progress` is driven by `.easeInOut(duration: flightDuration)`
  (`ExpansionFlightGeometry.animateFlight`) with `flightDuration = 0.25` for
  tap-to-open, the reverse close flight, and the cancel flight back to open,
  and linearly by live drag translation for an interactive
  dismiss — the same geometry/opacity math serves all of them, so there's no
  separate "interactive" rendering branch, only a different thing writing to
  `progress`. An explicit-duration curve rather than a spring: the
  `.spring(response: 1, …)` Revs 5–6 used does ~85% of its travel in the first
  ~0.65s and then crawls, so the *visible* growth never read as the intended
  length even though `progress` technically took ~1.5s to settle — see Rev 7.
  (The Photos measurements in "Research" above still describe the
  *interactive* feel; the open/close duration is a product decision, not a
  spring parameter — 1s in Rev 7, 350ms in Rev 8, 250ms since Rev 9.)
- The **player is scrubbed in step** (`FlightScrubber`, shared): an animated
  flight drives exact seeks on the same ease-in-out curve as the geometry, one
  seek in flight at a time, stopping intermediate seeks once another couldn't
  finish inside the flight and always ending on an exact seek to the landing
  frame; an interactive drag requests the frame proportional to its travel,
  keeping only the latest target while a seek is in flight. See Rev 8.
- **Close** always runs the same two steps: animate `progress` back to 0,
  then — once that's visually landed (`flightDuration + 0.05`, not a
  completion callback, and never before the scrub's final seek has completed)
  — call the real `dismiss()`,
  suppressing the system's own cover-dismissal transition the same two-layer
  way the open side suppresses its presentation animation (see "Suppressing
  the system's own dismissal animation" below) so it doesn't layer a second
  animation — a visible slide of the already-landed card — on top of motion
  that already ended at the tile's exact position and size.

### Where the two containers genuinely differ

| | `ClipExpansionContainer` | `HomeExpansionContainer` |
|---|---|---|
| Destination frame | The editor's fixed crop marker (`destination = measuredMarker ?? fallbackMarker`): the card is laid out at the marker, with the video placed in it exactly as the editor places it under the marker (`ClipEditorStage.videoPlacement`), so inside the marker the settled card and the editor's own surface are the same picture, and the flight shows the crop alone. The marker is reported via a `PreferenceKey` (`ClipEditorCropMarkerFramePreferenceKey`), independent of media and so available from the editor's first layout pass; a fallback marker over a rough stage band stands in only until then. Live through the opening flight, frozen once a close can begin (`acceptsDestinationUpdates`). Revs 2–11 measured the editor's aspect-fit preview frame as the destination instead; see "Measuring the destination without a race or a feedback loop" below for how that measurement was made reliable | Defaults to a synchronous aspect-ratio estimate from the tapped `PHAsset`'s own pixel dimensions (full screen only when no estimate applies, e.g. a destination that goes straight to `ClipListView`), narrowing to `ProcessingView`'s real, letterboxed video rect once it reports one via `ProcessingVideoFramePreferenceKey` — see "Matching the destination's real content rect" and "Measuring the destination without a race or a feedback loop" below. Never locked — stays live, so browsing to a neighbor with a different aspect ratio retargets it rather than flying toward the first video's letterbox rect |
| Card content | The editor's own `ClipEditorVideoSurface`, rendering the container-owned `ClipEditorViewModel`'s `AVPlayer` (the editor renders the same object), over the tile's poster thumbnail placed at the crop marker. The window starts on the marker's center square (what the tile's aspect-filled loop shows) | The tile's square thumbnail at the frame's center square, the cached full-frame poster where there is one, and `ProcessingView`'s live player once reported |
| Source frame / time | Both captured once, at tap time: `sourceFrame: CGRect`, and `sourceTime` — the tile's paused loop position (the tile pauses *before* reading it), or its poster's midpoint time without a loop | A **live closure** (`sourceFrame: () -> CGRect?`), re-read on every render until a close begins — a close after `ProcessingView`'s own swipe-to-browse-neighbors must land on whichever tile is *now* current, not the one first tapped. It stays live through an interactive drag; a non-interactive close (the back button, or a committed swipe) latches it into `lockedSourceFrame` for the rest of that flight |
| Dismiss gesture | Owns one itself, planted into `ClipEditorView`'s background (see "Gesture ownership" below) | Doesn't own one — the destination (`ProcessingView`) already has its own vertical swipe, reported *into* the container via `HomeExpansionCloseHandlers` |
| Delete | Its own close path: fades out in place rather than flying, since the tile's grid slot holds different content (or nothing) by the time delete runs | N/A — Home has no per-tile delete |

## Matching the destination's real content rect, not just its view bounds

A view's own frame isn't always where its *content* visually ends up.
`HomeExpansionContainer` originally treated `ProcessingView` as always
filling the full screen — true of the SwiftUI view's bounds, but not of the
video itself: `BareVideoPlayerView` (the `AVPlayerLayer` wrapper) uses
`.resizeAspect` gravity, so a video whose aspect ratio doesn't match the
screen's (a landscape recording in this portrait-only app, for example)
only occupies a smaller, letterboxed sub-rect within those bounds — the rest
is black bars drawn by the layer itself, invisible to SwiftUI's own layout
system entirely. Flying the card to the full screen while the real content
only ever filled a narrower band meant the card-to-content cut
landed on a visible size mismatch: the card had grown past where the video
actually was.

The fix mirrors `ClipExpansionContainer`'s own destination-measuring
approach (see the table above), computed with the same `AVMakeRect` math
`ProcessingView.poseOverlay` already used to align the pose skeleton to the
letterboxed video: a `ProcessingVideoFramePreferenceKey`, reported from a
`GeometryReader`-backed `.background` inside `ProcessingView.videoStage`
once `displaySize` (the asset's natural size, loaded asynchronously from its
track info) is available, consumed by `HomeExpansionContainer` the same way
`ClipExpansionContainer` consumes `ClipEditorCropMarkerFramePreferenceKey`.
Unlike that key's reports, though, it's never locked — see the table above for why: this
container applies no transform for a lock to protect against, and the live
update is what lets a browse-to-neighbor with a different aspect ratio
retarget correctly instead of flying toward a stale video's letterbox rect.
`ClipListView` as a destination never reports a frame through this key at
all (it has no single video, just its own grid), so the full-screen default
stands unchanged for that case.

Verified by seeding the simulator's Photos library with a synthetic
landscape test video (`xcrun simctl addmedia`, a solid-color clip rendered
narrower than tall) and recording the open/settle/close sequence at native
frame rate: the settled video sits correctly letterboxed, and critically the
*close* flight also now shrinks from that same narrower band — before the
fix it would have shrunk from (and, on open, grown to) the full screen.

## Measuring the destination without a race or a feedback loop

Rev 1 shipped two different bugs that both showed up as the same symptom —
the open flight's growth target (and, for Clip, the close flight's start
point) not matching the destination's real on-screen size — for different
reasons in each container.

**`HomeExpansionContainer`: the measurement can't start until well after the
open spring does.** `ProcessingVideoFramePreferenceKey` only reports once
`ProcessingView`'s own `displaySize` has loaded from the asset's track info
— and that load is inside a `.task` scoped to `ProcessingView` itself, which
doesn't even mount until `viewModel.path.last` resolves to a video. Per
`HomeView.presentSlot`'s own doc comment, that PhotoKit resolve "can be
anywhere from instant to several seconds" — so the track load that feeds the
real measurement routinely starts *after* the open spring has already
finished. The destination fallback before Rev 2 was blind to this: a plain
full screen. The open flight grew toward the full screen the entire time,
only narrowing to the correct letterboxed rect once the real measurement
eventually landed (if it landed before the crossfade cut, that was at least
invisible; if not, the card itself was visibly the wrong size).

The fix doesn't wait any longer for the real measurement — it replaces the
*blind* full-screen guess with an *informed* one. `PHAsset.pixelWidth`/
`pixelHeight` are ordinary asset metadata, already in hand from the grid
tile that was tapped, needing no resolve or track load at all, and already
reflect display orientation (the same thing `VideoTrackGeometry.displayedSize`
computes from `naturalSize` + `preferredTransform`, just synchronously).
`HomeExpansionContainer.initialAspectRatio` runs the same `AVMakeRect` math
the real measurement does, against this synchronous estimate, so the open
flight grows toward (almost always exactly) the right rect from the first
frame — and still retargets live if the real measurement, once it lands,
differs at all. This estimate is only correct for a destination that will
letterbox, so `HomeView` only supplies one when the tapped video is actually
headed for `ProcessingView` — for the camera-originated case that goes
straight to `ClipListView` (never measured, correctly full screen), it's
`nil`, and the full-screen default stands exactly as before.

*Revs 2–7, superseded: the rest of this subsection describes a measurement
that no longer exists. `ClipEditorPreviewFramePreferenceKey`,
`ClipEditorView.previewSection` and the `editorScale`/`editorOffsetX`/
`editorOffsetY` transform are gone; the Clip container now measures the crop
marker (`ClipEditorCropMarkerFramePreferenceKey`) into `measuredMarker` — see
Rev 12 and Rev 13.*

**`ClipExpansionContainer`: the destination measurement needed the
transform it fed into to have already settled, which only happened near the
very end of a flight — or never, during one.** `ClipEditorPreviewFramePreferenceKey`'s
report is read *through* this container's own `.scaleEffect`/`.offset` on
`ClipEditorView` (unlike Home, which applies no transform to its content),
so the raw report isn't the editor's true, untransformed frame — it's that
frame as distorted by whatever transform was currently in effect. Rev 1's
fix for this was to simply wait: ignore every report until `progress > 0.98`
and lock the first one that arrives after that, on the theory that the
transform is close enough to identity by then for the distortion not to
matter. In practice this meant the *open* flight's destination stayed the
placeholder fallback square for the entire flight, every time — the lock
can't fire until `progress` is already almost at `1`, i.e. after the growth
is already visually done — so the open flight always grew toward the wrong
target. The *close* flight's start point fared better (whatever got locked
near the end of the preceding open was at least close to correct), but was
only ever an approximation, not the real frame — the residual ~1-2% of
transform distortion still in effect at `progress = 0.98` baked itself into
the locked value permanently.

The fix divides the known transform back out of *every* report, recovering
the editor's true frame algebraically instead of waiting for the transform
to become (approximately) the identity on its own:

```swift
measuredDestination = CGRect(
    x: (frame.minX - editorOffsetX) / editorScale,
    y: (frame.minY - editorOffsetY) / editorScale,
    width: frame.width / editorScale,
    height: frame.height / editorScale)
```

This is correct at *any* `progress`, including `0`, so there's no more
waiting and no more locking during the opening flight — convergence starts
from the first report instead of only becoming trustworthy once `progress`
is already most of the way to `1`. The one thing this needed to actually
land correctly: `ClipEditorView.previewSection` used to report its frame
unconditionally, including from its *own* loading-placeholder branch (an
arbitrary 9:16 rect) — dividing out the transform recovers whatever frame
was reported faithfully, placeholder included, so a placeholder report
would have handed this container a confidently-wrong destination instead
of an admittedly rough one. `previewSection` now only reports from the
branch that renders the real, aspect-correct preview.

Rev 2 initially *also* kept `measuredDestination` live for the rest of the
editor's lifetime, the same way `HomeExpansionContainer`'s already does —
reasoning that since the divide-out is correct at any `progress`, there was
no more reason to stop accepting reports than `HomeExpansionContainer` has.
That part was wrong; see Rev 3 below.

*Rev 8 note:* the divide-out above is gone. `ClipExpansionContainer` no
longer applies any transform to `ClipEditorView` (see Rev 8 for why that
transform was both invisible under the hard cut and the cause of the
back-button flash), so the measured value is the raw reported frame — since
Rev 12, the crop marker's frame, held in `measuredMarker`.
The `acceptsDestinationUpdates` gate from Rev 3 stays: once the user could be
leaving, the flight's endpoint shouldn't track a value that could still move.

## Rev 3: the live version of the fix above livelocked real devices

*2026-10-03, same day.* Unlike `HomeExpansionContainer`, which applies no
transform to its own content, `ClipExpansionContainer`'s `editorScale`/
`editorOffsetX`/`editorOffsetY` — the transform `measuredDestination` is
divided out of — are themselves computed *from* `measuredDestination`. Kept
live for the container's whole lifetime, this is self-referential: each
report feeds a value back into the next render's transform, which the next
report then gets divided back out of. At a steady `progress` (fully open,
fully closed) the system has one chance to converge and then goes quiet —
no further reports arrive once `previewSection`'s on-screen frame stops
moving. During an *animated* close, `progress` instead keeps moving
continuously for the whole transition, whether driven by the back button's
spring or the interactive swipe's 1:1 drag — both go through the exact same
`onPreferenceChange` handler every intermediate frame — so the
self-referential system gets perturbed continuously rather than settling
once — a plausible mechanism for a livelock, inferred from the code's own
structure, not something stepped through live.

What's actually confirmed, from a user's device where the always-live
version above froze on *every* close (never reproduced on the simulator,
across several attempts — see "Measuring the destination without a race or
a feedback loop" above for this doc's own history of exactly that kind of
false negative): the main thread livelocked and never recovered on its own,
and two debugger pauses taken a few seconds apart each landed inside a
`CATransaction` commit — one inside SwiftUI's own graph update, the other
25 frames into a `CALayer` tree walk — with no app code in either stack.
That's real evidence of a genuine, unrecovering main-thread livelock
triggered by closing the editor. It is *not* confirmation that this
specific self-reference is the mechanism — two pauses can't show the thread
cycling, only that it was busy with expensive internal work at two
different moments. The fix below is the best structural candidate found,
shipped on that basis; if a user's device still freezes after it, this
inference was wrong and the real cause is still out there.

Taking only the first report and freezing for good (tried first) turned
out to be too aggressive: the earliest reports, sampled before
`editorScale` has grown much past its starting value, are themselves still
visibly off — a newly-mounted view's first geometry report doesn't yet
reflect the real composited transform — and need a few more live updates
to actually converge, which `ExpansionTransitionVerificationTests`
(`testClipExpansionOpenConvergesToTheEditorsRealPreviewFrame`) caught
immediately: the card latched onto the wrong frame and never corrected.

The fix instead draws the boundary at the thing that's actually unstable —
not "has a report arrived yet" but "could the user possibly be leaving":
`measuredDestination` stays exactly as live as it was for the opening
flight (where that liveness is the real fix and the existing regression
test already proves it converges), gated by a new
`acceptsDestinationUpdates` flag that's set `false` on the first touch-move
of an interactive drag, or when `close()`/`closeForDelete()` runs, whichever
comes first — covering a committed swipe, a cancelled one, the back button,
and Delete alike, for the rest of the container's lifetime. A cancelled
drag's snap-back to `progress == 1` is *not* a special case left live: by
the time any drag can start, the opening flight converged long ago, so
there's nothing left to gain from remeasuring through the cancel-spring
either.

## Rev 4: the cut Rev 2 thought it shipped was still a fade

*2026-10-04.* Reported symptoms: the growing layer looked semi-transparent during
the flight, and there was a subtle but persistent-feeling gap between where the
expand/shrink motion topped out and the real destination's video frame
(`ProcessingView` and `ClipEditorView` both). Both traced to the same cause, and
Rev 2's "replace the cross-fade with an instant cut" fix (`editorOpacity`/
`contentOpacity`'s `progress >= crossfadeThreshold ? 1 : 0`) never actually took
effect for any `withAnimation`-driven flight — tap-to-open, back-button-close, the
cancel-spring. Only the interactive drag (which writes `progress` directly,
outside `withAnimation`) ever saw the step function behave like one.

**Why.** A SwiftUI `View`'s `body` is a computed property, not a per-frame
callback. `withAnimation(.spring…) { progress = 1 }` evaluates `body` *once*, at
the new state's target value (`progress == 1`) — not at any of the values the
spring will actually pass through on the way there. `editorOpacity(for:)` is a
plain function of that single `progress` value, so for the whole 0.3s flight it
only ever gets asked about the two endpoints (`0` and `1`), never anything
in between — exactly the two inputs a plain `.opacity()` modifier was already
going to receive. But `.opacity()` is itself `Animatable`: SwiftUI's own render
loop takes those two endpoint values and interpolates between them using the
*same* spring, smoothly, across the entire flight — reproducing, frame for
frame, the cross-dissolve this feature exists to not have. The geometry
(`.frame`/`.position`/`.scaleEffect`/`.offset`) was never broken this way —
`currentRect` is linear in `progress`, so interpolating its two endpoint values
gives the same answer as evaluating it continuously would — only the *step
function* lost information by being evaluated solely at the endpoints.

This was originally believed to also explain the reported "gap" between the
expand/shrink motion's max size and the real destination frame — the theory
being that since opacity and geometry were interpolated by the identical spring
curve, the moment either layer crossed into human-visibility corresponded to a
sub-final fraction of the geometry's growth. **That theory was wrong** — see
"Rev 5: the gap was a second, unrelated bug" below, found after this fix shipped
and the gap was reported to still be there.

**Confirmed, not assumed** — this doc has enough history of fixes that looked
right on paper and weren't (see "A verification note" below) to not repeat that
here. A `print()` inside `contentOpacity(for:)`, read via `xcrun simctl launch
--console-pty` (the one mechanism in this codebase's own notes that reliably
captures `print()`, not `log stream`), showed exactly two calls for the entire
open flight:
```
SCRATCH_OLD_OPACITY progress=0.0 result=0.0
SCRATCH_OLD_OPACITY progress=1.0 result=1.0
```
— proving the step function never ran against an intermediate value, for a real
on-device flight, not a theoretical one.

**The fix** can't live in a computed property no matter how it's written — it
needs `body` itself (or an equivalent) to be re-invoked at intermediate
`progress` values. `CrossfadeCut`, a `ViewModifier` conforming to `Animatable`
with `progress` as its own `animatableData`, does exactly that: SwiftUI drives a
custom `Animatable` type's `animatableData` through the spring itself, calling
`body(content:)` once per rendered frame with the *live* interpolated value —
the same mechanism a custom `GeometryEffect` uses for frame-accurate shape
animation, applied here to a visibility cut instead. `.transaction { $0.animation
= nil }` on the inner `.opacity()` stops that per-frame discrete jump from being
treated as yet another animatable change and smoothed over whatever's left of
the spring. Re-verified the same way, post-fix:
```
SCRATCH_CROSSFADE above=false progress=0.8334805370860541 visible=true
SCRATCH_CROSSFADE above=true  progress=0.8334805370860541 visible=false
SCRATCH_CROSSFADE above=false progress=0.8713415891185463 visible=false
SCRATCH_CROSSFADE above=true  progress=0.8713415891185463 visible=true
```
36 calls across the one flight, converging smoothly from `progress ≈ 0` through
every intermediate value to `1.0`, with the visibility swap landing tight against
`crossfadeThreshold` (between `0.8335` and `0.8713`) instead of at one of the two
endpoints.

Duplicated as `CrossfadeCut` in both `ClipExpansionContainer.swift` and
`HomeExpansionContainer.swift` rather than shared, consistent with how the rest
of each container's logic is independently implemented (see this doc's own
intro). `editorOpacity`/`contentOpacity` stay, unchanged, as the (correct, since
hit-testing only needs the two endpoints) gate for `allowsHitTesting` — they just
no longer drive the layers' actual visibility.

## Rev 5: the gap was a second, unrelated bug

*2026-10-04, same day.* After Rev 4 shipped and the open/close spring's
`response` was raised from `0.3`/`0.29` to `1` (an unrelated "make the flight
last about a second" request), the previously-reported sizing gap was
confirmed still present — Rev 4's theory that it was a side effect of the
crossfade-opacity bug (and would therefore already be fixed by Rev 4) was
wrong. The real cause: `measuredDestination`'s `onPreferenceChange` handler,
in both containers, was a plain assignment —

```swift
measuredDestination = CGRect(/* divided-out report */)
```

— and `destination = measuredDestination ?? fallbackDestination(in:)` feeds
directly into `currentRect`, which drives `rect`'s `.frame`/`.position`.
Unlike the opacity bug, this isn't about `body` only seeing `progress`'s two
endpoints — `currentRect` being linear in `progress` is exactly why the
*geometry* survived that problem untouched (Rev 4's own reasoning). But a
change to `destination` *itself*, arriving from a separate, later state
update (the real measurement landing well after `fallbackDestination` has
already been driving the flight for a while, since `ClipEditorPreviewFrame`/
`ProcessingVideoFramePreferenceKey` both depend on an async load with no
upper bound), recomputes `rect` at whatever `progress` is already committed
to — and without `withAnimation` around *that specific* assignment, SwiftUI
has nothing to interpolate from: `.frame`/`.position` snap straight to the
new value in a single frame. The longer `response: 1` flight didn't create
this bug — it just gave the async measurement far more time to land mid-flight
instead of before the card had grown large enough for the jump to be
noticeable, which is almost certainly why the original `response: 0.3`-era
report called it "subtle."

**What didn't work for verifying this, and why**, since getting this wrong
cost real time again:
- **XCUITest's `element.frame`, and a `GeometryReader`/`PreferenceKey`
  reporting its own `.global` frame (the same mechanism `measuredDestination`
  itself is built on), both report the current *model* value, not Core
  Animation's live `presentation()` value.** Polling either one repeatedly
  during an open flight returns the *same, already-settled* number on every
  sample — confirmed directly: a poll loop sampling every 30ms from
  immediately after the tap returned the final settled frame on its very
  first sample, long before a `response: 1` spring could plausibly have
  finished. Neither tool can tell "jumped" from "animated smoothly"; they can
  only tell you a change happened, after the fact.
- **A `UIViewRepresentable` probe reading `layer.presentation()?.frame` via a
  `CADisplayLink`** seemed like the fix for the above, but a UIKit view
  bridged into SwiftUI has its frame set by the SwiftUI↔UIKit bridge, not
  necessarily driven through the same implicit Core Animation transaction a
  native SwiftUI `.frame`/`.position` modifier uses — so it can't be trusted
  to reflect what the native layer is actually doing either, and this
  session's readings from it didn't hold up under scrutiny.
- **`simctl io recordVideo` reliably dropped frames during the exact window
  the animation was playing** — not an occasional flake: four separate
  attempts (driving the real tap through `ClipListView` via XCUITest, a
  direct-mount scratch harness with zero XCUITest overhead, and `xcodebuild
  test-without-building` to remove compile-time CPU contention) each showed
  multi-second gaps in the recorded timeline exactly spanning the open
  flight, with the frame immediately before showing the stale fallback
  square and the frame immediately after already fully settled. The
  simulator appears to deprioritize screen recording under the same render
  load the animation itself generates — the thing being measured competes
  with the measurement.

**What did work:** a *bordered* recording — temporary `.border()`s on
`cardLayer` and on the editor's/processing view's own real content — doesn't
need to catch the transition in flight, only to catch one frame on each side
of it. That recording showed a frame with a `(48, 300, 1080, 1082)`-pixel
bordered square (dividing out the 3x simulator scale: `(16, 100, 360, 361)`pt
— `fallbackDestination`'s `screen.width - 32` square, pixel-exact) directly
adjacent, 12–40ms later depending on the run, to a frame with the correct
`(154, 388, 868, 1544)`-pixel rect (`(51, 129, 289, 515)`pt — the real
letterboxed/preview destination). Two consecutive captured frames, not a
gradual transition between them, is itself the proof of an unanimated snap —
this doesn't need dense in-between sampling to be conclusive, which is why it
survived the recording tool's frame-dropping where the duration measurements
above didn't.

**The fix:** wrap the assignment itself —

```swift
withAnimation(.spring(response: 0.25, dampingFraction: 1)) {
    measuredDestination = next
}
```

— in both containers' `onPreferenceChange` handlers. This is the standard
SwiftUI idiom for exactly this shape of problem (a model value correction
arriving asynchronously, independent of whatever `withAnimation` block
produced the surrounding state), and — unlike the opacity bug — there's no
`Animatable`-modifier trick needed here: `.frame`/`.position` are genuinely
continuous, animatable modifiers, so retargeting them mid-flight with a short
spring is the documented, interruptible-animation case, not a special one.
`0.25`s (independent of the main flight's own `response`) is deliberately
short: a correction, not a second flight. Every live update during the open
flight gets this treatment, not just the first — consistent with
`measuredDestination` already being designed to converge over a few reports
(see "Measuring the destination without a race or a feedback loop" above);
later, smaller corrections just become smaller nudges on top of whatever
correction is already in flight, which is the same "retarget an in-progress
spring" case SwiftUI already handles for the first one.

**Left open:** `ClipExpansionContainer`'s divide-out (`editorScale`/
`editorOffsetX`/`editorOffsetY`) still reads these as plain `body`-level
values — which, per the opacity bug's own lesson, are `progress`'s *target*
values, not a live in-flight transform — so the divide-out is only exactly
correct once the surrounding spring (now including this new correction
spring) has actually settled, same as before this rev. This wasn't changed
here: doing so would mean threading live geometry through an `Animatable`
modifier the way `CrossfadeCut` does for opacity, which touches the exact
self-referential `measuredDestination`-feeds-the-transform-that-divides-out-
the-next-`measuredDestination` relationship Rev 3's real-device livelock came
from. If a real device still shows jitter or a lingering mismatch during the
open flight after this fix, that's the next place to look — `verified, not
assumed` applies especially there.

**Postscript, same day: the fix above was itself wrong.** Reported back after
shipping — neither the duration change nor the gap fix seemed to have taken
effect. They hadn't, for a reason that follows directly from the SwiftUI
semantics explained above but wasn't thought through at the time: the
`withAnimation(.spring(response: 0.25, …))` wrapped around
`measuredDestination`'s assignment doesn't just smooth *that* value — it
retargets the exact same `.frame`/`.position` the *main* open spring
(`response: 1`) is still actively animating. SwiftUI's implicit-animation
retargeting takes the newest animation's curve for whatever it touches, not a
blend of the two, so once the short correction fires, the long spring's
remaining influence over the geometry is simply gone. Confirmed with a
timestamped `print()` through the real `ClipListView` tap flow (not the
isolated harness, which has different, shorter, asset-load timing): the real
measurement arrived at `t≈0.13s`, the 0.25s correction then ran the geometry
to its final size by `t≈0.4s` — while `CrossfadeCut`'s own `progress`
logging, untouched by any of this, showed the *correct* curve the whole time
(crossing `0.85` at `t≈0.67s`, settling at `t≈1.5s`). The card finished
growing and then sat static for another half-second-plus before the crossfade
cut, which is a *third*, different-looking defect from either original
report — and reads, from the outside, exactly like "nothing changed," since
the dominant visual cue (the card's own growth) really was back to taking a
fraction of a second.

The `withAnimation` wrap was reverted (back to the plain assignment this
section originally replaced) to restore the open spring's correct pacing
immediately — this reintroduces the original unanimated-jump bug, now
confirmed to be smaller/less visually prominent at `response: 1` than it was
at the original `response: 0.3`, since the real measurement lands at a much
earlier *fraction* of a now-longer flight, but it is still a bug. The
architecturally correct fix — computing `rect` (and, for
`ClipExpansionContainer`, `editorScale`/`editorOffsetX`/`editorOffsetY`) from
*live* `progress` via an `Animatable` modifier, `CrossfadeCut`'s own
technique applied to geometry instead of opacity — removes the need for any
second animation at all: a `destination` change just becomes a new per-frame
lerp target, nothing to retarget or fight. See "Rev 6" below for that fix,
once it lands; until then, the known-smaller jump from the plain assignment
is the shipped state.

## Rev 6: the live-geometry fix, three attempts in

*2026-10-04, same day.* Three shapes of "compute `rect` from live `progress`"
were tried before one actually worked. The first two each caused a
confirmed hang — not a vague slowdown, a sustained near-100% CPU spin that
needed the process killed. Both are worth recording in full, because both
*looked* like the obviously-correct application of the exact technique
`CrossfadeCut` had already proven safe for opacity.

**Attempt 1: a `View` with a `@ViewBuilder content` closure.** The natural
reading of "compute geometry live and hand it to both layers" is a wrapper
view, `Animatable`, whose `body` calls a content closure with the live
`rect`/`editorScale`/`editorOffsetX`/`editorOffsetY`/`cornerRadius`:

```swift
LiveFlightGeometry(progress: progress, sourceFrame: sourceFrame, destination: destination) {
    rect, editorScale, editorOffsetX, editorOffsetY, cornerRadius in
    ZStack {
        NavigationStack { ClipEditorView(...) } /* ... */
        cardLayer(rect: rect) /* ... */
    }
}
```

This compiles, looks reasonable, and is wrong in a way that only shows up at
runtime: `Animatable`'s `body` is called once per rendered frame for the
whole duration of the spring (confirmed for `CrossfadeCut` already, same
mechanism) — and here, `body` calling the `content` closure means the
closure's entire literal contents, including `NavigationStack { ClipEditorView
(...) }`, get *rebuilt* every one of those frames. `NavigationStack` is
backed by a real `UIViewController` (this doc's own "Gesture ownership"
section, below, already established that). Reconstructing that
`UIViewController`-backed subtree ~60–120 times a second for the ~1s open
spring is not a cost SwiftUI's diffing can hide. Confirmed via `ps`: the
simulator's `Turnip` process pinned at 98.5% CPU, state `R` (running, not
blocked), for the full 175s an `XCTest` accessibility query then timed out
waiting on. Indistinguishable from Rev 3's real-device livelock by symptom
alone — it took checking actual CPU state to tell "working through a huge
backlog" from "stuck."

**Attempt 2: a plain `ViewModifier` applying layout modifiers.** The fix for
attempt 1 seemed obvious: `ViewModifier.body(content:)` receives `content`
the *enclosing* body already built once — `CrossfadeCut` proves this doesn't
rebuild anything expensive, since it only ever receives an already-built
`NavigationStack` and adds `.opacity()`/`.transaction()` to it. So, two
`Animatable` `ViewModifier`s — `LiveCardGeometry` applying `.frame`/
`.clipped`/`.position`/`.clipShape`, `LiveEditorGeometry` applying
`.scaleEffect`/`.offset` — each called via `.modifier(...)` on content built
once by the enclosing `body`.

This one is more insidious: it doesn't hang immediately, and the failure
mode changes depending on `.modifier()` ordering relative to `CrossfadeCut`
(explored at length before the real cause was found — nesting order turned
out to be a red herring both times). With `LiveCardGeometry` nested inside
`CrossfadeCut`, a timestamped-`NSLog` check showed it was called only
*three* times total for the whole flight — not live at all, just the
ordinary handful of `body`-level re-renders a plain `@State` change would
have produced anyway. Swapping the order (geometry modifier outermost) did
make it live — 79 calls, matching `CrossfadeCut`'s own count — but applying
the *same* swapped order to the editor's `.scaleEffect`/`.offset` produced a
second, different hang: 22,295 calls to `effectValue`-equivalent code in
under 40 seconds, for what should be a ~1.5s flight.

The actual mechanism, once traced: `.frame`/`.position`/`.clipShape` are
*layout* modifiers, not render-time ones. A `ViewModifier`'s `body(content:)`
being called with a *new* size/position every frame means the surrounding
layout system has to re-run layout to accommodate the new intrinsic size the
modifier is now requesting — which can itself trigger another pass through
the modifier (its inputs, read from the enclosing `body`'s `@State`-derived
values, haven't *logically* changed, but the layout engine doesn't know
that) — a layout feedback loop, not an animation one. On the editor side
specifically, there's a second compounding mechanism: `ClipEditorView`'s own
`previewSection` reports its on-screen frame via a `GeometryReader`
`.background`, in `.global` coordinate space — which, once the editor's own
`.scaleEffect`/`.offset` are *live*, genuinely changes on every rendered
frame (the editor's actual on-screen position is changing, correctly). That
feeds `onPreferenceChange(ClipEditorPreviewFramePreferenceKey.self)`, which
fired on *every* such change instead of a bounded handful of times, writing
`measuredDestination` every frame — Rev 3's self-referential livelock,
reintroduced through a different door than the one Rev 3 closed.
`CrossfadeCut` never hit either problem because `.opacity()`/`.transaction()`
are render-time, not layout, modifiers — the same distinction `GeometryEffect`
below is built around.

**Attempt 3: `GeometryEffect` — the fix.** This is the primitive SwiftUI
actually provides for "per-frame animatable transform, computed after layout,
with no way to feed back into layout": `effectValue(size:) -> ProjectionTransform`
runs at render time against an already-settled layout size, and returns a
transform applied to the rendered output, not a new layout request.
`.scaleEffect`/`.offset` — what this container already used for the editor
— are themselves built on `GeometryEffect`; `CardFlightEffect` and (the
editor-side version, tried and itself reverted — see below) `EditorFlightEffect`
just compute their transform from `liveRect(progress:sourceFrame:destination:)`
instead of a fixed value:

```swift
private struct CardFlightEffect: GeometryEffect {
    var progress: CGFloat   // animatableData
    let sourceFrame: CGRect
    let destination: CGRect

    func effectValue(size: CGSize) -> ProjectionTransform {
        let rect = liveRect(progress: progress, sourceFrame: sourceFrame, destination: destination)
        let scaleX = rect.width / max(destination.width, 1)
        let scaleY = rect.height / max(destination.height, 1)
        let offsetX = rect.minX - destination.minX * scaleX
        let offsetY = rect.minY - destination.minY * scaleY
        return ProjectionTransform(CGAffineTransform(a: scaleX, b: 0, c: 0, d: scaleY, tx: offsetX, ty: offsetY))
    }
}
```

`cardLayer` is laid out at `destination`'s size/position — fixed, the same
way the editor was already laid out at the full screen size — with
`CardFlightEffect` flying it to wherever `liveRect` says it should visually
be, every frame, without ever asking layout for a different size. Nothing
for a layout pass to feed back into; nothing for `onPreferenceChange` to
fire more than the same bounded handful of times it already did.

**Applied only to the card, not the editor.** `EditorFlightEffect`
(mechanically identical to `CardFlightEffect`, minus the independent
width/height scaling — the editor's own content has `destination`'s fixed
aspect ratio throughout, so it's a uniform scale, matching the pre-live
`editorScale`'s original formula) was written, and did reproduce attempt 2's
second hang — confirming the `previewSection`/`onPreferenceChange` feedback
mechanism above has nothing to do with *which* geometry primitive drives the
transform; it's specifically about the editor's transform being live at all.
But the editor doesn't need to be live: it's invisible (`CrossfadeCut`) for
the entire flight until `progress` nears the crossfade threshold, by which
point `destination` has long since stabilized — the real measurement
consistently arrives within the first ~15% of the flight (confirmed on
real-device-equivalent timing below), nowhere near 0.85. The body-level,
static `targetEditorScale`/`targetEditorOffsetX`/`targetEditorOffsetY` this
container already computes for the preference-divide-out math (see
`measuredDestination`'s own doc comment, and the comment at the editor's
`.scaleEffect`/`.offset` call site) are *also* exactly correct for driving
the editor's actual transform — there was never a second bug to fix on the
editor's side, only the appearance of needing the same medicine the card
needed. `EditorFlightEffect` was deleted once this was confirmed, not kept
unused.

**Confirmed, not assumed**, same discipline as every other revision in this
doc. A `print()`/`NSLog()` from inside `CrossfadeCut.body(content:)` and
`CardFlightEffect.effectValue(size:)`, captured via `xcrun simctl spawn
<device> log stream --predicate 'process == "Turnip"'` while an `XCTest`
drove the real `ClipListView` tap (not the isolated harness — see the next
paragraph for why that distinction mattered), showed:

```
SCRATCH_PROGRESS progress=0.000000
SCRATCH_RECT progress=0.000000 width=176.500000 destWidth=361.000000   ← fallback square
SCRATCH_RECT progress=0.000000 width=176.500000 destWidth=290.522621   ← real measurement lands
SCRATCH_PROGRESS progress=0.001297
SCRATCH_RECT progress=0.001297 width=176.647931 destWidth=290.522621
SCRATCH_PROGRESS progress=0.014304
SCRATCH_RECT progress=0.014304 width=178.131031 destWidth=290.522621
… (continuous, 34 samples total, width tracking progress smoothly toward 290.52) …
SCRATCH_RECT progress=0.843322 width=272.657762 destWidth=290.522621   ← card about to cut out
SCRATCH_PROGRESS … continues to progress=1.000000 at ~1.5s
```

The destination switches from the `361`pt fallback square to the real
`290.52`pt measurement while `progress` is still `0.000000` on both sides —
`rect.width` doesn't move at all across that switch, because at `progress =
0` the lerp always equals `sourceFrame` regardless of `destination`. Growth
from there is smooth and continuous straight through to where the card cuts
out (`progress ≈ 0.85`), with no discontinuity anywhere. `CardFlightEffect`
isn't called every single rendered frame the way `CrossfadeCut` is (34
calls vs. 79 over the same flight — SwiftUI apparently doesn't always
re-invoke a `GeometryEffect` on frames where nothing about its *rendered*
output would meaningfully change) but every call it does receive is
continuous with its neighbors, which is the property that actually matters.

**Why the isolated harness gave a different, less useful answer.**
Diagnosing this against `ScreenshotClipExpansionHarness`-style direct mounts
(no `ClipListView`, no tap, no `XCUITest`) is what made attempt 2's "only 3
calls" result look like a nesting-order problem in the first place — the
harness's locally-generated sample movie loads fast enough that the
real-measurement retarget was already long done by the time any diagnostic
frame got sampled, hiding the actual timing relationship between the retarget
and the live interpolation. The real `ClipListView` → `ClipEditorView` path,
with real (if still fast — a 6-second generated sample movie, not a user's
actual Photos-library asset) `AVAsset` loading, was the only context where
this was visible. Lesson, adjacent to this doc's existing ones about
`recordVideo` dropping frames under load: an isolated harness built to
remove confounding variables can *also* remove the variable you're trying to
measure. When timing relative to an async load is the thing under test, the
real call path has to be in the loop somewhere.

**Verification in the end:** `ExpansionTransitionVerificationTests` (both
cases, pixel-exact against the previously-passing values), a scratch
hang-check test (tap-and-wait with a 45s kill-guard, both for open and for
back-button close — passed in ~7–11s each, consistent with a flight that
isn't stuck), and the `NSLog` continuity check above. `HomeExpansionContainer`
got the identical `CardFlightEffect` treatment (its own `liveRect`/
`CardFlightEffect`, duplicated per this file's own convention) — simpler
there, since Home's `content` never has a transform applied to it at all
(only the opacity cut), so there was never an editor-side self-reference
risk to avoid in the first place.

## Rev 7: the cut was in the wrong place, and the verification measured the wrong thing

*2026-10-05.* Rev 6 shipped with a log showing `progress` following a ~1s
curve and `rect` continuous through the destination retarget, and was reported
back as fixing neither request. Both reports were correct. The two causes:

**The cut at `crossfadeThreshold = 0.85` was itself the gap.** `currentRect`
only reaches `destination` at `progress == 1`. Swapping to the real content at
`0.85` swapped a card that was still 15% of the tile-to-destination distance
short for content already sitting at 100% — a hard pop at the end of every
open. For `HomeExpansionContainer`, whose content has no transform at all, that
is the full 15% (a ~190pt tile growing to 393pt pops ~30pt). For
`ClipExpansionContainer` the editor's own uniform scale/offset started from a
value computed against the *fallback* square, so it never quite coincided
with the card either. This was the user's "gap between the maximum size of the
expansion and the video frame" from the very first report — Rev 2's fade had
smeared it, Rev 4's hard cut made it crisp, and Revs 5–6 chased the
destination retarget instead, which was a real but *separate* defect. The
threshold is now `0.999`: fractionally under `1` only so an interactive
drag's first touch-move already hands back to the card.

**`.spring(response: 1, dampingFraction: 1)` is not a one-second expansion.**
It reaches 85% of its travel at ~0.65s and 95% at ~0.8s, then crawls toward
1.0 until ~1.5s. The card's visible growth therefore read as well under a
second, ended with the pop above, and the only thing that visibly lasted a
second was the scrim fading in — exactly the "you lengthened a cross fade, not
the expansion" report. Rev 6's own calibration note ("settles to 99% in ~1.1s")
was true and beside the point. The flight is now `.easeInOut(duration:
flightDuration)` with `flightDuration = 1`: it ends at exactly `1.0` at
exactly one second, and the dismiss delay is `flightDuration + 0.05` instead
of a spring-settle guess.

**Why five revisions of verification missed both.** Every check measured
something the code *computes* — `progress`'s curve, `rect`'s continuity, the
card's *settled* accessibility frame — and none measured what the user
*sees*: how long the card is visibly growing, and whether the card's frame at
the instant it disappears equals the frame of what replaces it. The settled
frame is correct in every revision; the problem was never at settle. A log
that `progress` reaches `0.99` at 1.1s says nothing about when the growth
stopped being perceptible.

**The redesigned verification**, run against the real `ClipListView` tap flow
(not the direct-mount harness — Rev 6 already recorded why that hides timing):

1. *Duration, as the user sees it:* a timestamped `NSLog("T0")` in `onAppear`
   and one in `CrossfadeCut` on every frame, via `simctl spawn … log stream`.
   The number that matters is the wall-clock delta from `T0` to the first
   frame the editor instance reports `visible`, because that is when the
   card's growth is replaced by the content. Result: **+1.038s** (and
   `+1.052s` on a second run).
2. *Gap, at the only instant it can exist:* `CardFlightEffect.effectValue`
   logs `rect` and `destination` every frame; the last `rect` logged before
   the cut is compared against `destination`. Result:
   `rect=(51.6, 129.0, 290.3×514.9)` vs `dest=(51.2, 129.0, 290.5×515.7)` —
   under 1pt on every edge. Under Rev 6's `0.85` cut the same measurement
   would have shown `rect` ≈ 15% of the distance short, which is how this
   check would have caught the original bug.
3. *Liveness guard:* the number of `effectValue` calls between `T0` and the
   cut — **121** on a ~1s flight, i.e. per-frame. A handful means the effect
   isn't animating; thousands means a feedback loop (Rev 6).
4. *Eyes:* `XCUIScreen.main.screenshot()` at ~180ms intervals after the tap,
   exported from the `.xcresult` and actually looked at. At 0.70s the card
   is roughly a third of the way; at 0.88s about two-thirds; at 1.06s
   essentially there. Growth is visibly still happening past 0.9s, which
   no earlier revision could have claimed.

Two things that pass of checks 1–3 and the screenshots caught, recorded
because they're the kind of mistake that will recur:

- The log said the card's `rect` was correct while a screenshot showed the
  card ~150pt to the right of where it "should" be. The log was right: the
  tapped tile (`label == 'Open clip'`) is the **top-right** tile in
  `-screenshotClipListMedia`, with `sourceFrame.minX = 200.5`, not the
  top-left one. Reading `sourceFrame` out of the first `effectValue` log line
  before interpreting a screenshot would have avoided a wrong "fix" (moving
  `CardFlightEffect` before `.position`) that then broke the live calls.
- That wrong fix produced its own clean signal: 6 `effectValue` calls instead
  of 121. Applying the effect inside `.position` puts it *under*
  `CrossfadeCut`, whose `.transaction { $0.animation = nil }` applies to its
  whole subtree, so the nested `Animatable` never interpolates and the card
  snaps to its final size. Third independent observation of the same rule
  (Rev 6 saw it twice and misattributed it): **any `Animatable` whose
  interpolation matters must be applied *outside* `CrossfadeCut`.** Check 3
  is what makes this visible immediately.

`CardFlightEffect` is therefore applied after `.position`, outermost, with
its transform expressed in the post-`.position` layer's space (origin at the
screen's, since the enclosing `GeometryReader` is edge to edge):
`scale = rect.size / destination.size`, `offset = rect.min - destination.min *
scale`. Both containers. (Rev 8 replaced it with the shared
`ExpansionFlightEffect`, whose scale is uniform — see below.)

## Rev 8: 350ms, no stretch, the card is the video, and the back-button flash

*2026-10-05.* Six requests in one pass: a 350ms flight; no stretching; the
open to start on the frame the tile shows and play back to the clip's first
frame; the close to start on the frame the editor shows and scrub to the
tile's frame; and a one-frame glitch on the back-button close only, "the whole
screen 1/4 smaller, pinned at the top-right, then gone".

**The flash, reproduced before anything changed.** A `-vsync 0` dump of a
back-button close at the then-current 1s flight showed exactly one frame
between the full-size editor and the first frame of the card flight: the whole
`NavigationStack` — nav bar, preview, trim slider — at ≈0.6 scale, anchored
top-leading and offset to the top-right tile's position. Mechanism:
`ClipEditorView` carried a body-level `.scaleEffect(targetEditorScale,
anchor: .topLeading).offset(…)` computed from `progress`'s *target* value, and
both modifiers sat *inside* `CrossfadeCut`, whose `.transaction { $0.animation
= nil }` applies to its whole subtree (lesson 14). So the instant `close()`
wrote `progress = 0`, the editor snapped to the tile transform while
`CrossfadeCut`'s own animated progress was still ≥ 0.999 for the first
rendered frame of a 1s ease-in-out (it crosses 0.999 at ~22ms). The swipe path
never showed it because the first touch-move writes `progress < 0.999`
synchronously, hiding the editor on the same frame it's transformed. The open
side never showed it because the target at `progress = 1` is the identity. The
transform was dead weight under a hard cut — never visible at a non-identity
value — so it is deleted rather than animated; with it goes the Rev 2
divide-out (the raw preference report is now the destination) and the
self-reference Rev 3 worried about.

**No stretch = the card must end as the full frame.** The tile shows the center
square of the *cropped* composition; the editor shows the *full* frame with a
dimmed surround. Any still image aspect-filled into the preview rect either
stretches (Rev 7) or ends zoomed into the crop and pops at the cut. So the card
is laid out at the destination, and only a window onto it animates:
`ExpansionFlightGeometry.resolve(progress:sourceFrame:destination:focus:)`
returns `rect` (where the card is on screen), `region` (the visible window, in
the card's coordinates: from the tile's aspect-filled sub-rect of `focus` to
the whole content) and one `scale` with `region.size * scale == rect.size` at
every progress. `ExpansionFlightClip` (an `Animatable` `Shape`, so it is
render-time — no lesson-11 layout loop) clips to `region`, and
`ExpansionFlightEffect` maps it onto `rect`. Order is load-bearing, same as
Rev 7: `cardLayer → ExpansionCrossfadeCut → .clipShape → .modifier(effect)`.
`ExpansionFlightGeometryTests` pins the three invariants (starts as the tile's
center square, ends as the whole content, uniform scale throughout).

**The card is the editor's own player.** "Play back to the first frame during
the transition" needs video frames in the card, not a still. Rather than a
second player that has to be kept in lockstep, `ClipExpansionContainer` now
owns the `ClipEditorViewModel` (`@StateObject`) and hands it to
`ClipEditorView(viewModel:)`; the card renders `ClipEditorVideoSurface` — the
same `AVPlayer` through a second `AVPlayerLayer`, with the same
crop-adjustment transform the editor's preview applies (extracted from
`fullFramePreview`, without the preference reporter). Two layers on one player
both display frames; confirmed on the simulator by the grey-level readings
below. Whatever frame the player is on, both layers show it in the same place,
so the cut is invisible by construction.

**Open sequence.** The tile is an autoplaying loop, so "the thumbnail frame" is
the loop's *current* frame, not the midpoint poster: `ClipCardView` pauses its
loop first, then reads `player.currentTime()` and passes it as `sourceTime`
(midpoint when there is no loop — Reduce Motion / autoplay off). The container
calls `viewModel.holdPlayback(at: sourceTime)`: attaches the item, pauses,
seeks exactly there, and keeps `prepare()` from starting the loop. The flight
starts only once that seek has completed *and* the card's `AVPlayerLayer`
reports `isReadyForDisplay` (`BareVideoPlayerView.onReadyForDisplay`), bounded
by a 300ms timeout — until then the tile stays visible and the card is
transparent over it, so nothing is seen; `onFlightStarted` is what hides the
tile (`ClipListView.hiddenItemID`), not presentation. The flight then scrubs
`sourceTime → window.startTime` and `releasePlayback()` starts the editor's
loop from exactly where the card left off.

**Close sequence.** `beginPresenterScrub()` pauses and reports the editor's
current frame; the flight scrubs it to `landingTime` — `sourceTime` when the
clip is unchanged (the tile's loop resumes from where it paused, so that is
what it will show), else the new window's midpoint (the tile rebuilds and
shows its new poster). The periodic observer's loop-back is suppressed
meanwhile (`isPresenterScrubbing`, same role as `isTrimming`), or a scrub
approaching the window's end would bounce. An interactive drag seeks
proportionally on every touch-move; a cancelled one scrubs back and resumes
only if `isPlaying`. `dismiss()` waits for `flightDuration + 0.05` *and* the
scrub's final seek.

**Home.** Same duration and the same uncropping geometry (`focus` = the frame's
center square, since `ThumbnailLoader` aspect-fills tile images). The card
stacks the square tile thumbnail at the center square, the cached full-frame
poster where there is one, and `ProcessingView`'s live player once reported
through the new `ProcessingPlayerPreferenceKey`; the close pauses that player
and scrubs it to 0 (the poster frame). Home's open side was already
frame-continuous (the poster is the first frame and the destination autoplays
from it) and the card now shows the live player too, so there was no Home
counterpart of request 4 to fix.

**Verification — reading the video frame off the recording.** The harness
movie (`-screenshotClipListMedia`) is `memset(base, frame % 255)`: every pixel
of frame *N* has grey level ≈ *N* (±3 after the H.264 round trip), so a
`-vsync 0` frame dump gives the video time a card is showing per recorded
frame. Back-button close, after: the card's grey went 55 → 53 → 51 → 47 → 42 →
39 → 38 while shrinking (the editor had been at 55; the tile's frame is the
1.25s midpoint, ≈38), with no flash frame; the first frame after the tap is
already the card. Open: 40 → 35 → 31 → 28 → 24 → 18 → 16 → 13 over 8 recorded
frames (≈0.33s), the card starting on the tile's own frame and the editor then
playing on from 13 (= 0.5s, the clip's first frame). The scrub timing log
(temporary `NSLog`, removed) showed ~45 exact seeks per 350ms flight on this
tiny movie, each ~1–3ms. Duration, as Rev 7 measures it: 8 recorded frames at
the recorder's ~24–26fps ≈ 0.33–0.35s for both open and close. The flash:
compare the pre-fix dump's single shrunk-editor frame to the post-fix dump,
where the frame after the tap is the full-size card.

Two limits of this run, recorded so nobody re-derives them: the harness
tiles' loops never render on this simulator — the loop builds, then CoreMedia
fails the video composition (`-19230`), so the tile shows its poster and the
`sourceTime`-from-loop path could only be checked by reading the code, not a
frame. And `simctl io recordVideo` often emits no frames for the last ~1s of a
swipe-dismiss run, so the recording alone can't show the dismiss; an
end-of-test `XCUIScreen.main.screenshot()` saved to `/tmp` does, and it showed
the grid with the tile's trash button back every time.

## Rev 9: chrome fades in over the card, Home stops flickering, the list pops sideways

*2026-10-05.* Six requests: no flicker of Home at the start of the open; the
destination's controls to cross-fade *during* the flight instead of appearing
at its end; a faster flight; the editor's whole area above the video to accept
the dismiss drag; and the clip list's back button to pop sideways rather than
shrink.

**The Home flicker, reproduced before anything changed** (a `-vsync 0` dump of
a tile tap, plus timestamped `NSLog`s at the tap, the cover's first body, its
`onAppear` and the resolve landing): three separate things happened in the
~100ms between the tap and the card's first frame, and un-happened ~80ms into
the flight.

1. `presentSlot` hid the tapped tile on the same render it set the slot, but
   UIKit took ~70–100ms to actually present the cover — an empty black slot in
   the grid for those frames, with no card yet to stand in. Fixed the way
   `ClipListView` already did it: the container's `onFlightStarted` (called from
   its `onAppear`) is what sets `HomeView.hidesSourceTile`, not the slot.
2. `viewModel.select` set `resolution`, which `.disabled`-ed every grid tile —
   and a disabled `.plain` button dims its label, so the whole grid went to
   ~53% brightness — and raised `ResolutionBanner` at the bottom. A local video
   resolved ~170ms later, mid-flight, snapping both back while the scrim was
   still thin. `VideoGalleryView.isCovered` now skips both while a slot is
   presented (the cover blocks input anyway, and its own resolving state shows
   the same progress); the double-tap guard the disabling provided moved to
   `onTileTapped` (`guard presentationSlot == nil`).
3. `ResolvingDestination`'s progress box, once chrome became visible mid-flight
   (below), would have faded in and then been replaced by `ProcessingView`'s
   controls a few frames later. It now lags its appearance by 0.4s, the way
   `ProcessingView.browsingOverlayDelay` does.

**Chrome cross-fades: the destination moves above the card.** Through Rev 8 the
destination sat *under* the card, hidden by a hard cut until `progress ≈ 1`, so
everything it drew — including chrome that overlaps the video (the editor's
crop surround, marker rectangle and playback pill; Processing's chevron and
bottom controls over a portrait video's letterbox rect) — appeared whole on the
cut frame. Fading the destination in under the card would have left exactly
that overlapping chrome popping. So the destination is now the *top* layer, at
a plain `.opacity(progress)` (which `.opacity` interpolates on its own across
the flight, no `Animatable` needed), with two things excepted:

- Its own backdrop and video surface, which the card is already drawing in
  their place, stay hidden behind `expansionVideoSurface()` until the card has
  landed: `ProcessingView`'s `swipeBackdrop` and `videoStage`'s black-plus-
  poster-plus-player stack, `ResolvingDestination`'s black-plus-thumbnail,
  `ClipEditorView`'s `ClipEditorVideoSurface`, and — the one destination with
  no backdrop of its own — a `systemBackground` fill behind the camera-case
  `ClipListView`.
- The navigation container itself. A `NavigationStack` is opaque (confirmed in
  a throwaway host app: a red fill behind one is invisible), so at
  `.opacity(progress)` its system background would have dimmed the card for the
  whole flight. `expansionTransparentNavigationContainer()` applies
  `containerBackground(.clear, for: .navigation)` (iOS 18 — confirmed in the
  same probe to make the stack see-through); the container's scrim is the
  backdrop instead. Pre-18, `destinationChromeCrossfades` is `false` and both
  containers keep the destination *under* the card behind the same landed flag,
  i.e. Rev 8's hard cut without the fade.

Because the content's cut now lives inside the destination, its
`.transaction { $0.animation = nil }` is gone from above the destination —
which had been suppressing every animation inside `ProcessingView` (the browse
slide and spring-back) and `ClipEditorView` since Rev 4.

**Why the cut is a flag, not the live `progress`.** The first version handed
the destination an `expansionProgress` environment value and cut its video
surface with `ExpansionCrossfadeCut` keyed on it — the same `Animatable`
mechanism as the card's own cut. A per-frame `NSLog` inside the cut (the
lesson-14 check) showed it interpolating perfectly on the *close* (the inner
cuts crossed the threshold on the same frame as the card's) and not at all on
the *open*: the first value the destination's cut ever saw was `1.0`. An
`Animatable` only interpolates for a view that existed when the animation
started; `ResolvingDestination` first renders a frame after `onAppear`'s
`withAnimation`, and `ProcessingView` replaces it mid-flight when the resolve
lands — both read the *target* and showed their backdrop at `.opacity(progress)`
over the card. So the containers keep a `hasLanded: Bool` instead, written only
through `setLanded(_:)` under `Transaction.disablesAnimations`: `true` from the
open flight's completion (`ExpansionFlightGeometry.animateFlight`, which uses
`withAnimation(_:completionCriteria:_:completion:)` with `.logicallyComplete`
on iOS 17+, and waits `flightDuration + 0.05` before that — late is invisible,
the card rests on the destination showing the same player; early would be a
size pop), `false` on `close()`'s first frame and on every interactive
touch-move, `true` again when a cancelled drag's snap-back completes (unless a
new drag or a close began meanwhile). The card's `.opacity(hasLanded ? 0 : 1)`
and the destination's `expansionHasLanded` read the same flag in the same
update, so the swap is one atomic frame; a view mounting mid-flight reads
`false` and simply stays hidden. `ExpansionCrossfadeCut` and the
`crossfadeThreshold` are gone with it, and hit-testing (`allowsHitTesting`) is
keyed on the flag too.

**250ms.** One constant, `ExpansionFlightGeometry.flightDuration`, shared by
both containers; the dismiss delay still derives from it.

**The editor's dismiss band.** The area above the video that ignored the drag
was the navigation bar: the bar is the stack's own view laid over the screen,
so a drag starting in its band never reached the gesture planted behind the
editor's content — the same reason `ProcessingView` has no bar. `ClipEditorView`
now hides its bar and draws `topRow` as content (a `ScrimIconButton` chevron,
the title, a glass/bordered Delete), and its gesture layer `ignoresSafeArea()`
so the status-bar band counts too. A visible change the request implied rather
than asked for. The UI tests that waited on `navigationBars["Edit clip"]` wait
on `staticTexts["clip-editor-title"]` instead.

**The list pops sideways.** `HomeExpansionCloseHandlers.onRequestSlideClose`
→ `HomeExpansionContainer.slideClose()`: `progress` stays at `1`, a separate
`slideProgress` carries the whole `ZStack` (scrim, card, destination) a screen
width to the trailing edge over 0.3s, `onSlideOutStarted` reveals the hidden
tile as the grid comes back into view, then the same two-layer-suppressed
`dismiss()`. Wired as `ProcessingView`'s `popToRoot` (which only its pushed
clip list receives) and as the camera-case `ClipListView`'s; Processing's own
chevron and `ResolvingDestination`'s cancel still fly back into the tile.

**Verification**, all against the real tap flows through the scratch driver,
`-vsync 0` dumps, and the landed-flag/lifecycle `NSLog`s (removed):

- *Flicker:* every frame from the last pre-tap one to the first flight frame
  has the grid at full brightness, no banner, and the tapped tile in place
  (`tile0 (247,174,0)` throughout; the slot is never black before the card).
  The flag log shows `false` for both the placeholder's and Processing's
  mid-flight mount, `true` ~270ms after `onAppear`, `false` on close.
- *Cross-fade:* Home open — `Analyze clips` region rises `16 → 59 → 103 →
  133 → 139` (blue channel) over consecutive frames while the scrim goes
  `247 → 165 → 81 → 19 → 8` on an uncovered tile; Home close — the chevron,
  scrub bar and button fade out over 354–356 while the card shrinks. Editor
  open — the top row, crop marker, pill and trim slider fade in over 331–335
  as the card grows; the last open frame's preview reads grey `13` = the
  clip's first frame, so the scrub still lands where Rev 8 left it.
- *Band drag:* a 25%-screen downward drag starting on the video leaves the
  editor up (the crop drag takes it); one starting at normalized `y = 0.10`
  (the title row) dismisses to the clip list. Both asserted by the driver.
- *Slide:* 425–431 show the Clips page moving right with the grid uncovered
  from the left, no shrink; the end-of-test screenshot is the grid with the
  tile back.
- *Cancelled drag that never moved:* an upward-only drag on the editor's
  empty area, then the back button — the clip list returns (the synchronous
  `setLanded(true)` branch in `cancelDrag`; no animation runs, so no completion
  would have).
- *A recorder artifact, not a bug:* two of seven recordings showed frames
  alternating, strictly every other frame and pixel-identical, between the
  settled cover and the Home grid *with the tapped tile visible* — once for
  ~1s after a close had landed, once while Processing sat idle. The grid with
  that tile visible can't be the app's state under a presented cover, and 60
  consecutive `XCUIScreen.main.screenshot()` samples of the settled
  Processing view (two runs) all read the video's pixels at center, never the
  grid's. `simctl io recordVideo` interleaving two sources; lesson 19.

## Rev 10: the cross-fade has its own curve, with a movable inflection point

*2026-10-06/07.* Request: keep the slide exactly as it is; during the
cross-fade, disappearing components should ease out and appearing components
ease in — refined over several rounds to: each fade spans the whole flight,
and its *inflection point* (where it crosses half, its steepest moment) is
set per layer — first specified as 60% of the travel for the disappearing
layer and 40% for the appearing one, then tuned by hand (see "What shipped").

**What shipped.** `ExpansionFlightGeometry.crossfadeOpacity(progress:
inflection:steepness:)` is an ease-in-out of the card's *travel* (`progress`, `0` at the
tile, `1` open) whose halves meet at `inflection` instead of the middle: a
power-`steepness` ease-in from `0` to `0.5` over `[0, inflection]`, the
matching ease-out from `0.5` to `1` over `[inflection, 1]`. The steepness is
per layer (`chromeCrossfadeSteepness`, `scrimCrossfadeSteepness`), since white
chrome over the card is seen long before a dark scrim over bright tiles is;
at `3` the system's near-quadratic curves would already show a layer clearly
where this still holds it within a few percent of its start, and `4` holds it
longer. Each container applies it to its
two layers through `ExpansionCrossfade`, an `Animatable` modifier keyed on
`progress` — the Rev 4 lesson: a plain `.opacity(f(progress))` in `body` only
ever sees the two endpoints and would interpolate linearly between them; an
`Animatable` gets every interpolated value and applies the curve per frame.
Under a drag `progress` is written directly and the same curve applies, so
the swipe and the button share the cross-fade by construction (`UIUX.md`,
"A gesture and its button play one animation").

**Why one inflection per layer serves both directions.** The roles swap with
the direction and the two readings land on the same point. Opening, the
chrome is the layer *appearing* — half in at 40% of the way out, i.e.
`progress = 0.4`; closing, it is the layer *disappearing* — half gone at 60%
of the way back, also `progress = 0.4`. The scrim is the mirror: the
presenter under it disappears on an open (half covered at 60% out) and
reappears on a close (half back at 40% back), `progress = 0.6` either way. So one
inflection per layer, no per-direction state, no separate animated values.
The values were then tuned by hand in Xcode against the real flights: the
chrome's inflection moved from `0.4` to `0.99` with steepness `4` — the
picture does the transition and the controls arrive as it lands — and the
scrim stayed at `0.6` with steepness `3`. The measurements below are from the
`0.4` / `0.6` build; they verify the mechanism, which the constants only
parameterise.

**How it got here**, since each step was measured and the measurements are
what ruled the earlier shapes out:

1. *Full-length `.easeIn`/`.easeOut` on two extra animated states* (chrome
   and scrim), the fade's direction picking the curve. Measured exactly as
   specified in opacity terms — clip open chrome 0.17 → 0.30 → 0.47 → 0.62
   against card 0.22 → 0.44 → 0.67 → 0.86 and scrim 0.49 → 0.65 → 0.79 →
   0.90 — and seen as the old layer lingering and the new one arriving early.
   Opacity isn't brightness: on black, white chrome at 30% already looks
   present and a tile at 35% still looks lit.
2. *Same, on cubic Bézier curves* (0.125 at the midpoint instead of 0.315):
   chrome 0.04 → 0.13 → 0.25 → 0.56, scrim 0.63 → 0.85 → 0.93 → 0.99. Still
   too much overlap, too soon.
3. *The fades offset in time* — the disappearing layer over the first
   `crossfadeShare` of the flight, the appearing layer `.delay`ed into the
   last — at 0.6, then 0.3, 0.5 and 0.6 again, with the drag mapped onto the
   same windows by travel. This was a misreading of "inflection point" as the
   start/end of each fade: at 0.3 the chrome was 0 until the card was at
   86% and the list 96% covered at 6%, i.e. two near-cuts with the card alone
   in between. The request was for full-span fades whose *midpoints* move.
4. The shipped curve above.

**Verification** that doesn't depend on knowing when a frame was captured
(the recorder keeps 3–6 frames of a 250ms flight at irregular spacing — lesson
1): read the geometry and both fades off the *same* frame and compare each
fade with the curve's prediction at that frame's `progress`. Clip (the
`-screenshotClipListMedia` tap flow through the scratch driver): `p` from the
card's left edge lerped between the tile's (592px) and the editor preview's
(163px); scrim from the clip list's Save Clips button showing through (`1 −
blue/255`); chrome from the brightest pixel of the editor's Delete pill
(nothing of the list under it) over its landed value. Home (the seeded
library, second tile): `p` from the card's top edge (345px → 836px); scrim
from the untapped top-left tile; chrome from the scrub bar's track over a
tile with no blue of its own.

Measured against the curve's prediction at each frame's own `p` (chrome =
`crossfadeOpacity(p, 0.4)`, scrim = `crossfadeOpacity(p, 0.6)`), measured →
predicted:

- Clip open, `p` 0.22 / 0.43 / 0.67 / 0.86: chrome 0.11 / 0.62 / 0.91 / 0.98 →
  0.08 / 0.57 / 0.92 / 0.99; scrim 0.03 / 0.20 / 0.73 / 0.98 → 0.02 / 0.19 /
  0.72 / 0.98.
- Clip back-button close, `p` 0.93 / 0.77 / 0.55 / 0.32 / 0.13: chrome 1.00 /
  0.98 / 0.83 / 0.30 / 0.02 → 1.00 / 0.97 / 0.79 / 0.26 / 0.02; scrim 1.00 /
  0.91 / 0.40 / 0.09 / 0.01 → 1.00 / 0.91 / 0.39 / 0.07 / 0.00.
- Clip swipe, under the finger at `p` 0.79 / 0.78 and held at 0.55: chrome
  0.99 / 0.98 / 0.81 → 0.98 / 0.98 / 0.79; scrim 0.93 / 0.91 / 0.40 → 0.93 /
  0.92 / 0.39. Released, `p` 0.51 / 0.36 / 0.23: chrome 0.74 / 0.43 / 0.12 →
  0.72 / 0.36 / 0.10; scrim 0.31 / 0.12 / 0.04 → 0.30 / 0.10 / 0.02. The same
  curve the button plays, at every sampled point of the drag.
- Home open, `p` 0.41 / 0.79: scrim 0.18 / 0.94 → 0.16 / 0.93; chrome (scrub
  track) 0.55 / 0.97 → 0.53 / 0.98. Home close, `p` 0.96 / 0.76 / 0.43: scrim
  1.00 / 0.91 / 0.21 → 1.00 / 0.91 / 0.18; chrome 0.98 at 0.76 → 0.97, and at
  0.43 the frame shows the controls at roughly half (predicted 0.56) — the
  track probe can't read it there, since the bar's played/unplayed split has
  moved since the landed reference and the tab bar's highlight sits under the
  button.

Also on the record from the earlier rounds: an idle editor sampled 30 times
over ~3s with `XCUIScreen.main.screenshot()` read Save Clips-blue 0 on all — the
"nearly closed" frames the recorder emitted while the app idled, alternating
with a list frame that had no card and a hidden slot, were lesson 19's
interleave, not the app; the recorder can also emit a flight's frames *late*
(the clip open's frames once showed up after the close). The looping preview
shifts the frame's overall brightness while the editor idles (the harness
movie's grey level is its frame index), so a whole-screen brightness change
there is not a transition.

## Rev 11: the swipe commits the edit, and every header sits where the bar's items do

*2026-10-07.* Two reports: an edit made in the editor was lost when the
editor was swiped closed rather than closed with the chevron, and the
editor's header sat at a different height than the clip list's.

**The swipe commits.** `ClipExpansionContainer.dismissDragGesture`'s
committing release called `close()` alone; the editor's back chevron calls
`onCommit(viewModel.result)` and *then* its close. The draft lives in the
editor's view state until it is left, and nothing else delivers it, so the
swipe path dropped it. The committing branch now commits first, exactly as
the chevron does; a cancelled drag still commits nothing. (Committing inside
`close()` instead would apply the result twice on the chevron path.)
`landingTime` already distinguished an edited landing from an unchanged one,
so the rest of the close was ready for this.

**The header band.** Rev 9's `topRow` was a plain row inside the editor's
16 pt-padded `VStack`, so on iOS 26 it sat 16 pt lower and 6 pt further in
than the clip list's bar items it cross-fades over (measured by element
frames: chevron center 97 vs 81, 38 vs 44). Processing's chevron and Camera's
corner controls had the same bare padding. All of them now go through
`ScreenHeaderBand`/`screenHeaderItemPlacement()`
(`Turnip/DesignSystem/ScreenHeaderBand.swift`), which encodes the system
inline bar's measured geometry: a 54 pt band on iOS 26 (44 before), items
centered in the band's top 44 pt, a 20 pt side inset on iOS 26 (16 before),
and — pre-26 only — the bar hanging from the status bar's bottom edge, 5 pt
above the top safe-area inset on Dynamic Island devices (read from
`statusBarManager`; on iOS 26 the bar starts at the inset itself). Home's
pre-26 overlay uses the same placement without that overhang, since it sits
beside the wordmark header rather than a bar. The clip list's chevron, the
one chevron the system drew, was then the odd one out — iOS 26 wraps a toolbar
item in a 48×36 glass pill — so its `ToolbarItem` now holds the same
`ScrimIconButton` circle with the bar's own background hidden under it
(`sharedBackgroundVisibility(.hidden)`); `BackChevronButton` is gone.

**Verification**, by element frames through the scratch driver on an
iPhone 15 (iOS 26.2, and a throwaway iOS 18.5 simulator for the pre-26
branch), not screenshots: list and editor chevrons both at `x 20, y 59,
44×44` and titles at center `y 81` on 26.2; editor/Processing/Camera at
center 76 against the bar's 75.67 on 18.5, Home's pre-26 gear at 81 level
with the wordmark. Trim-then-swipe: the tile caption went 1.5s → 2.8s on the
fixed build, unchanged on the old one. Both are regression tests in
`ExpansionTransitionVerificationTests` (`testClipEditorHeaderLinesUpWithTheClipListsBar`,
`testSwipeToDismissCommitsTheEdit`); the swipe test starts its drag from the
title element so it doesn't depend on the device's status-bar height.

## Rev 12: a fixed crop marker, the video under the whole screen

*2026-10-07.* Two requests on the editor: the crop boundary should be the
same size at the same place no matter the clip, with the video moving and
scaling under it to show what the crop will be; and the video should cover
the whole screen rather than a center rectangle that cut off whatever a
pinch or rotation pushed outside it.

**The stage.** `ClipEditorView` is now a `ZStack`: an edge-to-edge stage
(the video surface, the dimmed surround with a hole at the marker, the
marker's outline, the crop gesture over the stage band only) under the
chrome column (header row, a measuring placeholder where the stage band is,
reset button, trim slider). The marker is `ClipEditorStage.markerRect`: the
largest rect of the export's aspect ratio centered in that band, which
depends only on the device's layout. The video is `ClipEditorStage.videoPlacement`:
one uniform scale that maps the clip's crop rect onto the marker, the crop's
center on the marker's center, the rest of the frame laid out around it —
routinely wider than the screen on a landscape source — and never clipped.
For that mapping to be uniform the crop rect has to have the marker's
aspect ratio, so `CropRectCalculator.fittedInFrame` no longer clamps an
over-long axis to the frame: it centers the rect on the frame and lets it
overhang equally at both ends, and the export, the tile thumbnail
(`ClipThumbnailLoader` now fills black first) and the tile loop all render
black there. The editor's marker is therefore exactly what export cuts to.

**The card.** With the surface laid out full screen in the editor, the card
is laid out full screen too, from the same placement function and the same
marker, so at `progress == 1` it is pixel-identical to the editor's surface
for any adjustment — a per-clip destination rect would have clipped a
zoomed or rotated picture at the card's edge and let it pop in at the cut.
The measured value is now the marker (`ClipEditorCropMarkerFramePreferenceKey`),
which is the window's starting rect; it needs no media, so it is reported
on the editor's first layout pass, before the flight (which waits on the
player) can start. `ExpansionFlightGeometry` is unchanged.

**One mistake worth recording.** The stage band's own `PreferenceKey` first
reduced with `value = nextValue()`; the placeholder's siblings in the chrome
column contribute the zero default, and the last of them won, so the marker
stayed empty and the stage rendered black. Every frame-reporting key in this
codebase keeps the latest non-zero value for that reason.

**Verification.** `-screenshotClipEditor` screenshots on an iPhone 15
(iOS 26.2): the marker at `(48, 124, 296×526)` with the video filling it
and the dimmed frame running under the header and the controls. A scratch
XCUITest driver dragged, pinched and rotated the stage: the marker's
element frame was identical before and after each gesture, the video's
edge moved under it, and Reset restored it. A recording of the open flight
over `-screenshotClipListMedia` showed the tile growing into the marker
with the chrome fading in and no size or frame pop at the landing cut.
`testClipExpansionCardLandsOnTheEditorsCropMarker` (replacing the
preview-frame convergence test) checks the card's settled frame against the
marker element; the header-alignment and swipe-commit tests still pass.

## Rev 13: the frosted surround, and the card is the crop again

*2026-10-08.* The editor's surround outside the marker is now `.thinMaterial`
with a hole at the marker (UIUX.md Rev 12), instead of a flat 55% black. A
material only blurs what it sits over when it is drawn at full opacity: under
the chrome cross-fade of either flight, and under Delete's fade-out of the
whole container, SwiftUI renders it as a flat tint. Recorded on the "Turnip
Shots 17PM" simulator with real footage, that flattened tint let the frame
outside the marker show *sharp* for the whole of Delete's 220ms fade — a cut
from frosted to sharp on the fade's first frame — and, during the open
flight, the surround read as near-black until the blur popped in at landing.
A flat stand-in for the material while not landed (tried first) kept the
tone but still showed the frame outside the marker sharp under it, since the
full-screen card was there to show.

The design that holds: **the flight shows the crop and nothing else.** The
card is laid out at the marker again (`destination` is the measured marker,
`focus` its own bounds), so the window uncrops from the tile's center square
to the marker, not to the whole screen; the card's `ClipEditorVideoSurface`
still lays the whole frame out around the marker, past the card's bounds,
and the window never reaches past them. `ClipEditorView` draws the frosted
surround only while `expansionHasLanded`, so on landing the editor's
edge-to-edge surface, the frosted frame around the crop and the marker's
white outline appear together — the "uncrop"; the outline is gated with the
frost rather than cross-faded with the chrome, so on a close it doesn't
outlive the frost around the bare crop — and on any close (including Delete, whose `closeForDelete()`
now calls `setLanded(false)` like `close()`) they go in the first frame and
the crop alone flies or fades. Rev 12's "the card must end as the full frame"
was about a dim surround that showed the frame sharp; a frosted surround
appearing with the landing is the reveal, not a pop.

One more thing Delete's fade needed: `cardLayer` is now a
`.compositingGroup()` under its opacity. With the fade applied to the live
player view directly, the video spilled past `ExpansionFlightClip` and showed
the frame outside the marker sharp for the whole fade — reproduced with the
fade on the whole stack and with it on each layer separately; rendering the
card as one group first is what keeps the clip. The UI test
`testClipExpansionCardLandsOnTheEditorsCropMarker` already asserted the
card's settled frame is the marker's; it still passes. Verified by re-recording the open flight, the back
flight and the Delete fade on real footage: the crop alone moves, the
frosted frame appears with the landing and leaves with the first frame of a
close, and no frame shows the surround sharp.

## Gesture ownership: why the dismiss drag can't live behind the content

A `NavigationStack` is backed by a real `UIViewController`. A SwiftUI
`DragGesture` attached to a sibling view *behind* one in a `ZStack` never
fires for touches landing inside the `NavigationStack`'s bounds — including
its own empty space — because UIKit's hit-testing resolves those touches to
the hosting view controller itself, not through to a SwiftUI sibling behind
it. (Confirmed empirically, not assumed: an initial version of
`ClipExpansionContainer` attached its dismiss drag to the scrim behind the
`NavigationStack` and it never fired at all, from a driver test exercising
real touch dispatch.)

The fix in both features: the dismiss gesture is planted *inside* the same
content the `NavigationStack` hosts, on the destination's own views —

- `ClipEditorView` takes a `dismissGesture: AnyGesture<DragGesture.Value>?`
  and attaches it as a `.background` behind its own root `ZStack`, on a layer
  that covers only the band above the crop marker — the top row and the
  status-bar band over it, extended into the safe area (its height is the
  marker's `minY` less the layer's own top). The top row's buttons keep their
  own taps over it; the marker's band belongs to the crop gesture, and the
  controls below the marker (the Auto buttons, the trim slider, their
  margins) never dismiss, so a drag that slips off one goes nowhere. The
  editor has no navigation bar — the bar would sit over that layer and
  swallow a drag starting in its band — and draws its own top row as content
  instead.
- `ProcessingView` already *had* its own vertical swipe-to-dismiss (it just
  used to commit unilaterally on release and call `dismiss()` directly). It
  now reports that gesture's live state to the presenter instead of deciding
  for itself — see `ProcessingView.DismissGestureHooks` (`onChanged`,
  `onEnded`, `onCancelled`) — and the container owns the commit/cancel
  decision and the resulting flight. This also means the Photos-exact
  "almost any downward release commits" rule lives in exactly one place
  (`ExpansionFlightGeometry.dismissCommits`, applied by
  `HomeExpansionContainer.closeHandlers` and `ClipExpansionContainer`'s drag),
  not duplicated into `ProcessingView`.

For `ProcessingView` specifically, the dismiss and the browse share one
gesture: a single `.simultaneousGesture(videoSwipeGesture)` covers the whole
page, video included. The axis is fixed per drag by its first movement
(`dragAxis`): a drag that starts mostly downward dismisses, any other
browses. The scrub bar's track wins its own drags — this gesture defers to
it through `isScrubbingVideo` — and both the dismiss and the browse are off
while an analysis runs.

## Stable presentation identity (`fullScreenCover(item:)`)

`HomeExpansionContainer` is presented via `.fullScreenCover(item:
$presentationSlot)`. A naive version of this bound the cover directly to the
*video* being shown — but `VideoLibraryViewModel.browse(to:)` (swipe-to-
browse-neighbors) replaces `path`'s top element with a *different* video
while the cover is already up, which changes that item's identity. Verified
in an isolated scratch harness before committing to the architecture:
`fullScreenCover(item:)` tears the presentation down and re-presents with
the system's own slide when the bound item's `id` changes, even with no
explicit dismiss/present call anywhere — exactly the same unwanted motion
this whole feature exists to replace.

The fix: `presentationSlot: HomePresentationSlot?` is a *stable* identity —
its own `id` never changes for the life of one open→close cycle, regardless
of which video is currently showing inside it. The content closure
(`destinationContent`) reads `viewModel.path.last` live and reactively on
every render instead of capturing a value at presentation time, so a browse
mid-presentation updates the content in place without the cover's own
identity ever changing.

## Suppressing the system's own presentation animation

Even with a stable slot, the *first* transition from nil → non-nil is a real
modal presentation, and `fullScreenCover` plays the system's default
slide-up-from-bottom for it unless told not to. Two layers of suppression
turned out to both be necessary — confirmed by adding temporary colored
debug borders to every layer (scrim, card, destination content,
`ProcessingView`'s own root) and inspecting a screen recording at its true
native frame rate (not a downsampled extraction — see "A verification note"
below):

1. `Transaction.disablesAnimations = true` around the state change that sets
   `presentationSlot`. This suppresses SwiftUI's *own* animation system, but
   — discovered only by direct frame inspection, after it visibly failed to
   fix the reported bug on its own — does not reliably reach the UIKit
   `present(animated:)` call underneath `fullScreenCover`.
2. `UIView.setAnimationsEnabled(false)` around the same state change,
   re-enabled on the next run-loop turn (`DispatchQueue.main.async`) after
   the presentation has already been issued. This reaches UIKit's own
   CoreAnimation-level animation state directly. Both wrapped together in
   `HomeView.presentSlot(_:)`, the single call site both the tile-tap path
   and the camera-capture fallback path (`.onChange(of:
   viewModel.path.isEmpty)`) go through.

`ClipExpansionContainer`'s equivalent call site (`ClipListView`'s tile tap,
setting `expandTarget`, now `ClipListView.presentExpandTarget(_:)`) was
originally believed to only need step 1 — the `disablesAnimations`
transaction alone looked sufficient when that conclusion was reached, but it
was never actually isolated with the rigorous frame-by-frame method (see "A
verification note"), just a reasonable-looking screen recording at the
time. It turned out not to be sufficient: reported separately as a brief
shrink-then-expand flash on the tile right at tap time, which is exactly
what a residual, unsuppressed `present(animated:)` would produce — step 2
was missing here the whole time. Both steps now wrap `expandTarget`'s
assignment the same way `presentSlot` wraps `presentationSlot`'s. The
view-controller-hierarchy-depth theory above (why Home seemed to need more
suppression than Clip List) was never a real asymmetry — both needed it,
one bug just went unnoticed for longer.

Both steps live in one place, `SystemTransition.present`
(`Turnip/DesignSystem/SystemTransition.swift`), which `presentSlot(_:)` and
`presentExpandTarget(_:)` both call.

## Suppressing the system's own dismissal animation

Both containers' `close()` (and `ClipExpansionContainer.closeForDelete()`)
need the *same* two-layer suppression as the open side, around the
`dismiss()` call that ends the flight — `Transaction.disablesAnimations`
alone leaves a residual slide visible, for the identical reason it did on
the present side: it suppresses SwiftUI's own animation system but not the
UIKit `dismiss(animated:)` call underneath `fullScreenCover`. Left
unsuppressed, the already-landed card (by this point sized and positioned to
exactly match the tile, mid-screen) visibly slides downward and off-screen,
dragged along by the system's own default cover-dismissal transition.

The dismiss side needed a **longer `UIView.setAnimationsEnabled(false)` hold
than the present side does**, discovered only after an initial fix — mirroring
`presentSlot`'s "re-enable on the very next run-loop turn" — shipped, was
reported working, and then was reported still broken by the person who filed
the original bug. Re-verifying with full-native-frame screen recordings
(see "A verification note" below) showed the slide still playing out over
several hundred more milliseconds even with that fix in place: UIKit
schedules `dismiss(animated:)`'s transition later than it schedules
`present(animated:)`'s, so re-enabling animations on the next run-loop turn
re-enables them before the dismiss transition has actually been scheduled.
Holding `setAnimationsEnabled(false)` for 0.5s after calling `dismiss()`
instead reliably suppressed it, confirmed across multiple independent
recordings; the shorter, `presentSlot`-equivalent delay did not, in every
recording it was tested against. `SystemTransition.dismiss` holds it for
`SystemTransition.dismissHold` (0.5s); both containers dismiss through it.

## Mounting the destination's `NavigationStack` eagerly

`HomeView`'s destination content used to create its `NavigationStack` only
once `viewModel.path.last` resolved to an actual video (inside the `if let
video = … else { ResolvingDestination }` branch). A `NavigationStack` is a
real `UINavigationController`; creating one for the first time *mid-
presentation* — once the tapped video's async PhotoKit/iCloud resolve lands,
which can be anywhere from instant to several seconds after the tap — gave
it a first UIKit layout pass (hiding its nav bar, settling its safe area)
that happened on UIKit's own schedule and animated into place instead of
snapping, independent of and on top of the container's own `progress`-driven
flight. From the outside this read as the destination page separately
sliding into place after the card had already landed.

The fix: the `NavigationStack` is now created once, immediately, wrapping
*both* branches (`ResolvingDestination` and the real destination) —
`HomeView.destinationContent(identifier:handlers:)`. Only the root content
inside it swaps once the video resolves, which is an ordinary SwiftUI
content change inside an already-settled controller rather than the
controller's own first mount. Mounting it at `progress ≈ 0` — while the
content layer is still near-invisible over the card (the chrome
cross-fade's 0.99 inflection) — also means any residual first-layout cost is itself covered.

## The grid's scroll-to-current-tile effect must skip the initial resolve

`VideoGalleryView`'s grid scrolls to re-center whichever tile is current
(`anchor: .center`) so that a close after browsing to a neighbor lands on a
tile that's actually on screen — matching the real Photos app, which
scrolls its own grid behind the covered one-up during paging (see
"Research" above). The first version of this fired on *every* change to
`viewModel.path.last?.assetIdentifier`, including the very first tap's own
resolve landing. Since the tapped tile is by definition already on screen
(that's how it got tapped), this was both unnecessary and highly visible: a
full `anchor: .center` recenter of a top-of-grid tile scrolls the grid by
close to half a screen height, and because it fired the instant resolution
completed — which for a local video can be faster than the card has grown
enough to cover it — the recenter was often visible through the still-thin
early scrim. On close, the grid was left at that shifted position, which
read as a second, unrelated slide happening *after* the card had already
landed.

The fix (`VideoGalleryView.lastScrolledIdentifier`): the effect now tracks
the previously-scrolled-to identifier and only recenters when the current
video changes to a genuinely *different* one than last time — the initial
nil → first-tile transition is skipped.

## System-cancelled drags need `@GestureState`, not a plain flag

Both containers' dismiss-drag state must reset reliably even when a drag is
cancelled by the system (an incoming call, Control Center, or any gesture
that simply never reaches `onEnded`). A plain `@State` "is dragging" flag set
in `onChanged` and cleared in `onEnded` stays stuck `true` forever in that
case — and since the destination's `.allowsHitTesting` is gated on
`hasLanded`, which a drag clears and only a completed flight back to open
sets again, a stuck flag leaves the whole screen's controls, including the back
button, permanently disabled with no way out.

Both containers use `@GestureState` instead (`dragTranslation` in
`ClipExpansionContainer`; the equivalent lives in `ProcessingView`'s own
gesture, reported out via `DismissGestureHooks.onCancelled`), which SwiftUI
resets to its initial value whenever a gesture ends for *any* reason,
cancellation included — paired with an `onChange` that fires the same
cancel flight `onEnded` would have, but only if `onEnded` didn't already run
(tracked via a one-shot `didHandleDragEnd`/equivalent flag, to avoid
double-firing on an ordinary release).

## A verification note

Several fixes in this feature's history looked correct on paper and were
"confirmed" against screen recordings sampled at 25–30fps, only for the
underlying bug to still reproduce. Two lessons from that, worth preserving
for the next person debugging a transition in this codebase:

1. **`simctl io recordVideo`'s declared frame rate is not its real one.**
   The container metadata claims ~60fps; actual frame delivery is far
   sparser during idle periods (closer to the ~20fps a previous session's
   own notes recorded) and bursts to its true native rate only while the
   screen is actively changing. Extracting at a fixed 25–30fps with
   `ffmpeg -vf fps=N` silently *drops* real frames rather than sampling
   evenly, and a brief one-or-two-frame glitch can fall entirely between
   sample points. Use `-fps_mode passthrough` (or `-vsync 0` on older
   ffmpeg) to extract every frame actually encoded, with no rate
   conversion, and compare file sizes across the sequence to locate where
   content actually changed before eyeballing it.
2. **Temporary debug borders are worth adding immediately, not as a last
   resort.** Once each layer (scrim, card, destination content, the
   destination's own root view) had its own distinct `.border()` color, a
   single frame made the actual bug — the destination's content layer
   provably not covering the full screen for its first few frames —
   obvious, where several rounds of reasoning about plausible SwiftUI/UIKit
   mechanisms without this had each produced a fix that didn't address the
   real cause.

Both of these cost real time to learn; a `scratch-xcuitest-driver-for-real-
app`-style memory note captures the reusable parts of the recipe (recording
+ `ffprobe`/`ffmpeg` extraction commands) for the next session.

3. **A burst of `XCUIScreen.main.screenshot()` calls with no `sleep` between
   them is still not dense enough.** Fixing the dismiss-animation issue above
   (see "Suppressing the system's own dismissal animation") was first
   "verified" two different undersampled ways that both looked clean and
   were both wrong — the bug was still fully present, as the person who
   filed it confirmed after the fix shipped:
   - A back-to-back screenshot burst still only sampled every ~85–115ms,
     since each `screenshot()` call itself takes roughly that long. A
     sub-200ms residual slide can land entirely between two samples; "no
     throttling sleep" bounds how fast you're *asking*, not how fast the API
     actually *answers*.
   - Inline `NSLog`/`os_log` added to the suspect code path (logging
     `progress` and the computed rect on every SwiftUI body re-render) is
     *also* unreliable for a fast repeating glitch: the unified logging
     system throttles/dedupes rapid near-identical messages, so a burst of
     ~20 renders across 400ms showed up as only 2–3 lines in `simctl spawn
     log stream`, with everything in between silently dropped. Absence of an
     expected log line is not evidence that code path didn't run that way.
   - What actually worked, again: `simctl io recordVideo` plus
     `ffmpeg -vsync 0` (every native frame, no `-vf fps=` resampling — see
     lesson 1 above, which applies just as much to a "looks dense enough"
     screenshot loop as it does to a resampled recording), then classifying
     a known-color pixel at the suspect on-screen location frame-by-frame.
   - The general principle: before trusting a "looks fixed" result for a
     fast, sub-second visual glitch, check whether the verification method's
     *own* sampling interval is shorter than the suspected glitch duration.
     If it isn't, a clean result only means the method didn't happen to
     catch it this time — not that the bug is gone.

4. **Plain `print()` never reaches `simctl ... log stream`, at any
   predicate.** Unlike `NSLog`/`os_log` (lesson 3's own caveat about
   throttling still applies to those), a bare Swift `print()` writes
   straight to the process's stdout file descriptor and never enters the
   unified logging subsystem `log stream` taps — a `print()` added to debug
   Rev 2's destination math produced zero matches against every predicate
   tried, including one scoped to the exact process name, with the log
   otherwise visibly flowing. What worked: `xcrun simctl launch
   --console-pty <device> <bundle-id> <launch-args>`, which attaches to the
   app's real stdout/stderr and streams `print()` output directly — the
   same mechanism this doc's own `ScreenshotTests.addScreenshot(named:)`
   relies on when it prints a result for `xcodebuild test`'s own log to
   capture, except that capture path is the *test runner* process's stdout,
   not the *app-under-test* process's, and the two aren't interchangeable.
5. **An `Image().resizable().scaledToFill().clipped()`'s accessibility
   frame is its pre-clip, filled size — not the outer `.frame().clipped()`
   box.** Giving `cardLayer`'s `Image` an `accessibilityIdentifier` to let a
   UI test read its laid-out rect (see below) is the right idea, but if the
   source image's aspect ratio doesn't match the box it's being fit into,
   XCUITest reports the *overflowed* rendered size the image would have
   before clipping, not the visible clipped rect — a test built around a
   deliberately square synthetic thumbnail against a deliberately
   non-square destination read back a confidently wrong frame for exactly
   this reason, with no error, before the mismatch was traced to the
   thumbnail's own aspect ratio rather than to the geometry under test.
   Giving the synthetic thumbnail the same aspect ratio as the destination
   it's meant to land in sidesteps this; it isn't a bug in `cardLayer`, just
   a property of how `Image` accessibility nodes report their frame.
6. **`UIView.setAnimationsEnabled(false)` — the same call `close()` uses
   deliberately, see "Suppressing the system's own dismissal animation" —
   also blocks XCUITest's own accessibility snapshot for as long as it's in
   effect.** A UI test that samples the flying card's frame partway through
   a close, to verify it lands on the right `sourceFrame`, reliably timed
   out or hung for ~30s trying to take a snapshot during exactly the
   window `close()` holds animations disabled (the delay before `dismiss()`
   plus the 0.5s hold after it — about 0.8s: `flightDuration` plus 0.05s
   before `dismiss()`, then the 0.5s hold) — reproduced
   across a simulator reboot, so not host flakiness. There's no known
   workaround short of not sampling in that window; the close direction's
   destination correctness has to be inferred from the open direction's
   (same measured destination, same `ExpansionFlightGeometry.resolve`, no
   separate computation close performs) rather than independently screenshotted.
7. **A frame-accessible geometry regression test cannot catch a pure-opacity
   bug.** `ExpansionTransitionVerificationTests` samples the card's *settled*
   frame, well after any animation finished, so it kept passing throughout Rev
   2's own fade-that-wasn't-removed (Rev 4 above) — the geometry it checks was
   never wrong, only the opacity *during* the flight was. When the suspect
   behavior is "something is animating that shouldn't be" rather than "the
   wrong value was computed," the decisive check is counting how many times a
   value-producing function actually gets called, not reading its settled
   output: a `print()` inside the suspect computed property, captured live via
   `xcrun simctl launch --console-pty` (lesson 4's own technique — plain
   `print()`, not `log stream`), showed the pre-Rev-4 opacity function was
   called exactly twice for an entire spring-driven flight (`progress=0.0`,
   then `progress=1.0`) — conclusive proof `body` only ever saw the two
   endpoints, in a way no amount of re-reading the `progress >=
   crossfadeThreshold` line would have surfaced.
8. **Neither XCUITest's `element.frame` nor a `GeometryReader`/
   `PreferenceKey` reports Core Animation's live, mid-flight `presentation()`
   value — both report the current SwiftUI model value, settled or not.**
   (Rev 5's own investigation, above.) These tools are the right ones for
   proving a value *changed* (what this doc's other geometry tests already
   use them for), but they cannot distinguish an animated transition from an
   instant snap: polling either one on a timer during an active spring
   returns the same already-final number on every sample. Proving a snap
   needs either two adjacent frames of a recording (bordered, so the jump is
   visually unambiguous — "two consecutive captured frames show different,
   discrete states" is itself the proof, no dense in-between sampling
   required) or counting how many times the producing code actually runs
   (lesson 7's technique). A `UIViewRepresentable`-wrapped `CADisplayLink`
   probe reading `layer.presentation()?.frame` looked like a fix for this but
   wasn't trustworthy either: that view's frame is set by the SwiftUI↔UIKit
   bridge, not necessarily through the same implicit animation a native
   SwiftUI `.frame`/`.position` modifier uses.
9. **`simctl io recordVideo` drops frames specifically during the CPU-heavy
   window an animation is actually playing** — confirmed across four
   independently-structured attempts in Rev 5's investigation (a real
   `ClipListView` tap via XCUITest, a direct-mount scratch harness with no
   XCUITest process running at all, and `xcodebuild test-without-building` to
   remove compile-time load from the mix), each showing a multi-second gap in
   the recorded timeline exactly spanning the open flight. The frame
   immediately before the gap showed the stale state, the frame immediately
   after showed the fully-settled one — the simulator appears to deprioritize
   screen recording under the same render load the animation itself
   generates, so the thing being measured competes with the measurement.
   Lesson 1's "sparse during idle, bursts during real change" turned out to
   have a corollary: it can also go sparse *during* a sufficiently demanding
   change, not just between them.
10. **A hung test and a slow-but-working one look identical from the outside
    — `ps`'s CPU/state column is what tells them apart.** Rev 6's first
    `LiveFlightGeometry` attempt made an `XCTest` accessibility query time
    out after 175s; the natural read is "deadlock, something's blocked
    forever." `ps aux | grep Turnip` during the hang showed the process at
    98.5% CPU, state `R` (running), not `D`/blocked or `T`/stopped — it
    wasn't stuck, it was burning CPU continuously reconstructing a
    `NavigationStack` ~every rendered frame. That distinction changed the
    fix entirely: a real deadlock needs a different class of investigation
    (locks, semaphores, main-thread-blocking calls) than a tight CPU loop
    does (what's being recomputed, how often, how expensive is it). Don't
    assume "hung" means "blocked" without checking.
11. **An `Animatable` conformance only gets per-frame live calls where the
    primitive is actually meant to be animated at — layout modifiers inside
    an `Animatable` `ViewModifier.body(content:)` don't count.**
    `.frame`/`.position`/`.clipShape` request a *new layout*, which can
    trigger a parent layout pass that re-invokes the modifier, which
    requests another new layout — confirmed as tens of thousands of calls
    in under a minute for what should be a ~60–120 Hz, ~1.5s flight. The
    fix for the *loop* is using `GeometryEffect`, whose `effectValue(size:)`
    runs at render time against an *already-settled* layout size and returns
    a transform, with structurally no path back into another layout pass.
    (Rev 6 also called nesting order "a red herring". Rev 7 corrected that:
    order does matter, for a different reason — see lesson 14.)
12. **Verify the thing the user described, not the thing the code computes.**
    Revs 2–6 each shipped with a passing check, and every check was of an
    internal value: `progress`'s curve, `rect`'s continuity, the card's
    *settled* accessibility frame. The two reported symptoms — "the expansion
    doesn't take a second" and "there's a gap between the expansion's final
    size and the video frame" — translate to two measurable quantities that no
    revision had measured: wall-clock from flight start to the frame the
    content replaces the card, and the card's rect on its last visible frame
    vs. the content's frame. Rev 7's checks 1–2 are exactly those; both would
    have failed on every earlier revision. Before declaring an animation bug
    fixed, write down the user's sentence and the one number that would make
    it false, then measure that number.
13. **Read the inputs out of the log before interpreting a screenshot.** A
    screenshot showed the card ~150pt right of where it "should" be while the
    log said `rect` was correct. The log was right: the tapped tile in
    `-screenshotClipListMedia` is the top-right one (`sourceFrame.minX =
    200.5`). Acting on the screenshot alone produced a wrong "fix" that
    broke the animation (lesson 14). The first log line of a flight carries
    `sourceFrame` and `destination`; check them first.
14. **Any `Animatable` whose interpolation matters goes *outside*
    `CrossfadeCut`, never inside.** `CrossfadeCut` ends in `.transaction {
    $0.animation = nil }`, which applies to its whole subtree, so a nested
    `Animatable` never receives per-frame values and snaps to its target.
    Observed three times (Rev 6 twice, Rev 7 once) with the same signature:
    a single-digit call count from the inner effect against ~120 from
    `CrossfadeCut` over the same flight. That call-count ratio is the fast
    check — see Rev 7's check 3.
15. **A bounded spin that silently degrades to a fallback turns a slow CI
    runner into an unexplained timeout.** `ScreenshotHarness.appendSolidFrame`
    waited at most 500 × 2ms for the encoder, then appended anyway; on a
    loaded shared runner `append` failed, the harness fell back to
    `/dev/null`, the editor showed its load-failure state, and
    `ScreenshotTests.testClipEditor` ran out its full 45s with no diagnostic
    (CI run 37261809377, the first after Rev 6 — 6–14s on every earlier
    green run, 73s then). Two fixes, both needed: bound such waits by wall
    clock with a generous budget, and make the test assert the failure state
    is *absent* while it waits, so a degraded harness fails in seconds with a
    reason instead of in a minute with none.

16. **A body-level value inside `CrossfadeCut` doesn't just fail to animate —
    it snaps *before* the cut hides it.** Lesson 14 said nested `Animatable`s
    snap. The corollary that cost a visible bug: a nested *non-animated* layout
    transform computed from `progress`'s target jumps to its end value on the
    first frame of a close, while `CrossfadeCut`'s own interpolated progress
    hasn't crossed its threshold yet. One frame of the destination at the
    wrong size is the signature (Rev 8). If content under the cut needs no
    transform while visible, give it none.
17. **A synthetic test video whose pixel values encode the frame index turns a
    recording into a video-time trace.** `memset(base, frame % 255)` means a
    `-vsync 0` dump reports which frame a player layer was showing on each
    recorded frame — the only way Rev 8 could show a scrub's direction, its
    continuity across the cut, and its landing frame. Solid *colors* (the
    seeded Home videos) can't do this; a gradient over time can.
18. **The recorder can stop emitting frames for the last second of a run.**
    Three swipe-dismiss recordings each ended on a mid-fade frame with the
    card still at the tile, while an end-of-test screenshot showed the grid
    fully restored. Don't read "the last recorded frame" as "the end state";
    capture the end state separately.
19. **The recorder can interleave frames from two sources.** Strictly
    alternating, pixel-identical frames of two settled states — one of which
    the app cannot be in (Rev 9: the grid with the expanded tile *visible*
    under a presented cover) — are the signature. Confirm against the real
    compositor with a burst of `XCUIScreen.main.screenshot()` samples before
    chasing it in the app; a sub-second glitch that's real shows up there too.

`TurnipUITests/ExpansionTransitionVerificationTests.swift` verifies the
containers against the running app. It holds four tests:
`testHomeExpansionFallbackDestinationLetterboxesInsteadOfFullScreen`,
`testClipExpansionCardLandsOnTheEditorsCropMarker`,
`testClipEditorHeaderLinesUpWithTheClipListsBar` and
`testSwipeToDismissCommitsTheEdit`. Run it directly
(`-only-testing:TurnipUITests/ExpansionTransitionVerificationTests`) the
next time either container's destination math, the editor's header or the
dismiss gesture changes. It leans on the
same accessibility-frame-reads-geometry-regardless-of-opacity property the
`"expansion-card"` identifier on each container's card layer exists for,
and, for `HomeExpansionContainer` specifically — which needs a real
`PHAsset` to reach through the app's own UI, the thing `ScreenshotHomeHarness`'s
own doc comment already flags as unscriptable — drives the container
directly via `ScreenshotHomeExpansionHarness` (`-screenshotHomeExpansion`)
with a synthetic non-square `initialAspectRatio` and a `content` that never
reports a measurement, isolating `fallbackDestination` from everything else
the container does.
