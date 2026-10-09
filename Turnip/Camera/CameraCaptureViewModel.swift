// AVFoundation predates Swift concurrency and isn't Sendable-audited, but its own
// threading contract already guarantees what these calls need: `AVCaptureSession`
// configuration is documented safe from any thread as long as it's bracketed by
// begin/commitConfiguration, which is exactly how `sessionQueue` uses it.
@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// A lens choice exposed to the UI as an "0.5x / 1x / 2x"-style pill. `zoomFactor` is the
/// *raw* `videoZoomFactor` value on the virtual device that activates this physical lens;
/// `label` is the display multiplier derived from it (see
/// `CameraCaptureViewModel.computeLensOptions(for:)`).
struct LensOption: Identifiable, Equatable {
    let id = UUID()
    let label: String
    let zoomFactor: CGFloat
}

/// One resolution+frame-rate combination pulled from `AVCaptureDevice.formats`, plus the
/// `AVCaptureDevice.Format` needed to actually select it — the option list is built from
/// whatever the connected device reports rather than a fixed guess, since availability
/// differs per device and per lens.
struct CameraFormatOption: Identifiable, Equatable {
    let id: String
    let format: AVCaptureDevice.Format
    let width: Int32
    let height: Int32
    let fps: Int

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

/// `CameraFormatOption`s grouped by resolution, for a two-level "resolution -> fps" menu.
struct CameraFormatGroup: Identifiable {
    let id: String
    let label: String
    let options: [CameraFormatOption]
}

/// Backs the camera-recording screen: permission, session lifecycle, recording, and the
/// manual controls (lens/zoom, front/rear flip, resolution/fps, torch, exposure bias).
/// All `AVCaptureSession`/`AVCaptureDevice` mutation past the very first configuration —
/// input swaps, format changes, start/stop — happens on `sessionQueue`, never inline on
/// whatever thread called in, since those are blocking AVFoundation calls that would
/// otherwise stall the UI on every flip/format tap.
@MainActor
final class CameraCaptureViewModel: NSObject, ObservableObject {
    @Published private(set) var authorization: CameraAccessState = .notDetermined
    @Published private(set) var isRecording = false
    /// True from Stop until the take's live results have finished scoring — one inference in
    /// steady state — so the record button cannot start a new take that would cancel them.
    @Published private(set) var isFinishingRecording = false
    @Published var errorMessage: String?
    /// Receives each finished take. Called from here rather than observed on the view: the
    /// hand-off happens after Stop's drain wait, and the user can have swiped away from the
    /// camera page by then. A file that finished writing is always handed on, whatever the
    /// view is doing.
    var onFinished: ((CameraRecording) -> Void)?

    @Published private(set) var hasCaptureDevice = false
    @Published private(set) var lensOptions: [LensOption] = []
    @Published private(set) var zoomFactor: CGFloat = 1
    @Published private(set) var isTorchAvailable = false
    @Published private(set) var isTorchOn = false
    @Published private(set) var exposureBias: Float = 0
    @Published private(set) var exposureBiasRange: ClosedRange<Float> = 0...0
    @Published private(set) var availableFormats: [CameraFormatOption] = []
    @Published private(set) var currentFormatLabel = ""

    let session = AVCaptureSession()

    private let movieOutput = AVCaptureMovieFileOutput()
    private var isConfigured = false
    private var videoDevice: AVCaptureDevice?
    private var videoInput: AVCaptureDeviceInput?
    /// Live-pinch baseline: the zoom factor the device was at when the current pinch
    /// gesture began, so each `onChanged` value (a cumulative magnification since
    /// gesture start) multiplies against a fixed base rather than compounding per frame.
    private var pinchBaseZoomFactor: CGFloat?
    private let sessionQueue = DispatchQueue(label: "com.hoiekim.turnip.camera.session")

    /// The pose scored most recently during the current recording, in capture-device
    /// coordinates (the unrotated sensor picture, which `AVCaptureVideoPreviewLayer` maps onto
    /// the preview for whatever orientation and mirroring it applies). Empty when not
    /// recording. See docs/LIVE_POSE.md.
    @Published private(set) var livePoseKeypoints: [PoseKeypoint] = []

