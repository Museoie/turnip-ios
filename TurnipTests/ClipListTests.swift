import AVFoundation
import CoreGraphics
import SwiftUI
import XCTest
@testable import Turnip

/// Collects what the view model handed to VoiceOver, in order — the order is the assertion.
@MainActor
private final class SpokenAnnouncements {
    var messages: [String] = []
}

final class ClipListTests: XCTestCase {
    private let window = TrickWindow(startTime: 2, endTime: 5)
    private let fullFrame = NormalizedRect(minX: 0, maxX: 1, minY: 0, maxY: 1)

    private func makeItem() -> ClipListItem {
        ClipListItem(window: window, cropRect: fullFrame)
    }

    /// `AVAsset` is abstract and throws at runtime, so the view-model tests use the
    /// concrete `AVURLAsset` subclass. The URL resolves to nothing — these tests never
    /// decode, they only exercise the list and save logic.
    private func dummyAsset() -> AVURLAsset {
        AVURLAsset(url: URL(fileURLWithPath: "/dev/null"))
    }

    /// Builds a view model whose `items[0]` is always the injected original item —
    /// the invariant `ClipListViewModel.init` enforces — followed by `items`. `settingsProvider`
    /// defaults to a plain, deterministic `TurnipSettings()` rather than the production default
    /// (`TurnipSettingsStore.shared.current`), so these tests never touch the real
    /// `UserDefaults.standard`-backed singleton or its state from other tests.
    @MainActor
    private func makeViewModel(
        items: [ClipListItem],
        poseFrames: [PoseFrameResult] = [],
        people: [PoseTrack] = [],
        asset: AVURLAsset? = nil,
        assetIdentifier: String = "asset-1",
        duration: TimeInterval = 30,
        exportClip: @escaping ExportOneClip = { _, _, _, _ in URL(fileURLWithPath: "/tmp/fake.mp4") },
        saveToPhotos: @escaping SaveOneClipToPhotos = { url, _ in url.lastPathComponent },
        recordSaved: @escaping RecordSavedClips = { _ in [] },
        settingsProvider: @escaping @MainActor () -> TurnipSettings = { TurnipSettings() },
        announce: @escaping AccessibilityAnnouncing = { _ in },
        announceAfterScreenChange: AccessibilityAnnouncing? = nil
    ) -> ClipListViewModel {
        ClipListViewModel(
            items: items,
            poseFrames: poseFrames,
            people: people,
            asset: asset ?? dummyAsset(),
            assetIdentifier: assetIdentifier,
            duration: duration,
            exportClip: exportClip,
            saveToPhotos: saveToPhotos,
            recordSaved: recordSaved,
            makeDirectory: {
                FileManager.default.temporaryDirectory
                    .appendingPathComponent("turnip-test-\(UUID().uuidString)", isDirectory: true)
            },
            settingsProvider: settingsProvider,
            announce: announce,
            announceAfterScreenChange: announceAfterScreenChange ?? announce)
    }

    // MARK: - ClipListItem

    func testNewItemsStartUnsaved() {
        XCTAssertFalse(makeItem().isSaved)
    }

    func testDurationLabelShowsOneDecimalSecond() {
        XCTAssertEqual(makeItem().durationLabel, "3.0s")
    }

    func testDurationLabelRoundsToOneDecimal() {
        let item = ClipListItem(
            window: TrickWindow(startTime: 1, endTime: 3.35), cropRect: fullFrame)
        XCTAssertEqual(item.durationLabel, "2.4s")
    }

    // MARK: - ClipListViewModel: the original item

    @MainActor
    func testOriginalItemIsAlwaysFirst() {
        let viewModel = makeViewModel(items: [makeItem(), makeItem()], duration: 12)

        XCTAssertEqual(viewModel.items.count, 3)
        XCTAssertTrue(viewModel.items[0].isOriginal)
        XCTAssertFalse(viewModel.items[1].isOriginal)
        XCTAssertFalse(viewModel.items[2].isOriginal)
    }

    @MainActor
    func testOriginalItemSpansTheFullDuration() {
        let viewModel = makeViewModel(items: [], duration: 12)

        XCTAssertEqual(viewModel.items[0].window, TrickWindow(startTime: 0, endTime: 12))
        XCTAssertEqual(viewModel.items[0].cropRect, fullFrame)
    }

    @MainActor
    func testDeleteNeverRemovesTheOriginalItem() {
        let viewModel = makeViewModel(items: [])
        let originalId = viewModel.items[0].id

        viewModel.delete(originalId)

        XCTAssertEqual(viewModel.items.count, 1)
        XCTAssertTrue(viewModel.items[0].isOriginal)
    }

    // MARK: - Editor destination

    @MainActor
    func testApplyEditorResultReplacesTheMatchingItem() {
        let target = makeItem()
        let other = makeItem()
        let viewModel = makeViewModel(items: [other, target])

        let result = ClipEditorResult(
            window: TrickWindow(startTime: 1, endTime: 4),
            cropRect: NormalizedRect(minX: 0.1, maxX: 0.9, minY: 0.1, maxY: 0.9),
            followCrop: FollowCrop.uniform(
                scale: 1.5, rotationRadians: 0,
                keyframes: [FollowKeyframe(time: 2, center: CGPoint(x: 10, y: 10), autoCenter: nil)],
                restingCenter: CGPoint(x: 10, y: 10), isAutoFollow: false))
        viewModel.applyEditorResult(result, to: target.id)

        // The editor's commit lands on the tapped item — window, crop rect, and follow
        // crop — and leaves the rest of the list alone.
        let updated = viewModel.items[2]
        XCTAssertEqual(updated.id, target.id)
        XCTAssertEqual(updated.window, result.window)
        XCTAssertEqual(updated.cropRect, result.cropRect)
        XCTAssertEqual(updated.followCrop, result.followCrop)
        XCTAssertEqual(viewModel.items[1], other)
    }

    @MainActor
    func testApplyEditorResultIgnoresUnknownIds() {
        let item = makeItem()
        let viewModel = makeViewModel(items: [item])

        viewModel.applyEditorResult(
            ClipEditorResult(
                window: TrickWindow(startTime: 1, endTime: 4),
                cropRect: fullFrame),
            to: makeItem().id)

        XCTAssertEqual(viewModel.items[1], item)
    }

    /// A clip the user retrimmed or recropped is not the clip that landed in Photos, so the
    /// editor's commit has to put it back in Save Clips' queue. Without this, an edit made after a
    /// partial failure would be silently dropped on the retry: the tile would show the new
    /// geometry while the library kept only the pre-edit video.
    @MainActor
    func testApplyEditorResultClearsTheSavedFlag() async {
        let viewModel = makeViewModel(items: [makeItem()])
        let result = await viewModel.save()
        XCTAssertTrue(result)
        XCTAssertTrue(viewModel.items[1].isSaved)

        viewModel.applyEditorResult(
            ClipEditorResult(
                window: TrickWindow(startTime: 1, endTime: 4),
                cropRect: fullFrame),
            to: viewModel.items[1].id)

        XCTAssertFalse(viewModel.items[1].isSaved)
    }

    /// The editor commits on every close, including one where nothing changed. Opening a saved
    /// clip just to watch it must leave it saved, or the retry writes it to Photos a second time.
    @MainActor
    func testApplyEditorResultKeepsTheSavedFlagWhenNothingChanged() async {
        let viewModel = makeViewModel(items: [makeItem()])
        let result = await viewModel.save()
        XCTAssertTrue(result)

        viewModel.applyEditorResult(
            ClipEditorResult(window: window, cropRect: fullFrame),
            to: viewModel.items[1].id)

        XCTAssertTrue(viewModel.items[1].isSaved)
    }

