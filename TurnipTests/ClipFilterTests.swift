import AVFoundation
import CoreGraphics
import XCTest
@testable import Turnip

// MARK: - Colour

final class LabColorTests: XCTestCase {
    func testConvertsSRGBToLab() {
        let red = LabColor(red: 1, green: 0, blue: 0)
        XCTAssertEqual(red.lightness, 53.24, accuracy: 0.05)
        XCTAssertEqual(red.greenRed, 80.09, accuracy: 0.05)
        XCTAssertEqual(red.blueYellow, 67.20, accuracy: 0.05)

        let white = LabColor(red: 1, green: 1, blue: 1)
        XCTAssertEqual(white.lightness, 100, accuracy: 0.01)
        XCTAssertEqual(white.greenRed, 0, accuracy: 0.01)
        XCTAssertEqual(white.blueYellow, 0, accuracy: 0.01)

        XCTAssertEqual(LabColor(red: 0, green: 0, blue: 0).lightness, 0, accuracy: 0.01)
    }

    /// A swatch shows the colour it was read as, and a colour picked by hand reads back as itself.
    func testRoundTripsThroughCGColor() throws {
        let color = LabColor(red: 0.2, green: 0.5, blue: 0.7)

        let back = try XCTUnwrap(LabColor(color.cgColor))

        XCTAssertLessThan(back.distance(to: color), 0.1)
    }

    /// One shirt in shade and in sun differs mostly in lightness, so lightness counts half.
    func testLightnessCountsHalfAsMuchAsHue() {
        let base = LabColor(lightness: 50, greenRed: 10, blueYellow: 10)

        XCTAssertEqual(
            base.distance(to: LabColor(lightness: 60, greenRed: 10, blueYellow: 10)), 5, accuracy: 0.0001)
        XCTAssertEqual(
            base.distance(to: LabColor(lightness: 50, greenRed: 20, blueYellow: 10)), 10, accuracy: 0.0001)
    }

    /// A logo or an arm across the chest is outvoted by the shirt around it.
    func testMedianIsTakenChannelByChannel() {
        let colors = [
            LabColor(lightness: 10, greenRed: 50, blueYellow: -5),
            LabColor(lightness: 90, greenRed: 0, blueYellow: -4),
            LabColor(lightness: 20, greenRed: 40, blueYellow: 30)
        ]

        XCTAssertEqual(LabColor.median(of: colors), LabColor(lightness: 20, greenRed: 40, blueYellow: -4))
        XCTAssertNil(LabColor.median(of: []))
    }
}

// MARK: - Torso

final class TorsoSampleTests: XCTestCase {
    func testNeedsAllFourCornersOfTheTorso() {
        XCTAssertNotNil(TorsoSample(frame: PoseFixture.body(index: 0, hip: (x: 0.5, y: 0.6))))
        XCTAssertNil(TorsoSample(frame: PoseFixture.body(index: 0, hip: (x: 0.5, y: 0.6), dropped: ["right_hip"])))
    }

    /// The grid sits inside the torso, kept in from the shoulders' edges and above the waistband.
    func testReadsAGridKeptInsideTheTorso() {
        let sample = TorsoSample(
            timestamp: 0, leftShoulder: CGPoint(x: 0.4, y: 0.2), rightShoulder: CGPoint(x: 0.6, y: 0.2),
            leftHip: CGPoint(x: 0.4, y: 0.6), rightHip: CGPoint(x: 0.6, y: 0.6), confidence: 0.9)

        let points = sample.readingPoints

        XCTAssertEqual(points.count, 25)
        XCTAssertEqual(points[0].x, 0.44, accuracy: 0.0001)
        XCTAssertEqual(points[0].y, 0.26, accuracy: 0.0001)
        XCTAssertEqual(points[24].x, 0.56, accuracy: 0.0001)
        XCTAssertEqual(points[24].y, 0.5, accuracy: 0.0001)
        XCTAssertTrue(points.allSatisfy { (0.4...0.6).contains($0.x) && (0.2...0.6).contains($0.y) })
    }

