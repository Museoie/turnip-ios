import AVFoundation
import CoreImage

/// The editor item's one composition instruction (`PreviewFrames.composition`): the source track,
/// and where its frames go on the render size.
final class PreviewCompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = false
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let trackID: CMPersistentTrackID
    /// From the encoded frame onto the render size, upright and scaled, in Core Image's coordinates
    /// (`PreviewCompositor.transform(track:scale:)`).
    let transform: CGAffineTransform

    init(timeRange: CMTimeRange, trackID: CMPersistentTrackID, transform: CGAffineTransform) {
        self.timeRange = timeRange
        self.trackID = trackID
        self.transform = transform
        requiredSourceTrackIDs = [NSNumber(value: trackID)]
    }
}

/// Draws the editor's frames ahead of the display, off the main thread: each source frame turned
/// upright at the preview's size, a standard-range frame in its own colour as it was, and an HDR
/// frame tone mapped to standard range with the system's tone mapper at the frame's own headroom,
/// then encoded as Rec. 709 video the way an SDR camera take is.
///
/// The preview's plain layer (`EditorPlayerView`) would otherwise tone map an HLG frame itself,
/// with shadows and midtones about a tenth darker than the `AVPlayerLayer` the tile plays through
/// (iPhone 13 mini), and the composition engine's own conversion to standard range is darker still.
/// The compositor takes the source frames as they are decoded, colour and all
/// (`supportsHDRSourceFrames`, `canConformColorOfSourceFrames`), so neither conversion runs first.
@available(iOS 18.0, *)
final class PreviewCompositor: NSObject, AVVideoCompositing {
    /// What the frames are drawn in, and what a source without colour tags is read as.
    static let colorSpace = CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpaceCreateDeviceRGB()

    private let context = CIContext(options: [.cacheIntermediates: false])

    /// The decoder's own formats, so a source frame reaches the compositor without a conversion.
    let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: [
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelFormatType_32BGRA
        ]
    ]
    // The name is `AVVideoCompositing`'s own.
    // swiftlint:disable:next identifier_name
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]
    let supportsHDRSourceFrames = true
    let supportsWideColorSourceFrames = true
    let canConformColorOfSourceFrames = true

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? PreviewCompositionInstruction,
              let source = request.sourceFrame(byTrackID: instruction.trackID),
              let output = request.renderContext.newPixelBuffer()
        else {
            request.finish(with: NSError(domain: "PreviewCompositor", code: 1))
            return
        }
        let frame = Self.frame(from: source, transform: instruction.transform)
        context.render(
            frame.image, to: output, bounds: CGRect(origin: .zero, size: request.renderContext.size),
            colorSpace: frame.colorSpace)
        // The colour tags the drawn values are in: the source's own, or Rec. 709 for a tone mapped frame.
        CVBufferRemoveAllAttachments(output)
        if frame.isToneMapped {
            let rec709: [(CFString, CFString)] = [
                (kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2),
                (kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2),
                (kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
            ]
            for (key, value) in rec709 {
                CVBufferSetAttachment(output, key, value, .shouldPropagate)
            }
        } else {
            CVBufferPropagateAttachments(source, output)
        }
        request.finish(withComposedVideoFrame: output)
    }

    /// `source` read in its own colour space and moved by `transform`, with the colour space to
    /// draw it in: its own for a standard-range frame, so it comes through unchanged, or Rec. 709
    /// for an HDR frame, tone mapped to standard range first. A source without colour tags is read
    /// and drawn as Rec. 709.
    static func frame(from source: CVPixelBuffer, transform: CGAffineTransform) -> PreviewCompositorFrame {
        let attachments = CVBufferCopyAttachments(source, .shouldPropagate)
        let space = attachments.flatMap { CVImageBufferCreateColorSpaceFromAttachments($0)?.takeRetainedValue() }
            ?? colorSpace
        let image = CIImage(cvPixelBuffer: source, options: [.colorSpace: space])
        guard image.contentHeadroom > 1 else {
            return PreviewCompositorFrame(
                image: image.transformed(by: transform), colorSpace: space, isToneMapped: false)
        }
        let mapped = image.applyingFilter("CIToneMapHeadroom", parameters: [
            "inputSourceHeadroom": NSNumber(value: image.contentHeadroom),
            "inputTargetHeadroom": NSNumber(value: 1)
        ])
        return PreviewCompositorFrame(
            image: mapped.transformed(by: transform), colorSpace: colorSpace, isToneMapped: true)
    }

    /// The encoded frame turned upright and scaled by `scale`, in Core Image's coordinates (y up),
    /// so it lands on `[0, displayedSize × scale]` as `track.uprightTransform` places it in pixels.
    static func transform(track: VideoTrackGeometry, scale: CGFloat) -> CGAffineTransform {
        let intoPixels = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: track.naturalSize.height)
        let outOfPixels = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: track.displayedSize.height * scale)
        return intoPixels
            .concatenating(track.uprightTransform)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(outOfPixels)
    }
}

/// A source frame ready to draw (`PreviewCompositor.frame(from:transform:)`): the image, the colour
/// space to draw it in, and whether it was tone mapped from HDR.
struct PreviewCompositorFrame {
    let image: CIImage
    let colorSpace: CGColorSpace
    let isToneMapped: Bool
}
