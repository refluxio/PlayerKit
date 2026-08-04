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
/// PiP window aspect ratio is controlled via preferredContentSize (iOS 16+).
/// The display layer stays full-screen so the PiP expand/collapse animation
/// is smooth — no snap from video-rect back to full-screen on return.
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
    /// On iOS 16+ this feeds preferredContentSize so the PiP window has the
    /// correct aspect ratio without needing to resize the display layer.
    public var videoSize: CGSize? {
        didSet {
            guard let size = videoSize, size.width > 0, size.height > 0 else { return }
            if #available(iOS 16.0, macOS 13.0, *) {
                pipController.preferredContentSize = size
            }
        }
    }

    public var isActive: Bool { pipController.isPictureInPictureActive }
    public var isPossible: Bool { pipController.isPictureInPicturePossible }

    public init?(displayLayer: AVSampleBufferDisplayLayer) {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return nil }
        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: displayLayer,
            playbackDelegate: delegate
        )
        pipController = AVPictureInPictureController(contentSource: source)
        // Let the system start PiP automatically when the app backgrounds
        // (after rotation animation settles, GPU safe). No manual pip.start()
        // from willResignActive needed — that path races with orientation changes.
        if #available(iOS 14.2, macOS 11.0, *) {
            pipController.canStartPictureInPictureAutomaticallyFromInline = true
        }
        self.displayLayer = displayLayer
        super.init()
        let obs = PiPDelegateObserver(owner: self)
        pipController.delegate = obs
        delegateObserver = obs
    }

    public func start() {
        guard !isActive else { return }
        // Do NOT resize the display layer before starting PiP.
        // Keeping the layer full-screen ensures the expand/collapse animation
        // is smooth — resizing to video-rect causes a visible snap on return.
        // preferredContentSize (set via videoSize) handles the window proportion.
        pipController.startPictureInPicture()
    }

    public func stop() {
        guard isActive else { return }
        pipController.stopPictureInPicture()
    }
}