    /// The editor clamps a window that runs past the video's end as it loads, against the
    /// `AVAsset`'s own duration, so an untouched clip like that comes back with a shorter window.
    /// The list is handed the Photos duration, which can differ — here half a second longer —
    /// so the comparison has to clamp against the asset's duration too.
    @MainActor
    func testApplyEditorResultKeepsTheSavedFlagWhenOnlyTheLoadClampMovedTheWindow() async throws {
        let url = try await TestVideoWriter.writeTestVideo(frameCount: 60, width: 64, height: 64, fps: 30)
        defer { try? FileManager.default.removeItem(at: url) }
        let overrunning = ClipListItem(
            window: TrickWindow(startTime: 1, endTime: 4), cropRect: fullFrame)
        let viewModel = makeViewModel(items: [overrunning], asset: AVURLAsset(url: url), duration: 2.5)
        let loaded = await viewModel.assetDuration()
        let assetDuration = try XCTUnwrap(loaded)
        let result = await viewModel.save()
        XCTAssertTrue(result)

        viewModel.applyEditorResult(
            ClipEditorResult(
                window: ClipEditorViewModel.clamped(window: overrunning.window, to: assetDuration),
                cropRect: fullFrame),
            to: viewModel.items[1].id)

        XCTAssertTrue(viewModel.items[1].isSaved)
    }

    /// A crop rect change alone is an edit too.
    @MainActor
    func testApplyEditorResultClearsTheSavedFlagOnACropRectChange() async {
        let viewModel = makeViewModel(items: [makeItem()])
        let result = await viewModel.save()
        XCTAssertTrue(result)

        viewModel.applyEditorResult(
            ClipEditorResult(
                window: window,
                cropRect: NormalizedRect(minX: 0.1, maxX: 0.9, minY: 0.1, maxY: 0.9)),
            to: viewModel.items[1].id)

        XCTAssertFalse(viewModel.items[1].isSaved)
    }

    /// A follow crop change alone — what a drag or a pinch in the editor sets — is an edit too.
    @MainActor
    func testApplyEditorResultClearsTheSavedFlagOnAFollowCropChange() async {
        let viewModel = makeViewModel(items: [makeItem()])
        let result = await viewModel.save()
        XCTAssertTrue(result)

        viewModel.applyEditorResult(
            ClipEditorResult(
                window: window,
                cropRect: fullFrame,
                followCrop: FollowCrop.uniform(
                    scale: 2, rotationRadians: 0,
                    keyframes: [FollowKeyframe(time: 3, center: CGPoint(x: 10, y: 10), autoCenter: nil)],
                    restingCenter: CGPoint(x: 10, y: 10), isAutoFollow: false)),
            to: viewModel.items[1].id)

        XCTAssertFalse(viewModel.items[1].isSaved)
    }

    /// No stale thumbnail after an edit: `thumbnail(for:)` decodes through the real
    /// `ClipThumbnailLoader` against a real one-frame video. The edit changes only
    /// `cropRect` (same window, same midpoint, so the seek target is identical both
    /// times) to a half-width crop — the decoded image's width is the discriminator: a
    /// stale cache hit would keep returning the full-width image, so this passes only
    /// when the second call genuinely re-decodes. With no pose analysis the clip holds the
    /// whole frame, whose poster is the marker's 9:16 box around the crop rect: 64 wide around
    /// the full 64x64 frame, 36 wide around the half-width crop.
    @MainActor
    func testApplyEditorResultInvalidatesTheCachedThumbnail() async throws {
        let url = try await TestVideoWriter.writeTestVideo(frameCount: 1, width: 64, height: 64, fps: 30)
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        let item = ClipListItem(window: TrickWindow(startTime: 0, endTime: 1.0 / 30), cropRect: fullFrame)
        let viewModel = makeViewModel(items: [item], asset: asset, duration: 1.0 / 30)
        let target = viewModel.items[1]

        let beforeImage = await viewModel.thumbnail(for: target)
        let before = try XCTUnwrap(beforeImage)
        XCTAssertEqual(before.width, 64)

        let halfWidth = NormalizedRect(minX: 0, maxX: 0.5, minY: 0, maxY: 1)
        let result = ClipEditorResult(window: item.window, cropRect: halfWidth)
        viewModel.applyEditorResult(result, to: target.id)
        let updated = viewModel.items[1]
        XCTAssertEqual(updated.cropRect, halfWidth)

        let afterImage = await viewModel.thumbnail(for: updated)
        let after = try XCTUnwrap(afterImage)
        XCTAssertEqual(after.width, 36)
    }

    /// Regression for the clip list's live preview player showing the raw, un-cropped,
    /// un-framed source regardless of the item's crop rect or follow crop:
    /// `videoComposition(for:)` — what a tile's loop attaches to its `AVPlayerItem` before
    /// looping — must render at the marker's own size around the crop rect, not the source's,
    /// with the follow crop's center, zoom AND turn actually wired into the layer instruction,
    /// not just the render size. A half-width crop discriminates `renderSize`: an un-composed
    /// player would report the full 64px width. A crop held off-center, zoomed and turned, read
    /// back through `getTransformRamp` as exactly the transform the card's poster draws its
    /// frame with (`ClipThumbnailLoader.followRect` through `ClipExportTransform.make`),
    /// discriminates the layer instruction itself: a future edit that dropped `setTransform`
    /// would leave `renderSize` alone (this test's first assertion would still pass) while
    /// quietly un-cropping or un-rotating both the tile and the exported clip.
    @MainActor
    func testVideoCompositionRendersTheFollowCropAtTheMarkersSize() async throws {
        let url = try await TestVideoWriter.writeTestVideo(frameCount: 1, width: 64, height: 64, fps: 30)
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        let halfWidth = NormalizedRect(minX: 0, maxX: 0.5, minY: 0, maxY: 1)
        let followCrop = FollowCrop(
            keyframes: [], resting: FollowFraming(center: CGPoint(x: 20, y: 30), scale: 1.4, rotationRadians: .pi / 6),
            isAutoFollow: false)
        let item = ClipListItem(
            window: TrickWindow(startTime: 0, endTime: 1.0 / 30), cropRect: halfWidth, followCrop: followCrop)
        let viewModel = makeViewModel(items: [item], asset: asset, duration: 1.0 / 30)
        let target = viewModel.items[1]

        let loadedComposition = await viewModel.videoComposition(for: ClipCardPlaybackGeometry(
            window: target.window, cropRect: target.cropRect, followCrop: target.followCrop))
        let composition = try XCTUnwrap(loadedComposition)

        // The 9:16 marker around a 32x64 crop is 36 wide.
        XCTAssertEqual(composition.renderSize, CGSize(width: 36, height: 64))

        let track = try await asset.loadTracks(withMediaType: .video)[0]
        let naturalSize = try await track.load(.naturalSize)
        let preferredTransform = try await track.load(.preferredTransform)
        let posterRect = try XCTUnwrap(ClipThumbnailLoader.followRect(
            followCrop, at: 0, cropRect: halfWidth, naturalSize: naturalSize, preferredTransform: preferredTransform))
        let expected = try XCTUnwrap(ClipExportTransform.make(
            cropRect: posterRect, naturalSize: naturalSize, preferredTransform: preferredTransform,
            cropAdjustment: CropAdjustment(scale: 1.4, rotationRadians: .pi / 6, offset: .zero)))
        let instruction = try XCTUnwrap(
            composition.instructions.first as? AVMutableVideoCompositionInstruction)
        let layerInstruction = try XCTUnwrap(instruction.layerInstructions.first)
        var start = CGAffineTransform.identity
        var end = CGAffineTransform.identity
        var ramp = CMTimeRange(start: .zero, duration: .zero)
        XCTAssertTrue(layerInstruction.getTransformRamp(for: .zero, start: &start, end: &end, timeRange: &ramp))
        for transform in [start, end] {
            XCTAssertEqual(transform.a, expected.layerTransform.a, accuracy: 1e-9)
            XCTAssertEqual(transform.b, expected.layerTransform.b, accuracy: 1e-9)
            XCTAssertEqual(transform.c, expected.layerTransform.c, accuracy: 1e-9)
            XCTAssertEqual(transform.d, expected.layerTransform.d, accuracy: 1e-9)
            XCTAssertEqual(transform.tx, expected.layerTransform.tx, accuracy: 1e-6)
            XCTAssertEqual(transform.ty, expected.layerTransform.ty, accuracy: 1e-6)
        }
    }

