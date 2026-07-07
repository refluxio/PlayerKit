import CoreVideo
import QuartzCore

// MARK: - VideoColorParams

/// Color space parameters for video rendering.
public struct VideoColorParams: Equatable, Sendable {

    /// Color matrix standard.
    public enum ColorMatrix:  Sendable { case bt709, bt2020, bt601 }
    /// Transfer function (electro-optical).
    public enum TransferFunc: Sendable { case sdr, pq, hlg }
    /// Pixel value range.
    public enum ColorRange:   Sendable { case limited, full }

    /// YCbCr color matrix.
    public var matrix:   ColorMatrix  = .bt709
    /// Transfer characteristic.
    public var transfer: TransferFunc = .sdr
    /// Pixel range (limited for broadcast, full for PC).
    public var range:    ColorRange   = .limited

    /// Create default SDR BT.709 color params.
    public init() {}

    /// Create color params from mpv property strings.
    /// - Parameters:
    ///   - mpvColormatrix: mpv `colormatrix` property value.
    ///   - mpvGamma: mpv `gamma` property value.
    ///   - mpvColorlevels: mpv `colorlevels` property value.
    public init(mpvColormatrix: String?, mpvGamma: String?, mpvColorlevels: String?) {
        switch mpvColormatrix {
        case "bt.2020-ncl", "bt.2020-cl": matrix = .bt2020
        case "bt.601":                    matrix = .bt601
        default:                          matrix = .bt709
        }
        switch mpvGamma {
        case "pq":  transfer = .pq
        case "hlg": transfer = .hlg
        default:    transfer = .sdr
        }
        range = mpvColorlevels == "pc" ? .full : .limited
    }
}

// MARK: - VideoRenderer

/// Renders decoded video frames onto a Core Animation layer.
@MainActor
public protocol VideoRenderer: AnyObject {
    /// The Core Animation layer that displays the video content.
    var layer: CALayer { get }

    /// Render a decoded pixel buffer immediately.
    /// - Parameters:
    ///   - pixelBuffer: Decoded video frame.
    ///   - pts: Presentation timestamp in seconds.
    ///   - colorParams: Color space parameters for the frame.
    func render(pixelBuffer: CVPixelBuffer, pts: Double, colorParams: VideoColorParams)

    /// Flush pending rendering commands.
    func flush()

    /// Clear the renderer surface and show black.
    func clear()
}
