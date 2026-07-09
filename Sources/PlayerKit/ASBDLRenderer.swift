import AVFoundation
import CoreVideo

/// A processor that applies custom tone-mapping to a pixel buffer before
/// display. Implemented by PlayerKitPro's ToneMapProcessor for Pro users.
public protocol ToneMapping: AnyObject {
    func process(pixelBuffer: CVPixelBuffer,
                 colorParams: VideoColorParams,
                 metadata: FrameMetadata,
                 strategy: RendererStrategy?) -> CVPixelBuffer
}

/// Video renderer wrapping `AVSampleBufferDisplayLayer`.
///
/// `AVSampleBufferDisplayLayer` is a Core Animation layer that handles
/// pixel-buffer-to-display rendering natively via the video pipeline,
/// including HDR tone-mapping and display refresh coordination.
///
/// This renderer is best suited for:
/// - HDR (PQ/HLG) content where system-level EDR is desired.
/// - 10-bit pixel formats.
/// - Streams that don't require custom shader-based processing.
///
/// It is **not** suitable for:
/// - Dolby Vision Profile 5 (needs custom RPU injection).
/// - Real-time filter chains.
public class ASBDLRenderer: VideoRenderer {

    public let displayLayer: AVSampleBufferDisplayLayer
    public var layer: CALayer { displayLayer }

    public var prefersTenBit: Bool { true }

    public var displayCapability: DisplayCapability

    /// Optional tone-mapping processor (injected by PlayerKitPro for Pro users).
    /// When non-nil, pixel buffers are processed before enqueuing to the display layer.
    public var toneMapper: (any ToneMapping)?

    public init(displayCapability: DisplayCapability = .macSDR) {
        self.displayCapability = displayCapability
        displayLayer = AVSampleBufferDisplayLayer()
        displayLayer.videoGravity = .resizeAspect
    }

    public func render(
        pixelBuffer: CVPixelBuffer,
        pts: Double,
        colorParams: VideoColorParams,
        metadata: FrameMetadata,
        strategy: RendererStrategy?
    ) {
        let pb = toneMapper?.process(pixelBuffer: pixelBuffer, colorParams: colorParams, metadata: metadata, strategy: strategy) ?? pixelBuffer
        let cmPts = CMTime(seconds: pts, preferredTimescale: 90000)
        guard let sbuf = makeSampleBuffer(pixelBuffer: pb, pts: cmPts) else { return }
        displayLayer.enqueue(sbuf)
    }

    public func flush() {
        displayLayer.flushAndRemoveImage()
    }

    public func clear() {
        displayLayer.flushAndRemoveImage()
        // Show black to satisfy the protocol "show black" contract.
        displayLayer.isHidden = true
    }

    public func configure(codedSize: CGSize, sampleAspectRatio: Double) {
        // ASBDL auto-configures from sample buffers; no explicit config needed.
    }

    private func makeSampleBuffer(pixelBuffer: CVPixelBuffer, pts: CMTime) -> CMSampleBuffer? {
        var formatDesc: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDesc
        )
        guard status == noErr, let fd = formatDesc else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime.invalid,
            presentationTimeStamp: pts,
            decodeTimeStamp: CMTime.invalid
        )

        var sampleBuffer: CMSampleBuffer?
        let sbufStatus = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: fd,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard sbufStatus == noErr, let sbuf = sampleBuffer else { return nil }
        return sbuf
    }
}
