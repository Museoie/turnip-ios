import XCTest

extension XCUIApplication {
    /// Why a harness editor hasn't loaded its movie, for a test's failure message: the
    /// harness's own account of a failed encode when it drew one, otherwise whether the
    /// editor couldn't read the movie it was given or was still loading. The app's log, which
    /// has the rest, isn't in the test output.
    var harnessMovieState: String {
        let note = staticTexts[HarnessIdentifier.sampleMovieFailure]
        if note.exists { return note.label }
        let loadFailure = descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Couldn't load this clip"))
            .firstMatch
        return loadFailure.exists
            ? "the movie encoded, but the editor couldn't read it"
            : "the editor was still loading"
    }
}
