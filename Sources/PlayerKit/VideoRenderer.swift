import CoreVideo
import QuartzCore

// MARK: - VideoColorParams

public struct VideoColorParams: Equatable, Sendable {

    public enum ColorMatrix:  Sendable { case bt709, bt2020, bt601 }
    public enum TransferFunc: Sendable { case sdr, pq, hlg }
    public enum ColorRange:   Sendable { case limited, full }

    public var matrix:   ColorMatrix  = .bt709
    public var transfer: TransferFunc = .sdr
    public var range:    ColorRange   = .limited

    public init() {}

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

@MainActor
public protocol VideoRenderer: AnyObject {
    var layer: CALayer { get }
    func render(pixelBuffer: CVPixelBuffer, pts: Double)
    func flush()
    func clear()
    func updateColorParams(_ params: VideoColorParams)
}
