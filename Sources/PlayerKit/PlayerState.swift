import Foundation

/// Snapshot of current player state. Emitted on every change via onStateChange.
public struct PlayerState: Sendable {
    /// Whether media is actively playing (not paused).
    public var isPlaying:   Bool     = false
    /// Whether the player is currently buffering.
    public var isBuffering: Bool     = false
    /// Total duration buffered and available for playback.
    public var bufferedDuration: Duration = .zero
    /// Current playback position.
    public var position:    Duration = .zero
    /// Total media duration, zero until known.
    public var duration:    Duration = .zero
    /// Current volume (0.0-1.0).
    public var volume:      Double   = 1.0
    /// Current playback rate.
    public var rate:        Double   = 1.0
    /// Non-nil when an error has occurred.
    public var error:       String?  = nil

    /// Available audio tracks.
    public var audioTracks:    [TrackInfo] = []
    /// Available subtitle tracks.
    public var subtitleTracks: [TrackInfo] = []
    /// Currently selected audio track ID, nil if default/auto.
    public var selectedAudioTrackId: Int? = nil
    /// Currently selected subtitle track ID, nil if none.
    public var selectedSubtitleTrackId: Int? = nil
    /// Current video stream info, nil until loaded.
    public var videoInfo:      VideoInfo?  = nil
    /// Cache download speed in bytes/second.
    public var cacheSpeed:     Int64       = 0

    public init() {}
}

/// Metadata for a single audio or subtitle track.
public struct TrackInfo: Identifiable, Sendable, Equatable {
    /// Track index in the container.
    public let id: Int
    /// Human-readable track title.
    public let title: String?
    /// Language code (BCP 47 or ISO 639).
    public let lang: String?
    /// Codec name.
    public let codec: String?
    /// Whether this track is the default selection.
    public let isDefault: Bool
    /// Whether this audio track carries Dolby Atmos object metadata.
    public let isAtmos: Bool

    public init(id: Int, title: String? = nil, lang: String? = nil,
                codec: String? = nil, isDefault: Bool = false, isAtmos: Bool = false) {
        self.id = id
        self.title = title
        self.lang = lang
        self.codec = codec
        self.isDefault = isDefault
        self.isAtmos = isAtmos
    }
}

/// Info about the currently playing video stream.
public struct VideoInfo: Sendable, Equatable {
    /// Display width in pixels.
    public let width: Int
    /// Display height in pixels.
    public let height: Int
    /// Video codec name.
    public let codec: String?
    /// Whether the stream uses HDR.
    public let isHDR: Bool
    /// Color matrix (e.g. "bt.2020-ncl").
    public let colorMatrix: String?
    /// Transfer characteristic (e.g. "smpte2084").
    public let transfer: String?
    /// Whether the stream is Dolby Vision (profile 5/8/9 detected via DOVI_CONF side data).
    public let isDolbyVision: Bool

    public init(width: Int, height: Int, codec: String? = nil,
                isHDR: Bool = false, colorMatrix: String? = nil,
                transfer: String? = nil, isDolbyVision: Bool = false) {
        self.width = width
        self.height = height
        self.codec = codec
        self.isHDR = isHDR
        self.colorMatrix = colorMatrix
        self.transfer = transfer
        self.isDolbyVision = isDolbyVision
    }
}

/// Errors that can occur during player lifecycle.
public enum PlayerError: Error, Sendable {
    /// Initialization failed with a reason message.
    case initFailed(String)
    /// Render context creation failed.
    case renderContextFailed
    /// Media loading failed with a reason message.
    case loadFailed(String)
    /// Metal is not available on this device.
    case metalUnavailable
    /// Decoding failed for the given stream index.
    case decodeFailed(Int)
}
