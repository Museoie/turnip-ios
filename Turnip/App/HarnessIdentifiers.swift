/// Accessibility identifiers that the DEBUG harnesses draw and the UI tests look up. This file
/// is compiled into both the app and the UI test target, so renaming one on either side alone
/// fails to build instead of leaving a test that silently stops finding its element.
enum HarnessIdentifier {
    /// The sample movie's encode failure, drawn over a harness so a UI test can report it.
    static let sampleMovieFailure = "harness-sample-movie-failure"
}
