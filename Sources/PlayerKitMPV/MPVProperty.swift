import Foundation

// MARK: - Property Names

public enum MPVPropertyName: String, Sendable {
    case timePos             = "time-pos"
    case duration            = "duration"
    case pause               = "pause"
    case volume              = "volume"
    case aid                 = "aid"
    case sid                 = "sid"
    case cacheBufferingState = "cache-buffering-state"
    case width               = "width"
    case height              = "height"
    case trackList           = "track-list"
    case videoParams         = "video-params"
    case hwdec               = "hwdec"
    case speed               = "speed"
    case demuxerCacheDuration = "demuxer-cache-duration"
    case cacheSpeed           = "cache-speed"
    case videoParamsCodec    = "video-params/pixelformat"
    case videoParamsColormatrix = "video-params/colormatrix"
    case videoParamsGamma       = "video-params/gamma"
    case videoParamsColorlevels = "video-params/colorlevels"
}

// MARK: - Events

public enum MPVEvent: Sendable {
    case fileLoaded
    case startFile
    case playbackRestart
    case videoReconfig
    case audioReconfig
    case endOfFile(reason: EndReason)
    case propertyChange(name: MPVPropertyName, value: MPVValue)
    case shutdown
    case unknown

    public enum EndReason: UInt32, Sendable {
        case eof      = 0
        case stop     = 2
        case quit     = 3
        case error    = 4
        case redirect = 5
    }
}

// MARK: - Property Values

public enum MPVValue: Sendable {
    case double(Double)
    case int64(Int64)
    case bool(Bool)
    case string(String)
    case none
}
