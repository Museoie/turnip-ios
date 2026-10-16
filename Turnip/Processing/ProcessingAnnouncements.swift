import Foundation

/// Which of a run's progress reports VoiceOver actually hears.
///
/// The pipeline reports once per processed frame — hundreds of times in a run — and VoiceOver
/// speaks announcements in sequence rather than coalescing them, so posting every report would
/// bury the screen's own controls under minutes of speech. A report is spoken only when the run
/// crosses into a new quarter of its length, which is the "sparingly" that
/// `docs/ACCESSIBILITY.md` asks of progress.
enum ProcessingAnnouncements {
    /// How many equal parts a run of known length is divided into for speech.
    static let milestoneCount = 4

    /// The quarter `progress` lands in, or `nil` when the track reported no frame rate and the
    /// run therefore has no length to cross quarters of.
    static func milestone(for progress: ProcessingProgress) -> Int? {
        guard let fraction = progress.fraction else { return nil }
        return min(Int(fraction * Double(milestoneCount)), milestoneCount - 1)
    }

    /// What `progress` should say, and the milestone that answer consumes, or `nil` to stay
    /// silent. `lastAnnounced` is the milestone already spoken in this run, `nil` before the
    /// first report.
    ///
    /// A run whose length is unknown has no quarters, so it speaks its first report and then
    /// stays quiet until the run ends — a bare frame counter repeated every frame carries no
    /// information a listener can act on.
    static func progressAnnouncement(
        for progress: ProcessingProgress,
        lastAnnounced: Int?
    ) -> (message: String, milestone: Int)? {
        guard let milestone = milestone(for: progress) else {
            return lastAnnounced == nil ? (progress.label, 0) : nil
        }
        guard let lastAnnounced else { return (progress.label, milestone) }
        guard milestone > lastAnnounced else { return nil }
        return (progress.label, milestone)
    }

    /// What a failed run says. `message` is the error the screen already shows, so a listener
    /// hears the same reason a reader sees rather than a generic failure.
    static func failureAnnouncement(message: String) -> String {
        String(localized: "Analysis failed. \(message)")
    }
}
