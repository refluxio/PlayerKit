#if canImport(AVKit)
import AVKit
#endif
import AVFoundation
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

    /// Set the video's native dimensions so the PiP window uses the correct
    /// aspect ratio.  For sampleBufferDisplayLayer-based PiP the system cannot
    /// derive this automatically — without it, the system falls back to the
    /// display layer's full-screen bounds, producing an incorrectly sized window.
    public func setPreferredContentSize(_ size: CGSize) {
        pipController.preferredContentSize = size
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
