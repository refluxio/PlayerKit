import Foundation
import CoreVideo

/// Snapshot of HDR-relevant stream attributes. Built once from the demuxer's
/// video stream + codec parameters; passed to `decideRendererStrategy`.
///
/// `VideoColorParams` carries the same matrix/transfer/range fields, but
/// `VideoStreamAttributes` additionally captures DoVi profile and HDR10+ flag,
/// which `VideoColorParams` doesn't know about (color params travel per-frame
/// through the jitter buffer; stream attributes are read once at open time).
public struct VideoStreamAttributes: Sendable {

    public var width: Int
    public var height: Int

    /// FFmpeg codec id (AV_CODEC_ID_HEVC, AV_CODEC_ID_H264, ...).
    public var codecID: UInt32

    public var colorMatrix: VideoColorParams.ColorMatrix
    public var transfer: VideoColorParams.TransferFunc
    public var range: VideoColorParams.ColorRange

    /// True when the stream carries a Dolby Vision configuration record.
    public var isDolbyVision: Bool

    /// DV profile (4/5/7/8). 0 when `isDolbyVision` is false.
    public var doviProfile: UInt8

    /// BL signal compatibility id from the DV config record.
    /// 1 = DV-Mel, 2 = DV-CT (HDR10 fallback), etc. 0 when non-DV.
    public var blSignalCompatibilityId: UInt8

    /// True when the stream carries HDR10+ ST 2094-40 dynamic metadata.
    /// Stream-level hint; per-frame bezier data arrives via `FrameMetadata.hdr10Plus`.
    public var hasHDR10Plus: Bool

    /// True when the stream is HEVC (H.265) and the codec reports 10-bit
    /// samples. Used by `decideRendererStrategy` to detect unmarked HDR10:
    /// many Blu-ray remuxes ship HEVC 10-bit PQ content without writing the
    /// `color_trc` tag into the MKV container, so FFmpeg reads transfer=SDR
    /// even though the pixels are PQ. See "未标记 HDR10 的判定" in
    /// `Docs/hdr-rendering.md`.
    public var isHEVC10Bit: Bool

    public init(width: Int,
                height: Int,
                codecID: UInt32,
                colorMatrix: VideoColorParams.ColorMatrix,
                transfer: VideoColorParams.TransferFunc,
                range: VideoColorParams.ColorRange,
                isDolbyVision: Bool = false,
                doviProfile: UInt8 = 0,
                blSignalCompatibilityId: UInt8 = 0,
                hasHDR10Plus: Bool = false,
                isHEVC10Bit: Bool = false) {
        self.width = width
        self.height = height
        self.codecID = codecID
        self.colorMatrix = colorMatrix
        self.transfer = transfer
        self.range = range
        self.isDolbyVision = isDolbyVision
        self.doviProfile = doviProfile
        self.blSignalCompatibilityId = blSignalCompatibilityId
        self.hasHDR10Plus = hasHDR10Plus
        self.isHEVC10Bit = isHEVC10Bit
    }

    /// Heuristic: HEVC + 10-bit + transfer=SDR is almost certainly an unmarked
    /// HDR10 stream (PQ pixels with a missing `color_trc` tag), not a genuine
    /// 10-bit SDR upload. Broadcast SDR is 8-bit H.264 or 10-bit H.265 with
    /// an explicit transfer tag; 10-bit HEVC SDR is essentially nonexistent in
    /// real sources. See "未标记 HDR10 的判定" in `Docs/hdr-rendering.md`.
    public var isHEVC10BitSDRHint: Bool {
        isHEVC10Bit && transfer == .sdr
    }
}

/// Which decoder to instantiate for a stream.
public enum DecoderPreference: Sendable, Equatable {
    /// FFmpeg software decoder (`FFmpegVideoDecoder` with `forceSoftware: true`).
    /// Required for DoVi Profile 5/8 (VT strips RPU) and HDR10+ (VT strips ST 2094-40).
    case ffmpegSW
    /// FFmpeg VideoToolbox hardware acceleration. Used for non-DV HEVC/H.264 when
    /// the renderer wants 10-bit VT output.
    case ffmpegHW
    /// VideoToolbox direct (`VTVideoDecoder`). Used for SDR HEVC/H.264 — fastest
    /// path, gives Metal-compatible IOSurface-backed CVPixelBuffers directly.
    case vtHW
}

/// Which renderer pipeline to run for a stream.
public enum RendererEntry: Sendable, Equatable {
    /// EDRRenderer 10-bit Metal HDR pipeline.
    case metalHDR
    /// 8-bit CoreImage SDR pipeline (MetalRenderer.display's non-HDR branch).
    case ciSDR
    /// 8-bit CoreImage pipeline with EDR color space + CIToneCurve (non-EDR
    /// display playing HDR content — fake-PQ path).
    case ciEDRFallback
}

