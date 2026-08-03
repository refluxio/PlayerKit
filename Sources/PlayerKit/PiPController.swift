#if canImport(AVKit)
import AVKit
#endif
import AVFoundation
import Foundation
import QuartzCore

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

/// PiP controller backed by the main ASBDLRenderer display layer.
///
/// The PiP window size is determined by the content source layer's bounds.
/// PlayerNativeView sizes the displayLayer to match the video's actual aspect
/// ratio (excluding letterbox/pillarbox bars), so the PiP window gets the
/// correct compact size rather than the full-screen portrait bounds.
@available(iOS 15.0, macOS 12.0, *)
public class PiPController: NSObject {
    private let pipController: AVPictureInPictureController
    private let displayLayer: AVSampleBufferDisplayLayer
    private let delegate = PiPPlaybackDelegate()
    private var delegateObserver: PiPDelegateObserver?

    /// Fired when PiP stops (user dismisses PiP or system stops it).
    /// Called on the main thread.
    public var onStop: (() -> Void)?
    /// Fired when PiP starts. Called on the main thread.
    public var onStart: (() -> Void)?
    /// Fired when PiP fails to start. Called on the main thread.
    public var onFailedToStart: ((Error) -> Void)?

    /// Video's native dimensions. Set by Player when videoInfo becomes available.
    /// Used to resize the display layer to the correct aspect ratio before starting PiP,
    /// ensuring the PiP window reflects the video shape rather than the full-screen layer.
    public var videoSize: CGSize?

    public var isActive: Bool { pipController.isPictureInPictureActive }
    public var isPossible: Bool { pipController.isPictureInPicturePossible }

    public init?(displayLayer: AVSampleBufferDisplayLayer) {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return nil }
        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: displayLayer,
            playbackDelegate: delegate
        )
        pipController = AVPictureInPictureController(contentSource: source)
        self.displayLayer = displayLayer
        super.init()
        let obs = PiPDelegateObserver(owner: self)
        pipController.delegate = obs
        delegateObserver = obs
    }

    public func start() {
        guard !isActive else { return }
        resizeDisplayLayerForPiP()
        pipController.startPictureInPicture()
    }

    /// Resize the display layer to the video's actual aspect-ratio rect within its
    /// superlayer. Called right before startPictureInPicture() so the PiP window
    /// reads the correct bounds regardless of whether layoutSubviews() has run.
    private func resizeDisplayLayerForPiP() {
        guard let size = videoSize, size.width > 0, size.height > 0 else { return }
        guard let superlayer = displayLayer.superlayer else { return }
        let container = superlayer.bounds.size
        guard container.width > 0, container.height > 0 else { return }
        let aspect = size.width / size.height
        let containerAspect = container.width / container.height
        let frame: CGRect
        if aspect > containerAspect {
            let h = container.width / aspect
            frame = CGRect(x: 0, y: (container.height - h) / 2, width: container.width, height: h)
        } else {
            let w = container.height * aspect
            frame = CGRect(x: (container.width - w) / 2, y: 0, width: w, height: container.height)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = frame
        displayLayer.videoGravity = .resize
        CATransaction.commit()
    }

    public func stop() {
        guard isActive else { return }
        pipController.stopPictureInPicture()
    }
}
