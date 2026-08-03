#if canImport(AVKit)
import AVKit
#endif
import AVFoundation
import CoreVideo
import Foundation

/// A minimal playback delegate that keeps PiP from asking for playback control.
@available(iOS 15.0, macOS 12.0, *)
private class PiPPlaybackDelegate: NSObject, AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(_: AVPictureInPictureController, setPlaying _: Bool) {}
    func pictureInPictureControllerTimeRangeForPlayback(_: AVPictureInPictureController) -> CMTimeRange {
        // Return a large finite range so AVKit stays in "playing" state rather
        // than the loading spinner. Exact value doesn't matter since we don't
        // expose scrubbing via this delegate.
        CMTimeRange(start: .zero, duration: CMTime(value: 86400, timescale: 1))
    }
    func pictureInPictureControllerIsPlaybackPaused(_: AVPictureInPictureController) -> Bool {
        false
    }
    func pictureInPictureController(_: AVPictureInPictureController, didTransitionToRenderSize _: CMVideoDimensions) {}
    func pictureInPictureController(_: AVPictureInPictureController, skipByInterval _: CMTime, completion: @escaping () -> Void) {
        completion()
    }
}

@available(iOS 15.0, macOS 12.0, *)
private class PiPDelegateObserver: NSObject, AVPictureInPictureControllerDelegate {
    weak var owner: PiPController?
    init(owner: PiPController) { self.owner = owner }

    func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {}

    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        owner?.onStart?()
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        owner?.onStop?()
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        owner?.onFailedToStart?(error)
    }
}

/// PiP controller backed by a dedicated, video-sized AVSampleBufferDisplayLayer.
///
/// The PiP window size is determined by the content source layer's bounds, NOT
/// by the pixel buffer dimensions inside the sample buffers.  Using the main
/// (full-screen) display layer as the content source causes the PiP window to
/// appear the same size as the device screen.  Instead, this controller owns a
/// private layer sized to the video's actual aspect ratio and receives frames
/// via FrameSink, so the PiP window is the compact overlay users expect.
@available(iOS 15.0, macOS 12.0, *)
public class PiPController: NSObject {
    private let pipController: AVPictureInPictureController
    // Dedicated small layer used as the PiP content source.
    // Its bounds drive the PiP window aspect ratio; frames are forwarded here
    // from the main renderer via the FrameSink conformance below.
    private let pipLayer: AVSampleBufferDisplayLayer
    private let delegate = PiPPlaybackDelegate()
    private var delegateObserver: PiPDelegateObserver?
    // Track the last pixel dimensions to avoid redundant layer resizes.
    private var lastPixelWidth: Int = 0
    private var lastPixelHeight: Int = 0

    /// Fired when PiP stops (user dismisses PiP or system stops it).
    /// Called on the main thread.
    public var onStop: (() -> Void)?
    /// Fired when PiP starts. Called on the main thread.
    public var onStart: (() -> Void)?
    /// Fired when PiP fails to start. Called on the main thread.
    public var onFailedToStart: ((Error) -> Void)?

    public var isActive: Bool { pipController.isPictureInPictureActive }
    public var isPossible: Bool { pipController.isPictureInPicturePossible }

    public override init() {
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        // Default 16:9; resized to actual video aspect ratio on first received frame.
        layer.frame = CGRect(origin: .zero, size: CGSize(width: 320, height: 180))
        self.pipLayer = layer

        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: layer,
            playbackDelegate: delegate
        )
        pipController = AVPictureInPictureController(contentSource: source)
        super.init()
        let obs = PiPDelegateObserver(owner: self)
        pipController.delegate = obs
        delegateObserver = obs
    }

    public func start() {
        guard !isActive else { return }
        pipController.startPictureInPicture()
    }

    public func stop() {
        guard isActive else { return }
        pipController.stopPictureInPicture()
    }
}

// MARK: - FrameSink

@available(iOS 15.0, macOS 12.0, *)
extension PiPController: FrameSink {
    @MainActor
    public func receive(pixelBuffer: CVPixelBuffer, pts: Double) {
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        if w != lastPixelWidth || h != lastPixelHeight, w > 0, h > 0 {
            lastPixelWidth = w; lastPixelHeight = h
            let aspect = CGFloat(w) / CGFloat(h)
            pipLayer.frame = CGRect(origin: .zero,
                                    size: CGSize(width: 320, height: 320 / aspect))
        }

        guard let sbuf = makeSampleBuffer(pixelBuffer: pixelBuffer, pts: pts) else { return }
        pipLayer.enqueue(sbuf)
    }

    private func makeSampleBuffer(pixelBuffer: CVPixelBuffer, pts: Double) -> CMSampleBuffer? {
        var formatDesc: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDesc
        ) == noErr, let fd = formatDesc else { return nil }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(seconds: pts, preferredTimescale: 90000),
            decodeTimeStamp: .invalid
        )
        var sbuf: CMSampleBuffer?
        guard CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: fd,
            sampleTiming: &timing,
            sampleBufferOut: &sbuf
        ) == noErr else { return nil }
        return sbuf
    }
}