    /// `dummyAsset()` resolves to nothing, so the track load `videoComposition(for:)` depends
    /// on fails — this must return `nil` rather than throw or hang, so a tile's loop can fall
    /// back to an uncomposed player.
    @MainActor
    func testVideoCompositionIsNilWhenTheTrackCannotBeLoaded() async {
        let item = makeItem()
        let viewModel = makeViewModel(items: [item])
        let target = viewModel.items[1]

        let composition = await viewModel.videoComposition(for: ClipCardPlaybackGeometry(
            window: target.window, cropRect: target.cropRect, followCrop: target.followCrop))

        XCTAssertNil(composition)
    }

    // MARK: - clipCardPlaybackNeedsRebuild
    //
    // Covers the rebuild-decision logic in isolation, not the surrounding `ClipCardView`
    // lifecycle it's called from: `ClipCardView` is a private `View` with no
    // view-hosting harness for a host-app unit test, and a UI test can't read an
    // `AVPlayerLooper`'s `CMTimeRange` across the XCUITest process boundary to assert
    // which range is actually looping.

    private func makePlaybackGeometry(
        window: TrickWindow? = nil,
        cropRect: NormalizedRect? = nil,
        followCrop: FollowCrop? = nil
    ) -> ClipCardPlaybackGeometry {
        ClipCardPlaybackGeometry(
            window: window ?? self.window, cropRect: cropRect ?? fullFrame, followCrop: followCrop)
    }

    func testPlaybackNeedsRebuildWhenTheBuiltWindowDiffersFromTarget() {
        let builtFor = makePlaybackGeometry(window: TrickWindow(startTime: 0, endTime: 2))
        let target = makePlaybackGeometry(window: TrickWindow(startTime: 1, endTime: 3))

        XCTAssertTrue(clipCardPlaybackNeedsRebuild(builtFor: builtFor, target: target))
    }

    /// A follow-crop edit alone (same window) needs a new `videoComposition`, not just a
    /// resumed player: a gate that compared only the window would leave the live tile playing
    /// the pre-edit framing indefinitely.
    func testPlaybackNeedsRebuildWhenOnlyTheFollowCropDiffersFromTarget() {
        let builtFor = makePlaybackGeometry()
        let target = makePlaybackGeometry(followCrop: FollowCrop(
            keyframes: [], resting: FollowFraming(center: CGPoint(x: 10, y: 10), scale: 1.5, rotationRadians: 0),
            isAutoFollow: false))

        XCTAssertTrue(clipCardPlaybackNeedsRebuild(builtFor: builtFor, target: target))
    }

    func testPlaybackNeedsRebuildWhenOnlyTheCropRectDiffersFromTarget() {
        let builtFor = makePlaybackGeometry()
        let target = makePlaybackGeometry(
            cropRect: NormalizedRect(minX: 0.1, maxX: 0.9, minY: 0.1, maxY: 0.9))

        XCTAssertTrue(clipCardPlaybackNeedsRebuild(builtFor: builtFor, target: target))
    }

    func testPlaybackDoesNotNeedRebuildWhenTheBuiltGeometryMatchesTarget() {
        let geometry = makePlaybackGeometry()

        XCTAssertFalse(clipCardPlaybackNeedsRebuild(builtFor: geometry, target: geometry))
    }

    func testPlaybackDoesNotNeedRebuildWhenNothingHasBeenBuiltYet() {
        let target = makePlaybackGeometry()

        XCTAssertFalse(clipCardPlaybackNeedsRebuild(builtFor: nil, target: target))
    }

    @MainActor
    func testDeleteRemovesTheMatchingItem() {
        let target = makeItem()
        let other = makeItem()
        let viewModel = makeViewModel(items: [other, target])

        viewModel.delete(target.id)

        XCTAssertEqual(viewModel.items[1], other)
        XCTAssertEqual(viewModel.items.count, 2)
    }

    @MainActor
    func testDeleteIgnoresUnknownIds() {
        let item = makeItem()
        let viewModel = makeViewModel(items: [item])

        viewModel.delete(makeItem().id)

        XCTAssertEqual(viewModel.items[1], item)
    }

    @MainActor
    func testEditorSourceCarriesTheItemAndAsset() {
        let asset = dummyAsset()
        let item = makeItem()
        let viewModel = makeViewModel(items: [item], asset: asset)

        let source = viewModel.editorSource(for: item)

        XCTAssertEqual(source.window, item.window)
        XCTAssertEqual(source.cropRect, item.cropRect)
        XCTAssertEqual(source.followCrop, item.followCrop)
        XCTAssertTrue(source.asset === asset)
    }

    /// The video's scored frames reach the editor whole — not just the item's window's —
    /// since a trim can pull frames outside the window into the crop, and Auto follow has
    /// nothing to fit without them.
    @MainActor
    func testEditorSourceCarriesTheVideosPoseFrames() {
        let frames = PoseFixture.frames(hipXPositions: [0.3, 0.4, 0.5, 0.6])
        let item = makeItem()
        let viewModel = makeViewModel(items: [item], poseFrames: frames)

        let source = viewModel.editorSource(for: item)

        XCTAssertEqual(source.poseFrames, frames)
    }

    /// A clip found following everyone opens on its own person's frames, so Auto follow fits that
    /// person; a clip without a person still gets every scored frame.
    @MainActor
    func testEditorSourceCarriesTheClipsOwnPersonsFrames() {
        let everyFrame = PoseFixture.frames(hipXPositions: [0.3, 0.4, 0.5, 0.6])
        let person = PoseTrack(id: 4, frames: PoseFixture.frames(hipXPositions: [0.8, 0.8]))
        let theirs = ClipListItem(window: window, cropRect: fullFrame, personID: 4)
        let nobodys = makeItem()
        let viewModel = makeViewModel(items: [theirs, nobodys], poseFrames: everyFrame, people: [person])

        XCTAssertEqual(viewModel.editorSource(for: theirs).poseFrames, person.frames)
        XCTAssertEqual(viewModel.editorSource(for: nobodys).poseFrames, everyFrame)
    }

    /// The editor's commit keeps the clip's person, so a reopened clip still fits its own person.
    @MainActor
    func testApplyingAnEditorResultKeepsTheClipsPerson() throws {
        let item = ClipListItem(window: window, cropRect: fullFrame, personID: 2)
        let viewModel = makeViewModel(items: [item])

        viewModel.applyEditorResult(
            ClipEditorResult(window: window, cropRect: fullFrame), to: item.id)

        XCTAssertEqual(try XCTUnwrap(viewModel.items.last).personID, 2)
    }

    // MARK: - save()

