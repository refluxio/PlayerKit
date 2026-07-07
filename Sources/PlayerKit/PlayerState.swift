import Foundation

public struct PlayerState: Sendable {
    public var isPlaying:   Bool     = false
    public var isBuffering: Bool     = false
    public var bufferedDuration: Duration = .zero
    public var position:    Duration = .zero
    public var duration:    Duration = .zero
    public var volume:      Double   = 1.0
    public var rate:        Double   = 1.0
    public var error:       String?  = nil

    public var audioTracks:    [TrackInfo] = []
    public var subtitleTracks: [TrackInfo] = []
    public var videoInfo:      VideoInfo?  = nil
    public var cacheSpeed:     Int64       = 0

    public init() {}
}

public struct TrackInfo: Identifiable, Sendable, Equatable {
    public let id: Int
    public let title: String?
    public let lang: String?
    public let codec: String?
    public let isDefault: Bool

    public init(id: Int, title: String? = nil, lang: String? = nil, codec: String? = nil, isDefault: Bool = false) {
        self.id = id
        self.title = title
        self.lang = lang
        self.codec = codec
        self.isDefault = isDefault
    }
}

public struct VideoInfo: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let codec: String?
    public let isHDR: Bool
    public let colorMatrix: String?
    public let transfer: String?

    public init(width: Int, height: Int, codec: String? = nil, isHDR: Bool = false, colorMatrix: String? = nil, transfer: String? = nil) {
        self.width = width
        self.height = height
        self.codec = codec
        self.isHDR = isHDR
        self.colorMatrix = colorMatrix
        self.transfer = transfer
    }
}

public enum PlayerError: Error, Sendable {
    case initFailed(String)
    case renderContextFailed
    case loadFailed(String)
    case metalUnavailable
    case decodeFailed(Int)
}