    /// Live pose inference alongside recording (docs/LIVE_POSE.md): a video data output on the
    /// session ahead of the movie output, sampled while the movie output records. `nonisolated`
    /// so the recording delegate, which AVFoundation calls off the main actor, can reach it; the
    /// tap is `Sendable` and does its own locking.
    nonisolated let livePoseTap = LivePoseFrameTap()
    /// The take's roll, written into the file as it records (`RollTrack`): a metadata input
    /// on the session connected to the movie output, sampling gravity between record start
    /// and the output's finish. What the editor's Auto rotate levels an in-app take by.
    nonisolated let rollRecorder = RollTrackRecorder()
    /// Loaded once, when the camera first starts, and reused across recordings. Nil until it
    /// loads, or if the bundled model is missing; recordings made meanwhile skip live pose.
    private var poseModel: MoveNetThunderModel?
    /// The consumer of the last stopped recording while it finishes scoring what was queued.
    /// Leaving the camera cancels it; a new take cannot start until it is done.
    private var drainingLivePose: LivePoseRecording?
    /// The pixel size the current take's keypoints are normalized against, read at record start.
    private var liveRenderedPixelSize: CGSize = .zero
    /// Steps 4-6 over the take's live results, built for the sample rate the take was actually
    /// armed at (see `armedSampleRate` below) — the same `TrickWindowDetector` sustained/quiet
    /// thresholds the file path derives from `TurnipSettings.analysisGranularity`, so a take
    /// scored live and the same take analyzed from the file detect the same tricks. Injected so
    /// the camera can be tested without a real `ProcessingPipeline`; the default is the same
    /// detection the Processing screen runs.
    private let makeDetectClips: (Int) -> ClipDetection
    /// The granularity `armLivePose()` last armed the tap with, read again in `finishLivePose()`
    /// so detection uses the same rate the recording was sampled at even if the setting changed
    /// mid-recording.
    private var armedSampleRate = VideoFrameSampler.targetSamplesPerSecond
    /// Reads the current settings snapshot at the point a setting takes effect (Record tap),
    /// rather than once at init — a change made while the camera tab is already open is picked
    /// up by the next recording. `@MainActor`-typed (not plain, and not `@Sendable`/`async`) so
    /// the default value below — a closure literal that reads the `@MainActor`-isolated
    /// `TurnipSettingsStore.shared` — type-checks: a default argument's closure literal is
    /// nonisolated unless its declared parameter type carries the actor annotation itself: the
    /// enclosing `init` being a member of this `@MainActor` class does not carry over to it.
    /// Every call site (`toggleRecording()`, `armLivePose()`) is already on the main actor, so
    /// calling it is an ordinary synchronous call. Injected so tests can drive both
    /// `AnalysisMode` cases without touching `UserDefaults`.
    private let settingsProvider: @MainActor () -> TurnipSettings

    typealias ClipDetection = @Sendable ([PoseFrameResult], CGSize) -> [ProcessedClip]

    init(
        makeDetectClips: @escaping (Int) -> ClipDetection = { rate in
            ProcessingPipeline(sampleRate: rate).detectClips
        },
        settingsProvider: @escaping @MainActor () -> TurnipSettings = { TurnipSettingsStore.shared.current }
    ) {
        self.makeDetectClips = makeDetectClips
        self.settingsProvider = settingsProvider
    }

    /// Candidate frame rates to probe each format against, rather than only reading off
    /// each range's `maxFrameRate` — a format whose range is (say) 1...30 would otherwise
    /// never offer 24fps even though it's a perfectly valid rate within that range.
    private nonisolated static let candidateFrameRates = [24, 25, 30, 50, 60, 120, 240]

    var formatGroups: [CameraFormatGroup] {
        let grouped = Dictionary(grouping: availableFormats) { "\($0.width)x\($0.height)" }
        return grouped.keys
            .sorted { lhs, rhs in
                let leftArea = (grouped[lhs]?.first).map { Int($0.width) * Int($0.height) } ?? 0
                let rightArea = (grouped[rhs]?.first).map { Int($0.width) * Int($0.height) } ?? 0
                return leftArea > rightArea
            }
            .compactMap { key -> CameraFormatGroup? in
                guard let options = grouped[key]?.sorted(by: { $0.fps < $1.fps }),
                      let first = options.first else { return nil }
                return CameraFormatGroup(id: key, label: "\(first.width) \u{00D7} \(first.height)", options: options)
            }
    }

