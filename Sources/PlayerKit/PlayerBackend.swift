import Foundation
import QuartzCore

/// Player backend implementation type.
public enum BackendType: Sendable {
    /// Native AVFoundation-based backend.
    case native
    /// mpv (libmpv) based backend.
    case mpv
}

/// Rendering path used by the backend.
public enum RenderPath: Sendable {
    /// Software decoding, CPU-only rendering.
    case sw
    /// OpenGL/Metal interop (mpv --vo=gpu with libmpv).
    case glMetal
    /// Native Metal rendering (preferred).
    case metal
}

/// Full backend: combines playback control, a renderer, and frame-sink management.
/// NativeBackend and MPVBackend conform to this protocol.
@MainActor
public protocol PlayerBackend: Playable {
    /// The video renderer associated with this backend.
    var renderer: any VideoRenderer { get }

    /// Register a frame sink to receive decoded video frames.
    func addFrameSink(_ sink: any FrameSink)

    /// Remove a previously registered frame sink.
    func removeFrameSink(_ sink: any FrameSink)

    /// Reset the backend for reuse with new media. Releases current resources.
    func prepareForReuse()
}
