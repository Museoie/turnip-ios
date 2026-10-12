# Turnip — Accessibility checklist (v1 screens)

*From issue [#22](https://github.com/hoiekim/turnip-ios/issues/22).*

None of the v1 screen issues mention accessibility, and `UIUX.md` scopes itself to
"screens and transitions, not pixels" — so this is the checklist each v1 screen is built
against. Apply the per-screen items as the screen lands; reviewers check them on the
screen's PR rather than retrofitting later.

## Per-screen items

### Settings (UIUX §1a, #163)

- Reachable from Home's gear button (`accessibilityLabel` "Settings", identifier
  `settings-button`), which VoiceOver reads the same as any other icon button — no separate
  affordance needed since it isn't decorative.
- Every control carries a stable `accessibilityIdentifier`: `settings-analysis-mode` (the
  segmented picker), `settings-auto-add-album`, `settings-album-name` (only present while the
  toggle above is on), `settings-granularity`, `settings-done`.
- The granularity `Stepper` exposes the `.adjustable` trait natively (SwiftUI's `Stepper`
  already does — no extra work), so VoiceOver can change it with increment/decrement gestures
  without a drag.
- Section footers explain each option in plain language rather than relying on the control's
  own label alone — read on entry to the section, same as any other `Form` footer.

### Camera (UIUX §1b)

- The record button carries the state: "Start recording" / "Stop recording" as its label, so
  the red shape's change is never the only signal. It is disabled, and dimmed, for the brief
  wait after Stop while the take's live results finish scoring.
- The live pose skeleton drawn over the preview is decorative feedback about what the model
  sees, not information a VoiceOver user needs to act on: it is hidden from the accessibility
  tree (`isAccessibilityElement = false` on the preview view) rather than announced ten times
  a second. Confident joints only, green on the live picture; there is no text over it.
- Manual controls (lens pills, flip, format menu, flash, exposure) are labeled buttons. Lens
  pills, flip and the format menu are disabled while recording rather than hidden, so their
  state is announced; flash ("Turn on flash" / "Turn off flash") and exposure stay live.

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

### Processing (#17)

- Progress and completion are announced (`AccessibilityNotification.Announcement` /
  `UIAccessibility.post`) — a VoiceOver user must not sit on a silent screen while the
  pipeline runs. Announce phase changes ("Analyzing frame 400 of 1,200") sparingly; the
  empty and error states must both be announced on arrival. Availability: the SwiftUI
  `AccessibilityNotification.Announcement` API is iOS 17+ and needs `if #available(iOS 17, *)`
  gating — on the iOS 16 floor (`IPHONEOS_DEPLOYMENT_TARGET: "16.0"` in `project.yml`), use
  `UIAccessibility.post(notification: .announcement, argument:)` instead. **Not yet met:**
  nothing posts an announcement today; the progress indicator is labeled "Analysis progress"
  (determinate) or "Analyzing video" (indeterminate).
- Cancel action reachable and labeled.

### Clip List (#11)

- Each tile's picture is one accessible element: "Open clip" with the `.isButton` trait for a
  derived clip, "Original video" for the original. Its trash button is a separate labeled
  element ("Trash clip" / "Restore clip"), its duration caption is read separately, a derived
  clip's range timeline is one element ("Clip from 2.0s to 5.0s of 30.0s"), and a trashed
  original carries a "Will be deleted" label. **Not yet met:** no label carries the clip's
  index.
- "Save Clips" action labeled; disabled while a save runs.
- No auto-playing loops when `accessibilityReduceMotion` is on; respect
  `UIAccessibility.isVideoAutoplayEnabled` (iOS 13.0+, no availability gate needed on the
  iOS 16 floor). The only iOS 17+ symbol named by this checklist is SwiftUI's
  `AccessibilityNotification.Announcement` (Processing section above).

### Clip Detail / Editor (#18) — verify on device

- Trim handles expose the `.adjustable` trait with `accessibilityIncrement` /
  `accessibilityDecrement` (step ≈ 0.1 s) so start/end can be set without dragging — a
  pure-gesture trim UI with no VoiceOver alternative is unusable non-visually. This is the
  screen to verify with a real VoiceOver pass on device, plus Accessibility Inspector's audit.
- Player controls labeled ("Play" / "Pause", "Mute" / "Unmute"); the Delete button is
  labeled "Delete clip".
- Touch targets: trim handles ≥ 44×44 pt. **Not yet met:** each handle's hit frame is 32 pt
  wide (56 pt tall); a drag anywhere on the timeline grabs the nearer handle, which offsets it.
- No auto-playing preview loop when reduce motion is on. **Not yet met:** the editor's
  preview loops regardless; only Clip List's tiles honor Reduce Motion.

### Export Confirmation (#19) — retired

- The screen is gone (UIUX decision 6): Clip List's "Save Clips" saves inline. Its one item moves
  there — the save's completion, and any per-clip failure, must be announced, not only shown
  as the spinner leaving. **Not yet met:** a failure raises the "Couldn't save clips" alert,
  but a successful save is not announced.

## Cross-cutting rules (every v1 screen)

- **Dynamic Type**: all text uses text styles (`.body`, `.caption`, …), no fixed point
  sizes; layouts survive the largest accessibility sizes (cards wrap, don't clip).
- **Contrast**: text overlaid on video/thumbnails meets 4.5:1 against video content — use a
  scrim, don't rely on the frame.
- **Reduce Motion**: no auto-playing loops when `accessibilityReduceMotion` is on.
- **Touch targets**: interactive elements ≥ 44×44 pt.
- **Identifiers**: stable `accessibilityIdentifier`s on interactive elements — also what a
  future UI-test target hooks into.
- **Localization-ready**: user-facing strings built in code go through `String(localized:)`
  (SwiftUI string literals are already `LocalizedStringKey`). No translations in v1.

## Not in scope

- Translations (`CFBundleDevelopmentRegion` is the only language today).
- Switch Control / Voice Control-specific work beyond what proper labels and traits give
  for free.
