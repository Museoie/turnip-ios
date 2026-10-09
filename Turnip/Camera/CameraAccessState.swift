import AVFoundation

/// Combined camera + microphone authorization, collapsed the way
/// `PhotoLibraryAuthorization` collapses PhotoKit's status enum — a recording needs both,
/// so the UI only ever needs one three-way state rather than two `AVAuthorizationStatus`
/// values.
enum CameraAccessState: Equatable {
    case notDetermined
    case authorized
    case denied(restricted: Bool)

    init(video: AVAuthorizationStatus, audio: AVAuthorizationStatus) {
        if video == .authorized, audio == .authorized {
            self = .authorized
        } else if video == .restricted || audio == .restricted {
            self = .denied(restricted: true)
        } else if video == .notDetermined || audio == .notDetermined {
            self = .notDetermined
        } else {
            self = .denied(restricted: false)
        }
    }
}
