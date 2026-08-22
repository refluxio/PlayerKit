// Sources/PlayerKitNative/VideoDecoding.swift
import CoreVideo
import PlayerKit
import CFFmpeg

/// Output of `VideoDecoding.decode(packet:)`: a decoded pixel buffer paired
/// with optional per-frame HDR side data (DoVi / HDR10+ / mastering display)
/// extracted from the AVFrame.
struct DecodedVideoFrame {
    let pixelBuffer: CVPixelBuffer
    let metadata: FrameMetadata
    /// The decoder's own display-order presentation time, in seconds, when
    /// the decoder can determine it more reliably than the caller's
    /// submission-order packet pts (e.g. FFmpeg software decode: with
    /// B-frames, avcodec_receive_frame's output for call N can correspond
    /// to an EARLIER submitted packet — pairing it with the pts of the
    /// packet just sent mislabels roughly 1 in 3 frames with a pts several
    /// frame-durations too far ahead, causing visible display-order jitter.
    /// nil when the decoder has no better source than the caller's own
    /// packet-based pts (e.g. VTVideoDecoder, unaffected by this class of
    /// bug in practice).
    var pts: Double? = nil
}

protocol VideoDecoding {
    var width: Int { get }
    var height: Int { get }
    var isHardware: Bool { get }
    func decode(packet: UnsafeMutablePointer<AVPacket>) -> DecodedVideoFrame?
    func flush()
}
