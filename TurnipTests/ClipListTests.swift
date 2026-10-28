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

    private func makeItem(isTrashed: Bool = false) -> ClipListItem {
        ClipListItem(window: window, cropRect: fullFrame, isTrashed: isTrashed)
    }

    /// `AVAsset` is abstract and throws at runtime, so the view-model tests use the
    /// concrete `AVURLAsset` subclass. The URL resolves to nothing — these tests never
    /// decode, they only exercise the trash and save logic.
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
        deleteOriginalAsset: @escaping DeleteOriginalAsset = { _ in },
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
            deleteOriginalAsset: deleteOriginalAsset,
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

    func testNewItemsStartUntrashed() {
        XCTAssertFalse(makeItem().isTrashed)
    }

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
        XCTAssertFalse(viewModel.items[0].isTrashed)
    }

    @MainActor
    func testDeleteNeverRemovesTheOriginalItem() {
        let viewModel = makeViewModel(items: [])
        let originalId = viewModel.items[0].id

        viewModel.delete(originalId)

        XCTAssertEqual(viewModel.items.count, 1)
        XCTAssertTrue(viewModel.items[0].isOriginal)
    }

    // MARK: - ClipListViewModel: trash toggle

    @MainActor
    func testToggleTrashFlipsOnlyTheTappedCard() {
        let first = makeItem(), second = makeItem()
        let viewModel = makeViewModel(items: [first, second])

        viewModel.toggleTrash(first)

        XCTAssertTrue(viewModel.items[1].isTrashed)
        XCTAssertFalse(viewModel.items[2].isTrashed)

        viewModel.toggleTrash(first)
        XCTAssertFalse(viewModel.items[1].isTrashed)
    }

    @MainActor
    func testToggleTrashIgnoresUnknownItems() {
        let viewModel = makeViewModel(items: [makeItem()])

        viewModel.toggleTrash(makeItem())

        XCTAssertFalse(viewModel.items[1].isTrashed)
    }

    @MainActor
    func testToggleTrashWorksOnTheOriginalItem() {
        let viewModel = makeViewModel(items: [])
        let original = viewModel.items[0]

        viewModel.toggleTrash(original)

        XCTAssertTrue(viewModel.items[0].isTrashed)
    }

    // MARK: - ClipListViewModel: trash button routing

    @MainActor
    func testTrashOnADerivedClipRemovesItImmediately() {
        let first = makeItem(), second = makeItem()
        let viewModel = makeViewModel(items: [first, second])

        viewModel.trash(viewModel.items[1])

        // Removed, not toggled: a `toggleTrash` call would have left the item in
        // place with `isTrashed` flipped and the count unchanged.
        XCTAssertEqual(viewModel.items.count, 2)
        XCTAssertEqual(viewModel.items[1].id, second.id)
    }

    @MainActor
    func testTrashOnTheOriginalItemTogglesInsteadOfRemoving() {
        let viewModel = makeViewModel(items: [])
        let original = viewModel.items[0]

        viewModel.trash(original)

        // Toggled, not removed: a `delete` call would have dropped the item, but
        // `delete(_:)` never removes the original regardless.
        XCTAssertEqual(viewModel.items.count, 1)
        XCTAssertTrue(viewModel.items[0].isTrashed)

        viewModel.trash(original)
        XCTAssertFalse(viewModel.items[0].isTrashed)
    }

    @MainActor
    func testTrashIgnoresUnknownItems() {
        let viewModel = makeViewModel(items: [makeItem()])

        viewModel.trash(makeItem())

        XCTAssertEqual(viewModel.items.count, 2)
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
            cropAdjustment: CropAdjustment(scale: 1.5, rotationRadians: 0, offset: .zero))
        viewModel.applyEditorResult(result, to: target.id)

        // The editor's commit lands on the tapped item — window, crop rect, and crop
        // adjustment — and leaves the rest of the list (and the item's own trash
        // decision, which the editor doesn't own) alone.
        let updated = viewModel.items[2]
        XCTAssertEqual(updated.id, target.id)
        XCTAssertEqual(updated.window, result.window)
        XCTAssertEqual(updated.cropRect, result.cropRect)
        XCTAssertEqual(updated.cropAdjustment, result.cropAdjustment)
        XCTAssertEqual(updated.isTrashed, target.isTrashed)
        XCTAssertEqual(viewModel.items[1], other)
    }

    @MainActor
    func testApplyEditorResultIgnoresUnknownIds() {
        let item = makeItem()
        let viewModel = makeViewModel(items: [item])

        viewModel.applyEditorResult(
            ClipEditorResult(
                window: TrickWindow(startTime: 1, endTime: 4),
                cropRect: fullFrame,
                cropAdjustment: .identity),
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
                cropRect: fullFrame,
                cropAdjustment: .identity),
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
            ClipEditorResult(window: window, cropRect: fullFrame, cropAdjustment: .identity),
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
                cropRect: fullFrame,
                cropAdjustment: .identity),
            to: viewModel.items[1].id)

        XCTAssertTrue(viewModel.items[1].isSaved)
    }

    /// A crop rect change alone — what Auto crop moves — is an edit too.
    @MainActor
    func testApplyEditorResultClearsTheSavedFlagOnACropRectChange() async {
        let viewModel = makeViewModel(items: [makeItem()])
        let result = await viewModel.save()
        XCTAssertTrue(result)

        viewModel.applyEditorResult(
            ClipEditorResult(
                window: window,
                cropRect: NormalizedRect(minX: 0.1, maxX: 0.9, minY: 0.1, maxY: 0.9),
                cropAdjustment: .identity),
            to: viewModel.items[1].id)

        XCTAssertFalse(viewModel.items[1].isSaved)
    }

    /// A crop adjustment change alone is an edit too.
    @MainActor
    func testApplyEditorResultClearsTheSavedFlagOnACropAdjustmentChange() async {
        let viewModel = makeViewModel(items: [makeItem()])
        let result = await viewModel.save()
        XCTAssertTrue(result)

        viewModel.applyEditorResult(
            ClipEditorResult(
                window: window,
                cropRect: fullFrame,
                cropAdjustment: CropAdjustment(scale: 2, rotationRadians: 0, offset: .zero)),
            to: viewModel.items[1].id)

        XCTAssertFalse(viewModel.items[1].isSaved)
    }

    /// No stale thumbnail after an edit: `thumbnail(for:)` decodes through the real
    /// `ClipThumbnailLoader` against a real one-frame video. The edit changes only
    /// `cropRect` (same window, same midpoint, so the seek target is identical both
    /// times) to a half-width crop — the decoded image's width is the discriminator: a
    /// stale cache hit would keep returning the full-width image, so this passes only
    /// when the second call genuinely re-decodes.
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
        let result = ClipEditorResult(window: item.window, cropRect: halfWidth, cropAdjustment: .identity)
        viewModel.applyEditorResult(result, to: target.id)
        let updated = viewModel.items[1]
        XCTAssertEqual(updated.cropRect, halfWidth)

        let afterImage = await viewModel.thumbnail(for: updated)
        let after = try XCTUnwrap(afterImage)
        XCTAssertEqual(after.width, 32)
    }

    /// Regression for the clip list's live preview player showing the raw, un-cropped,
    /// un-adjusted source regardless of the item's crop rect or manual adjustment:
    /// `videoComposition(cropRect:cropAdjustment:)` — what a tile's loop attaches to its
    /// `AVPlayerItem` before looping — must render at the crop's own
    /// size, not the source's, with the crop AND the adjustment actually wired into the
    /// layer instruction, not just the render size. A half-width crop discriminates
    /// `renderSize`: an un-composed player would report the full 64px width. A non-
    /// identity `cropAdjustment` (not `.identity`, unlike a fixture that would pass even
    /// with the argument dropped, since `ClipExportTransform.make`'s `cropAdjustment`
    /// parameter defaults to `.identity`) plus `getTransformRamp` reading back exactly the
    /// transform `ClipExportTransform.make` predicts discriminates the layer instruction
    /// itself: the composition path shares `ClipExportTransform.makeVideoComposition` with
    /// the exporter, but a future edit that dropped `setTransform`, or the `cropAdjustment`
    /// argument at the call site, would leave `renderSize` alone (this test's first
    /// assertion would still pass) while quietly un-cropping or un-rotating both the tile
    /// and the exported clip.
    @MainActor
    func testVideoCompositionRendersAtTheCropRectsSizeAndAdjustment() async throws {
        let url = try await TestVideoWriter.writeTestVideo(frameCount: 1, width: 64, height: 64, fps: 30)
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        let halfWidth = NormalizedRect(minX: 0, maxX: 0.5, minY: 0, maxY: 1)
        let adjustment = CropAdjustment(scale: 1.4, rotationRadians: .pi / 6, offset: CGSize(width: 2, height: -3))
        let item = ClipListItem(
            window: TrickWindow(startTime: 0, endTime: 1.0 / 30), cropRect: halfWidth,
            cropAdjustment: adjustment)
        let viewModel = makeViewModel(items: [item], asset: asset, duration: 1.0 / 30)
        let target = viewModel.items[1]

        let loadedComposition = await viewModel.videoComposition(for: ClipCardPlaybackGeometry(
            window: target.window, cropRect: target.cropRect, cropAdjustment: target.cropAdjustment))
        let composition = try XCTUnwrap(loadedComposition)

        XCTAssertEqual(composition.renderSize, CGSize(width: 32, height: 64))

        let track = try await asset.loadTracks(withMediaType: .video)[0]
        let naturalSize = try await track.load(.naturalSize)
        let preferredTransform = try await track.load(.preferredTransform)
        let expected = try XCTUnwrap(ClipExportTransform.make(
            cropRect: halfWidth, naturalSize: naturalSize, preferredTransform: preferredTransform,
            cropAdjustment: adjustment))
        let instruction = try XCTUnwrap(
            composition.instructions.first as? AVMutableVideoCompositionInstruction)
        let layerInstruction = try XCTUnwrap(instruction.layerInstructions.first)
        var start = CGAffineTransform.identity
        var end = CGAffineTransform.identity
        var ramp = CMTimeRange(start: .zero, duration: .zero)
        XCTAssertTrue(layerInstruction.getTransformRamp(for: .zero, start: &start, end: &end, timeRange: &ramp))
        XCTAssertEqual(start, expected.layerTransform)
        XCTAssertEqual(end, expected.layerTransform)
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
            window: target.window, cropRect: target.cropRect, cropAdjustment: target.cropAdjustment))

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
        cropAdjustment: CropAdjustment = .identity
    ) -> ClipCardPlaybackGeometry {
        ClipCardPlaybackGeometry(
            window: window ?? self.window, cropRect: cropRect ?? fullFrame,
            cropAdjustment: cropAdjustment)
    }

    func testPlaybackNeedsRebuildWhenTheBuiltWindowDiffersFromTarget() {
        let builtFor = makePlaybackGeometry(window: TrickWindow(startTime: 0, endTime: 2))
        let target = makePlaybackGeometry(window: TrickWindow(startTime: 1, endTime: 3))

        XCTAssertTrue(clipCardPlaybackNeedsRebuild(builtFor: builtFor, target: target))
    }

    /// A crop-area or rotation edit alone (same window) needs a new `videoComposition`,
    /// not just a resumed player: a gate that compared only the window would leave the
    /// live tile playing the pre-edit framing indefinitely.
    func testPlaybackNeedsRebuildWhenOnlyTheCropAdjustmentDiffersFromTarget() {
        let builtFor = makePlaybackGeometry()
        let target = makePlaybackGeometry(
            cropAdjustment: CropAdjustment(scale: 1.5, rotationRadians: 0, offset: .zero))

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
        XCTAssertEqual(source.cropAdjustment, item.cropAdjustment)
        XCTAssertTrue(source.asset === asset)
    }

    /// The video's scored frames reach the editor whole — not just the item's window's —
    /// since a trim can pull frames outside the window into the crop, and Auto crop has
    /// nothing to fit without them.
    @MainActor
    func testEditorSourceCarriesTheVideosPoseFrames() {
        let frames = PoseFixture.frames(hipXPositions: [0.3, 0.4, 0.5, 0.6])
        let item = makeItem()
        let viewModel = makeViewModel(items: [item], poseFrames: frames)

        let source = viewModel.editorSource(for: item)

        XCTAssertEqual(source.poseFrames, frames)
    }

    /// A clip found following everyone opens on its own person's frames, so Auto crop fits that
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
            ClipEditorResult(window: window, cropRect: fullFrame, cropAdjustment: .identity), to: item.id)

        XCTAssertEqual(try XCTUnwrap(viewModel.items.last).personID, 2)
    }

    // MARK: - save()

    @MainActor
    func testSaveExportsAndSavesEveryNonTrashedDerivedClip() async {
        actor Recorder {
            var exportedWindows: [TrickWindow] = []
            var savedURLs: [URL] = []
            func recordExport(_ window: TrickWindow) { exportedWindows.append(window) }
            func recordSave(_ url: URL) { savedURLs.append(url) }
        }
        let recorder = Recorder()
        let kept = makeItem()
        let trashed = makeItem(isTrashed: true)
        let viewModel = makeViewModel(
            items: [kept, trashed],
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
        XCTAssertEqual(windows, [kept.window])
        let saved = await recorder.savedURLs
        XCTAssertEqual(saved.count, 1)
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
    func testSaveDeletesTheOriginalWhenItIsTrashedAndEverythingSucceeded() async {
        actor Recorder {
            var deletedIdentifiers: [String] = []
            func record(_ identifier: String) { deletedIdentifiers.append(identifier) }
        }
        let recorder = Recorder()
        let viewModel = makeViewModel(
            items: [makeItem()],
            assetIdentifier: "original-123",
            deleteOriginalAsset: { identifier in await recorder.record(identifier) })
        viewModel.toggleTrash(viewModel.items[0])

        let result = await viewModel.save()

        XCTAssertTrue(result)
        let deleted = await recorder.deletedIdentifiers
        XCTAssertEqual(deleted, ["original-123"])
    }

    @MainActor
    func testSaveLeavesTheOriginalAloneWhenItIsNotTrashed() async {
        actor Recorder {
            var deleteCount = 0
            func increment() { deleteCount += 1 }
        }
        let recorder = Recorder()
        let viewModel = makeViewModel(
            items: [makeItem()],
            deleteOriginalAsset: { _ in await recorder.increment() })

        let result = await viewModel.save()

        XCTAssertTrue(result)
        let count = await recorder.deleteCount
        XCTAssertEqual(count, 0)
    }

    @MainActor
    func testSaveDoesNotDeleteTheOriginalWhenAClipFails() async {
        struct Boom: Error {}
        actor Recorder {
            var deleteCount = 0
            func increment() { deleteCount += 1 }
        }
        let recorder = Recorder()
        let viewModel = makeViewModel(
            items: [makeItem()],
            exportClip: { _, _, _, _ in throw Boom() },
            deleteOriginalAsset: { _ in await recorder.increment() })
        viewModel.toggleTrash(viewModel.items[0])

        let result = await viewModel.save()

        XCTAssertFalse(result)
        let count = await recorder.deleteCount
        // A failed clip must never cost the original its only remaining copy: the
        // original stays until every derived clip has confirmed it landed in Photos.
        XCTAssertEqual(count, 0)
        XCTAssertNotNil(viewModel.saveFailureMessage)
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

    /// What Save Clips announces and what it does read off the same scope, so a trashed clip that
    /// still counted would promise a save that never happens.
    @MainActor
    func testSaveScopeSkipsTrashedClipsAndReportsTheOriginal() {
        let viewModel = makeViewModel(items: [makeItem(), makeItem(isTrashed: true), makeItem()])

        XCTAssertEqual(viewModel.saveScope.clipCount, 2)
        XCTAssertFalse(viewModel.saveScope.deletesOriginal)

        viewModel.toggleTrash(viewModel.items[0])

        XCTAssertTrue(viewModel.saveScope.deletesOriginal)
        XCTAssertEqual(viewModel.saveScope.clipCount, 2, "the original is not one of the clips")
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
        XCTAssertEqual(viewModel.saveScope.clipCount, 1)

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

    @MainActor
    func testSaveIgnoresAFailedOriginalDeletion() async {
        struct Boom: Error {}
        let viewModel = makeViewModel(
            items: [],
            deleteOriginalAsset: { _ in throw Boom() })
        viewModel.toggleTrash(viewModel.items[0])

        let result = await viewModel.save()

        // A declined system delete-confirmation or a revoked permission leaves the
        // original in place, which is the safe outcome — not a reportable failure.
        XCTAssertTrue(result)
        XCTAssertNil(viewModel.saveFailureMessage)
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
    /// clean first Save Clips — pop to Home, and delete the trashed original.
    @MainActor
    func testRetriedSaveSucceedsAndDeletesTheTrashedOriginalOnceTheLastClipLands() async {
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
            var deleteCount = 0
            func recordSave(_ name: String) { savedNames.append(name) }
            func recordDelete() { deleteCount += 1 }
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
            },
            deleteOriginalAsset: { _ in await recorder.recordDelete() })
        viewModel.toggleTrash(viewModel.items[0])

        let first = await viewModel.save()
        XCTAssertFalse(first)
        let deletesAfterTheFailure = await recorder.deleteCount
        XCTAssertEqual(deletesAfterTheFailure, 0)

        viewModel.saveFailureMessage = nil
        let second = await viewModel.save()

        XCTAssertTrue(second)
        let savedNames = await recorder.savedNames
        XCTAssertEqual(savedNames, ["clip-0.mp4", "clip-5.mp4"])
        let deleteCount = await recorder.deleteCount
        XCTAssertEqual(deleteCount, 1)
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

    // MARK: - Follow the athlete

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
        items: [ClipListItem], poseFrames: [PoseFrameResult], url: URL, follow: Bool = true,
        exportClip: @escaping ExportOneClip = { _, _, _, _ in URL(fileURLWithPath: "/tmp/fake.mp4") }
    ) -> ClipListViewModel {
        makeViewModel(
            items: items, poseFrames: poseFrames, asset: AVURLAsset(url: url), duration: 3,
            exportClip: exportClip, settingsProvider: { TurnipSettings(followAthlete: follow) })
    }

    /// Settings' Follow the athlete is the mode a detected clip starts in; the original stands
    /// for the whole video and never follows.
    @MainActor
    func testFollowTheAthleteStartsDetectedClipsInFollow() async throws {
        let url = try await writeFollowVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let following = followViewModel(items: [detectedItem()], poseFrames: crossingAthlete(), url: url)
        let still = followViewModel(
            items: [detectedItem()], poseFrames: crossingAthlete(), url: url, follow: false)

        XCTAssertEqual(following.items[0].framingMode, .still)
        XCTAssertEqual(following.items[1].framingMode, .follow)
        XCTAssertNil(following.items[1].followCrop)
        XCTAssertEqual(still.items[1].framingMode, .still)
        let stillCrop = await still.followCrop(for: still.items[1])
        XCTAssertNil(stillCrop)
    }

    /// A "+" clip starts in Still whatever the setting says.
    @MainActor
    func testAHandAddedClipStartsInStill() async throws {
        let url = try await writeFollowVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let viewModel = followViewModel(items: [detectedItem()], poseFrames: crossingAthlete(), url: url)

        await viewModel.addClip()

        XCTAssertEqual(viewModel.items[2].framingMode, .still)
    }

    /// A clip in Follow with no follow crop of its own draws Auto follow's for its window: a
    /// few keyframes, not one per pose sample, marked as Auto follow's.
    @MainActor
    func testAClipInFollowWithoutACropDrawsAutoFollows() async throws {
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

    /// The editor hands back both modes' framings and the active mode; the clip keeps all of
    /// them. Only the active mode's framing is in the video, so a change to the other one
    /// alone isn't an edit of the saved clip.
    @MainActor
    func testAnEditorCommitKeepsBothFramings() async throws {
        let url = try await writeFollowVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let item = ClipListItem(window: followedWindow, cropRect: fullFrame, isSaved: true)
        let viewModel = followViewModel(items: [item], poseFrames: crossingAthlete(), url: url, follow: false)
        let followCrop = FollowCrop.uniform(
            scale: 2, rotationRadians: 0,
            keyframes: [FollowKeyframe(time: 1, center: CGPoint(x: 20, y: 18), autoCenter: nil)],
            restingCenter: CGPoint(x: 32, y: 18), isAutoFollow: false)

        viewModel.applyEditorResult(
            ClipEditorResult(
                window: item.window, cropRect: item.cropRect, cropAdjustment: item.cropAdjustment,
                framingMode: .still, followCrop: followCrop),
            to: item.id)

        XCTAssertEqual(viewModel.items[1].framingMode, .still)
        XCTAssertEqual(viewModel.items[1].followCrop, followCrop)
        XCTAssertTrue(viewModel.items[1].isSaved, "Follow's framing isn't in a clip saved in Still")

        viewModel.applyEditorResult(
            ClipEditorResult(
                window: item.window, cropRect: item.cropRect, cropAdjustment: item.cropAdjustment,
                framingMode: .follow, followCrop: followCrop),
            to: item.id)

        XCTAssertEqual(viewModel.items[1].framingMode, .follow)
        XCTAssertFalse(viewModel.items[1].isSaved, "switching the saved clip to Follow changes its video")
    }

    /// Read once when the screen opens: a change mid-screen would leave the cards already on
    /// screen and the save disagreeing about which mode a clip starts in.
    @MainActor
    func testFollowTheAthleteIsReadOnceWhenTheScreenOpens() async throws {
        final class FollowSwitch { var isOn = true }
        let url = try await writeFollowVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let toggle = FollowSwitch()
        let viewModel = makeViewModel(
            items: [detectedItem()], poseFrames: crossingAthlete(), asset: AVURLAsset(url: url), duration: 3,
            settingsProvider: { TurnipSettings(followAthlete: toggle.isOn) })
        toggle.isOn = false

        let drawn = await viewModel.followCrop(for: viewModel.items[1])

        XCTAssertNotNil(drawn)
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

        let loaded = await viewModel.videoComposition(for: ClipCardPlaybackGeometry(
            window: window, cropRect: fullFrame, cropAdjustment: .identity, framingMode: .follow))

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
        let followed = followViewModel(items: [detectedItem()], poseFrames: crossingAthlete(), url: url)
        let still = followViewModel(
            items: [detectedItem()], poseFrames: crossingAthlete(), url: url, follow: false)

        let followedPoster = await followed.thumbnail(for: followed.items[1])
        let stillPoster = await still.thumbnail(for: still.items[1])

        let portrait = try XCTUnwrap(followedPoster)
        let landscape = try XCTUnwrap(stillPoster)
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
        XCTAssertFalse(added.isTrashed)
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