    /// Upright moments first, then the surest, spread out, inside the window, in time order.
    func testPicksUprightSureMomentsSpreadAcrossTheWindow() {
        let frames = [
            torsoFrame(at: 0.5, confidence: 0.99),
            torsoFrame(at: 1.0, confidence: 0.99, isUpright: false),
            torsoFrame(at: 1.1, confidence: 0.9),
            torsoFrame(at: 1.2, confidence: 0.95),
            torsoFrame(at: 1.4, confidence: 0.6),
            torsoFrame(at: 2.0, confidence: 0.7)
        ]

        let picks = TorsoSample.picks(from: frames, in: TrickWindow(startTime: 1, endTime: 3))

        XCTAssertEqual(picks.map(\.timestamp), [1.2, 2.0])
    }

    func testFallsBackToAnInvertedMomentWhenNoneIsUpright() {
        let frames = [torsoFrame(at: 1.0, confidence: 0.9, isUpright: false)]

        XCTAssertEqual(
            TorsoSample.picks(from: frames, in: TrickWindow(startTime: 0, endTime: 2)).map(\.timestamp), [1.0])
    }

    private func torsoFrame(at time: TimeInterval, confidence: Float, isUpright: Bool = true) -> PoseFrameResult {
        let shoulderY: Float = isUpright ? 0.3 : 0.7
        let hipY: Float = isUpright ? 0.6 : 0.4
        let keypoints = [
            PoseKeypoint(name: "left_shoulder", y: shoulderY, x: 0.4, confidence: confidence),
            PoseKeypoint(name: "right_shoulder", y: shoulderY, x: 0.6, confidence: 0.99),
            PoseKeypoint(name: "left_hip", y: hipY, x: 0.42, confidence: 0.99),
            PoseKeypoint(name: "right_hip", y: hipY, x: 0.58, confidence: 0.99)
        ]
        return PoseFrameResult(frameIndex: Int(time * 10), timestamp: time, keypoints: keypoints)
    }
}

final class TorsoColorReaderTests: XCTestCase {
    /// Keypoints are y down from the top of the frame; a reader that took rows bottom-up would
    /// read the legs for the shirt.
    func testReadsPixelsTopDownAsTheKeypointsAre() throws {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        // A context's y runs up: its lower half is the bottom of the image it makes.
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 2))
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 2, width: 4, height: 2))
        let image = try XCTUnwrap(context.makeImage())

        let colors = TorsoColorReader.colors(
            in: image, at: [CGPoint(x: 0.5, y: 0.1), CGPoint(x: 0.5, y: 0.9), CGPoint(x: 1.2, y: 0.5)])

        XCTAssertEqual(colors.count, 2, "a point outside the frame is skipped")
        XCTAssertLessThan(colors[0].distance(to: LabColor(red: 1, green: 0, blue: 0)), 1)
        XCTAssertLessThan(colors[1].distance(to: LabColor(red: 0, green: 0, blue: 1)), 1)
    }
}

// MARK: - Filter rules

final class ClipFilterTests: XCTestCase {
    private let fullFrame = NormalizedRect(minX: 0, maxX: 1, minY: 0, maxY: 1)
    private let red = LabColor(red: 0.8, green: 0.1, blue: 0.1)
    private let blue = LabColor(red: 0.1, green: 0.2, blue: 0.8)

    private func clip(confidence: Float?) -> ClipListItem {
        ClipListItem(window: TrickWindow(startTime: 0, endTime: 2), cropRect: fullFrame, confidence: confidence)
    }

    func testConfidenceHidesTheClipsBelowIt() {
        let filter = ClipFilter(minimumConfidence: 0.5)

        XCTAssertTrue(filter.admits(clip(confidence: 0.5), torsoColor: nil))
        XCTAssertFalse(filter.admits(clip(confidence: 0.49), torsoColor: nil))
        XCTAssertTrue(ClipFilter().admits(clip(confidence: 0), torsoColor: nil), "0 lets every clip through")
    }

    /// The user made a clip added by hand, so no filter hides it, whatever its top.
    func testAClipAddedByHandPassesEveryFilter() {
        let filter = ClipFilter(minimumConfidence: 1, shirtColor: ShirtColorMatch(picked: red))

        XCTAssertTrue(filter.admits(clip(confidence: nil), torsoColor: TorsoColorReading(color: blue)))
        XCTAssertTrue(filter.admits(clip(confidence: nil), torsoColor: TorsoColorReading(color: nil)))
    }

