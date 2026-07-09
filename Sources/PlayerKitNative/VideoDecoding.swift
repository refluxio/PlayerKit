// Sources/PlayerKitNative/VideoDecoding.swift
import CoreVideo
import PlayerKit
import CFFmpeg

/// Output of `VideoDecoding.decode(packet:)`: a decoded pixel buffer paired
/// with optional per-frame Dolby Vision metadata extracted from the AVFrame.
struct DecodedVideoFrame {
    let pixelBuffer: CVPixelBuffer
    let dovi: DolbyVisionFrameMetadata?
}

protocol VideoDecoding {
    var width: Int { get }
    var height: Int { get }
    var isHardware: Bool { get }
    func decode(packet: UnsafeMutablePointer<AVPacket>) -> DecodedVideoFrame?
    func flush()
}