/// Concrete tone-mapping algorithm variant to instantiate in `EDRRenderer`.
public enum ToneMappingAlgorithmKind: Sendable, Equatable {
    /// No tone-map — SDR 8-bit / 10-bit content.
    case passthroughSDR
    /// Static BT.2390 EETF using mastering display peak luminance.
    case bt2390Static
    /// BT.2390 EETF driven by DoVi DM Level 1 per-frame dynamic metadata.
    case bt2390DoViL1
    /// HDR10+ ST 2094-40 bezier curve tone-map.
    case hdr10PlusDynamic
    /// HLG OOTF + static tone-map (broadcast HLG on EDR displays).
    case hlgOOTF
}

/// Result of `decideRendererStrategy` — the full rendering recipe for a stream.
///
/// A single value carries decoder preference, renderer entry and tone-map
/// algorithm together so the three-way coupling (DoVi → SW decoder + Metal HDR
/// pipeline + L1 tone-map) is impossible to express inconsistently.
public enum RendererStrategy: Sendable, Equatable {

    /// SDR 8-bit content (BT.709 or BT.601). Goes through CI SDR pipeline.
    case sdr8Bit(matrix: VideoColorParams.ColorMatrix)
    /// SDR 10-bit content (e.g. 10-bit H.264 still goes through CI).
    case sdr10Bit
    /// HDR10 PQ with static mastering display metadata. EDR displays use Metal
    /// HDR + BT.2390 static; non-EDR fall back to CI EDR fallback.
    case hdr10Static(peakNits: UInt16)
    /// HDR10+ ST 2094-40 dynamic metadata. Requires FFmpeg SW (VT strips it).
    case hdr10Plus
    /// Dolby Vision Profile 5 (Netflix/Disney exclusive). FFmpeg SW + Metal HDR
    /// + DoVi L1 dynamic tone-map.
    case doviProfile5
    /// Dolby Vision Profile 8 (HDR10-compatible). `tonemapCompat` is true when
    /// bl_signal_compatibility_id == 2 (CT, HDR10-compatible fallback).
    case doviProfile8(tonemapCompat: Bool)
    /// HLG broadcast content on an EDR display — apply OOTF + tone-map.
    case hlgOOTF
    /// DoVi Profile 7 (BL+EL dual-layer) — VT hardcodes as HDR10; software
    /// dual-layer decode is out of scope. Falls back to `hdr10Static` path
    /// when VT handles it.
    case degradedHDR10

    /// True when this strategy needs 10-bit pixel buffers from the decoder.
    public var pixelFormat10Bit: Bool {
        switch self {
        case .sdr8Bit:       return false
        case .sdr10Bit:      return true
        case .hdr10Static, .hdr10Plus, .doviProfile5, .doviProfile8, .hlgOOTF, .degradedHDR10:
            return true
        }
    }

    /// Which decoder to instantiate.
    public var decoderPreference: DecoderPreference {
        switch self {
        case .doviProfile5, .doviProfile8, .hdr10Plus:
            // VT strips DoVi RPU and HDR10+ ST 2094-40 metadata; must go SW.
            return .ffmpegSW
        case .hdr10Static, .hlgOOTF, .degradedHDR10:
            // HEVC HDR10 / HLG — FFmpeg VT hwaccel gives 10-bit IOSurface-backed output.
            return .ffmpegHW
        case .sdr8Bit, .sdr10Bit:
            // SDR HEVC/H.264 — VT direct is the fastest path.
            return .vtHW
        }
    }

    /// Which renderer pipeline to run.
    /// - Note: The EDR fallback path is decided per-display here, so the caller
    ///   doesn't need a separate `displayCapability.supportsEDR` check at render time.
    public func rendererEntry(display: DisplayCapability) -> RendererEntry {
        switch self {
        case .sdr8Bit, .sdr10Bit:
            return .ciSDR
        case .hdr10Static, .hdr10Plus, .doviProfile5, .doviProfile8, .hlgOOTF, .degradedHDR10:
            return display.supportsEDR ? .metalHDR : .ciEDRFallback
        }
    }

    /// Which tone-mapping algorithm to instantiate in EDRRenderer.
    public var toneMapAlgorithm: ToneMappingAlgorithmKind {
        switch self {
        case .sdr8Bit, .sdr10Bit:                return .passthroughSDR
        case .hdr10Static, .degradedHDR10:      return .bt2390Static
        case .hdr10Plus:                        return .hdr10PlusDynamic
        case .doviProfile5, .doviProfile8:       return .bt2390DoViL1
        case .hlgOOTF:                          return .hlgOOTF
        }
    }
}

