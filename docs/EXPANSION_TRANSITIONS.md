# Photos-style expansion transitions

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
by a hand-built `progress: CGFloat` spring.

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

Both containers' numeric constants (`dismissTravel`, the "almost any
downward release commits" rule in each `dismissEnded`/`onEnded`, the spring
response/damping pairs) are this research's measurements translated into
SwiftUI's spring parameterization, not arbitrary tuning.

## Shared design: a two-layer hard cut over one `progress` clock

Both containers share one structure, independently implemented:

```
progress: CGFloat        // 0 = exactly at the source tile, 1 = fully open
```

- A **card** layer: the tile's own already-decoded thumbnail/poster, with no
  dependency on the real destination's content being ready. Its frame is a
  plain linear interpolation between the tile's captured/live source frame
  and the destination frame, lerping center and size separately so it grows
  from its own middle rather than a corner (`currentRect(destination:)` in
  both files).
- The **real destination content**, hidden for the entire flight and cut in
  only once the card has actually arrived (`crossfadeThreshold = 0.999`, i.e.
  `progress ≈ 1`) — an instant cut, not a fade, and at the one point where the
  card's rect equals the content's settled frame, so nothing pops. (Through
  Rev 6 this was `0.85`: the card was swapped out while still 15% of the
  distance short, which was the "sizing gap" bug — see Rev 7.) On close, the
  same threshold hands back to the card on the first frame of travel, so
  toolbar/control text is never seen mid-shrink. `ClipExpansionContainer`
  additionally scales/offsets the real
  `ClipEditorView` to match the growing rect, since its destination is the
  editor's own crop-hole preview, not the full screen. `HomeExpansionContainer`
  never scales/offsets its content — only the hard-cut visibility swap — but
  its *destination rect* still isn't reliably the full screen either: see
  "Matching the destination's real content rect, not just its view bounds"
  below.
- Only the card layer, and the two destinations' own real content, are ever
  faded/cut at all — the *source* tile sitting in the grid/list underneath is
  hidden outright at the same instant (`VideoGalleryView`'s
  `hiddenAssetIdentifier` / `ClipCardView.isHidden`, both wrapped in the same
  `disablesAnimations`/`setAnimationsEnabled` transaction as the slot's own
  state change — see "Suppressing the system's own presentation animation"
  below), not faded — there's nothing animating that hide, so it was never the
  source of a visible fade; the one that was visible was the crossfade this
  rev replaced.
- `progress` is driven by `.easeInOut(duration: flightDuration)` with
  `flightDuration = 1` for tap-to-open, the reverse close flight, and the
  cancel-snap-back, and 1:1 by live drag translation for an interactive
  dismiss — the same geometry/opacity math serves all of them, so there's no
  separate "interactive" rendering branch, only a different thing writing to
  `progress`. An explicit-duration curve rather than a spring: the
  `.spring(response: 1, …)` Revs 5–6 used does ~85% of its travel in the first
  ~0.65s and then crawls, so the *visible* growth never read as a second even
  though `progress` technically took ~1.5s to settle — see Rev 7. (The
  Photos-measured spring constants in "Research" above still describe the
  *interactive* feel; the open/close duration is now a product decision, not
  a spring parameter.)