    /// The lens pill that matches the current zoom factor — the highest-activation lens
    /// at or below `zoomFactor` is the one currently in effect.
    var activeLensZoomFactor: CGFloat {
        lensOptions.filter { $0.zoomFactor <= zoomFactor }.map(\.zoomFactor).max()
            ?? lensOptions.first?.zoomFactor
            ?? 1
    }

    /// Requests camera + microphone access on first launch, then starts the session.
    /// Safe to call again — a second call after a prompt just resumes the session.
    func start() async {
        let videoStatus = AVCaptureDevice.authorizationStatus(for: .video)
        let audioStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        authorization = CameraAccessState(video: videoStatus, audio: audioStatus)
        if authorization == .notDetermined {
            let grantedVideo = await AVCaptureDevice.requestAccess(for: .video)
            let grantedAudio = await AVCaptureDevice.requestAccess(for: .audio)
            authorization = CameraAccessState(
                video: grantedVideo ? .authorized : .denied,
                audio: grantedAudio ? .authorized : .denied)
        }
        guard authorization == .authorized else { return }
        if isConfigured {
            await resumeRunningSession()
            return
        }
        isConfigured = true
        let (device, input) = await configureSessionAndStart()
        videoDevice = device
        videoInput = input
        refreshDeviceCapabilities()
        loadPoseModel()
    }

    /// Also clears `isTorchOn`: torch physically turns off once the session stops
    /// running, so the published state would otherwise claim it's still on.
    func stop() {
        let session = self.session
        sessionQueue.async {
            if session.isRunning {
                session.stopRunning()
            }
        }
        isTorchOn = false
        cancelLivePose()
        rollRecorder.stop()
    }

    /// Starts the roll track's sampling for the take about to record, with the picture
    /// geometry it maps gravity through read now: the movie connection's rotation and which
    /// camera is up, both of which a camera switch changes between takes. Samples are only
    /// appended while the movie output says it is recording.
    private func armRollTrack() {
        guard let movieConnection = movieOutput.connection(with: .video) else { return }
        let movieOutput = self.movieOutput
        rollRecorder.start(
            videoRotationDegrees: LivePoseFrameTap.rotationDegrees(of: movieConnection),
            isFrontCamera: videoDevice?.position == .front,
            isRecording: { movieOutput.isRecording })
    }

    func toggleRecording() {
        if isRecording {
            movieOutput.stopRecording()
        } else {
            guard !isFinishingRecording else { return }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("turnip-recording-\(UUID().uuidString)")
                .appendingPathExtension("mov")
            // Offline mode never arms the tap: `endRecording()` then returns nil, `onFinished`
            // hands on `detectedClips: nil`, and the take lands on Processing's idle state
            // exactly like a tapped gallery tile (docs/UIUX.md § "Camera").
            if settingsProvider().analysisMode == .realTime {
                armLivePose()
            }
            armRollTrack()
            movieOutput.startRecording(to: url, recordingDelegate: self)
            isRecording = true
        }
    }

    // MARK: - Lens / zoom

