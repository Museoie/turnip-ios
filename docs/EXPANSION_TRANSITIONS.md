# Photos-style expansion transitions

*Rev 1 · 2026-10-02.*

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

## Shared design: a two-layer crossfade over one `progress` clock

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
- The **real destination content**, cross-faded in only over the last 15% of
  `progress` (`crossfadeThreshold = 0.85`) — late enough that toolbar/control
  text is never legible mid-shrink, early enough that the swap still reads as
  one continuous motion. `ClipExpansionContainer` additionally scales/offsets
  the real `ClipEditorView` to match the growing rect, since its destination
  is the editor's own crop-hole preview, not the full screen.
  `HomeExpansionContainer` never scales/offsets its content — only the
  opacity crossfade — but its *destination rect* still isn't reliably the
  full screen either: see "Matching the destination's real content rect, not
  just its view bounds" below.
- `progress` is driven by a critically-damped spring (`.spring(response:
  0.3, dampingFraction: 1)`) for tap-to-open, a slightly bouncier one
  (`response: 0.3, dampingFraction: 0.85`) for the reverse close flight, and
  1:1 by live drag translation for an interactive dismiss — the same
  geometry/opacity math serves all three, so there's no separate
  "interactive" rendering branch, only a different thing writing to
  `progress`.
- **Close** always runs the same two steps: animate `progress` back to 0,
  then — once that's visually landed (a fixed delay matching the spring's
  settle time, not a completion callback) — call the real `dismiss()`,
  suppressing the system's own cover-dismissal transition the same two-layer
  way the open side suppresses its presentation animation (see "Suppressing
  the system's own dismissal animation" below) so it doesn't layer a second
  animation — a visible slide of the already-landed card — on top of motion
  that already ended at the tile's exact position and size.

### Where the two containers genuinely differ

| | `ClipExpansionContainer` | `HomeExpansionContainer` |
|---|---|---|
| Destination frame | Measured via a `PreferenceKey` the editor's own preview surface reports (`ClipEditorPreviewFramePreferenceKey`) — the editor's *crop hole*, not the full screen, since the settled content is a different composition (full frame + dimmed surround) than the tile's cropped square. Locked after the first trustworthy report (`isDestinationLocked`), since this container scales/offsets the content and an unlocked measurement would feed back into its own transform | Defaults to the full screen (`ProcessingView`/`ClipListView` both already `ignoresSafeArea()`), but narrows to `ProcessingView`'s real, letterboxed video rect once it reports one via `ProcessingVideoFramePreferenceKey` — see "Matching the destination's real content rect" below. Never locked — stays live, the same `sourceFrame` is, so browsing to a neighbor with a different aspect ratio retargets it rather than flying toward the first video's letterbox rect |
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
