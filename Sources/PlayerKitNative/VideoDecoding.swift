// Sources/PlayerKitNative/VideoDecoding.swift
import CoreVideo
import CFFmpeg

protocol VideoDecoding {
    var width: Int { get }
    var height: Int { get }
    var isHardware: Bool { get }
    func decode(packet: UnsafeMutablePointer<AVPacket>) -> CVPixelBuffer?
    func flush()
}
