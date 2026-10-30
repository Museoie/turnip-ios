import CoreGraphics
import XCTest
import zlib
@testable import Turnip

/// The trick model end to end, against the baseline turnip-ml exports: the smoke model in
/// `Fixtures/`, and its outputs over two smoke samples as numpy computes them in training
/// (`Fixtures/make_trick_model_reference.py` says how both were made).
final class TrickModelLoadingTests: XCTestCase {
    private struct Reference: Decodable {
        let classes: [String]
        let windowFrames: Int
        let windowStride: Int
        let pose: [[Float]]
        let windowProbs: [[Float]]
        let windowEmbeddings: [[Float]]
        let segments: [ReferenceSegment]
    }

    private struct ReferenceSegment: Decodable {
        let startFrame: Int
        let endFrame: Int
        let name: String
    }

    private struct RefusedArchive {
        let label: String
        let archive: Data
        let failure: StoredZipArchive.Failure
    }

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrickModelLoadingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: nil), "missing fixture \(name)")
    }

    private func reference() throws -> Reference {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Reference.self, from: Data(contentsOf: fixture("TrickModelReference.json")))
    }

    private func smokeModel() async throws -> TrickModel {
        try await TrickModel.load(artifact: fixture("TrickDetectorSmoke.mlpackage.zip"), version: "trick-v0.0-smoke")
    }

    /// The reference pose as canonical slots: a row with the gap indicator set is a gap.
    private func slots(_ reference: Reference) -> [[Float]?] {
        reference.pose.map { $0[51] == 1 ? nil : Array($0[0..<51]) }
    }

    // MARK: - Unpacking

    func testTheExportsZipUnpacksIntoTheMLPackage() throws {
        try StoredZipArchive.extract(Data(contentsOf: fixture("TrickDetectorSmoke.mlpackage.zip")), to: scratch)
        let package = scratch.appendingPathComponent("TrickDetector.mlpackage")
        let files = ["Manifest.json", "Data/com.apple.CoreML/model.mlmodel", "Data/com.apple.CoreML/weights/weight.bin"]
        for path in files {
            XCTAssertTrue(FileManager.default.fileExists(atPath: package.appendingPathComponent(path).path), path)
        }
    }

    func testAnArchiveThatCouldEscapeOrHidesItsBytesIsRefused() {
        let cases = [
            RefusedArchive(
                label: "climbs out", archive: Self.archive(name: "a/../../evil"), failure: .unsafePath("a/../../evil")),
            RefusedArchive(
                label: "absolute", archive: Self.archive(name: "/tmp/evil"), failure: .unsafePath("/tmp/evil")),
            RefusedArchive(
                label: "backslash", archive: Self.archive(name: "a\\b"), failure: .unsafePath("a\\b")),
            RefusedArchive(
                label: "compressed", archive: Self.archive(name: "a/b", method: 8), failure: .unsupportedEntry("a/b")),
            RefusedArchive(
                label: "encrypted", archive: Self.archive(name: "a/b", flags: 1), failure: .unsupportedEntry("a/b")),
            RefusedArchive(
                label: "bad checksum", archive: Self.archive(name: "a/b", crcOffset: 1),
                failure: .checksumMismatch("a/b")),
            RefusedArchive(
                label: "truncated", archive: Data([0x50, 0x4b, 0x05]), failure: .malformed)
        ]
        for refused in cases {
            XCTAssertThrowsError(try StoredZipArchive.extract(refused.archive, to: scratch), refused.label) {
                XCTAssertEqual($0 as? StoredZipArchive.Failure, refused.failure, refused.label)
            }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: scratch.path), [])
    }

    func testAWellFormedArchiveWritesItsFile() throws {
        try StoredZipArchive.extract(Self.archive(name: "a/b/c.txt", contents: Data("hello".utf8)), to: scratch)
        XCTAssertEqual(
            try Data(contentsOf: scratch.appendingPathComponent("a/b/c.txt")), Data("hello".utf8))
    }

    // MARK: - Core ML

    /// The model describes itself: classes and window grid from the export's metadata, and the
    /// embedding output when it has one.
    func testTheModelReadsItsDescriptorFromItsMetadata() async throws {
        let model = try await smokeModel()
        let reference = try reference()
        XCTAssertEqual(model.version, "trick-v0.0-smoke")
        XCTAssertEqual(model.descriptor.classes, reference.classes)
        XCTAssertEqual(model.descriptor.windowFrames, reference.windowFrames)
        XCTAssertEqual(model.descriptor.windowStride, reference.windowStride)
        XCTAssertTrue(model.hasEmbeddings)
    }

    /// On device the model computes what training computed: probabilities within fp16's reach of
    /// numpy's, embeddings within what fp16 features divided by a small standard deviation keep,
    /// and the same segments.
    func testTheModelReproducesTrainingsOutputs() async throws {
        let model = try await smokeModel()
        let reference = try reference()
        let input = TrickModelInput(canonicalSlots: slots(reference))
        XCTAssertEqual(input.values, reference.pose.flatMap { $0 })

        let output = try XCTUnwrap(try model.run(input))
        let segments = output.segments.map {
            ReferenceSegment(
                startFrame: $0.startFrame, endFrame: $0.endFrame, name: $0.trickNames.joined(separator: "+"))
        }
        XCTAssertEqual(segments.map(\.startFrame), reference.segments.map(\.startFrame))
        XCTAssertEqual(segments.map(\.endFrame), reference.segments.map(\.endFrame))
        XCTAssertEqual(segments.map(\.name), reference.segments.map(\.name))

        let embeddings = try XCTUnwrap(output.embeddings)
        XCTAssertEqual(embeddings.count, reference.windowEmbeddings.count)
        for (row, expected) in zip(embeddings, reference.windowEmbeddings) {
            XCTAssertEqual(row.count, expected.count)
            for (value, wanted) in zip(row, expected) {
                XCTAssertEqual(value, wanted, accuracy: 0.15)
            }
        }
        let expectedScores = reference.segments.map { segment in
            let windows = (segment.startFrame / reference.windowStride)...(
                (segment.endFrame - reference.windowFrames) / reference.windowStride)
            let winner = reference.classes.firstIndex(of: segment.name) ?? 0
            return windows.map { reference.windowProbs[$0][winner] }.reduce(0, +) / Float(windows.count)
        }
        XCTAssertEqual(output.segments.count, expectedScores.count)
        for (score, expected) in zip(output.segments.map(\.score), expectedScores) {
            XCTAssertEqual(score, expected, accuracy: 2e-3)
        }
    }

    func testASequenceShorterThanAWindowHasNothingToClassify() async throws {
        let model = try await smokeModel()
        let short = TrickModelInput(canonicalSlots: Array(repeating: nil, count: model.descriptor.windowFrames - 1))
        XCTAssertNil(try model.run(short))
    }

    // MARK: - Loader

    private func store(staging data: Data?) throws -> ModelUpdateStore {
        let store = ModelUpdateStore(baseURL: scratch.appendingPathComponent("ModelUpdates"))
        if let data {
            try store.stage(
                modelData: data, version: ModelVersion("trick-v0.0-smoke"), fileName: "trick-v0.0-smoke.mlpackage.zip")
        }
        return store
    }

    /// The staged artifact loads once; every later call gets that same model.
    func testTheLoaderLoadsTheStagedModelOnce() async throws {
        let artifact = try Data(contentsOf: fixture("TrickDetectorSmoke.mlpackage.zip"))
        let loader = TrickModelLoader(store: try store(staging: artifact))
        let first = await loader.model()
        let second = await loader.model()
        XCTAssertEqual(first?.version, "trick-v0.0-smoke")
        XCTAssertTrue(first === second)
    }

    /// Nothing staged, or a staged artifact that doesn't load, leaves analysis to the heuristic.
    func testTheLoaderHasNoModelWhenNothingLoads() async throws {
        let nothing = await TrickModelLoader(store: try store(staging: nil)).model()
        XCTAssertNil(nothing)
        let broken = await TrickModelLoader(store: try store(staging: Data("not a zip".utf8))).model()
        XCTAssertNil(broken)
        let noStore = await TrickModelLoader(store: nil).model()
        XCTAssertNil(noStore)
    }

    // MARK: - Proposals

    private func frames(_ reference: Reference) -> [MultiPoseFrame] {
        reference.pose.enumerated().map { index, row in
            let keypoints = PoseKeypoint.names.enumerated().map { joint, name in
                PoseKeypoint(name: name, y: row[joint * 3 + 1], x: row[joint * 3], confidence: row[joint * 3 + 2])
            }
            let person = DetectedPerson(
                score: 0.9, box: NormalizedRect(minX: 0, maxX: 1, minY: 0, maxY: 1), keypoints: keypoints)
            return MultiPoseFrame(frameIndex: index, timestamp: Double(index) / 10, people: [person])
        }
    }

    /// With a model, its segments reach the clip list as clips, with their names and how they were
    /// proposed, and the run's embeddings travel with the detection.
    func testTheModelsProposalsBecomeTheClips() async throws {
        let model = try await smokeModel()
        let reference = try reference()
        let pipeline = ProcessingPipeline(proposalRules: TrickProposalRules(blindSampleRate: 0))

        let detection = pipeline.detect(
            in: frames(reference), people: .one, renderedPixelSize: CGSize(width: 1920, height: 1080),
            duration: 6.4, trickModel: model)

        XCTAssertEqual(detection.clips.map(\.window), reference.segments.map {
            TrickWindow(startTime: Double($0.startFrame) / 10, endTime: Double($0.endFrame) / 10)
        })
        XCTAssertEqual(detection.clips.map(\.proposal), reference.segments.map {
            ModelProposal(modelVersion: "trick-v0.0-smoke", suggestedNames: [$0.name], suggestionsWithheld: false)
        })
        XCTAssertEqual(detection.windowEmbeddings.count, 1)
        XCTAssertNil(detection.windowEmbeddings.first?.personID)
        XCTAssertEqual(detection.windowEmbeddings.first?.rows.count, reference.windowEmbeddings.count)
        XCTAssertEqual(detection.windowEmbeddings.first?.modelVersion, "trick-v0.0-smoke")
    }

    /// Following everyone, the model runs over each person's own pose: the athlete's clips are the
    /// ones it finds in the athlete's pose alone, every clip belongs to someone kept, and each kept
    /// person has their own embeddings.
    func testFollowingEveryoneTheModelRunsOverEachPersonsPose() async throws {
        let model = try await smokeModel()
        let reference = try reference()
        let bystanderKeypoints = PoseKeypoint.names.enumerated().map { joint, name in
            PoseKeypoint(name: name, y: 0.3 + Float(joint) * 0.03, x: 0.9, confidence: 0.9)
        }
        let bystander = DetectedPerson(
            score: 0.95, box: NormalizedRect(minX: 0.85, maxX: 0.95, minY: 0.3, maxY: 0.9),
            keypoints: bystanderKeypoints)
        let frames = frames(reference).map { frame in
            let athlete = DetectedPerson(
                score: 0.9, box: NormalizedRect(minX: 0.2, maxX: 0.7, minY: 0, maxY: 1),
                keypoints: frame.primary.keypoints)
            return MultiPoseFrame(
                frameIndex: frame.frameIndex, timestamp: frame.timestamp, people: [athlete, bystander])
        }
        let pipeline = ProcessingPipeline(proposalRules: TrickProposalRules(blindSampleRate: 0))

        let detection = pipeline.detect(
            in: frames, people: .everyone, renderedPixelSize: CGSize(width: 1920, height: 1080),
            duration: 6.4, trickModel: model)

        let athlete = try XCTUnwrap(detection.people.first { track in
            track.frames.contains { $0.keypoints.contains { abs($0.x - 0.9) > 0.01 } }
        })
        XCTAssertEqual(detection.clips.filter { $0.personID == athlete.id }.map(\.window), reference.segments.map {
            TrickWindow(startTime: Double($0.startFrame) / 10, endTime: Double($0.endFrame) / 10)
        })
        let kept = Set(detection.people.map(\.id))
        XCTAssertTrue(detection.clips.allSatisfy { $0.personID.map(kept.contains) == true })
        XCTAssertEqual(detection.windowEmbeddings.map(\.personID), detection.people.map(\.id))
    }

    func testBlindClipsKeepTheirWindowsWithoutNames() async throws {
        let model = try await smokeModel()
        let reference = try reference()
        let pipeline = ProcessingPipeline(proposalRules: TrickProposalRules(blindSampleRate: 1))

        let detection = pipeline.detect(
            in: frames(reference), people: .one, renderedPixelSize: CGSize(width: 1920, height: 1080),
            trickModel: model)

        XCTAssertEqual(detection.clips.count, reference.segments.count)
        XCTAssertTrue(detection.clips.allSatisfy { $0.proposal?.suggestionsWithheld == true })
        XCTAssertTrue(detection.clips.allSatisfy { $0.proposal?.prefilledNames == [] })
    }

    /// Without a model the heuristic proposes, and its clips carry no model provenance.
    func testWithoutAModelTheHeuristicProposes() throws {
        let reference = try reference()
        let detection = ProcessingPipeline().detect(
            in: frames(reference), people: .one, renderedPixelSize: CGSize(width: 1920, height: 1080))
        XCTAssertTrue(detection.clips.allSatisfy { $0.proposal == nil })
        XCTAssertEqual(detection.windowEmbeddings, [])
    }

    /// One stored entry, its local header then its central-directory header, with whatever
    /// `method`, `flags` and checksum error a case needs.
    private static func archive(
        name: String, contents: Data = Data("x".utf8), method: UInt16 = 0, flags: UInt16 = 0, crcOffset: UInt32 = 0
    ) -> Data {
        let nameBytes = Data(name.utf8)
        let crc = contents.withUnsafeBytes {
            UInt32(zlib.crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(contents.count)))
        } &+ crcOffset
        var archive = Data()
        func append<Value: FixedWidthInteger>(_ value: Value) {
            withUnsafeBytes(of: value.littleEndian) { archive.append(contentsOf: $0) }
        }
        func sizesAndName() {
            append(crc)
            append(UInt32(contents.count))
            append(UInt32(contents.count))
            append(UInt16(nameBytes.count))
            append(UInt16(0))
        }
        append(UInt32(0x0403_4b50))
        append(UInt16(20))
        append(flags)
        append(method)
        append(UInt32(0))
        sizesAndName()
        archive.append(nameBytes)
        archive.append(contents)

        let directoryOffset = archive.count
        append(UInt32(0x0201_4b50))
        append(UInt16(20))
        append(UInt16(20))
        append(flags)
        append(method)
        append(UInt32(0))
        sizesAndName()
        append(UInt16(0))
        append(UInt16(0))
        append(UInt16(0))
        append(UInt32(0))
        append(UInt32(0))
        archive.append(nameBytes)
        let directorySize = archive.count - directoryOffset

        append(UInt32(0x0605_4b50))
        append(UInt16(0))
        append(UInt16(0))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(directorySize))
        append(UInt32(directoryOffset))
        append(UInt16(0))
        return archive
    }
}