    @MainActor
    func testSaveExportsAndSavesEveryDerivedClip() async {
        actor Recorder {
            var exportedWindows: [TrickWindow] = []
            var savedURLs: [URL] = []
            func recordExport(_ window: TrickWindow) { exportedWindows.append(window) }
            func recordSave(_ url: URL) { savedURLs.append(url) }
        }
        let recorder = Recorder()
        let first = makeItem()
        let second = ClipListItem(window: TrickWindow(startTime: 8, endTime: 10), cropRect: fullFrame)
        let viewModel = makeViewModel(
            items: [first, second],
            exportClip: { spec, _, directory, _ in
                await recorder.recordExport(spec.window)
                return directory.appendingPathComponent("\(UUID().uuidString).mp4")
            },
            saveToPhotos: { url, _ in
                await recorder.recordSave(url)
                return url.lastPathComponent
            })

        let result = await viewModel.save()

        XCTAssertTrue(result)
        let windows = await recorder.exportedWindows
        XCTAssertEqual(windows, [first.window, second.window])
        let saved = await recorder.savedURLs
        XCTAssertEqual(saved.count, 2)
        XCTAssertNil(viewModel.saveFailureMessage)
    }

    /// The Settings screen's album destination reaches `saveToPhotos` — this is the one place
    /// the setting takes effect, so the wiring needs a test that would fail if
    /// `settingsProvider().albumDestination` were dropped on the way to the save call, the way a
    /// stub discarding the argument would let happen silently.
    @MainActor
    func testSaveThreadsTheConfiguredAlbumDestinationToEveryPhotosSave() async {
        actor Recorder {
            var albumTitles: [String?] = []
            func record(_ title: String?) { albumTitles.append(title) }
        }
        let recorder = Recorder()
        let viewModel = makeViewModel(
            items: [makeItem()],
            saveToPhotos: { url, albumTitle in
                await recorder.record(albumTitle)
                return url.lastPathComponent
            },
            settingsProvider: { TurnipSettings(autoAddToAlbum: true, albumName: "Tricking Sessions") })

        _ = await viewModel.save()

        let titles = await recorder.albumTitles
        XCTAssertEqual(titles, ["Tricking Sessions"])
    }

    /// The off default (`TurnipSettings()`, what every other `save()` test in this file uses)
    /// must reach `saveToPhotos` as `nil`, not merely be "not on" — a mutation that hardcoded a
    /// non-nil title would still pass every test above that ignores the argument.
    @MainActor
    func testSaveThreadsNilAlbumDestinationWhenTheSettingIsOff() async {
        actor Recorder {
            var albumTitles: [String?] = []
            func record(_ title: String?) { albumTitles.append(title) }
        }
        let recorder = Recorder()
        let viewModel = makeViewModel(
            items: [makeItem()],
            saveToPhotos: { url, albumTitle in
                await recorder.record(albumTitle)
                return url.lastPathComponent
            })

        _ = await viewModel.save()

        let titles = await recorder.albumTitles
        XCTAssertEqual(titles, [nil])
    }

    @MainActor
    func testSaveNeverExportsTheOriginalItem() async {
        actor Recorder {
            var exportCount = 0
            func increment() { exportCount += 1 }
        }
        let recorder = Recorder()
        let viewModel = makeViewModel(
            items: [],
            exportClip: { _, _, directory, _ in
                await recorder.increment()
                return directory.appendingPathComponent("clip.mp4")
            })

        _ = await viewModel.save()

        let count = await recorder.exportCount
        XCTAssertEqual(count, 0)
    }

    @MainActor
    func testSaveReportsExportFailureReason() async {
        let viewModel = makeViewModel(
            items: [makeItem()],
            exportClip: { _, _, _, _ in throw ClipSaveError.exportFailed(reason: "boom") })

        let result = await viewModel.save()

        XCTAssertFalse(result)
        XCTAssertEqual(viewModel.saveFailureMessage, "Export failed — boom")
    }

    @MainActor
    func testSaveReportsPhotosSaveFailureReason() async {
        let viewModel = makeViewModel(
            items: [makeItem()],
            saveToPhotos: { _, _ in throw ClipSaveError.photosSaveFailed(reason: "denied") })

        let result = await viewModel.save()

        XCTAssertFalse(result)
        XCTAssertEqual(viewModel.saveFailureMessage, "Couldn't save to Photos — denied")
    }

    // MARK: - Accessibility

    /// The card label counts off detected clips, and the original is not one of them — an
    /// off-by-one here reads as "Clip 2 of 3" on the third clip and nothing crashes.
    @MainActor
    func testClipPositionCountsOnlyTheDetectedClips() {
        let clips = [makeItem(), makeItem(), makeItem()]
        let viewModel = makeViewModel(items: clips)

        XCTAssertNil(viewModel.clipPosition(of: viewModel.items[0]), "the original has no position")
        XCTAssertEqual(viewModel.clipPosition(of: viewModel.items[1])?.number, 1)
        XCTAssertEqual(viewModel.clipPosition(of: viewModel.items[3])?.number, 3)
        XCTAssertEqual(viewModel.clipPosition(of: viewModel.items[2])?.count, 3)
    }

    /// What Save Clips announces and what it does read off the same count, so counting the
    /// original would promise a clip that never saves.
    @MainActor
    func testUnsavedClipCountLeavesOutTheOriginal() {
        let viewModel = makeViewModel(items: [makeItem(), makeItem()])

        XCTAssertEqual(viewModel.unsavedClipCount, 2, "the original is not one of the clips")
    }

    /// A retry writes only the clips still missing from Photos, so the button's count and the
    /// spoken start describe that run, while a failure keeps the number of the card it names.
    @MainActor
    func testARetryCountsOnlyTheClipsStillMissingFromPhotos() async {
        let spoken = SpokenAnnouncements()
        let doomed = TrickWindow(startTime: 5, endTime: 7)
        let viewModel = makeViewModel(
            items: [
                ClipListItem(window: TrickWindow(startTime: 0, endTime: 2), cropRect: fullFrame),
                ClipListItem(window: doomed, cropRect: fullFrame),
                ClipListItem(window: TrickWindow(startTime: 10, endTime: 12), cropRect: fullFrame)
            ],
            exportClip: { spec, _, directory, _ in
                if spec.window == doomed {
                    throw ClipSaveError.exportFailed(reason: "always")
                }
                return directory.appendingPathComponent("clip-\(Int(spec.window.startTime)).mp4")
            },
            announce: { spoken.messages.append($0) })

        let first = await viewModel.save()
        XCTAssertFalse(first)
        XCTAssertEqual(viewModel.saveFailureMessage, "Clip 2 of 3: Export failed — always")
        XCTAssertEqual(viewModel.unsavedClipCount, 1)

        viewModel.saveFailureMessage = nil
        let second = await viewModel.save()

        XCTAssertFalse(second)
        XCTAssertEqual(
            viewModel.saveFailureMessage, "Clip 2 of 3: Export failed — always",
            "the number is the failed card's, which the retry's own count of one would lose")
        XCTAssertEqual(spoken.messages, ["Saving 3 clips to Photos", "Saving 1 clip to Photos"])
    }

    /// The saving overlay is a spinner over a disabled grid and the screen then pops to Home,
    /// so without these two announcements a listener gets no signal that Save Clips did anything.
    @MainActor
    func testSaveSpeaksItsStartAndItsCompletionWithTheCount() async {
        let spoken = SpokenAnnouncements()
        let viewModel = makeViewModel(
            items: [makeItem(), makeItem()],
            announce: { spoken.messages.append($0) })

        let result = await viewModel.save()

        XCTAssertTrue(result)
        XCTAssertEqual(
            spoken.messages, ["Saving 2 clips to Photos", "Saved 2 clips to Photos"])
    }

