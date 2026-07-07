import AVFoundation
import Foundation
import QuartzCore
import PlayerKit

@MainActor
public final class MPVBackend: PlayerBackend {
    public private(set) var state = PlayerState()
    public private(set) var videoWidth: Int = 0
    public private(set) var videoHeight: Int = 0
    public private(set) var colorParams = VideoColorParams()
    public var onStateChange: ((PlayerState) -> Void)?

    private let core: MPVCore
    private var swRenderCtx: MPVRenderContext?
    #if os(iOS) || os(tvOS)
    private var glRenderCtx: OpenGLRenderContext?
    #endif
    private let mpvBridge: MPVDisplayBridge

    @ObservationIgnored private nonisolated(unsafe) var eventTask: Task<Void, Never>?
    private var pendingSeekPosition: Duration?

    public var renderer: any VideoRenderer { mpvBridge }

    public func addFrameSink(_ sink: any FrameSink) {
        // Frame sinks not supported for MPVBackend (mpv manages its own render pipeline)
    }
    public func removeFrameSink(_ sink: any FrameSink) {}

    public init() throws {
        core = MPVCore()

        let initialRenderer: any MPVInternalRenderer

        #if os(iOS) || os(tvOS)
        #if !targetEnvironment(simulator)
        if let glCtx = try? OpenGLRenderContext(core: core),
           let mr = try? GLMetalRenderer(renderCtx: glCtx) {
            glRenderCtx = glCtx
            initialRenderer = mr
            mpvBridge = MPVDisplayBridge(renderer: mr)
            startEventLoop()
            return
        }
        NSLog("[mpvkit] OpenGL+Metal unavailable, falling back to SW+Metal")
        #endif
        #endif

        let ctx = try MPVRenderContext(core: core)
        swRenderCtx = ctx
        if let mr = try? MetalRenderer(renderCtx: ctx) {
            initialRenderer = mr
        } else {
            initialRenderer = SWRenderer(renderCtx: ctx)
        }
        mpvBridge = MPVDisplayBridge(renderer: initialRenderer)
        startEventLoop()
    }

    public func play(url: URL, headers: [String: String], seekTo: Duration?, knownDuration: Duration? = nil) {
        if !headers.isEmpty { core.setHTTPHeaders(headers) }
        pendingSeekPosition = seekTo
        core.command(["loadfile", url.absoluteString])
        mpvBridge.isReadyToRender = false
        mpvBridge.flush()
        mpvBridge.clear()
        mpvBridge.start()
        state.isBuffering = true
        notifyStateChange()
    }

    public func pause() {
        core.setFlag(.pause, true)
    }

    public func resume() {
        core.setFlag(.pause, false)
    }

    public func seek(to: Duration) {
        let comps = to.components
        let secs = Double(comps.seconds) + Double(comps.attoseconds) * 1e-18
        core.command(["seek", String(format: "%.3f", secs), "absolute"])
    }

    public func stop() {
        core.command(["stop"])
        mpvBridge.stop()
        mpvBridge.flush()
        state = PlayerState()
        notifyStateChange()
    }

    public func setVolume(_ volume: Double) {
        let clamped = max(0, min(1, volume))
        state.volume = clamped
        core.setDouble(.volume, clamped * 100)
        notifyStateChange()
    }

    public func setRate(_ rate: Double) {
        let clamped = max(0.25, min(4.0, rate))
        state.rate = clamped
        core.setDouble(.speed, clamped)
        notifyStateChange()
    }

    public func selectAudioTrack(id: String) {
        core.setString(.aid, id)
    }

    public func selectSubtitle(id: String?) {
        core.setString(.sid, id ?? "no")
    }

    public func prepareForReuse() {
        core.setFlag(.pause, true)
        mpvBridge.flush()
        mpvBridge.clear()
        mpvBridge.stop()
    }

    // MARK: - Event loop

    private func startEventLoop() {
        let stream = core.events
        eventTask = Task { [weak self] in
            for await event in stream {
                await MainActor.run { [weak self] in self?.handle(event) }
            }
        }
    }

