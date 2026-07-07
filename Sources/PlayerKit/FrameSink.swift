import CoreVideo

@MainActor
public protocol FrameSink: AnyObject {
    func receive(pixelBuffer: CVPixelBuffer, pts: Double)
}
