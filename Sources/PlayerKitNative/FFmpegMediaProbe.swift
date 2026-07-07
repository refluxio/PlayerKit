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
            var audioStreams: [AudioStreamInfo] = []
            var subtitleStreams: [SubtitleStreamInfo] = []
            var chapters: [ChapterInfo] = []

            if let fmtCtx = demuxer.formatContext {
                // --- Streams ---
                let nbStreams = Int(fmtCtx.pointee.nb_streams)
                for i in 0..<nbStreams {
                    guard let stream = fmtCtx.pointee.streams[i] else { continue }
                    let cp = stream.pointee.codecpar.pointee
                    let codecType = cp.codec_type

                    switch codecType {
                    case AVMEDIA_TYPE_VIDEO:
                        let codecName = String(cString: avcodec_get_name(cp.codec_id))
                        let fr = stream.pointee.avg_frame_rate
                        let frameRate = fr.den > 0 ? Double(fr.num) / Double(fr.den) : 0
                        videoStreams.append(VideoStreamInfo(
                            index: Int(stream.pointee.index),
                            codec: codecName,
                            width: Int(cp.width),
                            height: Int(cp.height),
                            frameRate: frameRate,
                            isHDR: false,
                            hdrFormat: nil,
                            colorTransfer: nil
                        ))

                    case AVMEDIA_TYPE_AUDIO:
                        let codecName = String(cString: avcodec_get_name(cp.codec_id))
                        let channels = Int(cp.ch_layout.nb_channels)
                        let sampleRate = Int(cp.sample_rate)
                        let metadata = stream.pointee.metadata

                        var language: String?
                        if let entry = av_dict_get(metadata, "language", nil, 0) {
                            language = String(cString: entry.pointee.value)
                        }
                        var title: String?
                        if let entry = av_dict_get(metadata, "title", nil, 0) {
                            title = String(cString: entry.pointee.value)
                        }
                        let isDefault = (stream.pointee.disposition & AV_DISPOSITION_DEFAULT) != 0

                        audioStreams.append(AudioStreamInfo(
                            index: Int(stream.pointee.index),
                            sampleRate: sampleRate,
                            codec: codecName,
                            language: language,
                            channels: channels,
                            isDefault: isDefault,
                            title: title
                        ))

                    case AVMEDIA_TYPE_SUBTITLE:
                        let codecName = String(cString: avcodec_get_name(cp.codec_id))
                        let metadata = stream.pointee.metadata

                        var language: String?
                        if let entry = av_dict_get(metadata, "language", nil, 0) {
                            language = String(cString: entry.pointee.value)
                        }
                        var title: String?
                        if let entry = av_dict_get(metadata, "title", nil, 0) {
                            title = String(cString: entry.pointee.value)
                        }
                        let isDefault = (stream.pointee.disposition & AV_DISPOSITION_DEFAULT) != 0

                        subtitleStreams.append(SubtitleStreamInfo(
                            index: Int(stream.pointee.index),
                            codec: codecName,
                            language: language,
                            isDefault: isDefault,
                            title: title
                        ))

                    default:
                        break
                    }
                }

                // --- Chapters ---
                let nbChapters = Int(fmtCtx.pointee.nb_chapters)
                for i in 0..<nbChapters {
                    guard let chPtr = fmtCtx.pointee.chapters[i] else { continue }
                    let ch = chPtr.pointee
                    let tb = ch.time_base

                    var chapterTitle: String?
                    if let entry = av_dict_get(ch.metadata, "title", nil, 0) {
                        chapterTitle = String(cString: entry.pointee.value)
                    }

                    let startSec = Double(ch.start) * Double(tb.num) / Double(tb.den)
                    let endSec = Double(ch.end) * Double(tb.num) / Double(tb.den)
                    chapters.append(ChapterInfo(title: chapterTitle, startDuration: startSec, endDuration: endSec))
                }
            }

            return MediaProbeResult(
                duration: duration,
                videoStreams: videoStreams,
                audioStreams: audioStreams,
                subtitleStreams: subtitleStreams,
                container: nil,
                chapters: chapters
            )
        }.value
    }
}
