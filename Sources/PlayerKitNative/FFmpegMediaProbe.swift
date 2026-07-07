import Foundation
import PlayerKit
import CFFmpeg

/// Standalone media info probe. Use without instantiating a player.
///
///     let probe = FFmpegMediaProbe()
///     let result = try await probe.probe(url: url, headers: [:])
public struct FFmpegMediaProbe: MediaProbable {
    public init() {}

    public func probe(url: URL, headers: [String: String]) async throws -> MediaProbeResult {
        return try await Task.detached(priority: .userInitiated) {
            let demuxer = FFmpegDemuxer()
            try demuxer.open(url: url, headers: headers)

            // Probe real duration via separate connection (seek-to-end).
            let probed = FFmpegDemuxer.probeDuration(url: url, headers: headers)
            let duration: Double? = (probed ?? 0) > 0 ? probed : (demuxer.duration > 0 ? demuxer.duration : nil)

            var videoStreams: [VideoStreamInfo] = []
            if let vs = demuxer.videoStream {
                let cp = vs.pointee.codecpar.pointee
                let codecName = String(cString: avcodec_get_name(cp.codec_id))
                let fr = vs.pointee.avg_frame_rate
                let frameRate = fr.den > 0 ? Double(fr.num) / Double(fr.den) : 0
                videoStreams.append(VideoStreamInfo(
                    index: Int(vs.pointee.index),
                    codec: codecName,
                    width: Int(cp.width),
                    height: Int(cp.height),
                    frameRate: frameRate,
                    isHDR: false,
                    hdrFormat: nil,
                    colorTransfer: nil
                ))
            }

            return MediaProbeResult(
                duration: duration,
                videoStreams: videoStreams,
                audioStreams: [],
                subtitleStreams: [],
                container: nil
            )
        }.value
    }
}