    private func handle(_ event: MPVEvent) {
        switch event {
        case .fileLoaded:
            core.setFlag(.pause, false)
            mpvBridge.isReadyToRender = true
            if let pos = pendingSeekPosition {
                seek(to: pos)
                pendingSeekPosition = nil
            }
            state.duration = Duration.seconds(core.getDouble(.duration))
            state.isBuffering = false
            state.isPlaying = true
            let w = Int(core.getInt64(.width))
            let h = Int(core.getInt64(.height))
            if w > 0 { mpvBridge.videoWidth = w; videoWidth = w }
            if h > 0 { mpvBridge.videoHeight = h; videoHeight = h }
            refreshTracks()
            refreshVideoInfo()
            NSLog("[playerkit] fileLoaded: \(w)x\(h) duration=\(state.duration)")
        case .startFile:
            state.isBuffering = true
            mpvBridge.flush()
            NSLog("[playerkit] startFile")
        case .endOfFile(let reason):
            if reason == .eof || reason == .stop {
                state.isPlaying = false
            }
            NSLog("[playerkit] endOfFile: \(reason)")
        case .propertyChange(let name, let value):
            handlePropertyChange(name: name, value: value)
        case .videoReconfig:
            let w = Int(core.getInt64(.width))
            let h = Int(core.getInt64(.height))
            mpvBridge.videoWidth = w; videoWidth = w
            mpvBridge.videoHeight = h; videoHeight = h
            let params = VideoColorParams(
                mpvColormatrix: core.getString(.videoParamsColormatrix),
                mpvGamma: core.getString(.videoParamsGamma),
                mpvColorlevels: core.getString(.videoParamsColorlevels))
            colorParams = params
            mpvBridge.updateColorParams(params)
            refreshVideoInfo()
            NSLog("[playerkit] videoReconfig: \(w)x\(h)")
        case .shutdown, .unknown, .audioReconfig, .playbackRestart:
            break
        }
        notifyStateChange()
    }

    private func handlePropertyChange(name: MPVPropertyName, value: MPVValue) {
        switch name {
        case .timePos:
            if case .double(let secs) = value {
                state.position = Duration.seconds(secs)
            }
        case .duration:
            if case .double(let secs) = value {
                state.duration = Duration.seconds(secs)
            }
        case .pause:
            if case .bool(let paused) = value {
                state.isPlaying = !paused
            }
        case .cacheBufferingState:
            if case .int64(let pct) = value {
                state.isBuffering = pct < 100
            }
        case .demuxerCacheDuration:
            if case .double(let secs) = value, secs > 0 {
                state.bufferedDuration = state.position + Duration.seconds(secs)
            } else {
                state.bufferedDuration = .zero
            }
        case .cacheSpeed:
            if case .int64(let bps) = value {
                state.cacheSpeed = bps
            }
        case .width:
            if case .int64(let w) = value, w > 0 { videoWidth = Int(w); mpvBridge.videoWidth = Int(w) }
        case .height:
            if case .int64(let h) = value, h > 0 { videoHeight = Int(h); mpvBridge.videoHeight = Int(h) }
        case .speed:
            if case .double(let s) = value { state.rate = s }
        default:
            break
        }
    }

    private func refreshTracks() {
        guard let json = core.getJSON("track-list"),
              let data = json.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }

        var audio: [TrackInfo] = []
        var subs: [TrackInfo] = []

        for item in array {
            guard let id = item["id"] as? Int,
                  let type = item["type"] as? String else { continue }
            let track = TrackInfo(
                id: id,
                title: item["title"] as? String ?? item["codec"] as? String,
                lang: item["lang"] as? String,
                codec: item["codec"] as? String,
                isDefault: item["default"] as? Bool ?? false
            )
            switch type {
            case "audio": audio.append(track)
            case "sub":   subs.append(track)
            default: break
            }
        }
        state.audioTracks = audio
        state.subtitleTracks = subs
    }

    private func refreshVideoInfo() {
        let w = Int(core.getInt64(.width))
        let h = Int(core.getInt64(.height))
        guard w > 0, h > 0 else { return }
        let gamma = core.getString(.videoParamsGamma) ?? ""
        state.videoInfo = VideoInfo(
            width: w,
            height: h,
            codec: core.getString(.videoParamsCodec),
            isHDR: gamma == "pq" || gamma == "hlg",
            colorMatrix: core.getString(.videoParamsColormatrix),
            transfer: gamma.isEmpty ? nil : gamma
        )
    }

    deinit {
        eventTask?.cancel()
    }
}