    /// The start is spoken in place, but the completion lands as the screen pops to Home, which
    /// is when VoiceOver drops an announcement — so it goes out once the screen has settled.
    @MainActor
    func testSaveCompletionWaitsOutTheScreenChange() async {
        let spokenNow = SpokenAnnouncements()
        let spokenAfter = SpokenAnnouncements()
        let viewModel = makeViewModel(
            items: [makeItem()],
            announce: { spokenNow.messages.append($0) },
            announceAfterScreenChange: { spokenAfter.messages.append($0) })

        let result = await viewModel.save()

        XCTAssertTrue(result)
        XCTAssertEqual(spokenNow.messages, ["Saving 1 clip to Photos"])
        XCTAssertEqual(spokenAfter.messages, ["Saved 1 clip to Photos"])
    }

    /// The zero-tricks notice appears as the Clip List is pushed, so it is spoken after the push.
    @MainActor
    func testNoTricksNoticeIsSpokenAfterTheScreenChange() {
        let spokenNow = SpokenAnnouncements()
        let spokenAfter = SpokenAnnouncements()
        let viewModel = makeViewModel(
            items: [],
            announce: { spokenNow.messages.append($0) },
            announceAfterScreenChange: { spokenAfter.messages.append($0) })

        viewModel.announceNoTricksFound()

        XCTAssertEqual(spokenNow.messages, [])
        XCTAssertEqual(spokenAfter.messages, ["No tricks found"])
    }

    /// A run with nothing to write — no tricks found, or every clip discarded — still pops to
    /// Home, and "Saving 0 clips to Photos" would announce work that is not happening.
    @MainActor
    func testASaveWithNoClipsSpeaksNothing() async {
        let spoken = SpokenAnnouncements()
        let viewModel = makeViewModel(items: [], announce: { spoken.messages.append($0) })

        let result = await viewModel.save()

        XCTAssertTrue(result)
        XCTAssertEqual(spoken.messages, [])
    }

    /// A failed run must not claim it saved anything — the alert carries the reason, and the
    /// completion announcement is what would otherwise contradict it.
    @MainActor
    func testAFailedSaveNeverSpeaksCompletion() async {
        let spoken = SpokenAnnouncements()
        let viewModel = makeViewModel(
            items: [makeItem()],
            exportClip: { _, _, _, _ in throw ClipSaveError.exportFailed(reason: "boom") },
            announce: { spoken.messages.append($0) })

        let result = await viewModel.save()

        XCTAssertFalse(result)
        XCTAssertEqual(spoken.messages, ["Saving 1 clip to Photos"])
    }

    /// Failures from one run arrive together, so each names the clip it belongs to once the
    /// run holds more than one.
    @MainActor
    func testFailuresFromAMultiClipRunNameTheirClip() async {
        let viewModel = makeViewModel(
            items: [makeItem(), makeItem()],
            exportClip: { _, _, _, _ in throw ClipSaveError.exportFailed(reason: "boom") })

        let result = await viewModel.save()

        XCTAssertFalse(result)
        XCTAssertEqual(
            viewModel.saveFailureMessage,
            "Clip 1 of 2: Export failed — boom\nClip 2 of 2: Export failed — boom")
    }

    /// A retried Save Clips must not duplicate any healthy clip: `save()` selects by a
    /// predicate over `items`, so without a record of what already landed, the second tap
    /// would re-export and re-write the clips that had succeeded — one extra copy of each per
    /// attempt, and a Photos asset the app wrote is not one it can take back. The middle clip
    /// fails on every attempt, which is the case the docstring's retry advice invites.
    @MainActor
    func testRetriedSaveNeverWritesAnAlreadyLandedClipToPhotosTwice() async {
        actor Recorder {
            var exportedWindows: [TrickWindow] = []
            var savedNames: [String] = []
            func recordExport(_ window: TrickWindow) { exportedWindows.append(window) }
            func recordSave(_ name: String) { savedNames.append(name) }
        }
        let recorder = Recorder()
        let doomed = TrickWindow(startTime: 5, endTime: 7)
        let viewModel = makeViewModel(
            items: [
                ClipListItem(window: TrickWindow(startTime: 0, endTime: 2), cropRect: fullFrame),
                ClipListItem(window: doomed, cropRect: fullFrame),
                ClipListItem(window: TrickWindow(startTime: 10, endTime: 12), cropRect: fullFrame)
            ],
            exportClip: { spec, _, directory, _ in
                await recorder.recordExport(spec.window)
                if spec.window == doomed {
                    throw ClipSaveError.exportFailed(reason: "always")
                }
                return directory.appendingPathComponent("clip-\(Int(spec.window.startTime)).mp4")
            },
            saveToPhotos: { url, _ in
                await recorder.recordSave(url.lastPathComponent)
                return url.lastPathComponent
            })

        let first = await viewModel.save()
        XCTAssertFalse(first)
        // What the screen's alert does on OK; `save()` itself never reads it.
        viewModel.saveFailureMessage = nil
        let second = await viewModel.save()

        XCTAssertFalse(second)
        let savedNames = await recorder.savedNames
        XCTAssertEqual(savedNames, ["clip-0.mp4", "clip-10.mp4"])
        // The retry re-attempts only the clip still missing from the library — the healthy
        // two are not even re-exported, so the retry costs one export instead of three.
        let exportedWindows = await recorder.exportedWindows
        XCTAssertEqual(exportedWindows.filter { $0 == doomed }.count, 2)
        XCTAssertEqual(exportedWindows.count, 4)
    }

    @MainActor
    func testSaveMarksTheClipsThatLandedAndLeavesTheFailedOneUnmarked() async {
        let doomed = TrickWindow(startTime: 5, endTime: 7)
        let viewModel = makeViewModel(
            items: [
                ClipListItem(window: TrickWindow(startTime: 0, endTime: 2), cropRect: fullFrame),
                ClipListItem(window: doomed, cropRect: fullFrame)
            ],
            exportClip: { spec, _, directory, _ in
                if spec.window == doomed { throw ClipSaveError.exportFailed(reason: "always") }
                return directory.appendingPathComponent("clip.mp4")
            })

        let result = await viewModel.save()

        XCTAssertFalse(result)
        XCTAssertTrue(viewModel.items[1].isSaved)
        XCTAssertFalse(viewModel.items[2].isSaved)
        // The original is never exported as a clip, so it never carries the flag either.
        XCTAssertFalse(viewModel.items[0].isSaved)
    }

    /// Skipping the already-landed clips must not cost the retry its own success: once the
    /// last missing clip lands, `failures` is empty and the run has to behave exactly like a
    /// clean first Save Clips — pop to Home.
    @MainActor
    func testRetriedSaveSucceedsOnceTheLastClipLands() async {
        actor Flake {
            private var failuresLeft: Int
            init(failuresLeft: Int) { self.failuresLeft = failuresLeft }
            func shouldFail() -> Bool {
                guard failuresLeft > 0 else { return false }
                failuresLeft -= 1
                return true
            }
        }
        actor Recorder {
            var savedNames: [String] = []
            func recordSave(_ name: String) { savedNames.append(name) }
        }
        let flake = Flake(failuresLeft: 1)
        let recorder = Recorder()
        let flaky = TrickWindow(startTime: 5, endTime: 7)
        let viewModel = makeViewModel(
            items: [
                ClipListItem(window: TrickWindow(startTime: 0, endTime: 2), cropRect: fullFrame),
                ClipListItem(window: flaky, cropRect: fullFrame)
            ],
            exportClip: { spec, _, directory, _ in
                if spec.window == flaky, await flake.shouldFail() {
                    throw ClipSaveError.exportFailed(reason: "once")
                }
                return directory.appendingPathComponent("clip-\(Int(spec.window.startTime)).mp4")
            },
            saveToPhotos: { url, _ in
                await recorder.recordSave(url.lastPathComponent)
                return url.lastPathComponent
            })

        let first = await viewModel.save()
        XCTAssertFalse(first)

        viewModel.saveFailureMessage = nil
        let second = await viewModel.save()

        XCTAssertTrue(second)
        let savedNames = await recorder.savedNames
        XCTAssertEqual(savedNames, ["clip-0.mp4", "clip-5.mp4"])
    }

