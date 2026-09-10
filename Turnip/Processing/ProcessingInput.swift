import Foundation
import Photos

/// What the processing screen (issue #17) runs the pipeline against.
///
/// `photoAsset` exists because Home (#16) picks `PHAsset`s, and an iCloud-only asset must
/// download before the pipeline can read its frames — the pipeline reports that download as
/// its own progress phase rather than failing on an unreadable file. `fileURL` covers flows
/// where a local file is already on disk.
///
/// `PHAsset` is not `Sendable`; this is `@unchecked Sendable` because a fetched asset is
/// effectively immutable — the pipeline only reads it and hands the reference to
/// `PHImageManager`, never mutating it.
struct ProcessingInput: @unchecked Sendable {
    enum Source {
        case fileURL(URL)
        case photoAsset(PHAsset)
    }

    let source: Source
}
