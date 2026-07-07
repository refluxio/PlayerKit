import Foundation

/// Media metadata probe. Implementations parse containers and extract stream info.
public protocol MediaProbable: Sendable {
    /// Probe a media URL and return parsed stream information.
    /// - Parameters:
    ///   - url: Media URL to probe.
    ///   - headers: HTTP headers included in the request.
    /// - Returns: Parsed probe result with duration and stream lists.
    /// - Throws: ProbeError on failure.
    func probe(url: URL, headers: [String: String]) async throws -> MediaProbeResult
}

/// Chapter metadata (DVD-style chapter markers).
public struct ChapterInfo: Sendable {
    /// Chapter title, if available.
    public let title: String?
    /// Chapter start time in seconds.
    public let startDuration: Double
    /// Chapter end time in seconds.
    public let endDuration: Double

    public init(title: String?, startDuration: Double, endDuration: Double) {
        self.title = title
        self.startDuration = startDuration
        self.endDuration = endDuration
    }
}

/// Result of a media probe, containing duration, streams, and container format.
public struct MediaProbeResult: Sendable {
    /// Media duration in seconds, nil if unknown.
    public let duration: Double?
    /// Detected video streams.
    public let videoStreams: [VideoStreamInfo]
    /// Detected audio streams.
    public let audioStreams: [AudioStreamInfo]
    /// Detected subtitle streams.
    public let subtitleStreams: [SubtitleStreamInfo]
    /// Container format string (e.g. "matroska", "mp4").
    public let container: String?
    /// Detected chapters.
    public let chapters: [ChapterInfo]

    public init(duration: Double?, videoStreams: [VideoStreamInfo],
                audioStreams: [AudioStreamInfo], subtitleStreams: [SubtitleStreamInfo],
                container: String?, chapters: [ChapterInfo] = []) {
        self.duration = duration
        self.videoStreams = videoStreams
        self.audioStreams = audioStreams
        self.subtitleStreams = subtitleStreams
        self.container = container
        self.chapters = chapters
    }
}

/// Metadata for a single video stream.
public struct VideoStreamInfo: Sendable {
    /// Stream index in the container.
    public let index: Int
    /// Video codec name (e.g. "h264", "hevc").
    public let codec: String
    /// Display width in pixels.
    public let width: Int
    /// Display height in pixels.
    public let height: Int
    /// Nominal frame rate in fps.
    public let frameRate: Double
    /// Whether the stream uses HDR colorimetry.
    public let isHDR: Bool
    /// HDR format string (e.g. "SMPTE ST 2086", "Dolby Vision").
    public let hdrFormat: String?
    /// Color transfer characteristic (e.g. "smpte2084", "arib-std-b67").
    public let colorTransfer: String?

    public init(index: Int, codec: String, width: Int, height: Int, frameRate: Double,
                isHDR: Bool, hdrFormat: String?, colorTransfer: String?) {
        self.index = index
        self.codec = codec
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.isHDR = isHDR
        self.hdrFormat = hdrFormat
        self.colorTransfer = colorTransfer
    }
}

/// Metadata for a single audio stream.
public struct AudioStreamInfo: Sendable {
    /// Stream index in the container.
    public let index: Int
    /// Sample rate in Hz.
    public let sampleRate: Int
    /// Audio codec name (e.g. "aac", "opus", "ac3").
    public let codec: String
    /// Language code (BCP 47 or ISO 639).
    public let language: String?
    /// Number of audio channels.
    public let channels: Int
    /// Whether this stream is flagged as default in the container.
    public let isDefault: Bool
    /// Human-readable track title.
    public let title: String?

    public init(index: Int, sampleRate: Int, codec: String, language: String?, channels: Int,
                isDefault: Bool, title: String?) {
        self.index = index
        self.sampleRate = sampleRate
        self.codec = codec
        self.language = language
        self.channels = channels
        self.isDefault = isDefault
        self.title = title
    }
}

/// Metadata for a single subtitle stream.
public struct SubtitleStreamInfo: Sendable {
    /// Stream index in the container.
    public let index: Int
    /// Subtitle codec name (e.g. "subrip", "ass", "mov_text").
    public let codec: String
    /// Language code (BCP 47 or ISO 639).
    public let language: String?
    /// Whether this stream is flagged as default in the container.
    public let isDefault: Bool
    /// Human-readable track title.
    public let title: String?

    public init(index: Int, codec: String, language: String?,
                isDefault: Bool, title: String?) {
        self.index = index
        self.codec = codec
        self.language = language
        self.isDefault = isDefault
        self.title = title
    }
}
