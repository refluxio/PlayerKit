import Foundation

/// Uniform buffer payload sent from CPU to the Metal HDR shader per-frame.
///
/// 16-byte aligned for `setFragmentBytes` — total 64 bytes. Fields are laid out
/// to match the Metal `struct ToneMapUniform` in `EDRRenderer.hdrShaderSource`.
/// Layout changes here MUST be mirrored in the shader.
///
/// The `algorithm` field selects which branch the shader runs:
/// - 0 = static BT.2390 (or passthrough SDR on non-HDR pipelines)
/// - 1 = BT.2390 driven by DoVi DM Level 1 dynamic metadata
/// - 2 = HDR10+ bezier curve tone-map
/// - 3 = HLG OOTF + static tone-map
public struct ToneMapUniform: Sendable {

    /// DoVi L1 max luminance, converted from PQ (0..65535) to linear (0..1,
    /// representing 0..10000 cd/m² normalized). 0 when no L1 metadata.
    public var maxPqLinear: Float = 0

    /// DoVi L1 average luminance, PQ→linear.
    public var avgPqLinear: Float = 0

    /// DoVi L1 min luminance, PQ→linear.
    public var minPqLinear: Float = 0

    /// Source content peak luminance, cd/m². From `masteringDisplay.maxLuminance`
    /// or `dovi.level6.maxLuminance`; defaults to 1000 when absent.
    public var peakNits: Float = 1000

    /// Target display peak luminance, cd/m². From `DisplayCapability.targetPeakNits`.
    public var targetNits: Float = 1000

    /// 1 when per-frame dynamic metadata (DoVi L1 or HDR10+ bezier) is present,
    /// 0 otherwise. Drives the shader's branch between dynamic and static paths.
    public var hasDynamic: Int32 = 0

    /// Algorithm selector (see struct doc). Mapped from `ToneMappingAlgorithmKind`.
    public var algorithm: UInt32 = 0

    /// HLG system gamma. Computed from `targetNits` per BT.2100:
    ///   gamma = 1.2 + 0.42 * log10(targetNits / 1000)
    /// Only used when `algorithm == 3`.
    public var hlgSystemGamma: Float = 1.2

    public init() {}
}

/// Protocol for tone-mapping algorithms. Implementations live in PlayerKitPro
/// (closed-source) since they encode the Pro HDR pipeline logic.
///
/// `EDRRenderer` holds one instance per stream (instantiated from
/// `RendererStrategy.toneMapAlgorithm`) and calls `buildUniform` every frame
/// with the latest `FrameMetadata`.
public protocol ToneMappingAlgorithm: Sendable {
    /// Build the shader uniform for a single frame.
    /// - Parameters:
    ///   - metadata: Per-frame HDR side data. DoVi/HDR10+/mastering display.
    ///   - stream: Stream-level color params (matrix/transfer/range).
    ///   - display: Display capability snapshot (target peak, EDR support).
    func buildUniform(metadata: FrameMetadata,
                      stream: VideoColorParams,
                      display: DisplayCapability) -> ToneMapUniform
}