/// Pure function: pick a `RendererStrategy` from stream attributes + display
/// capability + renderer preference (EDRRenderer.prefersTenBit == true).
///
/// Decision order (spec §5):
/// 1. DoVi Profile 5 → `doviProfile5` (EDR) or `degradedHDR10` (non-EDR)
/// 2. DoVi Profile 8 → `doviProfile8` (EDR) or `degradedHDR10` (non-EDR)
/// 3. DoVi Profile 7 → `degradedHDR10` (always — VT handles as HDR10)
/// 4. HDR10+ → `hdr10Plus` (EDR) or `hdr10Static` (non-EDR)
/// 5. HLG → `hlgOOTF` (EDR) or `hdr10Static` (non-EDR)
/// 6. HDR10 PQ → `hdr10Static`
/// 7. SDR → `sdr8Bit` / `sdr10Bit`
///
/// When `prefersTenBit` is false (MetalRenderer / SDR-only renderer), all HDR
/// strategies fall back to `sdr8Bit` since the Metal HDR pipeline requires
/// 10-bit VT output. The caller is expected to keep the SDR path active.
public func decideRendererStrategy(
    stream: VideoStreamAttributes,
    prefersTenBit: Bool,
    display: DisplayCapability
) -> RendererStrategy {
    // Non-EDR display + non-10-bit renderer → always SDR path.
    // (Even HDR content on MetalRenderer / SDR-only renderer renders as SDR
    // via the CIToneCurve fake-PQ path; no point pretending it's HDR.)
    let edrCapable = display.supportsEDR && prefersTenBit

    // 1. Dolby Vision
    if stream.isDolbyVision {
        switch stream.doviProfile {
        case 5:
            return edrCapable ? .doviProfile5 : .degradedHDR10
        case 8:
            // bl_signal_compatibility_id == 2 → HDR10-compatible ("CT" mode).
            // These streams are designed to be played as HDR10 when DV is
            // unavailable — tonemapCompat flag tells EDRRenderer whether to
            // apply the DV L1 dynamic tone-map or fall back to BT.2390 static.
            let compat = stream.blSignalCompatibilityId == 2
            return edrCapable ? .doviProfile8(tonemapCompat: compat) : .degradedHDR10
        case 7:
            // Profile 7 (BL+EL dual-layer) — software dual-layer decode is out
            // of scope; VT hardcodes as HDR10. Always degraded.
            return .degradedHDR10
        default:
            // Unknown DV profile — treat as degraded HDR10 for safety.
            return .degradedHDR10
        }
    }

    // 2-3. HDR10+ / HDR10 / HLG
    switch stream.transfer {
    case .pq:
        if stream.hasHDR10Plus && edrCapable {
            return .hdr10Plus
        }
        // Default HDR10 PQ — peak nits from mastering display (caller resolves
        // to 1000 if absent; the strategy carries the value for the shader).
        // For now use a fixed 1000 default; FrameMetadata.masteringDisplay at
        // runtime overrides it.
        return .hdr10Static(peakNits: 1000)
    case .hlg:
        return edrCapable ? .hlgOOTF : .hdr10Static(peakNits: 1000)
    case .sdr:
        // SDR — pick 8-bit vs 10-bit by codec depth hint. H.264 is always 8-bit;
        // HEVC Main 10 is 10-bit even for SDR content.
        // For simplicity (and since MetalRenderer handles both) we always pick
        // sdr8Bit; refine later if a 10-bit SDR stream shows up.
        //
        // Unmarked-HDR10 fallback: many older Blu-ray remuxes ship HEVC 10-bit
        // PQ content but omit the color_trc tag in the MKV container. FFmpeg
        // then reports transfer=SDR, which would misroute the stream to the
        // SDR 8-bit pipeline and render PQ pixels as sRGB → red/clipped faces.
        // 10-bit HEVC SDR is almost nonexistent in real sources (broadcast SDR
        // is 8-bit H.264 or 10-bit H.265 with an explicit transfer tag), so we
        // treat HEVC + 10-bit + SDR as unmarked HDR10 and route through the
        // HDR10 static path (FFmpeg hwaccel + BT.2390). H.264 has no HDR10
        // profile in the wild, so it stays on the SDR path regardless of depth.
        if stream.isHEVC10BitSDRHint,
           edrCapable || display.supportsEDR {
            return .hdr10Static(peakNits: 1000)
        }
        _ = prefersTenBit  // currently unused on SDR path
        return .sdr8Bit(matrix: stream.colorMatrix)
    }
}
