import CoreVideo

/// Receiver of decoded video frames. Conforming types process raw pixel buffers.
@MainActor
public protocol FrameSink: AnyObject {
    /// Deliver a decoded video frame.
    /// - Parameters:
    ///   - pixelBuffer: Decoded pixel buffer.
    ///   - pts: Presentation timestamp in seconds.
    func receive(pixelBuffer: CVPixelBuffer, pts: Double)
}
