import Foundation

public protocol MediaProbable: Sendable {
    func probe(url: URL, headers: [String: String]) async throws -> MediaProbeResult
}

public struct MediaProbeResult: Sendable {
    public let duration: Double?
    public let videoStreams: [VideoStreamInfo]
    public let audioStreams: [AudioStreamInfo]
    public let subtitleStreams: [SubtitleStreamInfo]
    public let container: String?

    public init(duration: Double?, videoStreams: [VideoStreamInfo],
                audioStreams: [AudioStreamInfo], subtitleStreams: [SubtitleStreamInfo],
                container: String?) {
        self.duration = duration
        self.videoStreams = videoStreams
        self.audioStreams = audioStreams
        self.subtitleStreams = subtitleStreams
        self.container = container
    }
}

public struct VideoStreamInfo: Sendable {
    public let index: Int
    public let codec: String
    public let width: Int
    public let height: Int
    public let frameRate: Double
    public let isHDR: Bool
    public let hdrFormat: String?
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

public struct AudioStreamInfo: Sendable {
    public let index: Int
    public let codec: String
    public let language: String?
    public let channels: Int
    public let isDefault: Bool
    public let title: String?

    public init(index: Int, codec: String, language: String?, channels: Int,
                isDefault: Bool, title: String?) {
        self.index = index
        self.codec = codec
        self.language = language
        self.channels = channels
        self.isDefault = isDefault
        self.title = title
    }
}

public struct SubtitleStreamInfo: Sendable {
    public let index: Int
    public let codec: String
    public let language: String?
    public let isDefault: Bool
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
