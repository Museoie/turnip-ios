# Turnip — Accessibility checklist (v1 screens)

*From issue [#22](https://github.com/hoiekim/turnip-ios/issues/22).*

None of the v1 screen issues mention accessibility, and `UIUX.md` scopes itself to
"screens and transitions, not pixels" — so this is the checklist each v1 screen is built
against. Every screen named below has now been built and swept against it; a new screen, or
a new control on an existing one, is checked against the cross-cutting rules at the bottom on
its own pull request rather than retrofitted later.

Two conventions this codebase settled on while applying it, worth knowing before adding a
control:

- **A spoken string is built in a named type, not inline in the view.** `VideoTileView`,
  `ClipListAccessibility` and `ProcessingAnnouncements` each hold the wording for their
  screen, which is what makes it assertable — a label that drops a clause crashes nothing and
  only mis-speaks.
- **A touch target is widened with `contentShape`, not with `frame`.** A frame re-centers the
  drawn glyph inside the larger box and moves it; `contentShape([.interaction, .accessibility],
  Rectangle().inset(by: -N))` grows the region a finger and VoiceOver's focus ring get while
  leaving layout alone. Both kinds are named explicitly, since the interaction shape alone
  does not move the focus ring.

## Per-screen items

### Settings (UIUX §1a, #163) — done

- Reachable from Home's gear button (`accessibilityLabel` "Settings", identifier
  `settings-button`), which VoiceOver reads the same as any other icon button — no separate
  affordance needed since it isn't decorative.
- Every control carries a stable `accessibilityIdentifier`: `settings-analysis-mode` (the
  segmented picker), `settings-auto-add-album`, `settings-album-name` (only present while the
  toggle above is on), `settings-follow-athlete`, `settings-granularity`, `settings-done`.
- The granularity `Stepper` exposes the `.adjustable` trait natively (SwiftUI's `Stepper`
  already does — no extra work), so VoiceOver can change it with increment/decrement gestures
  without a drag.
- Section footers explain each option in plain language rather than relying on the control's
  own label alone — read on entry to the section, same as any other `Form` footer.

### Camera (UIUX §1b) — done

- The record button carries the state: "Start recording" / "Stop recording" as its label, so
  the red shape's change is never the only signal. It is disabled, and dimmed, for the brief
  wait after Stop while the take's live results finish scoring.
- The live pose skeleton drawn over the preview is decorative feedback about what the model
  sees, not information a VoiceOver user needs to act on: it is hidden from the accessibility
  tree (`isAccessibilityElement = false` on the preview view) rather than announced ten times
  a second. Confident joints only, green on the live picture; there is no text over it.
- Manual controls are labeled buttons. The ones that would interrupt the take — lens pills,
  flip, format menu — are disabled, and dimmed, while recording rather than hidden, so their
  state is announced. **Flash and exposure stay live while recording on purpose:** both are
  capture adjustments whose whole use is mid-take (the torch is the light the take is shot
  under), and the system camera keeps them available for the same reason.
- The active lens pill carries `.isSelected`. The yellow fill is otherwise the only thing
  that marks it, which a listener never sees.
- Identifiers: `camera-cancel`, `camera-record`, `camera-lens-<label>`, `camera-flip`,
  `camera-flash`, `camera-exposure-toggle`, `camera-exposure-slider`, `camera-format-menu`,
  `camera-open-settings`.

### Home / Video Gallery (#16) — done

- Each video tile is one accessible element: `accessibilityLabel` "Video, 12 seconds,
  Sep 4, 2026 at 3:04 PM" (spoken duration via `VideoDurationFormatter.accessibilityString`,
  not the `m:ss` badge text — "0:12" is announced "zero twelve"), `.isButton` trait, and the
  grid announces its count ("1 video" / "N videos") on entry.
- Duration badge: white text on a black-60% capsule scrim (4.5:1 against any frame), not a
  shadow that assumes dark footage.
