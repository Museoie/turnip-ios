import AVFoundation
import SwiftUI

/// The camera-recording screen, one of the two pages `RootTabView` swipes between:
/// full-screen preview, a cancel chevron, manual controls (lens/zoom, front/rear flip,
/// resolution/fps, torch, exposure bias), and one record button. While recording, the pose
/// scored live on the camera frames is drawn over the preview. On a successful recording,
/// `onFinished` hands the caller the temp file and any clips detected live, so it can save
/// the file to Photos and feed the resulting `PHAsset` into the picked-video flow — this
/// screen knows nothing about Photos or navigation. `onCancel` backs out to the gallery
/// tab; a no-op default since not every caller (e.g. a preview) needs one.
struct CameraCaptureView: View {
    let onFinished: (CameraRecording) -> Void
    var onCancel: () -> Void = {}

    @StateObject private var viewModel = CameraCaptureViewModel()
    /// The person mode the top-right control shows and the next take is recorded in, the same
    /// remembered choice Processing's picker sets.
    @ObservedObject private var settings = TurnipSettingsStore.shared
    @State private var showExposureSlider = false
    /// Whether this page has started the session and not yet stopped it — see
    /// `CameraPreviewView.isLive`.
    @State private var isPreviewLive = false
    /// Whether the preview was live when the app backgrounded. The scene-phase
    /// handler only restarts the session on return if the camera page was front:
    /// the page stays in the `TabView` hierarchy, so its `.onChange` fires on
    /// every tab — restarting unconditionally would start the camera under
    /// whatever tab the user is on.
    @State private var wasLiveBeforeBackground = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch viewModel.authorization {
            case .authorized:
                CameraPreviewView(
                    session: viewModel.session, isLive: isPreviewLive,
                    poseSkeletons: viewModel.livePoseSkeletons)
                    // The top inset is kept so the top-pinned picture starts just under the
                    // status bar, with the cancel and settings buttons floating inside it.
                    .ignoresSafeArea(edges: [.horizontal, .bottom])
                    .overlay {
                        // A transparent gesture catcher, not `.gesture` directly on the
                        // representable: the hosted `UIView` would otherwise hit-test the
                        // touch first. Sits below the button overlays added later in this
                        // modifier chain, so it never intercepts their taps.
                        Color.clear
                            .contentShape(Rectangle())
                            .gesture(pinchZoomGesture)
                    }
            case .denied(let restricted):
                CameraAccessDeniedView(restricted: restricted)
            case .notDetermined:
                EmptyView()
            }
        }
        .overlay(alignment: .topLeading) { cancelButton }
        .overlay(alignment: .topTrailing) {
            if viewModel.authorization == .authorized {
                topRightControls
            }
        }
        .safeAreaInset(edge: .bottom) {
            if viewModel.authorization == .authorized {
                bottomControls
            }
        }
        .task {
            viewModel.onFinished = onFinished
            isPreviewLive = true
            await viewModel.start()
        }
        .onDisappear {
            isPreviewLive = false
            viewModel.stop()
        }
        // `.task` / `.onDisappear` fire on navigation; neither fires when the
        // app is backgrounded or the session is interrupted, so without this
        // the session would keep running behind the lock screen and the torch
        // would stay on in the published state after the OS killed it.
        // `.active` restarts only if the page was front when the app went
        // away (`wasLiveBeforeBackground`) — see that property.
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .background:
                wasLiveBeforeBackground = isPreviewLive
                isPreviewLive = false
                viewModel.stop()
            case .active:
                guard wasLiveBeforeBackground else { return }
                wasLiveBeforeBackground = false
                isPreviewLive = true
                Task { await viewModel.start() }
            case .inactive:
                break
            @unknown default:
                break
            }
        }
        .overlay {
            if let reason = viewModel.interruptionReason {
                interruptionScrim(reason: reason)
            }
        }
        .errorAlert("Couldn't record video", message: $viewModel.errorMessage)
    }

    /// The frozen preview while the session is interrupted: a dim over the
    /// picture with the reason in words, so the camera never reads as alive
    /// while it records nothing. The top controls stay above it (their
    /// overlays are added after this one).
    private func interruptionScrim(reason: AVCaptureSession.InterruptionReason) -> some View {
        Color.black.opacity(0.6)
            .ignoresSafeArea()
            .overlay {
                Text(reason.displayMessage)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding()
            }
            .accessibilityIdentifier("camera-interrupted")
    }

    /// Placed where a navigation bar's leading item would sit (`screenHeaderItemPlacement`),
    /// level with Home's own bar controls across the pager swipe.
    private var cancelButton: some View {
        ScrimIconButton(
            systemImage: "xmark", accessibilityLabel: "Cancel", style: .scrim, action: onCancel)
            .accessibilityIdentifier("camera-cancel")
            .screenHeaderItemPlacement()
    }

    private var bottomControls: some View {
        VStack(spacing: 16) {
            if showExposureSlider {
                exposureSlider
            }
            if viewModel.lensOptions.count > 1 {
                lensPillRow
            }
            recordButton
        }
        // The floating tab bar (`RootTabView`) stays visible over this page too, so
        // without this the record button and lens row would sit directly underneath it.
        .padding(.bottom, FloatingTabBarMetrics.clearance)
    }

    private var recordButton: some View {
        Button {
            viewModel.toggleRecording()
        } label: {
            ZStack {
                Circle()
                    .stroke(.white, lineWidth: 4)
                    .frame(width: 74, height: 74)
                RoundedRectangle(cornerRadius: viewModel.isRecording ? 6 : 30)
                    .fill(.red)
                    .frame(
                        width: viewModel.isRecording ? 28 : 60,
                        height: viewModel.isRecording ? 28 : 60)
            }
            .animation(.easeOut(duration: 0.2), value: viewModel.isRecording)
        }
        .padding(.bottom, 24)
        .opacity(viewModel.isFinishingRecording ? 0.4 : 1)
        .disabled(viewModel.isFinishingRecording)
        .accessibilityLabel(viewModel.isRecording ? "Stop recording" : "Start recording")
        .accessibilityIdentifier("camera-record")
    }

    // MARK: - Lens / zoom

    private var lensPillRow: some View {
        HStack(spacing: 10) {
            ForEach(viewModel.lensOptions) { option in
                Button {
                    viewModel.selectLens(option)
                } label: {
                    Text(option.label)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(
                                option.zoomFactor == viewModel.activeLensZoomFactor
                                    ? Color.yellow.opacity(0.9)
                                    : Color.black.opacity(0.4))
                        )
                        // A footnote pill is about 30 pt tall.
                        .touchTarget(insetBy: 7)
                }
                .buttonStyle(.plain)
                // The active lens is otherwise marked only by the yellow fill, which a
                // listener never sees; the trait is what makes "selected" audible.
                .accessibilityAddTraits(
                    option.zoomFactor == viewModel.activeLensZoomFactor ? .isSelected : [])
                .accessibilityIdentifier("camera-lens-\(option.label)")
            }
        }
        .opacity(viewModel.isRecording ? 0.4 : 1)
        .disabled(viewModel.isRecording)
        .accessibilityElement(children: .contain)
    }

    private var pinchZoomGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in viewModel.pinchChanged(byMagnification: value) }
            .onEnded { _ in viewModel.pinchEnded() }
    }

    // MARK: - Top-right controls

    private var topRightControls: some View {
        HStack(spacing: 12) {
            personModeButton
            if viewModel.exposureBiasRange.lowerBound < viewModel.exposureBiasRange.upperBound {
                exposureToggleButton
            }
            if viewModel.isTorchAvailable {
                flashButton
            }
            if !viewModel.formatGroups.isEmpty {
                formatMenu
            }
            if viewModel.hasCaptureDevice {
                flipButton
            }
        }
        .screenHeaderItemPlacement()
    }

    /// Switches whose tricks the take is cut into clips for (`PersonMode`): one figure for the
    /// person the model is surest of, two for everyone. Read at the Record tap, so it is disabled
    /// while recording like the format and flip controls. Needs no capture device, so it shows
    /// whatever the camera has to offer.
    private var personModeButton: some View {
        ScrimIconButton(
            systemImage: settings.personMode == .one ? "person.fill" : "person.2.fill",
            accessibilityLabel: "Clips for",
            style: .scrim,
            action: {
                settings.personMode = settings.personMode == .one ? .everyone : .one
            })
            .accessibilityValue(settings.personMode.label)
            .opacity(viewModel.isRecording ? 0.4 : 1)
            .disabled(viewModel.isRecording)
            .accessibilityIdentifier("camera-person-mode")
    }

    private var exposureToggleButton: some View {
        ScrimIconButton(
            systemImage: showExposureSlider ? "sun.max.fill" : "sun.max",
            accessibilityLabel: "Exposure",
            style: .scrim,
            action: { showExposureSlider.toggle() })
            .accessibilityIdentifier("camera-exposure-toggle")
    }

    private var flashButton: some View {
        ScrimIconButton(
            systemImage: viewModel.isTorchOn ? "bolt.fill" : "bolt.slash.fill",
            accessibilityLabel: viewModel.isTorchOn ? "Turn off flash" : "Turn on flash",
            style: .scrim,
            action: viewModel.toggleTorch)
            .accessibilityIdentifier("camera-flash")
    }

    private var flipButton: some View {
        ScrimIconButton(
            systemImage: "arrow.triangle.2.circlepath.camera",
            accessibilityLabel: "Switch camera",
            style: .scrim,
            action: viewModel.switchCamera)
            .opacity(viewModel.isRecording ? 0.4 : 1)
            .disabled(viewModel.isRecording)
            .accessibilityIdentifier("camera-flip")
    }

    /// Not `ScrimIconButton` here: `Menu`'s `label` closure needs a bare glyph, and
    /// nesting `ScrimIconButton`'s own `Button` inside it would fight `Menu` for the tap.
    /// Mirrors `ScrimIconButton`'s look so it reads as the same control family.
    private var formatMenu: some View {
        Menu {
            Text(viewModel.currentFormatLabel)
            Divider()
            ForEach(viewModel.formatGroups) { group in
                Menu(group.label) {
                    ForEach(group.options) { option in
                        Button("\(option.fps) fps") {
                            viewModel.applyFormat(option)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.4), in: Circle())
        }
        .opacity(viewModel.isRecording ? 0.4 : 1)
        .disabled(viewModel.isRecording)
        .accessibilityLabel("Resolution and frame rate")
        .accessibilityIdentifier("camera-format-menu")
    }

    // MARK: - Exposure

    private var exposureSlider: some View {
        Slider(
            value: Binding(
                get: { viewModel.exposureBias },
                set: { viewModel.setExposureBias($0) }),
            in: viewModel.exposureBiasRange
        )
        .tint(.yellow)
        .padding(.horizontal, 40)
        .accessibilityLabel("Exposure bias")
        .accessibilityIdentifier("camera-exposure-slider")
    }

}

private struct CameraAccessDeniedView: View {
    let restricted: Bool

    var body: some View {
        AccessDeniedStateView(
            systemImage: "camera.fill",
            title: "Turnip needs camera access",
            message: restricted
                ? "Camera access is restricted on this device."
                : "Allow camera and microphone access in Settings to record a trick.",
            restricted: restricted,
            openSettingsIdentifier: "camera-open-settings")
    }
}

extension AVCaptureSession.InterruptionReason {
    /// What the interruption scrim says, in words: the reason enum is a
    /// device-state code, not something to show the user raw.
    var displayMessage: String {
        switch self {
        case .videoDeviceNotAvailableInBackground:
            "Camera paused while the app is in the background"
        case .audioDeviceInUseByAnotherClient:
            "Microphone in use by another app"
        case .videoDeviceInUseByAnotherClient:
            "Camera in use by another app"
        case .videoDeviceNotAvailableWithMultipleForegroundApps:
            "Camera unavailable while another app is in the foreground"
        case .videoDeviceNotAvailableDueToSystemPressure:
            "Camera paused — the device needs to cool down"
        @unknown default:
            "Camera interrupted"
        }
    }
}
