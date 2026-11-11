import SwiftUI

/// The gallery's first tile: a camera glyph that opens the camera (`RootTabView`), the way a photo
/// picker leads its grid with one. Square and edge to edge like the video tiles after it, so it
/// reads as part of the grid rather than a control laid over it.
struct GalleryCameraTile: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Color(.secondarySystemFill)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    Image(systemName: "camera.fill")
                        .font(.title.weight(.semibold))
                        .foregroundStyle(.white)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Camera")
        .accessibilityHint("Records a new video.")
        .accessibilityIdentifier("gallery-camera-tile")
    }
}

#Preview {
    GalleryCameraTile(action: {})
        .frame(width: 130)
        .preferredColorScheme(.dark)
}