- **Close** always runs the same two steps: animate `progress` back to 0,
  then — once that's visually landed (`flightDuration + 0.05`, not a
  completion callback) — call the real `dismiss()`,
  suppressing the system's own cover-dismissal transition the same two-layer
  way the open side suppresses its presentation animation (see "Suppressing
  the system's own dismissal animation" below) so it doesn't layer a second
  animation — a visible slide of the already-landed card — on top of motion
  that already ended at the tile's exact position and size.

### Where the two containers genuinely differ

| | `ClipExpansionContainer` | `HomeExpansionContainer` |
|---|---|---|
| Destination frame | Measured via a `PreferenceKey` the editor's own preview surface reports (`ClipEditorPreviewFramePreferenceKey`) — the editor's *crop hole*, not the full screen, since the settled content is a different composition (full frame + dimmed surround) than the tile's cropped square. Never locked: this container scales/offsets the content, so the raw report is read through that same transform, not the editor's true frame — rather than waiting for the transform to settle near identity (what a previous rev did), the current transform is divided back out of every report, recovering the true frame immediately and keeping it live, the same as `HomeExpansionContainer`'s own destination. A fallback square stands in only until the very first report arrives (see "Measuring the destination without a race or a feedback loop" below) | Defaults to a synchronous aspect-ratio estimate from the tapped `PHAsset`'s own pixel dimensions (full screen only when no estimate applies, e.g. a destination that goes straight to `ClipListView`), narrowing to `ProcessingView`'s real, letterboxed video rect once it reports one via `ProcessingVideoFramePreferenceKey` — see "Matching the destination's real content rect" and "Measuring the destination without a race or a feedback loop" below. Never locked — stays live, the same `sourceFrame` is, so browsing to a neighbor with a different aspect ratio retargets it rather than flying toward the first video's letterbox rect |
| Source frame | Captured once, at tap time (`sourceFrame: CGRect`) | A **live closure** (`sourceFrame: () -> CGRect?`), re-read continuously — a close after `ProcessingView`'s own swipe-to-browse-neighbors must land on whichever tile is *now* current, not the one first tapped |
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
only ever filled a narrower band meant the crossfade (`crossfadeThreshold`)
landed on a visible size mismatch: the card had grown past where the video
actually was.

The fix mirrors `ClipExpansionContainer`'s own destination-measuring
approach (see the table above), computed with the same `AVMakeRect` math
`ProcessingView.poseOverlay` already used to align the pose skeleton to the
letterboxed video: a `ProcessingVideoFramePreferenceKey`, reported from a
`GeometryReader`-backed `.background` inside `ProcessingView.videoStage`
once `displaySize` (the asset's natural size, loaded asynchronously from its
track info) is available, consumed by `HomeExpansionContainer` the same way
it already consumed `ClipEditorPreviewFramePreferenceKey`'s sibling. Unlike
that sibling, though, it's never locked — see the table above for why: this
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
reflect display orientation (the same thing `ClipEditorViewModel.displayedSize`
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
scale`. Both containers.

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
content the `NavigationStack` hosts, as a `.background()` on the
destination's own root view —

- `ClipEditorView` takes a `dismissGesture: AnyGesture<DragGesture.Value>?`
  and attaches it behind its own `VStack`, so it only fires where the
  editor's own crop-drag/trim-slider/button gestures don't claim the touch
  first.
- `ProcessingView` already *had* its own vertical swipe-to-dismiss (it just
  used to commit unilaterally on release and call `dismiss()` directly). It
  now reports that gesture's live state to the presenter instead of deciding
  for itself — see `ProcessingView.DismissGestureHooks` (`onChanged`,
  `onEnded`, `onCancelled`) — and the container owns the commit/cancel
  decision and the resulting flight. This also means the Photos-exact
  "almost any downward release commits" rule lives in exactly one place
  (`HomeExpansionContainer.closeHandlers`), not duplicated into
  `ProcessingView`.

Per the gesture-ownership question this raised during design, the chosen
split for `ProcessingView` specifically is: the dismiss zone is the area
**outside the video surface** (margins, the area below the trim/scrub
controls) — the video itself keeps its existing one-finger crop-drag/browse
gesture untouched, rather than overloading it or requiring a second finger.

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
recording it was tested against.

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
content layer is still near-invisible behind the card, per the crossfade
threshold — also means any residual first-layout cost is itself covered.

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
case — and since `.allowsHitTesting` is gated on `progress` being back near
1, a stuck flag leaves the whole screen's controls, including the back
button, permanently disabled with no way out.

Both containers use `@GestureState` instead (`dragTranslation` in
`ClipExpansionContainer`; the equivalent lives in `ProcessingView`'s own
gesture, reported out via `DismissGestureHooks.onCancelled`), which SwiftUI
resets to its initial value whenever a gesture ends for *any* reason,
cancellation included — paired with an `onChange` that fires the same
cancel-spring `onEnded` would have, but only if `onEnded` didn't already run
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
   plus the 0.5s hold after it — scales with the open/close spring's own
   `response`, currently ~1.4s–1.9s) — reproduced
   across a simulator reboot, so not host flakiness. There's no known
   workaround short of not sampling in that window; the close direction's
   destination correctness has to be inferred from the open direction's
   (same `measuredDestination`, same `currentRect`, no separate computation
   close performs) rather than independently screenshotted.
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

`TurnipUITests/ExpansionTransitionVerificationTests.swift` is where Rev 2's
own fix was actually verified against the running app rather than just
re-read as a diff, and it stays in the tree as a regression test against
these two specific bugs recurring — run it directly
(`-only-testing:TurnipUITests/ExpansionTransitionVerificationTests`) the
next time either container's destination math changes. It leans on the
same accessibility-frame-reads-geometry-regardless-of-opacity property the
`"expansion-card"` identifier on each container's card layer exists for,
and, for `HomeExpansionContainer` specifically — which needs a real
`PHAsset` to reach through the app's own UI, the thing `ScreenshotHomeHarness`'s
own doc comment already flags as unscriptable — drives the container
directly via `ScreenshotHomeExpansionHarness` (`-screenshotHomeExpansion`)
with a synthetic non-square `initialAspectRatio` and a `content` that never
reports a measurement, isolating `fallbackDestination` from everything else
the container does.
