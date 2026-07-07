import Foundation
import QuartzCore

public enum BackendType: Sendable {
    case native
    case mpv
}

public enum RenderPath: Sendable {
    case sw
    case glMetal
    case metal
}

/// Full backend: combines playback control, a renderer, and frame-sink management.
/// NativeBackend and MPVBackend conform to this protocol.
@MainActor
public protocol PlayerBackend: Playable {
    var renderer: any VideoRenderer { get }
    func addFrameSink(_ sink: any FrameSink)
    func removeFrameSink(_ sink: any FrameSink)
    func prepareForReuse()
}