    func testShirtColorKeepsMatchingAndUnreadClipsOnly() {
        let filter = ClipFilter(shirtColor: ShirtColorMatch(picked: red))
        let item = clip(confidence: 0.9)

        XCTAssertTrue(filter.admits(item, torsoColor: TorsoColorReading(color: red)))
        XCTAssertFalse(filter.admits(item, torsoColor: TorsoColorReading(color: blue)))
        XCTAssertFalse(filter.admits(item, torsoColor: TorsoColorReading(color: nil)), "nothing to match")
        XCTAssertTrue(filter.admits(item, torsoColor: nil), "not read yet")
    }

    func testIsActiveWhileEitherFilterIsSet() {
        XCTAssertFalse(ClipFilter().isActive)
        XCTAssertTrue(ClipFilter(minimumConfidence: 0.1).isActive)
        XCTAssertTrue(ClipFilter(shirtColor: ShirtColorMatch(picked: red)).isActive)
    }

    /// Every clip the user picked as theirs matches the colour read from them, however far apart
    /// they are, and one picked clip matches at the default tolerance.
    func testAColourReadFromClipsMatchesEveryOneOfThem() throws {
        // 61 apart, so their median is 30 from each: past the default tolerance.
        let lit = LabColor(lightness: 50, greenRed: 60, blueYellow: 40)
        let shaded = LabColor(lightness: 30, greenRed: 0, blueYellow: 40)
        let sources = [UUID(): lit, UUID(): shaded]

        let match = try XCTUnwrap(ShirtColorMatch(readFrom: sources))

        XCTAssertEqual(match.sourceClipIDs, Set(sources.keys))
        XCTAssertEqual(match.color, LabColor(lightness: 40, greenRed: 30, blueYellow: 40))
        XCTAssertTrue(sources.values.allSatisfy(match.matches))
        XCTAssertGreaterThan(match.tolerance, ShirtColorMatch.defaultTolerance)
        XCTAssertFalse(match.matches(blue))

        let single = try XCTUnwrap(ShirtColorMatch(readFrom: [UUID(): red]))
        XCTAssertEqual(single.tolerance, ShirtColorMatch.defaultTolerance)
        XCTAssertNil(ShirtColorMatch(readFrom: [:]))
    }
}

// MARK: - Confidence

final class DetectionConfidenceTests: XCTestCase {
    private let detector = TrickWindowDetector()

    func testConfidenceIsTheShareOfThePeakPastTheSpeedFloor() {
        let floor = detector.minimumSpeed

        XCTAssertEqual(detector.confidence(peakSpeed: floor), 0)
        XCTAssertEqual(detector.confidence(peakSpeed: floor / 2), 0)
        XCTAssertEqual(detector.confidence(peakSpeed: floor * 2), 0.5, accuracy: 0.0001)
        XCTAssertEqual(detector.confidence(peakSpeed: floor * 4), 0.75, accuracy: 0.0001)
    }

    /// A faster burst is a surer trick: the slow one is someone walking off.
    func testAFasterBurstIsSurer() {
        let speeds: [Float] = Array(repeating: 0, count: 30) + Array(repeating: 5, count: 3)
            + Array(repeating: 0, count: 30) + Array(repeating: 20, count: 3) + Array(repeating: 0, count: 30)
        let samples = speeds.enumerated().map { index, speed in
            MotionSample(
                startTime: Double(index) * PoseFixture.frameInterval,
                endTime: Double(index + 1) * PoseFixture.frameInterval, speed: speed)
        }

        let detected = detector.detect(in: samples)

        XCTAssertEqual(detected.map(\.confidence), [0.5, 0.875])
        XCTAssertEqual(detected.map(\.window), detector.detectWindows(in: samples))
    }

    /// The pipeline's clips carry the confidence Clip List's filter reads.
    func testTheHeuristicsClipsCarryTheirConfidence() {
        let frames = PoseFixture.bodies(hipXPositions: PoseFixture.slide(
            quietFrames: 15, from: 0.2, perFrame: 0.2, movingFrames: 6, tailFrames: 14))

        let clips = ProcessingPipeline().detectClips(in: frames, renderedPixelSize: CGSize(width: 1000, height: 1000))

        XCTAssertEqual(clips.count, 1)
        // 2 torso lengths a frame, 20 a second, against a floor of 2.5.
        XCTAssertEqual(clips.first?.confidence ?? 0, 0.875, accuracy: 0.01)
    }
}