    @MainActor
    func testSaveIgnoresReentrantCallsWhileAlreadySaving() async {
        actor Gate {
            private var continuation: CheckedContinuation<Void, Never>?
            func wait() async { await withCheckedContinuation { continuation = $0 } }
            func open() { continuation?.resume(); continuation = nil }
        }
        let gate = Gate()
        let viewModel = makeViewModel(
            items: [makeItem()],
            exportClip: { _, _, directory, _ in
                await gate.wait()
                return directory.appendingPathComponent("clip.mp4")
            })

        async let first = viewModel.save()
        // Give the first call a moment to set `isSaving` before the second races it.
        try? await Task.sleep(nanoseconds: 20_000_000)
        let second = await viewModel.save()
        await gate.open()

        XCTAssertFalse(second)
        _ = await first
    }

    // MARK: - Follow

    private let followedWindow = TrickWindow(startTime: 0, endTime: 3)

    private func detectedItem(window: TrickWindow? = nil) -> ClipListItem {
        ClipListItem(window: window ?? followedWindow, cropRect: fullFrame)
    }

    /// An athlete crossing the frame left to right, sampled every 0.1 s from `firstIndex`.
    private func crossingAthlete(from firstIndex: Int = 0) -> [PoseFrameResult] {
        (firstIndex..<(firstIndex + 30)).map { index in
            let x: Float = 0.2 + 0.02 * Float(index - firstIndex)
            return PoseFixture.frame(index: index, hip: (x: x, y: 0.6), upperBody: (x: x, y: 0.3))
        }
    }

    private func standingAthlete() -> [PoseFrameResult] {
        (0..<30).map { PoseFixture.frame(index: $0, hip: (x: 0.5, y: 0.6), upperBody: (x: 0.5, y: 0.3)) }
    }

    private func writeFollowVideo(seconds: Int = 3) async throws -> URL {
        try await TestVideoWriter.writeTestVideo(frameCount: seconds * 30, width: 64, height: 36, fps: 30)
    }

    @MainActor
    private func followViewModel(
        items: [ClipListItem], poseFrames: [PoseFrameResult], url: URL,
        exportClip: @escaping ExportOneClip = { _, _, _, _ in URL(fileURLWithPath: "/tmp/fake.mp4") }
    ) -> ClipListViewModel {
        makeViewModel(
            items: items, poseFrames: poseFrames, asset: AVURLAsset(url: url), duration: 3, exportClip: exportClip)
    }

    /// A detected clip draws Auto follow's crop until the editor gives it one of its own.
    @MainActor
    func testADetectedClipStartsWithoutAFollowCropOfItsOwn() async throws {
        let url = try await writeFollowVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let viewModel = followViewModel(items: [detectedItem()], poseFrames: crossingAthlete(), url: url)

        XCTAssertNil(viewModel.items[1].followCrop)
    }

    /// Without pose analysis there is nothing for Auto follow to fit: the clip holds the whole
    /// frame with no keyframes.
    @MainActor
    func testAClipWithoutPoseFollowsTheWholeFrameHeldStill() async throws {
        let url = try await writeFollowVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let viewModel = followViewModel(items: [detectedItem()], poseFrames: [], url: url)

        let drawn = await viewModel.followCrop(for: viewModel.items[1])

        XCTAssertEqual(drawn?.keyframes.count, 0)
    }

    /// A "+" clip draws Auto follow's crop like every other.
    @MainActor
    func testAHandAddedClipDrawsAutoFollows() async throws {
        let url = try await writeFollowVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let viewModel = followViewModel(items: [detectedItem()], poseFrames: crossingAthlete(), url: url)

        await viewModel.addClip()

        XCTAssertNil(viewModel.items[2].followCrop)
        let drawn = await viewModel.followCrop(for: viewModel.items[2])
        XCTAssertEqual(drawn?.isAutoFollow, true)
    }

    /// A clip with no follow crop of its own draws Auto follow's for its window: a few
    /// keyframes, not one per pose sample, marked as Auto follow's.
    @MainActor
    func testAClipWithoutACropDrawsAutoFollows() async throws {
        let url = try await writeFollowVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let viewModel = followViewModel(items: [detectedItem()], poseFrames: crossingAthlete(), url: url)

        let drawn = await viewModel.followCrop(for: viewModel.items[1])

        let crop = try XCTUnwrap(drawn)
        XCTAssertTrue(crop.isAutoFollow)
        XCTAssertTrue(crop.isUntouchedAutoFollow)
        XCTAssertGreaterThanOrEqual(crop.keyframes.count, 2)
        XCTAssertLessThan(crop.keyframes.count, 30)
        let first = try XCTUnwrap(crop.keyframes.first), last = try XCTUnwrap(crop.keyframes.last)
        XCTAssertLessThan(first.center.x, last.center.x, "the crop should move the way the athlete does")
    }

    /// An athlete who stays put has nothing to follow: the crop holds one framing.
    @MainActor
    func testAnAthleteWhoStaysPutGetsOneKeyframe() async throws {
        let url = try await writeFollowVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let viewModel = followViewModel(items: [detectedItem()], poseFrames: standingAthlete(), url: url)

        let drawn = await viewModel.followCrop(for: viewModel.items[1])

        XCTAssertEqual(drawn?.keyframes.count, 1)
    }

    /// The editor hands back the clip's follow crop, and moving it changes the saved clip's
    /// video; handing back the same crop doesn't.
    @MainActor
    func testAnEditorCommitKeepsTheFollowCrop() async throws {
        let url = try await writeFollowVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let followCrop = FollowCrop.uniform(
            scale: 2, rotationRadians: 0,
            keyframes: [FollowKeyframe(time: 1, center: CGPoint(x: 20, y: 18), autoCenter: nil)],
            restingCenter: CGPoint(x: 32, y: 18), isAutoFollow: false)
        let item = ClipListItem(window: followedWindow, cropRect: fullFrame, followCrop: followCrop, isSaved: true)
        let viewModel = followViewModel(items: [item], poseFrames: crossingAthlete(), url: url)

        viewModel.applyEditorResult(
            ClipEditorResult(window: item.window, cropRect: item.cropRect, followCrop: followCrop), to: item.id)

        XCTAssertEqual(viewModel.items[1].followCrop, followCrop)
        XCTAssertTrue(viewModel.items[1].isSaved, "the same follow crop is the same saved clip")

        let moved = FollowCrop.uniform(
            scale: 2, rotationRadians: 0,
            keyframes: [FollowKeyframe(time: 1, center: CGPoint(x: 40, y: 18), autoCenter: nil)],
            restingCenter: CGPoint(x: 32, y: 18), isAutoFollow: false)
        viewModel.applyEditorResult(
            ClipEditorResult(window: item.window, cropRect: item.cropRect, followCrop: moved), to: item.id)

        XCTAssertEqual(viewModel.items[1].followCrop, moved)
        XCTAssertFalse(viewModel.items[1].isSaved, "moving the saved clip's follow crop changes its video")
    }

    @MainActor
    func testSaveExportsAFollowedClipWithTheCropItsTileDraws() async throws {
        actor Recorder {
            var crops: [FollowCrop?] = []
            func record(_ crop: FollowCrop?) { crops.append(crop) }
        }
        let url = try await writeFollowVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = Recorder()
        let viewModel = followViewModel(
            items: [detectedItem()], poseFrames: crossingAthlete(), url: url,
            exportClip: { spec, _, _, _ in
                await recorder.record(spec.followCrop)
                return URL(fileURLWithPath: "/tmp/fake.mp4")
            })
        let expected = await viewModel.followCrop(for: viewModel.items[1])

        let result = await viewModel.save()

        XCTAssertTrue(result)
        XCTAssertNotNil(expected)
        let crops = await recorder.crops
        XCTAssertEqual(crops, [expected])
    }

