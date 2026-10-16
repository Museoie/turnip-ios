import Foundation

/// Whether a surface may auto-play a video loop at all, from the two system settings the
/// accessibility checklist names (`docs/ACCESSIBILITY.md`). They are independent switches —
/// Reduce Motion covers motion in general, Auto-Play Video Previews only video previews — so
/// either one set against looping is enough to rule it out.
///
/// Shared by every surface that starts a loop without being asked: the Clip List's tiles and
/// the clip editor's preview. A per-screen copy is how one of them ends up ungated.
func mayAutoplayVideoLoops(isVideoAutoplayEnabled: Bool, isReduceMotionEnabled: Bool) -> Bool {
    isVideoAutoplayEnabled && !isReduceMotionEnabled
}