- Stable `accessibilityIdentifier`s: `video-grid`, `video-tile-<localIdentifier>`,
  `limited-access-banner`, `select-more-videos`, `resolution-banner`,
  `cancel-video-resolution`, `photos-access-denied`, `open-settings`, `settings-button`,
  `gallery-filter-button` (`accessibilityLabel` "Filter", `accessibilityValue` the active
  filter's name — the filled-vs-outline glyph that marks an active filter is otherwise purely
  visual; its `Menu` rows carry no identifiers of their own, since XCUITest reaches a system
  menu's items by label/text, not identifier, the same as `CameraCaptureView`'s existing format
  menu — disabled, not hidden, without library access, so VoiceOver announces it as unavailable
  rather than omitting it), `clear-gallery-filter`.

### Processing (#17) — done

- Progress and failure are announced. The API is `UIAccessibility.post(notification:
  .announcement, argument:)`, not SwiftUI's `AccessibilityNotification.Announcement`, which is
  iOS 17+ against a 16.0 floor (`IPHONEOS_DEPLOYMENT_TARGET` in `project.yml`).
- **A run speaks four times, not once per frame.** The pipeline reports every processed frame
  and VoiceOver queues announcements rather than coalescing them, so posting each one buries
  the screen's own controls under minutes of speech. `ProcessingAnnouncements` speaks a report
  only when the run crosses into a new quarter of its length — "Analyzing frame 400 of 1200".
  A run whose track reports no frame rate has no quarters, so it speaks its first report and
  then stays quiet; a bare counter repeated every frame carries nothing to act on.
- The failed state is announced with the reason the screen shows. It replaces the page content
  in place rather than pushing, so there is no screen-change notification either — the
  announcement is the only signal a listener gets.
- The empty result is announced on the Clip List instead, where the zero-tricks notice lives:
  a run that detects nothing still navigates, and an announcement posted into a simultaneous
  screen change is the one VoiceOver drops. A run that *did* find clips is read off the Clip
  List grid's own count label for the same reason — see that section below.
- The progress bar carries the frame counter as its `accessibilityValue`, so the count is
  reachable from the bar itself and not only from the `Text` beside it.
- Cancel is reachable and labeled throughout the run.
- Identifiers: `processing-cancel`, `processing-back`, `start-analysis`, `analysis-progress`,
  `processing-retry`, `processing-back-home`, `cancel-browsing`.

### Clip List (#11) — done

- **The grid states its count on entry** ("3 clips" / "1 clip" / "No clips"), the same way
  Home's does. This is how a run's *result* reaches a listener: a run that found clips announces
  nothing of its own, because an announcement posted into the simultaneous screen change is the
  one VoiceOver drops, which leaves the grid's own label to carry the outcome. The `ScrollView`
  has to be declared an accessibility container for the label to be read at all.
- **Each clip card is one accessible element**, labeled with its position, its spoken length
  and its trash decision: "Clip 2 of 3, 2.4 seconds, kept". One element rather than four — a
  tile, a trash button, a timeline and a caption, none of which names the clip, is not a usable
  way to hear a grid. The caption is hidden from the tree, since the card's label carries it.
  - The original video is labeled "Original video, 1 minute, 3 seconds, kept" and is not
    counted among the clips: it stands for the source already in Photos, not a detection.
  - The two trash decisions are described differently because they *are* different. The
    original's is a reversible instruction to Save Clips ("will be deleted"); a derived clip's
    removes the card outright ("discarded").
  - A card whose frame has not decoded appends "thumbnail placeholder". Opacity is otherwise
    the only signal that the tile is showing a grey square.
- **The keep/discard toggle is reachable as an action on the card**, named for what the tap
  does ("Discard clip" / "Delete original after saving" / "Restore"). The visible 28 pt button
  stays in the tree as its own element too — it is additive, not a replacement, and the
  screenshot UI tests reach it by label.
- "Save Clips" carries what it commits to as its `accessibilityValue`: "Saves 3 clips to Photos",
  plus "and deletes the original video" when that toggle is set. Deleting the source is the one
  irreversible thing the button does and is never left to a dimmed thumbnail to convey. Its
  disabled state (during a save) is announced natively by `.disabled`.