    /// The tile's player runs over the untrimmed source, so the moving crop is timed in source
    /// time: before a clip that starts at 1 s the crop holds still, and inside it it moves.
    /// Timing it from the clip's own start would move it a second early.
    @MainActor
    func testAFollowedClipsPreviewMovesTheCropInSourceTime() async throws {
        let url = try await writeFollowVideo(seconds: 4)
        defer { try? FileManager.default.removeItem(at: url) }
        let window = TrickWindow(startTime: 1, endTime: 3.95)
        let viewModel = followViewModel(
            items: [detectedItem(window: window)], poseFrames: crossingAthlete(from: 10), url: url)

        let loaded = await viewModel.videoComposition(
            for: ClipCardPlaybackGeometry(window: window, cropRect: fullFrame))

        let composition = try XCTUnwrap(loaded)
        let instruction = try XCTUnwrap(
            composition.instructions.first as? AVMutableVideoCompositionInstruction)
        let layerInstruction = try XCTUnwrap(instruction.layerInstructions.first)
        func ramp(at seconds: TimeInterval) -> (start: CGAffineTransform, end: CGAffineTransform) {
            var start = CGAffineTransform.identity
            var end = CGAffineTransform.identity
            var range = CMTimeRange(start: .zero, duration: .zero)
            _ = layerInstruction.getTransformRamp(
                for: CMTime(seconds: seconds, preferredTimescale: 600), start: &start, end: &end, timeRange: &range)
            return (start, end)
        }
        let beforeTheClip = ramp(at: 0.5)
        let insideTheClip = ramp(at: 1.95)
        XCTAssertEqual(beforeTheClip.start, beforeTheClip.end)
        XCTAssertNotEqual(insideTheClip.start, insideTheClip.end)
    }

    /// The poster is cropped where the moving crop is at the poster's moment — a 9:16 rect on
    /// this landscape video — rather than to the clip's static full-frame rect.
    @MainActor
    func testAFollowedClipsPosterIsCroppedToThePath() async throws {
        let url = try await writeFollowVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let viewModel = followViewModel(items: [detectedItem()], poseFrames: crossingAthlete(), url: url)

        let followedPoster = await viewModel.thumbnail(for: viewModel.items[1])
        let cropRectPoster = await ClipThumbnailLoader().thumbnail(for: viewModel.items[1], in: AVURLAsset(url: url))

        let portrait = try XCTUnwrap(followedPoster)
        let landscape = try XCTUnwrap(cropRectPoster)
        XCTAssertLessThan(portrait.width, portrait.height)
        XCTAssertGreaterThan(landscape.width, landscape.height)
    }

    // MARK: - Add clip

    @MainActor
    func testAddClipAppendsAFullFrameClip() async throws {
        // The dummy asset resolves to nothing, so duration never loads and the new
        // clip falls back to the default 3-second window — clamped to the minimum
        // clip duration, though 3s never actually hits that floor.
        let viewModel = makeViewModel(items: [])

        await viewModel.addClip()

        XCTAssertEqual(viewModel.items.count, 2)
        let added = viewModel.items[1]
        XCTAssertEqual(added.window.startTime, 0)
        XCTAssertEqual(added.window.endTime, 3)
        XCTAssertEqual(added.cropRect, fullFrame)
    }

    @MainActor
    func testAddClipAppendsAfterExistingItems() async {
        let existing = makeItem()
        let viewModel = makeViewModel(items: [existing])

        await viewModel.addClip()

        XCTAssertEqual(viewModel.items.count, 3)
        XCTAssertEqual(viewModel.items[1], existing)
    }

    // MARK: - ClipThumbnailLoader.adjustedThumbnail

    /// Pins the `CGContext` flip `adjustedThumbnail` needs to draw `layerTransform`'s
    /// top-left/y-down space correctly. Identity inputs (full-frame crop, no rotation, no
    /// adjustment) collapse `layerTransform` to the identity map, so this isolates the
    /// flip from the rotation/crop math `ClipExporterTests` already covers: if the flip
    /// were dropped, or applied with the wrong sign, the quadrants would come back
    /// swapped top-to-bottom.
    func testAdjustedThumbnailWithIdentityInputsPreservesQuadrantLayout() throws {
        let source = try XCTUnwrap(Self.quadrantImage())

        let result = try XCTUnwrap(ClipThumbnailLoader.adjustedThumbnail(
            from: source,
            naturalSize: CGSize(width: 4, height: 4),
            preferredTransform: .identity,
            cropRect: fullFrame,
            cropAdjustment: .identity,
            maxPixelSize: CGSize(width: 100, height: 100)))

        XCTAssertEqual(result.width, 4)
        XCTAssertEqual(result.height, 4)
        try Self.assertQuadrants(
            of: result, topLeft: .red, topRight: .green, bottomLeft: .blue, bottomRight: .white)
    }

    /// A 90°-rotated track plus a partial (displayed right-half) crop — the same
    /// discriminating shape as `ClipExporterTests.testRotatedTrackCropUsesTheDisplayedSize`,
    /// carried through the actual `CGContext` render instead of only the abstract
    /// transform. Denormalizing the crop against the encoded (unrotated) size instead of
    /// the displayed size would select
    /// the wrong source region and this would read blue/white instead of red/green.
    func testAdjustedThumbnailAppliesRotationAndPartialCropTogether() throws {
        let source = try XCTUnwrap(Self.quadrantImage())
        // A 90°-rotated track's preferredTransform, calibrated for this test's 4x4 naturalSize.
        let rotate90For4x4 = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 4, ty: 0)
        let displayedRightHalf = NormalizedRect(minX: 0.5, maxX: 1, minY: 0, maxY: 1)

        let result = try XCTUnwrap(ClipThumbnailLoader.adjustedThumbnail(
            from: source,
            naturalSize: CGSize(width: 4, height: 4),
            preferredTransform: rotate90For4x4,
            cropRect: displayedRightHalf,
            cropAdjustment: .identity,
            maxPixelSize: CGSize(width: 100, height: 100)))

