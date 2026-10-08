import AVFoundation
import CoreGraphics
import SwiftUI
import XCTest
@testable import Turnip

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
        asset: AVURLAsset? = nil,
        assetIdentifier: String = "asset-1",
        duration: TimeInterval = 30,
        exportClip: @escaping ExportOneClip = { _, _, _, _ in URL(fileURLWithPath: "/tmp/fake.mp4") },
        saveToPhotos: @escaping SaveOneClipToPhotos = { _, _ in },
        deleteOriginalAsset: @escaping DeleteOriginalAsset = { _ in },
        settingsProvider: @escaping @MainActor () -> TurnipSettings = { TurnipSettings() }
    ) -> ClipListViewModel {
        ClipListViewModel(
            items: items,
            poseFrames: poseFrames,
            asset: asset ?? dummyAsset(),
            assetIdentifier: assetIdentifier,
            duration: duration,
            exportClip: exportClip,
            saveToPhotos: saveToPhotos,
            deleteOriginalAsset: deleteOriginalAsset,
            makeDirectory: {
                FileManager.default.temporaryDirectory
                    .appendingPathComponent("turnip-test-\(UUID().uuidString)", isDirectory: true)
            },
            settingsProvider: settingsProvider)
    }

    /// A 90°-rotated track's preferredTransform: landscape-encoded portrait video.
    /// Encoded (0,0) is the displayed top-right, so it discriminates transforms that mix up
    /// encoded and displayed space.
    private let rotate90 = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)

    // MARK: - ClipListItem

    func testNewItemsStartUntrashed() {
        XCTAssertFalse(makeItem().isTrashed)
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

    @MainActor
    func testBindingWritesThroughToTheListEntry() {
        let target = makeItem()
        let viewModel = makeViewModel(items: [makeItem(), target])

        guard let binding = viewModel.binding(for: target.id) else {
            XCTFail("expected a binding for an item that is in the list")
            return
        }
        binding.wrappedValue.isTrashed = true

        // The binding writes through to the list entry with the same id — the editor
        // destination edits the clip the card tapped.
        XCTAssertTrue(viewModel.items[2].isTrashed)
        XCTAssertFalse(viewModel.items[1].isTrashed)
    }

    @MainActor
    func testBindingIsNilForAnItemThatIsNotInTheList() {
        let viewModel = makeViewModel(items: [makeItem()])

        XCTAssertNil(viewModel.binding(for: makeItem().id))
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

    /// Regression for the stale-thumbnail bug: `thumbnail(for:)` decodes through the real
    /// `ClipThumbnailLoader` against a real one-frame video. The edit changes only
    /// `cropRect` (same window, same midpoint, so the seek target is identical both
    /// times) to a half-width crop — the decoded image's width is the discriminator: a
    /// stale cache hit would keep returning the full-width image, so this fails before
    /// the fix and passes only once the second call genuinely re-decodes.
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

        let loadedComposition = await viewModel.videoComposition(
            cropRect: target.cropRect, cropAdjustment: target.cropAdjustment)
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

    /// `dummyAsset()` resolves to nothing, so the track load `videoComposition(cropRect:
    /// cropAdjustment:)` depends on fails — this must return `nil` rather than throw or
    /// hang, so a tile's loop can fall back to an uncomposed player.
    @MainActor
    func testVideoCompositionIsNilWhenTheTrackCannotBeLoaded() async {
        let item = makeItem()
        let viewModel = makeViewModel(items: [item])
        let target = viewModel.items[1]

        let composition = await viewModel.videoComposition(
            cropRect: target.cropRect, cropAdjustment: target.cropAdjustment)

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

    /// The regression this fix addresses: a crop-area or rotation edit alone (same
    /// window) needs a new `videoComposition`, not just a resumed player — before this
    /// fix, the rebuild gate only compared the window, so an edit with no trim change
    /// left the live tile playing the pre-edit framing indefinitely.
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
            saveToPhotos: { url, _ in await recorder.recordSave(url) })

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
            saveToPhotos: { _, albumTitle in await recorder.record(albumTitle) },
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
            saveToPhotos: { _, albumTitle in await recorder.record(albumTitle) })

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

    // MARK: - ClipThumbnailLoader.displayedCropRect

    func testDisplayedCropRectWithIdentityTransformIsUnchanged() {
        // Fractions chosen exactly representable in Float so the assertion is exact —
        // the point here is the space mapping, not float dust.
        let crop = NormalizedRect(minX: 0.25, maxX: 0.75, minY: 0.5, maxY: 0.75)

        let rect = ClipThumbnailLoader.displayedCropRect(
            cropRect: crop,
            naturalSize: CGSize(width: 200, height: 100),
            preferredTransform: .identity)

        XCTAssertEqual(rect, CGRect(x: 50, y: 50, width: 100, height: 25))
    }

    func testDisplayedCropRectMapsARotatedTrackIntoDisplayedSpace() {
        // Full frame must become the portrait displayed frame.
        let full = ClipThumbnailLoader.displayedCropRect(
            cropRect: fullFrame,
            naturalSize: CGSize(width: 1920, height: 1080),
            preferredTransform: rotate90)
        XCTAssertEqual(full, CGRect(x: 0, y: 0, width: 1080, height: 1920))

        // The crop rect is normalized in display orientation, so the displayed left half
        // maps straight onto the displayed left half. The old buggy mapping —
        // denormalize in the encoded size, then map through preferredTransform —
        // landed it on the displayed top half instead: (0, 0, 1080, 960).
        let leftHalf = NormalizedRect(minX: 0, maxX: 0.5, minY: 0, maxY: 1)
        let rect = ClipThumbnailLoader.displayedCropRect(
            cropRect: leftHalf,
            naturalSize: CGSize(width: 1920, height: 1080),
            preferredTransform: rotate90)
        XCTAssertEqual(rect, CGRect(x: 0, y: 0, width: 540, height: 1920))
    }

    func testDisplayedCropRectUsesTheDisplayedSizeForPartialRects() {
        // A partial rect discriminates the encoded-vs-displayed denormalization: with the
        // old (buggy) denormalize-in-encoded-size + map-through-transform, this
        // display-normalized rect lands at (0, 480, 1080, 960) instead of (270, 0, 540, 1920).
        let rect = ClipThumbnailLoader.displayedCropRect(
            cropRect: NormalizedRect(minX: 0.25, maxX: 0.75, minY: 0, maxY: 1),
            naturalSize: CGSize(width: 1920, height: 1080),
            preferredTransform: rotate90)

        XCTAssertEqual(rect, CGRect(x: 270, y: 0, width: 540, height: 1920))
    }

    func testDisplayedCropRectReturnsNilForDegenerateInputs() {
        XCTAssertNil(ClipThumbnailLoader.displayedCropRect(
            cropRect: fullFrame,
            naturalSize: .zero,
            preferredTransform: .identity))

        let empty = NormalizedRect(minX: 0.5, maxX: 0.5, minY: 0, maxY: 1)
        XCTAssertNil(ClipThumbnailLoader.displayedCropRect(
            cropRect: empty,
            naturalSize: CGSize(width: 100, height: 100),
            preferredTransform: .identity))
    }

    // MARK: - ClipThumbnailLoader.displayedAspectRatio

    func testDisplayedAspectRatioWithIdentityTransformMatchesTheCropRect() {
        // Fractions chosen exactly representable in Float so the assertion is exact.
        let crop = NormalizedRect(minX: 0.25, maxX: 0.75, minY: 0.5, maxY: 0.75)

        XCTAssertEqual(
            ClipThumbnailLoader.displayedAspectRatio(
                cropRect: crop,
                naturalSize: CGSize(width: 200, height: 100),
                preferredTransform: .identity),
            4.0) // 100 wide x 25 tall
    }

    func testDisplayedAspectRatioUsesTheDisplayedSizeOnARotatedTrack() {
        // Portrait phone video: the crop rect is normalized in display orientation, so a
        // (0.25..<0.75, 0..<1) rect is a 9:32 portrait crop of the 1080x1920 displayed
        // frame. The old buggy mapping read it as an 8:9 encoded-space crop and reported
        // 9:8 (1.125) — the placeholder reserved the wrong shape, off by 4x.
        let crop = NormalizedRect(minX: 0.25, maxX: 0.75, minY: 0, maxY: 1)

        XCTAssertEqual(
            ClipThumbnailLoader.displayedAspectRatio(
                cropRect: crop,
                naturalSize: CGSize(width: 1920, height: 1080),
                preferredTransform: rotate90),
            9.0 / 32.0, // 540 wide x 1920 tall displayed
            accuracy: 1e-6)
    }

    func testDisplayedAspectRatioFallsBackForDegenerateInputs() {
        let empty = NormalizedRect(minX: 0.5, maxX: 0.5, minY: 0, maxY: 1)

        XCTAssertEqual(
            ClipThumbnailLoader.displayedAspectRatio(
                cropRect: empty,
                naturalSize: CGSize(width: 100, height: 100),
                preferredTransform: .identity),
            9.0 / 16.0)
        XCTAssertEqual(
            ClipThumbnailLoader.displayedAspectRatio(
                cropRect: fullFrame,
                naturalSize: .zero,
                preferredTransform: .identity),
            9.0 / 16.0)
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
    /// now carried through the actual `CGContext` render instead of only the abstract
    /// transform. Denormalizing the crop against the encoded (unrotated) size instead of
    /// the displayed size — the bug class this codebase already hit once — would select
    /// the wrong source region and this would read blue/white instead of red/green.
    func testAdjustedThumbnailAppliesRotationAndPartialCropTogether() throws {
        let source = try XCTUnwrap(Self.quadrantImage())
        // A 90°-rotated track's preferredTransform, calibrated for this test's 4x4
        // naturalSize (the class-level `rotate90` above is calibrated for 1920x1080).
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
        // that read the same either way would pass whether or not the fix shipped.
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
