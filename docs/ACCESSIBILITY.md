# Turnip — Accessibility checklist (v1 screens)

*From issue [#22](https://github.com/hoiekim/turnip-ios/issues/22).*

None of the v1 screen issues mention accessibility, and `UIUX.md` scopes itself to
"screens and transitions, not pixels" — so this is the checklist each v1 screen is built
against. Apply the per-screen items as the screen lands; reviewers check them on the
screen's PR rather than retrofitting later.

## Per-screen items

### Home / Video Gallery (#16) — done

- Each video tile is one accessible element: `accessibilityLabel` "Video, 12 seconds,
  Sep 4, 2026 at 3:04 PM" (spoken duration via `VideoDurationFormatter.accessibilityString`,
  not the `m:ss` badge text — "0:12" is announced "zero twelve"), `.isButton` trait, and the
  grid announces its count ("1 video" / "N videos") on entry.
- Duration badge: white text on a black-60% capsule scrim (4.5:1 against any frame), not a
  shadow that assumes dark footage.
- Stable `accessibilityIdentifier`s: `video-grid`, `video-tile-<localIdentifier>`,
  `limited-access-banner`, `select-more-videos`, `resolution-banner`,
  `cancel-video-resolution`, `photos-access-denied`, `open-settings`.

### Processing (#17)

- Progress and completion are announced (`AccessibilityNotification.Announcement` /
  `UIAccessibility.post`) — a VoiceOver user must not sit on a silent screen while the
  pipeline runs. Announce phase changes ("Analyzing frame 400 of 1,200") sparingly; the
  empty and error states must both be announced on arrival.
- Cancel action reachable and labeled.

### Clip List (#11)

- Each clip card is one accessible element: label with clip index, duration, kept/discarded
  state. The keep/discard toggle is reachable as an action, not just a tap target.
- "Export N clips" action labeled with the live count; disabled state announced.
- No auto-playing loops when `accessibilityReduceMotion` is on; respect
  `UIAccessibility.isVideoAutoplayEnabled`.

### Clip Detail / Editor (#18) — verify on device

- Trim handles expose the `.adjustable` trait with `accessibilityIncrement` /
  `accessibilityDecrement` (step ≈ 0.1 s) so start/end can be set without dragging — a
  pure-gesture trim UI with no VoiceOver alternative is unusable non-visually. This is the
  screen to verify with a real VoiceOver pass on device, plus Accessibility Inspector's audit.
- Player controls labeled. Keep/discard toggle reachable as an action.
- Touch targets: trim handles ≥ 44×44 pt.
- No auto-playing preview loop when reduce motion is on.

### Export Confirmation (#19)

- Per-clip progress and the final "N of M clips saved" summary are announced; per-clip
  failures are called out individually in the announcement, not just as a total.

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