// MARK: - Clip List

/// The tops the fake reader reads, kept outside the main actor so its `@Sendable` closure can
/// reach them.
private let readRed = LabColor(red: 0.8, green: 0.1, blue: 0.1)
private let readBlue = LabColor(red: 0.1, green: 0.2, blue: 0.8)

/// What a fake was asked for, in order.
private actor ReadLog {
    var times: [TimeInterval] = []

    func add(_ time: TimeInterval) {
        times.append(time)
    }
}

@MainActor
final class ClipListFilteringTests: XCTestCase {
    private var fullFrame: NormalizedRect { NormalizedRect(minX: 0, maxX: 1, minY: 0, maxY: 1) }

    private func clip(_ start: TimeInterval, confidence: Float?) -> ClipListItem {
        ClipListItem(
            window: TrickWindow(startTime: start, endTime: start + 2), cropRect: fullFrame, confidence: confidence)
    }

    /// An athlete standing through 25 s, so every clip has its torso to read. The fake reader
    /// reads red before 5 s and from 10 s on, and blue between.
    private func makeViewModel(
        items: [ClipListItem],
        log: ReadLog = ReadLog(),
        exportClip: @escaping ExportOneClip = { _, _, _, _ in URL(fileURLWithPath: "/tmp/fake.mp4") }
    ) -> ClipListViewModel {
        ClipListViewModel(
            items: items,
            poseFrames: (0..<250).map { PoseFixture.body(index: $0, hip: (x: 0.5, y: 0.6)) },
            asset: AVURLAsset(url: URL(fileURLWithPath: "/dev/null")),
            assetIdentifier: "asset-1",
            duration: 30,
            exportClip: exportClip,
            saveToPhotos: { url, _ in url.lastPathComponent },
            recordSaved: { _ in [] },
            storePose: { _, _ in nil },
            readTorsoColor: { samples, _ in
                guard let time = samples.first?.timestamp else { return nil }
                await log.add(time)
                return time < 5 || time >= 10 ? readRed : readBlue
            },
            makeDirectory: {
                FileManager.default.temporaryDirectory
                    .appendingPathComponent("turnip-test-\(UUID().uuidString)", isDirectory: true)
            },
            settingsProvider: { TurnipSettings() },
            announce: { _ in },
            announceAfterScreenChange: { _ in })
    }

    func testTheGridNameClipsAndTheCountsTakeOnlyTheClipsShown() {
        let unsure = clip(0, confidence: 0.2)
        let sure = clip(5, confidence: 0.9)
        let byHand = clip(10, confidence: nil)
        let viewModel = makeViewModel(items: [unsure, sure, byHand])

        viewModel.filter.minimumConfidence = 0.5

        XCTAssertEqual(viewModel.clipsToName.map(\.id), [sure.id, byHand.id])
        XCTAssertEqual(viewModel.allClips.count, 3)
        XCTAssertEqual(viewModel.unsavedClipCount, 2)
        XCTAssertEqual(viewModel.clipPosition(of: sure)?.number, 1)
        XCTAssertEqual(viewModel.clipPosition(of: byHand)?.count, 2)
        XCTAssertNil(viewModel.clipPosition(of: unsure), "a hidden clip has no place on the grid")
        XCTAssertEqual(viewModel.filterableClips.map(\.id), [unsure.id, sure.id])

        viewModel.clearFilter()

        XCTAssertEqual(viewModel.clipsToName.count, 3)
    }

    /// Save Clips writes what the grid shows; a hidden clip stays the video's, unsaved.
    func testSaveLeavesOutTheClipsTheFilterHides() async {
        let exported = ReadLog()
        let viewModel = makeViewModel(
            items: [clip(0, confidence: 0.2), clip(5, confidence: 0.9), clip(10, confidence: nil)],
            exportClip: { spec, _, directory, _ in
                await exported.add(spec.window.startTime)
                return directory.appendingPathComponent("clip.mp4")
            })
        viewModel.filter.minimumConfidence = 0.5

        let saved = await viewModel.save()

        XCTAssertTrue(saved)
        let exportedStarts = await exported.times
        XCTAssertEqual(exportedStarts, [5, 10])
        XCTAssertEqual(viewModel.allClips.map(\.isSaved), [false, true, true])
    }

