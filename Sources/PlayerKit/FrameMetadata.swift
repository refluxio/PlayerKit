import Foundation
import CoreVideo

/// Per-frame HDR side-data bundle — DoVi + HDR10+ + mastering display + CLL.
///
/// Extracted from the decoded `AVFrame` by `FFmpegVideoDecoder` before
/// `av_frame_free`. Travels through `VideoJitterBuffer.Frame` to the renderer
/// alongside the pixel buffer. VT-decoded frames carry an empty `FrameMetadata()`
/// (VT strips all HDR side data).
///
/// This is a pure Swift value type — no CFFmpeg dependency — so it can flow
/// through the open-source PlayerKit surface without leaking FFmpeg types.
public struct FrameMetadata: Sendable, Equatable {

    /// Dolby Vision DM metadata (per-frame Level 1 + static Level 6).
    /// Present only when the stream is DV Profile 5/7/8 AND the decoder is
    /// FFmpeg software (VT strips the RPU).
    public var dovi: DolbyVisionFrameMetadata?

    /// HDR10+ ST 2094-40 dynamic metadata (per-frame bezier curve).
    /// Present only for HDR10+ streams decoded via FFmpeg SW.
    public var hdr10Plus: HDR10PlusFrameMetadata?

    /// Mastering display characteristics (AV_FRAME_DATA_MASTERING_DISPLAY_METADATA).
    /// Typically constant per stream but technically per-frame.
    public var masteringDisplay: MasteringDisplayMetadata?

    /// Content light level (AV_FRAME_DATA_CONTENT_LIGHT_LEVEL).
    /// MaxCLL / MaxFALL — typically constant per stream.
    public var contentLightLevel: ContentLightLevelMetadata?

    public init() {}

    public init(dovi: DolbyVisionFrameMetadata?,
                hdr10Plus: HDR10PlusFrameMetadata?,
                masteringDisplay: MasteringDisplayMetadata?,
                contentLightLevel: ContentLightLevelMetadata?) {
        self.dovi = dovi
        self.hdr10Plus = hdr10Plus
        self.masteringDisplay = masteringDisplay
        self.contentLightLevel = contentLightLevel
    }
}

/// SMPTE ST 2086 mastering display characteristics.
///
/// `maxLuminance` is in cd/m² (0..10000). `minLuminance` is in 0.0001 cd/m²
/// steps (0..65535). Primaries are CIE 1931 chromaticities in 0.00002 increments.
public struct MasteringDisplayMetadata: Sendable, Equatable {
    /// Peak mastering display luminance, cd/m² (0..10000).
    public var maxLuminance: UInt16
    /// Minimum mastering display luminance, 0.0001 cd/m² steps (0..65535).
    public var minLuminance: UInt16
    /// Display primaries, in order: G(x,y), B(x,y), R(x,y), WhitePoint(x,y).
    /// Each value is 0..50000 (0.00002 increments).
    public var primaries: (UInt16, UInt16, UInt16, UInt16, UInt16, UInt16, UInt16, UInt16)

    public init(maxLuminance: UInt16,
                minLuminance: UInt16,
                primaries: (UInt16, UInt16, UInt16, UInt16, UInt16, UInt16, UInt16, UInt16)) {
        self.maxLuminance = maxLuminance
        self.minLuminance = minLuminance
        self.primaries = primaries
    }

    public static func == (lhs: MasteringDisplayMetadata, rhs: MasteringDisplayMetadata) -> Bool {
        guard lhs.maxLuminance == rhs.maxLuminance,
              lhs.minLuminance == rhs.minLuminance else { return false }
        let lp = lhs.primaries, rp = rhs.primaries
        return lp.0 == rp.0 && lp.1 == rp.1 && lp.2 == rp.2 && lp.3 == rp.3
            && lp.4 == rp.4 && lp.5 == rp.5 && lp.6 == rp.6 && lp.7 == rp.7
    }

    /// Synthesize a default BT.2020 / 1000-nit mastering display when the
    /// stream lacks ST 2086 side data. Used as a fallback by `BT2390Static`.
    public static let defaultBT2020_1000nit = MasteringDisplayMetadata(
        maxLuminance: 1000,
        minLuminance: 1,  // 0.0001 cd/m²
        primaries: (15000, 30000,    // G (0.30, 0.60) — approx BT.2020 green
                    7500, 3000,      // B (0.15, 0.06)
                    35400, 14600,    // R (0.708, 0.292)
                    15635, 16450))   // White (0.3127, 0.329)
}

/// Content light level (MaxCLL / MaxFALL).
public struct ContentLightLevelMetadata: Sendable, Equatable {
    /// Maximum content light level, cd/m².
    public var maxCll: UInt16
    /// Maximum frame-average light level, cd/m².
    public var maxFall: UInt16

    public init(maxCll: UInt16, maxFall: UInt16) {
        self.maxCll = maxCll
        self.maxFall = maxFall
    }
}

/// HDR10+ ST 2094-40 per-frame dynamic metadata.
///
/// Only the bezier curve part is captured — that's what drives the tone-map.
/// Theoretically there's also targeted/luminance parameters, but those overlap
/// with DoVi L1 semantics and aren't commonly authored.
public struct HDR10PlusFrameMetadata: Sendable, Equatable {

    /// Bezier curve tone-map defined by up to 9 control points (anchors).
    /// `anchors[0]` is always 0.0, `anchors[count-1]` is always 1.0; intermediate
    /// anchors define the knee. `count` may be 2..10 (1 fixed + up to 9 from the
    /// SEI). We store all 10 in a fixed-size tuple for buffer-friendliness.
    public struct BezierCurve: Sendable, Equatable {
        /// Control point x/y values in 0..1. Unused slots are 0.
        public var anchors: (Float, Float, Float, Float, Float, Float, Float, Float, Float, Float)
        /// Actual number of valid anchors (2..10).
        public var count: Int

        public init(anchors: (Float, Float, Float, Float, Float, Float, Float, Float, Float, Float),
                    count: Int) {
            self.anchors = anchors
            self.count = count
        }

        public static func == (lhs: BezierCurve, rhs: BezierCurve) -> Bool {
            guard lhs.count == rhs.count else { return false }
            let la = lhs.anchors, ra = rhs.anchors
            return la.0 == ra.0 && la.1 == ra.1 && la.2 == ra.2 && la.3 == ra.3
                && la.4 == ra.4 && la.5 == ra.5 && la.6 == ra.6 && la.7 == ra.7
                && la.8 == ra.8 && la.9 == ra.9
        }
    }

    /// Targeted system display maximum luminance, cd/m².
    public var targetedSystemDisplayMaxLuminance: UInt16

    /// Per-frame bezier curve. nil when the SEI carried only static fields.
    public var bezierCurve: BezierCurve?

    public init(targetedSystemDisplayMaxLuminance: UInt16,
                bezierCurve: BezierCurve? = nil) {
        self.targetedSystemDisplayMaxLuminance = targetedSystemDisplayMaxLuminance
        self.bezierCurve = bezierCurve
    }
}
