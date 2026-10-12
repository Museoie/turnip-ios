import AVFoundation
import XCTest
@testable import Turnip

/// Runs detection end to end — `ProcessingPipeline.run` with the bundled model — on hand-labelled
/// footage, and reports how the clips score against the labels (`TrickDetectionScore`).
///
/// Skipped unless the run names the evaluation directory: pass
/// `TEST_RUNNER_TURNIP_EVAL_DIR=<dir>` to `xcodebuild test`. The directory holds the videos and a
/// `labels.json` (`EvaluationManifest`); they are recordings of real people, so they live outside
/// the repository. Each run writes its scored windows to `<dir>/results/<label>.json`
/// (`TEST_RUNNER_TURNIP_EVAL_LABEL`, default `run`) and the pose it scored to `<dir>/pose/`;
/// both are overwritten by the next run with the same label or the next full run, so neither is
/// a history. `TEST_RUNNER_TURNIP_EVAL_REUSE_POSE=1` re-runs detection on that saved pose instead
/// of the model: seconds instead of minutes, and the same frames on both sides of a detector
/// change.
final class TrickDetectionEvaluationTests: XCTestCase {
    func testScoreDetectionOnLabelledFootage() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["TURNIP_EVAL_DIR"] else {
            throw XCTSkip("Set TEST_RUNNER_TURNIP_EVAL_DIR to a labelled footage directory to run this.")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let manifest = try JSONDecoder().decode(
            EvaluationManifest.self, from: Data(contentsOf: directory.appendingPathComponent("labels.json")))
        let reusePose = environment["TURNIP_EVAL_REUSE_POSE"] == "1"
        var report = EvaluationReport(label: environment["TURNIP_EVAL_LABEL"] ?? "run", reusedPose: reusePose)

        for clip in manifest.clips {
            report.add(clip, windows: try await detectedWindows(for: clip, in: directory, reusePose: reusePose))
        }

        for line in report.lines {
            print("TURNIP_EVAL " + line)
        }
        let results = directory.appendingPathComponent("results", isDirectory: true)
        try FileManager.default.createDirectory(at: results, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: results.appendingPathComponent("\(report.label).json"))
    }

    private func detectedWindows(
        for clip: EvaluationManifest.Clip,
        in directory: URL,
        reusePose: Bool
    ) async throws -> [TrickWindow] {
        let pipeline = ProcessingPipeline()
        let poseURL = directory.appendingPathComponent("pose/\(clip.video).json")
        if reusePose, let data = try? Data(contentsOf: poseURL) {
            let saved = try JSONDecoder().decode(SavedPose.self, from: data)
            return pipeline.detectClips(in: saved.poseFrames, renderedPixelSize: saved.renderSize).map(\.window)
        }

        let asset = AVURLAsset(url: directory.appendingPathComponent(clip.video))
        let video = SelectedVideo(
            assetIdentifier: clip.video, asset: asset, duration: try await asset.load(.duration).seconds)
        let result = try await pipeline.run(video: video) { _ in }

        let saved = SavedPose(frames: result.detection.poseFrames, renderSize: try await Self.renderSize(of: asset))
        try FileManager.default.createDirectory(
            at: poseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(saved).write(to: poseURL)
        return result.clips.map(\.window)
    }

    /// The display-orientation size the sampler renders frames at, which `run` measures the
    /// keypoints against — needed to re-run detection on saved pose.
    private static func renderSize(of asset: AVURLAsset) async throws -> CGSize {
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        return VideoTrackGeometry(
            naturalSize: try await track.load(.naturalSize),
            preferredTransform: try await track.load(.preferredTransform)
        ).displayedSize
    }
}

/// `labels.json`: one entry per video in the evaluation directory.
struct EvaluationManifest: Decodable {
    struct Clip: Decodable {
        /// File name, relative to the evaluation directory.
        let video: String
        /// Totals are reported per group, so footage the detector is not built for (handheld,
        /// several people) does not blur the number for footage it is.
        let group: String
        /// Labelled tricks as `[start, end]` seconds; nil for a video nobody has labelled, which
        /// reports its clips without a score.
        let tricks: [[TimeInterval]]?
    }

    let clips: [Clip]
}

/// What one evaluation run found, printed and written to the results directory.
private struct EvaluationReport: Encodable {
    struct ClipResult: Encodable {
        let video: String
        let group: String
        let windows: [[TimeInterval]]
        /// `TrickDetectionScore.summary`; nil for an unlabelled video.
        let score: String?
    }

    let label: String
    let reusedPose: Bool
    private(set) var clips: [ClipResult] = []
    private(set) var totals: [String: String] = [:]
    private var tallies: [String: TrickDetectionTally] = [:]

    init(label: String, reusedPose: Bool) {
        self.label = label
        self.reusedPose = reusedPose
    }

    mutating func add(_ clip: EvaluationManifest.Clip, windows: [TrickWindow]) {
        var summary: String?
        if let tricks = clip.tricks {
            let score = TrickDetectionScore(windows: windows, tricks: tricks.map { $0[0]...$0[1] })
            tallies[clip.group, default: TrickDetectionTally()].add(score)
            totals[clip.group] = tallies[clip.group]?.summary
            summary = score.summary
        }
        clips.append(ClipResult(
            video: clip.video, group: clip.group,
            windows: windows.map { [Self.rounded($0.startTime), Self.rounded($0.endTime)] }, score: summary))
    }

    var lines: [String] {
        let perClip = clips.map { clip in
            let windows = clip.windows.map { "\($0[0])-\($0[1])" }.joined(separator: " ")
            return "\(clip.video) [\(clip.group)] \(clip.score ?? "\(clip.windows.count) clips"): \(windows)"
        }
        return ["\(label)\(reusedPose ? " (saved pose)" : "")"] + perClip
            + totals.keys.sorted().map { "TOTAL [\($0)] \(totals[$0] ?? "")" }
    }

    private enum CodingKeys: String, CodingKey {
        case label, reusedPose, clips, totals
    }

    private static func rounded(_ seconds: TimeInterval) -> TimeInterval {
        (seconds * 10).rounded() / 10
    }
}

/// A run's scored frames and the size their keypoints are normalized against.
private struct SavedPose: Codable {
    struct Frame: Codable {
        let frameIndex: Int
        let timestamp: TimeInterval
        /// `[x, y, confidence]` per keypoint, in `PoseKeypoint.names` order.
        let keypoints: [[Float]]
    }

    let width: Double
    let height: Double
    let frames: [Frame]

    init(frames: [PoseFrameResult], renderSize: CGSize) {
        width = renderSize.width
        height = renderSize.height
        self.frames = frames.map { frame in
            let byName = Dictionary(uniqueKeysWithValues: frame.keypoints.map { ($0.name, $0) })
            return Frame(
                frameIndex: frame.frameIndex,
                timestamp: frame.timestamp,
                keypoints: PoseKeypoint.names.map { name in
                    byName[name].map { [$0.x, $0.y, $0.confidence] } ?? [0, 0, 0]
                })
        }
    }

    var renderSize: CGSize { CGSize(width: width, height: height) }

    var poseFrames: [PoseFrameResult] {
        frames.map { frame in
            PoseFrameResult(
                frameIndex: frame.frameIndex,
                timestamp: frame.timestamp,
                keypoints: zip(PoseKeypoint.names, frame.keypoints).map { name, values in
                    PoseKeypoint(name: name, y: values[1], x: values[0], confidence: values[2])
                })
        }
    }
}