    /// The clips the confidence filter shows are read first; a clip added by hand never is.
    func testReadsTheShownClipsFirstAndNeverOneAddedByHand() async {
        let log = ReadLog()
        let viewModel = makeViewModel(
            items: [clip(0, confidence: 0.2), clip(5, confidence: 0.9), clip(10, confidence: nil)], log: log)
        viewModel.filter.minimumConfidence = 0.5

        await viewModel.readTorsoColors()

        let reads = await log.times
        XCTAssertEqual(reads.count, 2)
        XCTAssertTrue((5...7).contains(reads[0]), "the shown clip first, read at \(reads[0])")
        XCTAssertTrue((0...2).contains(reads[1]), "then the hidden one, read at \(reads[1])")
        XCTAssertEqual(viewModel.readTorsoColorCount, 2)
    }

    /// Picking a clip keeps the clips of whoever wears its top once they are read, and taking it
    /// back shows every clip again.
    func testPickingAClipKeepsTheClipsOfWhoeverWearsItsTop() async {
        let mine = clip(0, confidence: 0.9)
        let theirs = clip(5, confidence: 0.9)
        let mineAgain = clip(12, confidence: 0.9)
        let byHand = clip(20, confidence: nil)
        let viewModel = makeViewModel(items: [mine, theirs, mineAgain, byHand])

        await viewModel.toggleShirtColorSource(mine)

        XCTAssertTrue(viewModel.isShirtColorSource(mine.id))
        XCTAssertEqual(viewModel.clipsToName.count, 4, "a clip not read yet stays until it is")

        await viewModel.readTorsoColors()

        XCTAssertEqual(viewModel.clipsToName.map(\.id), [mine.id, mineAgain.id, byHand.id])

        await viewModel.toggleShirtColorSource(mine)

        XCTAssertNil(viewModel.filter.shirtColor)
        XCTAssertEqual(viewModel.clipsToName.count, 4)
    }

    /// The colour picker showing the clips' colour hands it back unchanged: the clips stay picked.
    /// A new colour replaces them.
    func testAPickedColourReplacesTheClipsOnlyWhenItIsNew() async throws {
        let mine = clip(0, confidence: 0.9)
        let viewModel = makeViewModel(items: [mine, clip(5, confidence: 0.9)])
        await viewModel.toggleShirtColorSource(mine)
        let shown = try XCTUnwrap(viewModel.filter.shirtColor).color.cgColor

        viewModel.pickShirtColor(shown, shown: shown)

        XCTAssertTrue(viewModel.isShirtColorSource(mine.id))

        viewModel.pickShirtColor(readBlue.cgColor, shown: shown)

        XCTAssertFalse(viewModel.isShirtColorSource(mine.id))
        let picked = try XCTUnwrap(viewModel.filter.shirtColor)
        XCTAssertLessThan(picked.color.distance(to: readBlue), 1)
        XCTAssertEqual(picked.tolerance, ShirtColorMatch.defaultTolerance)
    }

    /// Reading stops with the sheet's task: a reading kept after the sheet has gone could hide a
    /// clip under Name Clips.
    func testACancelledReadKeepsNothing() async {
        let viewModel = makeViewModel(items: [clip(0, confidence: 0.9)])
        let task = Task { await viewModel.readTorsoColors() }
        task.cancel()

        await task.value

        XCTAssertEqual(viewModel.readTorsoColorCount, 0)
    }
}

final class ClipFilterAccessibilityTests: XCTestCase {
    func testSaysHowManyClipsTheFiltersLeave() {
        XCTAssertEqual(ClipListAccessibility.shownClips(shown: 23, total: 97), "23 of 97 clips shown")
        XCTAssertEqual(ClipListAccessibility.shownClips(shown: 0, total: 1), "0 of 1 clip shown")
    }

    func testSaysTheConfidenceSettingAsAPercentOrAny() {
        XCTAssertEqual(ClipListAccessibility.minimumConfidence(0), "Any")
        XCTAssertEqual(ClipListAccessibility.minimumConfidence(0.604), "60% or more")
    }
}