        XCTAssertEqual(result.width, 2)
        XCTAssertEqual(result.height, 4)
        let top = try XCTUnwrap(Self.pixel(atX: 1, y: 1, in: result))
        let bottom = try XCTUnwrap(Self.pixel(atX: 1, y: 3, in: result))
        XCTAssertGreaterThan(top.red, 0.5)
        XCTAssertLessThan(top.green, 0.5)
        XCTAssertGreaterThan(bottom.green, 0.5)
        XCTAssertLessThan(bottom.red, 0.5)
    }

    /// `cropAdjustment` reaching the thumbnail render at all. A
    /// 90° `rotationRadians` on top of an untouched full-frame crop rotates the composited
    /// transform the exact same way `ClipExportTransform`'s own rotation tests already
    /// validate; here it's asserted against `adjustedThumbnail`'s actual pixels, both
    /// against the algebraic prediction and directly against the identity-adjustment
    /// output, so a no-op that silently drops `cropAdjustment` fails this either way.
    func testAdjustedThumbnailAppliesCropAdjustmentRotation() throws {
        let source = try XCTUnwrap(Self.quadrantImage())
        let rotated = CropAdjustment(scale: 1, rotationRadians: .pi / 2, offset: .zero)

        let identityResult = try XCTUnwrap(ClipThumbnailLoader.adjustedThumbnail(
            from: source,
            naturalSize: CGSize(width: 4, height: 4),
            preferredTransform: .identity,
            cropRect: fullFrame,
            cropAdjustment: .identity,
            maxPixelSize: CGSize(width: 100, height: 100)))
        let rotatedResult = try XCTUnwrap(ClipThumbnailLoader.adjustedThumbnail(
            from: source,
            naturalSize: CGSize(width: 4, height: 4),
            preferredTransform: .identity,
            cropRect: fullFrame,
            cropAdjustment: rotated,
            maxPixelSize: CGSize(width: 100, height: 100)))

        XCTAssertEqual(rotatedResult.width, 4)
        XCTAssertEqual(rotatedResult.height, 4)
        // Algebraic prediction: rotating the crop 90° about its own center carries the
        // top-left quadrant to top-right, top-right to bottom-right, bottom-right to
        // bottom-left, and bottom-left to top-left.
        try Self.assertQuadrants(
            of: rotatedResult, topLeft: .blue, topRight: .red, bottomLeft: .white, bottomRight: .green)
        // Direct discriminator: the same source, window, and crop rect must decode to a
        // visibly different thumbnail once the adjustment is non-identity — a fixture
        // that read the same either way would pass whether or not the adjustment is applied.
        let identityTopLeft = try XCTUnwrap(Self.pixel(atX: 1, y: 1, in: identityResult))
        let rotatedTopLeft = try XCTUnwrap(Self.pixel(atX: 1, y: 1, in: rotatedResult))
        XCTAssertNotEqual(identityTopLeft.red > 0.5, rotatedTopLeft.red > 0.5)
    }

    func testAdjustedThumbnailReturnsNilForADegenerateCropRect() throws {
        let source = try XCTUnwrap(Self.quadrantImage())

        let result = ClipThumbnailLoader.adjustedThumbnail(
            from: source,
            naturalSize: CGSize(width: 4, height: 4),
            preferredTransform: .identity,
            cropRect: NormalizedRect(minX: 0.5, maxX: 0.5, minY: 0, maxY: 1),
            cropAdjustment: .identity,
            maxPixelSize: CGSize(width: 100, height: 100))

        XCTAssertNil(result)
    }

    // MARK: - ClipThumbnailLoader.thumbnail

    func testThumbnailReturnsNilWhenTheAssetHasNoVideoTrack() async throws {
        let loader = ClipThumbnailLoader()

        // A real audio-only file: track loading succeeds but finds no video track, so
        // the nil comes from the loader's no-video-track guard — not from a decode
        // throw. The card falls back to its placeholder tile; a throw must never reach
        // the view.
        let audioURL = try Self.audioOnlyFileURL()
        // The helper writes the WAV into tmp on every run; clean it up so the test
        // leaves no scratch behind.
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let result = await loader.thumbnail(
            for: makeItem(), in: AVURLAsset(url: audioURL))

        XCTAssertNil(result)
    }

    // MARK: - Helpers

    /// A minimal but structurally valid WAV (44-byte header, zero samples): AVFoundation
    /// parses it as an audio asset, so video-track loading succeeds with no video track.
    private static func audioOnlyFileURL() throws -> URL {
        var header = Data()
        func append(_ string: String) { header.append(contentsOf: string.utf8) }
        func appendLE<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) }
        }
        append("RIFF"); appendLE(UInt32(36)); append("WAVE")
        append("fmt "); appendLE(UInt32(16))
        appendLE(UInt16(1)) // PCM
        appendLE(UInt16(1)) // mono
        appendLE(UInt32(44_100))
        appendLE(UInt32(88_200)) // byte rate
        appendLE(UInt16(2)) // block align
        appendLE(UInt16(16)) // bits per sample
        append("data"); appendLE(UInt32(0)) // zero samples
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        try header.write(to: url)
        return url
    }

    /// A pixel's normalized RGB components (avoids a >2-member tuple return).
    private struct PixelRGB {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat

        static let red = PixelRGB(red: 1, green: 0, blue: 0)
        static let green = PixelRGB(red: 0, green: 1, blue: 0)
        static let blue = PixelRGB(red: 0, green: 0, blue: 1)
        static let white = PixelRGB(red: 1, green: 1, blue: 1)
    }

    /// The RGBA bytes of one pixel, read in the same row-major order `image(fromRows:)`
    /// writes and `bytesPerRow` reports — offset `y * bytesPerRow + x * 4`.
    private static func pixel(atX x: Int, y: Int, in image: CGImage) -> PixelRGB? {
        guard image.bitsPerPixel == 32,
              let data = image.dataProvider?.data as Data?
        else { return nil }
        let offset = y * image.bytesPerRow + x * 4
        guard offset + 4 <= data.count else { return nil }
        return PixelRGB(
            red: CGFloat(data[offset]) / 255,
            green: CGFloat(data[offset + 1]) / 255,
            blue: CGFloat(data[offset + 2]) / 255
        )
    }

    /// Builds a CGImage from an explicit row-major RGBA buffer — `rows[y][x]` — so which
    /// color sits at which row is pinned by construction rather than by `CGContext.fill`'s
    /// row order, which this suite never asserts. Uses the same 8-bit device-RGB layout
    /// `pixel(atX:y:in:)` reads.
    private static func image(fromRows rows: [[PixelRGB]]) -> CGImage? {
        let height = rows.count
        guard height > 0, let width = rows.first?.count, width > 0,
              rows.allSatisfy({ $0.count == width })
        else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for (y, row) in rows.enumerated() {
            for (x, pixel) in row.enumerated() {
                let offset = (y * width + x) * 4
                bytes[offset] = UInt8((pixel.red * 255).rounded())
                bytes[offset + 1] = UInt8((pixel.green * 255).rounded())
                bytes[offset + 2] = UInt8((pixel.blue * 255).rounded())
                bytes[offset + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    /// A 4x4 test image in four distinguishable quadrants — red (top-left), green
    /// (top-right), blue (bottom-left), white (bottom-right) — in `NormalizedRect`'s own
    /// space contract (origin top-left, y down), the same space `layerTransform` is
    /// computed against.
    private static func quadrantImage() -> CGImage? {
        image(fromRows: [
            [.red, .red, .green, .green],
            [.red, .red, .green, .green],
            [.blue, .blue, .white, .white],
            [.blue, .blue, .white, .white]
        ])
    }

    /// Samples one pixel inside each quadrant of a 4x4-grid image (at 1/4 and 3/4 of each
    /// axis, comfortably clear of any resampling at the quadrant boundaries) and asserts
    /// it against the expected color, loosely enough to tolerate interpolation but tightly
    /// enough that the wrong quadrant's color — the discriminating failure — still fails.
    private static func assertQuadrants(
        of image: CGImage,
        topLeft: PixelRGB,
        topRight: PixelRGB,
        bottomLeft: PixelRGB,
        bottomRight: PixelRGB,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let nearX = image.width / 4, farX = 3 * image.width / 4
        let nearY = image.height / 4, farY = 3 * image.height / 4
        for (name, x, y, expected) in [
            ("topLeft", nearX, nearY, topLeft),
            ("topRight", farX, nearY, topRight),
            ("bottomLeft", nearX, farY, bottomLeft),
            ("bottomRight", farX, farY, bottomRight)
        ] {
            let actual = try XCTUnwrap(pixel(atX: x, y: y, in: image), name, file: file, line: line)
            XCTAssertEqual(actual.red, expected.red, accuracy: 0.3, "\(name) red", file: file, line: line)
            XCTAssertEqual(
                actual.green, expected.green, accuracy: 0.3, "\(name) green", file: file, line: line)
            XCTAssertEqual(actual.blue, expected.blue, accuracy: 0.3, "\(name) blue", file: file, line: line)
        }
    }
}