    func selectLens(_ option: LensOption) {
        guard !isRecording, let device = videoDevice else { return }
        do {
            try device.lockForConfiguration()
            device.ramp(toVideoZoomFactor: option.zoomFactor, withRate: 8)
            device.unlockForConfiguration()
            zoomFactor = option.zoomFactor
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// `magnification` is `MagnificationGesture`'s cumulative value since the gesture
    /// began (not a per-frame delta), so the base zoom is captured once on first call
    /// and every subsequent call multiplies against that same base. Sets
    /// `videoZoomFactor` directly rather than `ramp`ing, for immediate 1:1 pinch feedback.
    func pinchChanged(byMagnification magnification: CGFloat) {
        guard let device = videoDevice else { return }
        let base = pinchBaseZoomFactor ?? device.videoZoomFactor
        pinchBaseZoomFactor = base
        let minZoom = device.minAvailableVideoZoomFactor
        let maxZoom = min(device.maxAvailableVideoZoomFactor, 10)
        let target = min(max(base * magnification, minZoom), maxZoom)
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = target
            device.unlockForConfiguration()
            zoomFactor = target
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func pinchEnded() {
        pinchBaseZoomFactor = nil
    }

    // MARK: - Torch

    func toggleTorch() {
        applyTorch(!isTorchOn)
    }

    /// Torch state lives on the `AVCaptureDevice` instance itself, not the session, so it
    /// doesn't carry over when `switchCamera()` installs a different device — callers
    /// re-apply the desired state explicitly after a swap.
    private func applyTorch(_ isOn: Bool) {
        guard let device = videoDevice, device.hasTorch, device.isTorchAvailable else {
            isTorchOn = false
            return
        }
        do {
            try device.lockForConfiguration()
            device.torchMode = isOn ? .on : .off
            device.unlockForConfiguration()
            isTorchOn = isOn
        } catch {
            isTorchOn = false
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Exposure

    func setExposureBias(_ value: Float) {
        guard let device = videoDevice else { return }
        do {
            try device.lockForConfiguration()
            device.setExposureTargetBias(value) { _ in }
            device.unlockForConfiguration()
            exposureBias = value
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Exposure bias doesn't carry over meaningfully across a device swap (front/rear or
    /// a different physical lens), so the newly installed device is put back to neutral
    /// on both the device and the published UI state, rather than just the UI resetting
    /// while the hardware keeps whatever bias the old device was holding.
    private func resetExposureBias(on device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            device.setExposureTargetBias(0) { _ in }
            device.unlockForConfiguration()
        } catch {
            errorMessage = error.localizedDescription
        }
        exposureBias = 0
    }

    // MARK: - Resolution / frame rate

    /// Sets `activeFormat` before the frame duration, since assigning `activeFormat`
    /// resets any frame-duration override back to the format's own default — the reverse
    /// order would silently drop the chosen frame rate. Assigning `activeFormat` can also
    /// reset the device's zoom back to 1.0, so the zoom factor in effect just before the
    /// change is restored (clamped to the new format's available range) rather than left
    /// to whatever the format reset it to. Runs on `sessionQueue`, and re-checks
    /// `isRecording` there since the caller's own guard can go stale in the gap before
    /// this closure runs.
    func applyFormat(_ option: CameraFormatOption) {
        guard !isRecording, let device = videoDevice else { return }
        let format = option.format
        let fps = option.fps
        let movieOutput = self.movieOutput
        sessionQueue.async {
            guard !movieOutput.isRecording else { return }
            do {
                try device.lockForConfiguration()
                let previousZoom = device.videoZoomFactor
                device.activeFormat = format
                let duration = CMTime(value: 1, timescale: Int32(fps))
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
                let restoredZoom = min(
                    max(previousZoom, device.minAvailableVideoZoomFactor),
                    device.maxAvailableVideoZoomFactor)
                device.videoZoomFactor = restoredZoom
                device.unlockForConfiguration()
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    currentFormatLabel = "\(option.width)\u{00D7}\(option.height) \u{00B7} \(fps)fps"
                    zoomFactor = restoredZoom
                }
            } catch {
                Task { @MainActor [weak self] in
                    self?.errorMessage = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Front / rear switch

    func switchCamera() {
        guard !isRecording, let currentDevice = videoDevice else { return }
        let newPosition: AVCaptureDevice.Position = currentDevice.position == .back ? .front : .back
        guard let newDevice = Self.bestDevice(for: newPosition),
              let newInput = try? AVCaptureDeviceInput(device: newDevice) else { return }
        let wasTorchOn = isTorchOn
        let session = self.session
        let oldInput = videoInput
        let movieOutput = self.movieOutput
        let dataOutput = livePoseTap.output
        sessionQueue.async {
            guard !movieOutput.isRecording else { return }
            session.beginConfiguration()
            if let oldInput {
                session.removeInput(oldInput)
            }
            let added = session.canAddInput(newInput)
            if added {
                session.addInput(newInput)
                // Every newly installed device needs the same seeding the very first
                // device got in `configureSessionAndStart()` — `.inputPriority` has no
                // built-in default, so without this a flip could land on a 4:3
                // photo-oriented format or the wrong lens's full-wide zoom.
                Self.seedDefaultFormat(on: newDevice)
                Self.seedDefaultZoom(on: newDevice)
            } else if let oldInput {
                session.addInput(oldInput)
            }
            session.commitConfiguration()
            guard added else { return }
            Self.applyMirroringPolicy(to: movieOutput)
            Self.applyMirroringPolicy(to: dataOutput)
            Task { @MainActor [weak self] in
                guard let self else { return }
                videoDevice = newDevice
                videoInput = newInput
                refreshDeviceCapabilities()
                applyTorch(wasTorchOn)
                resetExposureBias(on: newDevice)
            }
        }
    }

    // MARK: - Session configuration

    private func resumeRunningSession() async {
        let session = self.session
        await withCheckedContinuation { continuation in
            sessionQueue.async {
                if !session.isRunning {
                    session.startRunning()
                }
                continuation.resume()
            }
        }
    }

    /// One-time session setup: adds the back camera + microphone inputs, the live-pose data
    /// output and the movie output, then starts the session — all on `sessionQueue`, since
    /// `AVCaptureSession` configuration and `startRunning()` are the same kind of blocking
    /// call the rest of this class avoids running on the caller's thread. Uses
    /// `.inputPriority`, not `.high`: a session preset actively manages the device's format
    /// on its own and silently overrides a manually chosen `activeFormat`/frame-duration
    /// (the resolution/fps menu) if left in a preset mode. The data output goes in ahead of
    /// the movie output so the recorder's connection is formed after it.
    /// Puts the roll track's metadata input on the session and connects it to the movie
    /// output, which then records it alongside the video and audio. Inside the session's
    /// configuration, after the movie output is on the session — a connection needs both
    /// ends there. Best-effort: a session that refuses the input or the connection records
    /// takes with no roll track, which the editor treats like an imported video.
    private nonisolated static func addRollTrack(
        from recorder: RollTrackRecorder,
        to session: AVCaptureSession,
        recordingInto movieOutput: AVCaptureMovieFileOutput
    ) {
        guard let input = try? recorder.makeInput(), session.canAddInput(input) else { return }
        session.addInputWithNoConnections(input)
        let connection = AVCaptureConnection(inputPorts: input.ports, output: movieOutput)
        guard session.canAddConnection(connection) else {
            session.removeInput(input)
            return
        }
        session.addConnection(connection)
    }

    private func configureSessionAndStart() async -> (AVCaptureDevice?, AVCaptureDeviceInput?) {
        let session = self.session
        let movieOutput = self.movieOutput
        let dataOutput = livePoseTap.output
        let rollRecorder = self.rollRecorder
        return await withCheckedContinuation { continuation in
            sessionQueue.async {
                session.beginConfiguration()
                session.sessionPreset = .inputPriority
                var resultDevice: AVCaptureDevice?
                var resultInput: AVCaptureDeviceInput?
                if let device = Self.bestDevice(for: .back),
                   let input = try? AVCaptureDeviceInput(device: device),
                   session.canAddInput(input) {
                    session.addInput(input)
                    Self.seedDefaultFormat(on: device)
                    Self.seedDefaultZoom(on: device)
                    resultDevice = device
                    resultInput = input
                }
                if let audioDevice = AVCaptureDevice.default(for: .audio),
                   let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
                   session.canAddInput(audioInput) {
                    session.addInput(audioInput)
                }
                if session.canAddOutput(dataOutput) {
                    session.addOutput(dataOutput)
                }
                if session.canAddOutput(movieOutput) {
                    session.addOutput(movieOutput)
                }
                Self.addRollTrack(from: rollRecorder, to: session, recordingInto: movieOutput)
                session.commitConfiguration()
                Self.applyMirroringPolicy(to: movieOutput)
                Self.applyMirroringPolicy(to: dataOutput)
                session.startRunning()
                continuation.resume(returning: (resultDevice, resultInput))
            }
        }
    }

    private func refreshDeviceCapabilities() {
        guard let device = videoDevice else {
            hasCaptureDevice = false
            lensOptions = []
            zoomFactor = 1
            isTorchAvailable = false
            isTorchOn = false
            exposureBias = 0
            exposureBiasRange = 0...0
            availableFormats = []
            currentFormatLabel = ""
            return
        }
        hasCaptureDevice = true
        lensOptions = Self.computeLensOptions(for: device)
        zoomFactor = device.videoZoomFactor
        isTorchAvailable = device.hasTorch && device.isTorchAvailable
        exposureBias = 0
        exposureBiasRange = device.minExposureTargetBias...device.maxExposureTargetBias
        availableFormats = Self.computeFormatOptions(for: device)
        currentFormatLabel = Self.label(forActiveFormatOf: device)
    }

    /// Prefers the widest available virtual (multi-lens) device, falling back to
    /// progressively narrower virtual devices and finally the single physical wide lens
    /// (no lens-switch capability at all).
    private nonisolated static func bestDevice(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera
        ]
        for type in types {
            if let device = AVCaptureDevice.default(type, for: .video, position: position) {
                return device
            }
        }
        return nil
    }

    /// Preview mirrors the front camera automatically (comfortable "selfie" framing while
    /// shooting), but this app never mirrors the saved file, so exported clips read with
    /// correct orientation — readable text, correct left/right — regardless of which
    /// camera shot them. `isVideoMirroringSupported` is expected true for a camera ->
    /// movie-output connection, but guarded anyway since setting `isVideoMirrored` on an
    /// unsupported connection raises rather than failing silently. Applied to every video
    /// output on the session so frames analyzed live agree with the file left-to-right.
    private nonisolated static func applyMirroringPolicy(to output: AVCaptureOutput) {
        guard let connection = output.connection(with: .video) else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        guard connection.isVideoMirroringSupported else { return }
        connection.isVideoMirrored = false
    }

    /// Picks a plain 1920x1080@30 format so the first recording after launch has a
    /// predictable shape. Needed only because of `.inputPriority`: unlike a session
    /// preset, it has no built-in default, so a fresh device could otherwise hand the
    /// very first recording whatever format `activeFormat` happens to already be set to
    /// (on some devices, a 4:3 photo-oriented one). Best-effort — if no such format
    /// exists, recording proceeds with the device's own default.
    private nonisolated static func seedDefaultFormat(on device: AVCaptureDevice) {
        guard let format = device.formats.first(where: { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dimensions.width == 1920, dimensions.height == 1080 else { return false }
            return format.videoSupportedFrameRateRanges.contains {
                $0.minFrameRate <= 30 && $0.maxFrameRate >= 30
            }
        }) else { return }
        do {
            try device.lockForConfiguration()
            device.activeFormat = format
            let duration = CMTime(value: 1, timescale: 30)
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            device.unlockForConfiguration()
        } catch {}
    }

    /// A fresh virtual (multi-lens) device's raw `videoZoomFactor` starts at 1.0, which
    /// is its *widest* lens (ultra-wide, when present) — without this, the camera would
    /// silently open on 0.5x instead of the expected 1x. Sets the zoom to whatever raw
    /// factor `computeLensOptions` says activates the normal wide lens.
    private nonisolated static func seedDefaultZoom(on device: AVCaptureDevice) {
        let target = defaultZoomFactor(for: device)
        guard target != device.videoZoomFactor else { return }
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = target
            device.unlockForConfiguration()
        } catch {}
    }

    private nonisolated static func defaultZoomFactor(for device: AVCaptureDevice) -> CGFloat {
        computeLensOptions(for: device).first(where: { $0.label == "1x" })?.zoomFactor ?? 1
    }

    /// Derives displayed lens multipliers ("0.5x/1x/2x") from
    /// `virtualDeviceSwitchOverVideoZoomFactors`. A virtual device's raw `videoZoomFactor`
    /// starts at 1.0 for its widest constituent lens and crosses each switch-over factor
    /// to activate the next lens in `constituentDevices`, so lens *i*'s raw activation
    /// factor is 1.0 for the first lens and `switchOverVideoZoomFactors[i - 1]` after
    /// that. The displayed "1x" always means the normal wide lens, whichever raw factor
    /// that lens activates at (1.0 if it's the widest constituent, or the first
    /// switch-over factor if an ultra-wide lens comes before it) — every other lens's
    /// label is its own raw activation factor divided by that baseline.
    private nonisolated static func computeLensOptions(for device: AVCaptureDevice) -> [LensOption] {
        guard device.isVirtualDevice else {
            return [LensOption(label: "1x", zoomFactor: 1)]
        }
        let constituents = device.constituentDevices
        guard !constituents.isEmpty else {
            return [LensOption(label: "1x", zoomFactor: 1)]
        }
        let switchOvers = device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
        var rawFactors: [CGFloat] = [1]
        rawFactors.append(contentsOf: switchOvers)
        let count = min(rawFactors.count, constituents.count)
        guard count > 0 else {
            return [LensOption(label: "1x", zoomFactor: 1)]
        }
        let wideIndex = constituents.firstIndex(where: { $0.deviceType == .builtInWideAngleCamera }) ?? 0
        let baseline = wideIndex < rawFactors.count ? rawFactors[wideIndex] : 1
        return (0..<count).map { index in
            let raw = rawFactors[index]
            let multiplier = baseline > 0 ? raw / baseline : raw
            return LensOption(label: formatMultiplier(multiplier), zoomFactor: raw)
        }
    }

    private nonisolated static func formatMultiplier(_ value: CGFloat) -> String {
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return "\(Int(value))x"
        }
        return String(format: "%.1fx", value)
    }

    /// Built from `device.formats` rather than a fixed list — a virtual multi-lens
    /// device and a single physical lens can expose very different resolution/fps
    /// combinations, so hardcoding "720p/1080p/4K x 24/30/60" would silently claim
    /// options the connected device doesn't actually support (or omit ones it does).
    /// Restricted to plain 16:9 video-range formats: `device.formats` also lists 4:3
    /// photo-oriented formats and multiple pixel-format variants (HDR, binned, etc.) that
    /// would otherwise flood this menu with options this app has no use for.
    private nonisolated static func computeFormatOptions(for device: AVCaptureDevice) -> [CameraFormatOption] {
        var seenIDs = Set<String>()
        var options: [CameraFormatOption] = []
        for format in device.formats {
            let mediaSubType = CMFormatDescriptionGetMediaSubType(format.formatDescription)
            guard mediaSubType == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else { continue }
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dimensions.width > 0, dimensions.height > 0,
                  dimensions.width * 9 == dimensions.height * 16 else { continue }
            for fps in candidateFrameRates {
                let supported = format.videoSupportedFrameRateRanges.contains { range in
                    Double(fps) >= range.minFrameRate - 0.01 && Double(fps) <= range.maxFrameRate + 0.01
                }
                guard supported else { continue }
                let id = "\(dimensions.width)x\(dimensions.height)@\(fps)"
                guard !seenIDs.contains(id) else { continue }
                seenIDs.insert(id)
                options.append(CameraFormatOption(
                    id: id, format: format, width: dimensions.width, height: dimensions.height, fps: fps))
            }
        }
        return options
    }

    private nonisolated static func label(forActiveFormatOf device: AVCaptureDevice) -> String {
        let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        guard let frameRate = activeFrameRate(of: device) else {
            return "\(dimensions.width)\u{00D7}\(dimensions.height)"
        }
        return "\(dimensions.width)\u{00D7}\(dimensions.height) \u{00B7} \(Int(frameRate.rounded()))fps"
    }

    /// The frame rate the device is capturing at, from its active frame duration; nil when the
    /// device reports no duration.
    private nonisolated static func activeFrameRate(of device: AVCaptureDevice) -> Double? {
        let duration = device.activeVideoMinFrameDuration
        guard duration.value > 0 else { return nil }
        return Double(duration.timescale) / Double(duration.value)
    }
}

extension CameraCaptureViewModel: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didStartRecordingTo fileURL: URL,
        from connections: [AVCaptureConnection]
    ) {
        livePoseTap.recordingDidStart()
    }

    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        rollRecorder.stop()
        Task { @MainActor in
            isRecording = false
            livePoseKeypoints = []
            if let error {
                errorMessage = error.localizedDescription
                livePoseTap.cancel()
                return
            }
            isFinishingRecording = true
            let clips = await finishLivePose()
            isFinishingRecording = false
            onFinished?(CameraRecording(fileURL: outputFileURL, detectedClips: clips))
        }
    }
}

// MARK: - Live pose

extension CameraCaptureViewModel {
    /// A missing model is a build problem, not something the user can act on, so it is logged
    /// and recording carries on without live pose rather than raising the camera's alert.
    private func loadPoseModel() {
        guard poseModel == nil else { return }
        Task { [weak self] in
            do {
                let model = try await MoveNetThunderModel.load()
                self?.poseModel = model
            } catch {
                LivePoseLogger.logModelLoadFailure(error)
            }
        }
    }

    /// Record was tapped: give this recording its own consumer, wire its results to the overlay,
    /// and arm the tap. Results reach the overlay in capture-device coordinates — the recording
    /// produces them in the movie output's orientation, and the movie connection's own rotation
    /// undone is the sensor picture the preview layer maps from.
    private func armLivePose() {
        guard let poseModel, let device = videoDevice,
              let dataConnection = livePoseTap.output.connection(with: .video),
              let movieConnection = movieOutput.connection(with: .video) else { return }
        armedSampleRate = settingsProvider().analysisGranularity
        let movieRotation = LivePoseFrameTap.rotationDegrees(of: movieConnection)
        let rotation = LivePoseKeypointRotation.relativeDegrees(
            producer: LivePoseFrameTap.rotationDegrees(of: dataConnection), consumer: movieRotation)
        let toDeviceSpace = LivePoseKeypointRotation.relativeDegrees(producer: movieRotation, consumer: 0)
        let sensor = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        liveRenderedPixelSize = LivePoseCoverage.renderedPixelSize(
            sensorWidth: sensor.width, sensorHeight: sensor.height, movieRotationDegrees: movieRotation)
        let recording = LivePoseRecording(
            inference: { try await poseModel.runInference(on: $0) },
            channel: LivePoseSampleChannel(),
            onResult: { [weak self] result in
                let keypoints = LivePoseKeypointRotation.rotated(result.keypoints, clockwiseDegrees: toDeviceSpace)
                Task { @MainActor in
                    guard let self, self.isRecording else { return }
                    self.livePoseKeypoints = keypoints
                }
            })
        livePoseTap.arm(
            recording: recording,
            preparer: poseModel.inputPreparer,
            frameRate: Self.activeFrameRate(of: device) ?? 30,
            rotationDegrees: rotation,
            sampleRate: armedSampleRate)
    }

    /// The movie output finished. Waits for the consumer to score what is still queued — one
    /// inference in steady state — logs the recording's metrics (where the acceptance gate in
    /// docs/LIVE_POSE.md is read from), and returns the take's clips, with the scored frames,
    /// when live inference covered the whole take. Nil sends the take through Processing: no
    /// live recording ran, the camera was left mid-drain, or coverage fell short.
    private func finishLivePose() async -> DetectedClips? {
        guard let recording = livePoseTap.endRecording() else { return nil }
        drainingLivePose = recording
        let outcome = await recording.outcome()
        LivePoseLogger.log(outcome)
        if drainingLivePose === recording {
            drainingLivePose = nil
        }
        // `armedSampleRate` is what the gate (`LivePoseFrameGate(baseInterval:)` in `armLivePose`)
        // was actually configured with — the same granularity the file path's detector uses — so
        // coverage is checked against the grid the recording actually ran, not the shipped default.
        let interval = 1.0 / Double(armedSampleRate)
        guard LivePoseCoverage.isComplete(outcome, interval: interval) else { return nil }
        return DetectedClips(
            clips: makeDetectClips(armedSampleRate)(outcome.results, liveRenderedPixelSize),
            poseFrames: outcome.results)
    }

    private func cancelLivePose() {
        livePoseTap.cancel()
        drainingLivePose?.cancel(producer: nil)
        drainingLivePose = nil
        livePoseKeypoints = []
    }
}