- **The save announces its start and its completion.** The overlay that replaces the grid is a
  spinner with no accessible text, and the screen then pops to Home, so without these the only
  completion signal is the spinner leaving — which is exactly the item the retired export
  confirmation screen (#19) handed over. A run with no clip to write speaks neither. A failed
  run never speaks completion; its alert is a `UIAlertController`, which VoiceOver announces on
  presentation. The completion is posted just before the pop to Home, so it goes out a second
  later (`postAccessibilityAnnouncementAfterScreenChange`): VoiceOver drops an announcement
  posted while the screen is changing.
- Per-clip failures name their clip ("Clip 2 of 3: Export failed — …") by the card's own
  position, so the number leads back to the card that failed. A grid of one clip has nothing to
  disambiguate, so it stays unnumbered.
- After a partial failure, a clip that already landed carries a "Saved to Photos" marker, read
  as its own element after the card. A retry writes only the unmarked clips, so Save Clips'
  value and the start and completion announcements count those, not every card on screen.
- The zero-tricks notice is announced once the push onto the Clip List has settled, through
  the same delayed post, and **does not dismiss itself while a screen
  reader is running** — a notice on a five-second timer can expire before VoiceOver reaches it.
  It waits for a tap instead (`GlassNoticeView.isScreenReaderRunning`).
- No auto-playing loops when `accessibilityReduceMotion` is on; respect
  `UIAccessibility.isVideoAutoplayEnabled` (iOS 13.0+, no availability gate needed on the
  iOS 16 floor). Both switches are read through the shared `mayAutoplayVideoLoops`, which the
  clip editor's preview uses too — a per-screen copy is how one of them ends up ungated.
- Identifiers: `clip-grid`, `clip-list-back`, `clip-card-<n>` / `clip-card-original`,
  `clip-trash-toggle`, `add-clip`, `save-clips`, `no-tricks-notice`. The toggle's identifier
  is one value across both states — the state belongs in the label, which is where the
  screenshot tests read it from.

### Clip Detail / Editor (#18) — done in code; **the on-device VoiceOver pass is still owed**

- Trim handles expose the adjustable behavior with 0.1 s steps so start and end can be set
  without dragging — a pure-gesture trim UI with no VoiceOver alternative is unusable
  non-visually. Note that SwiftUI has no `.isAdjustable` trait to add: `accessibilityAdjustableAction`
  is the whole mechanism, and it is what makes VoiceOver announce "adjustable" and route
  swipe-up/down. Each handle's value is spoken ("2.4 seconds"), not read off the "2.4s" badge.
- **The crop area has the same non-visual path.** Framing a clip is pinch, two-finger rotate
  and drag, none of which a VoiceOver user can perform, which would leave the editor's whole
  purpose unreachable. Nine named actions — zoom in/out, rotate either way, move in four
  directions, Reset crop — drive the same view-model calls the gestures commit, so the two paths
  cannot diverge. Steps live in `CropAdjustmentStep`. The crop area's value spells out the
  framing those actions leave ("Zoom 125%, turned 3° clockwise, moved 5% left"), in the units
  they step by (`CropAdjustmentDescription`), so a press is heard to have done something.
- Player controls labeled. The scrub track carries a label, its position as a value, and an
  adjustable action seeking ±1 s: without one it is a pure drag surface, where a listener can
  hear where playback stands but has no way to move it.
- Keep/discard is not the editor's decision — the list's own toggle owns it. The editor's
  Delete is its own labeled, reachable element.
- Touch targets: trim handles, play/pause, mute and the scrub track all reach 44 pt.
- No auto-playing preview loop when reduce motion is on: the preview parks on the window's
  first frame and Play starts it on request.
- Identifiers: `clip-editor-back`, `clip-editor-delete`, `clip-editor-crop-surface`,
  `auto-crop-button`, `reset-crop-button`, `auto-rotate-button`, `trim-start-handle`, `trim-end-handle`, `playback-play-pause`,
  `playback-mute`, `playback-position`.
- **Still owed:** a real VoiceOver pass on device, plus Accessibility Inspector's audit.
  Everything above is verified by CI and by unit tests over the spoken strings and the gates,
  which is not the same as having listened to the screen — a focus order that reads badly, or
  a step size that turns out too coarse to frame with, only shows up on hardware. This line
  stays until someone has run it there.

### Export Confirmation (#19) — retired

- The screen is gone (UIUX decision 6): Clip List's "Save Clips" saves inline. Its one item moved
  there — see the Clip List section's save announcements above.

### Name Clips (planned — UIUX §3a, `PROFILE_DESIGN.md` §4)

- Clip List's "Next: name clips" and "Save without names" are both labeled buttons; the
  secondary keeps `PrimaryActionBar`'s plain-text style, so it must still meet the 44 pt
  target.
- The counter is read with the clip ("Clip 2 of 4"), and paging has buttons ("Next" /
  "Skip", "Save Clips" on the last clip, "Save now"), so moving between clips never
  depends on the swipe.
- The trick-name field is labeled "Trick name"; each chip is one element with a "Remove"
  action (`accessibilityAction(named:)`), not a tiny × target; suggestions are buttons
  announced with their position ("gainer, suggestion 1 of 3").
- The me / someone-else control announces its state as a value ("Who's in this clip: me"),
  never color alone.
- The contribute toggle is a labeled switch ("Contribute this clip"); while disabled it says
  why ("Name the clip first") rather than only dimming.
- The looping clip follows Clip List's rule: no auto-playing loop under Reduce Motion or
  with video autoplay off.

### Profile (planned — `PROFILE_DESIGN.md` §5–§8)

- Reached by the floating bar's profile icon (`accessibilityLabel` "Profile") as well as
  the page swipe, so it never depends on a gesture.
- Each achievement card is one element: "Gainer, level 2, 7 of 10 sessions to level 3",
  `.isButton`. Progress bars carry the same figures as `accessibilityValue`; the bar's fill
  is never the only signal.
- An achievement reached is announced once, when it is earned, not on every visit.
- Gallery tiles follow Clip List's rules: one element per tile, no auto-playing loops under
  Reduce Motion or with video autoplay off.
- Highlights: no autoplay under Reduce Motion; a side-by-side "then and now" reads as one
  element naming both dates ("Gainer, March 2025 and September 2026"); locked highlights
  read what they are missing ("Locked: name one more gainer from before April").
- Stable identifiers: `profile-tab`, `needs-a-name`, `achievement-<trick>-<kind>`,
  `gallery-trick-<trick>`, `highlight-<kind>`, `clip-view`.

## Cross-cutting rules (every v1 screen)

- **Dynamic Type**: all text uses text styles (`.body`, `.caption`, …), no fixed point
  sizes; layouts survive the largest accessibility sizes (cards wrap, don't clip). The two
  remaining `Font.system(size:)` uses are SF Symbol glyphs, not text — the "+" on the add-clip
  tile and the status-state icon.
- **Contrast**: text overlaid on video/thumbnails meets 4.5:1 against video content — use a
  scrim, don't rely on the frame.
- **Reduce Motion**: no auto-playing loops when `accessibilityReduceMotion` is on, via
  `mayAutoplayVideoLoops`.
- **Touch targets**: interactive elements ≥ 44×44 pt, widened with `contentShape` as described
  at the top rather than with `frame`.
- **Decorative glyphs stay out of the tree**: an icon whose meaning the adjacent text already
  carries is `accessibilityHidden` — otherwise a listener sits through "exclamation mark
  triangle" before reaching the sentence that matters.
- **Identifiers**: stable `accessibilityIdentifier`s on interactive elements — also what the
  screenshot UI tests hook into. Prefer an identifier over a label predicate there: a label is
  user-facing wording and will keep changing, an identifier is a contract.
- **Localization-ready**: user-facing strings built in code go through `String(localized:)`
  (SwiftUI string literals are already `LocalizedStringKey`). No translations in v1.
  - **Known gap:** the shared design-system components (`PrimaryActionBar`,
    `ScrimIconButton`, `BackChevronButton`, `StatusStateView`, `GlassNoticeView`) type their
    title/label parameters as `String`, so `Text(title)` resolves to the non-localizing
    `StringProtocol` overload and a literal passed at the call site is never a
    `LocalizedStringKey`. It looks localizable at every call site, which is what makes it easy
    to miss. Fixing it means changing those parameters to `LocalizedStringKey` across all
    their callers, which is tracked in #215 rather than folded into the accessibility sweep.

## Not in scope

- Translations (`CFBundleDevelopmentRegion` is the only language today).
- Switch Control / Voice Control-specific work beyond what proper labels and traits give
  for free.
