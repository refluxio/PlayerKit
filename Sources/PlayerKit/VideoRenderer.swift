import CoreVideo
import QuartzCore

// MARK: - DolbyVisionFrameMetadata

/// Per-frame Dolby Vision dynamic metadata extracted from the decoded `AVFrame`.
///
/// This is a pure Swift value type — no CFFmpeg dependency — so it can flow
/// through `VideoJitterBuffer` and `VideoColorParams` without leaking FFmpeg
/// types into the open-source PlayerKit surface.
public struct DolbyVisionFrameMetadata: Equatable, Sendable {

    /// DoVi DM Level 1 — per-frame dynamic brightness, PQ-encoded 16-bit.
    public struct Level1: Equatable, Sendable {
        /// Minimum PQ luminance in the frame (0..65535 → 0..1 PQ).
        public var minPq: UInt16
        /// Maximum PQ luminance in the frame.
        public var maxPq: UInt16
        /// Average PQ luminance in the frame.
        public var avgPq: UInt16

        public init(minPq: UInt16, maxPq: UInt16, avgPq: UInt16) {
            self.minPq = minPq
            self.maxPq = maxPq
            self.avgPq = avgPq
        }
    }

    /// DoVi DM Level 6 — static HDR10-like info, typically constant per stream.
    public struct Level6: Equatable, Sendable {
        /// Peak mastering display luminance, cd/m² (0..10000).
        public var maxLuminance: UInt16
        /// Minimum mastering display luminance, 0.0001 cd/m² steps.
        public var minLuminance: UInt16
        /// MaxCLL (maximum content light level), cd/m².
        public var maxCll: UInt16
        /// MaxFALL (maximum frame-average light level), cd/m².
        public var maxFall: UInt16

        public init(maxLuminance: UInt16, minLuminance: UInt16, maxCll: UInt16, maxFall: UInt16) {
            self.maxLuminance = maxLuminance
            self.minLuminance = minLuminance
            self.maxCll = maxCll
            self.maxFall = maxFall
        }
    }

    /// Per-frame dynamic Level 1 metadata. nil if the RPU carried none.
    public var level1: Level1?
    /// Static Level 6 metadata. nil if the RPU carried none.
    public var level6: Level6?
    /// Dolby Vision profile (4/5/7/8). Sourced from stream-level DOVI_CONF.
    public var profile: UInt8
    /// BL signal compatibility id (e.g. 0 = DV-CT, 1 = DV-Mel, 4 = HDR10 fallback).
    public var blSignalCompatibilityId: UInt8

    public init(profile: UInt8 = 0, blSignalCompatibilityId: UInt8 = 0) {
        self.profile = profile
        self.blSignalCompatibilityId = blSignalCompatibilityId
    }
}

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

    /// Per-frame Dolby Vision metadata. nil for non-DV streams (HDR10 / SDR).
    /// Populated by `FFmpegVideoDecoder` when the decoded frame carries
    /// `AV_FRAME_DATA_DOVI_METADATA` side data.
    public var dovi: DolbyVisionFrameMetadata?

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

    /// Whether this renderer requires 10-bit VT output for correct HDR rendering.
    /// EDRRenderer returns true; MetalRenderer uses 8-bit (its CIToneCurve handles fake-PQ).
    var prefersTenBit: Bool { get }

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

    /// Configure renderer with stream-level parameters.
    /// Called once after demuxer open, before the first frame.
    /// - Parameters:
    ///   - codedSize: Bitstream dimensions (may differ from CVPixelBuffer if VT pads).
    ///   - sampleAspectRatio: SAR from the container (1.0 = square pixels).
    func configure(codedSize: CGSize, sampleAspectRatio: Double)
}

public extension VideoRenderer {
    var prefersTenBit: Bool { false }

    func configure(codedSize: CGSize, sampleAspectRatio: Double) {}
}
