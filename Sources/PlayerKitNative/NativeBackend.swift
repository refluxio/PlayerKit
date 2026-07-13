import AVFoundation
import Foundation
import CoreMedia
import CoreVideo
import QuartzCore
import PlayerKit
import CFFmpeg
import os

private let logger = Logger(subsystem: "io.reflux.PlayerKit", category: "backend")

private final class DisplayLinkProxy: NSObject {
    weak var backend: NativeBackend?
    init(backend: NativeBackend) { self.backend = backend }
    @objc func tick() {
        guard let b = backend else { return }
        MainActor.assumeIsolated { b.displayNextFrame() }
    }
}

@MainActor
public final class NativeBackend: PlayerBackend {
    public private(set) var state = PlayerState()
    public private(set) var videoWidth: Int = 0
    public private(set) var videoHeight: Int = 0
    private var codedVideoWidth: Int = 0
    private var codedVideoHeight: Int = 0
    public private(set) var colorParams = VideoColorParams()
    /// Display capability used to resolve `RendererStrategy`. Defaults to
    /// `appleMobile` (no EDR); PlayerController should set this to `macEDR` /
    /// `macSDR` on macOS after observing NSScreen EDR support. Propagates to
    /// the renderer so EDRRenderer's tone-map uniform picks up the new target
    /// peak nits on the next frame.
    public var displayCapability: DisplayCapability = .appleMobile {
        didSet {
            // Strategy is only resolved at stream open time; while a stream is
            // playing we can still refresh the renderer's tone-map target.
            _renderer.displayCapability = displayCapability
        }
    }
    /// When false, Dolby Vision streams fall back to HDR10 base layer.
    /// Set by the app layer based on Pro subscription status.
    public var doviEnabled: Bool = true

    /// Strategy resolved once at open time from stream attributes + display
    /// capability + renderer's `prefersTenBit`. Drives decoder selection and
    /// is forwarded to `VideoRenderer.render` every frame so EDRRenderer can
    /// pick its tone-map algorithm without re-reading stream attributes.
    public private(set) var rendererStrategy: RendererStrategy?
    public var onStateChange: ((PlayerState) -> Void)?

    private let _renderer: any VideoRenderer
    public var renderer: any VideoRenderer { _renderer }

    /// Injected PRO audio output backend. When non-nil, replaces AudioUnitOutput.
    /// Written once in init(), only read afterwards — safe to access from any thread.
    private nonisolated(unsafe) var _injectedAudioOutput: (any AudioOutputBackend)?

    private var _frameSinks: [WeakFrameSink] = []
    private struct WeakFrameSink {
        weak var sink: (any FrameSink)?
    }

    private var demuxer: FFmpegDemuxer?
    /// VT may fail on extreme-parameter streams (e.g. 4K@120fps).
    /// When that happens the demux loop hot-swaps in a software FFmpegVideoDecoder.
    /// Written once in _finishOpen(), then swapped from the demux queue on fallback.
    private nonisolated(unsafe) var videoDecoder: (any VideoDecoding)?
    private var audioDecoder: FFmpegAudioDecoder?

    // A/V sync modules
    private let audioClock = AudioClock()
    private var audioUnitOutput: AudioUnitOutput?
    /// True only when compressed audio passthrough is actually in use (macOS
    /// with HDMI/SPDIF). On iOS/tvOS passthrough is disabled and PCM decode
    /// via AudioUnitOutput drives the audioClock normally.
    private var isPassthroughActive = false
    private let jitterBuffer = VideoJitterBuffer()
    private let syncController = SyncController()
    // Set after play() or seek(); cleared by displayNextFrame on first frame.
    // Calibrates audioClock to actual first decoded frame PTS so audio and video
    // start from the same position — required for H.264 streams whose PTS does
    // not start at 0 (e.g. B-frame reorder delays).
    private var needsClockCalibration: Bool = false

    // Subtitle cue buffer — written from demux loop, read from display loop.
    private struct SubtitleCue {
        let startPts: Double
        let endPts: Double
        let text: String
    }
    private let subtitleLock = NSLock()
    private nonisolated(unsafe) var subtitleCues: [SubtitleCue] = []
    private nonisolated(unsafe) var lastSubtitleText: String? = nil

    // Pipeline control
    private let demuxLock = NSLock()
    private let seekLock = NSLock()
    // Guarded by seekLock — safe to access from any thread holding the lock.
    private nonisolated(unsafe) var seekSerial: Int64 = 0
    // demuxCancelled is read from DispatchQueue.global() under demuxLock.
    // Bool reads/writes are atomic on ARM64 in practice; nonisolated(unsafe) makes
    // that contract explicit for the compiler's concurrency checker.
    private nonisolated(unsafe) var demuxCancelled = false
    private var displayLink: CADisplayLink?
    private var displayLinkProxy: DisplayLinkProxy?
    #if os(macOS)
    private var cvDisplayLink: CVDisplayLink?
    #endif

    // Cancellation: incremented on every play()/stop() to discard stale async opens
    private var playGeneration: Int = 0

    // Logging
    private var displayedVideoFrames = 0
    private var framesSinceLastLog = 0
    private var ticksSinceLastLog = 0
    private var lastLogTime: Double = 0
    private var lastNotifiedPos: Duration = .zero

    // Throughput tracking. Written from demux queue, read on main actor.
    private nonisolated(unsafe) var totalBytesRead: Int64 = 0
    private nonisolated(unsafe) var lastBytesLogged: Int64 = 0
    private nonisolated(unsafe) var lastThroughputTime: Double = 0

    /// Default init: ASBDLRenderer + AudioUnitOutput (PCM).
    public convenience init() throws {
        try self.init(renderer: nil, audioOutput: nil)
    }

    /// Default init with custom audio output (renderer uses ASBDLRenderer).
    /// - Parameter audioOutput: Custom AudioOutputBackend. nil defaults to AudioUnitOutput.
    public convenience init(audioOutput: (any AudioOutputBackend)?) throws {
        try self.init(renderer: nil, audioOutput: audioOutput)
    }

    /// PRO injection init: accepts custom renderer and audio output.
    /// - Parameters:
    ///   - renderer: Custom VideoRenderer. nil defaults to ASBDLRenderer.
    ///   - audioOutput: Custom AudioOutputBackend. nil defaults to AudioUnitOutput.
    public init(renderer: (any VideoRenderer)?, audioOutput: (any AudioOutputBackend)?) throws {
        self._renderer = try renderer ?? ASBDLRenderer()
        self._injectedAudioOutput = audioOutput
        #if canImport(UIKit)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        logger.info("init OK")
    }

    public func play(url: URL, headers: [String: String], seekTo: Duration?, knownDuration: Duration? = nil) {
        stop()
        state = PlayerState()
        state.isBuffering = true
        notifyStateChange()

        logger.notice("play \(url.absoluteString.prefix(120))")

        // Increment generation so any previously in-flight open is discarded.
        playGeneration += 1
        let gen = playGeneration

        // Open the demuxer on a background thread — avformat_open_input +
        // avformat_find_stream_info block on network I/O and must not run on
        // the main actor.  The player screen already shows isBuffering=true
        // (spinner) while we wait.
        Task.detached(priority: .userInitiated) { [weak self] in
            let demuxer = FFmpegDemuxer()
            do {
                try demuxer.open(url: url, headers: headers,
                                 skipDurationProbe: knownDuration != nil)
            } catch {
                logger.error("demuxer.open FAILED: \(error)")
                // Prefer CustomStringConvertible.description (our DemuxerError
                // provides FFmpeg ret + av_err2str). localizedDescription would
                // just return "The operation couldn't be completed. ... error N."
                let msg = (error as? CustomStringConvertible)?.description
                    ?? String(describing: error)
                await MainActor.run { [weak self] in
                    guard let self, self.playGeneration == gen else { return }
                    self.state.error = msg
                    self.notifyStateChange()
                }
                return
            }
            await MainActor.run { [weak self] in
                guard let self, self.playGeneration == gen else {
                    demuxer.close()
                    return
                }
                self._finishOpen(demuxer: demuxer, url: url, headers: headers,
                                 seekTo: seekTo, knownDuration: knownDuration)
            }
        }
    }

    private func _finishOpen(demuxer: FFmpegDemuxer, url: URL, headers: [String: String],
                              seekTo: Duration?, knownDuration: Duration?) {
        self.demuxer = demuxer
        let demuxDur = demuxer.duration
        if let kd = knownDuration, kd > .zero {
            state.duration = kd
        } else if demuxDur > 0 {
            // demuxDur is refined by seekRefine() inside FFmpegDemuxer.open() —
            // it already reflects the true end-of-stream PTS, not the container placeholder.
            state.duration = Duration.seconds(demuxDur)
        }
        logger.info("duration: knownDuration=\(knownDuration.map{"\(Double($0.components.seconds))s"} ?? "nil") demuxer=\(String(format:"%.1f",demuxDur))s → using \(String(format:"%.1f",Double(self.state.duration.components.seconds)))s")

        // Extract HDR color metadata from the video stream's codec parameters
        if let vs = demuxer.videoStream {
            let cp = vs.pointee.codecpar.pointee
            var cpParams = VideoColorParams()
            switch cp.color_trc {
            case AVCOL_TRC_SMPTE2084:   cpParams.transfer = .pq
            case AVCOL_TRC_ARIB_STD_B67: cpParams.transfer = .hlg
            default: break
            }
            switch cp.color_space {
            case AVCOL_SPC_BT2020_NCL, AVCOL_SPC_BT2020_CL: cpParams.matrix = .bt2020
            case AVCOL_SPC_BT470BG, AVCOL_SPC_SMPTE170M:     cpParams.matrix = .bt601
            default: break
            }
            cpParams.range = cp.color_range == AVCOL_RANGE_JPEG ? .full : .limited
            self.colorParams = cpParams
            if self.colorParams.transfer == .pq || self.colorParams.transfer == .hlg {
                logger.info("HDR: transfer=\(String(describing: self.colorParams.transfer)) matrix=\(String(describing: self.colorParams.matrix))")
            }

            // Resolve the renderer strategy from stream attributes + display
            // capability + renderer's 10-bit preference. DoVi profile and HDR10+
            // presence come from the demuxer (side-data scanning at open time);
            // matrix/transfer/range mirror the per-frame `colorParams` snapshot.
            // Detect HEVC 10-bit for unmarked-HDR10 fallback. MKV containers
            // often leave bits_per_raw_sample = 0 on older remuxes (verified on
            // a 1918x1036 HEVC remux that reported bits_per_raw=0 but is PQ),
            // so we also accept HEVC Main10 / REXT profile as 10-bit evidence —
            // matches the fallback in VTVideoDecoder.init.
            let isHEVC = cp.codec_id == AV_CODEC_ID_HEVC
            let isHEVC10BitByProfile = isHEVC
                && (cp.profile == AV_PROFILE_HEVC_MAIN_10
                    || cp.profile == AV_PROFILE_HEVC_REXT)
            let isHEVC10Bit = isHEVC
                && (cp.bits_per_raw_sample == 10 || isHEVC10BitByProfile)
            let attrs = VideoStreamAttributes(
                width: Int(cp.width),
                height: Int(cp.height),
                codecID: UInt32(cp.codec_id.rawValue),
                colorMatrix: cpParams.matrix,
                transfer: cpParams.transfer,
                range: cpParams.range,
                isDolbyVision: demuxer.isDolbyVision,
                doviProfile: demuxer.doviProfile,
                blSignalCompatibilityId: demuxer.doviBLSignalCompatibilityId,
                hasHDR10Plus: demuxer.hasHDR10Plus,
                isHEVC10Bit: isHEVC10Bit
            )
            let strat = decideRendererStrategy(
                stream: attrs,
                prefersTenBit: _renderer.prefersTenBit,
                display: displayCapability,
                doviEnabled: doviEnabled
            )
            self.rendererStrategy = strat
            // Verbose decision log: original container fields → resolved params →
            // final strategy. Makes "why did this stream pick SDR?" answerable
            // from a single log line at open time. See Docs/hdr-rendering.md.
            let codecName = cp.codec_id != AV_CODEC_ID_NONE
                ? String(cString: avcodec_get_name(cp.codec_id)) : "?"
            logger.info("""
            strategy decision: codec=\(codecName) \(cp.width)x\(cp.height) \
            bits_per_raw=\(cp.bits_per_raw_sample) profile=\(cp.profile) \
            trc=\(cp.color_trc.rawValue) matrix=\(cp.color_space.rawValue) range=\(cp.color_range.rawValue) \
            → resolved(transfer=\(String(describing: cpParams.transfer)) matrix=\(String(describing: cpParams.matrix)) range=\(String(describing: cpParams.range))) \
            isHEVC10Bit=\(isHEVC10Bit) \
            isDoVi=\(demuxer.isDolbyVision) profile=\(demuxer.doviProfile) \
            hasHDR10Plus=\(demuxer.hasHDR10Plus) \
            displayEDR=\(self.displayCapability.supportsEDR) renderer10bit=\(self._renderer.prefersTenBit) \
            → \(String(describing: strat))
            """)
        }

        // Sync the display capability snapshot to the renderer. EDRRenderer
        // reads `targetPeakNits` for its tone-map uniform; MetalRenderer
        // ignores the value (SDR pipeline).
        _renderer.displayCapability = displayCapability

        // Instantiate the video decoder based on the resolved strategy's
        // decoder preference. The previous version hardcoded DoVi → SW here;
        // routing through `RendererStrategy.decoderPreference` keeps the
        // decision in one place (the strategy resolver) so the renderer and
        // decoder can't disagree about which path a stream takes.
        if let vs = demuxer.videoStream {
            let sar = demuxer.sampleAspectRatio
            let preference = rendererStrategy?.decoderPreference ?? .vtHW
            let isDoVi = demuxer.isDolbyVision
            switch preference {
            case .ffmpegSW:
                if let dec = FFmpegVideoDecoder(stream: vs, forceSoftware: true, colorParams: colorParams) {
                    videoDecoder = dec
                    codedVideoWidth  = dec.width; codedVideoHeight = dec.height
                    videoWidth  = sar > 1.0 ? Int(Double(dec.width) * sar) : dec.width
                    videoHeight = sar < 1.0 ? Int(Double(dec.height) / sar) : dec.height
                    let sarStr = sar != 1.0 ? " sar=\(String(format:"%.3f",sar))" : ""
                    logger.info("video: FFmpeg SW \(dec.width)x\(dec.height)\(sarStr) display=\(self.videoWidth)x\(self.videoHeight) (strategy \(String(describing: self.rendererStrategy)))")
                } else if let dec = VTVideoDecoder(stream: vs, prefer10Bit: _renderer.prefersTenBit, colorParams: colorParams) {
                    videoDecoder = dec
                    codedVideoWidth  = dec.width; codedVideoHeight = dec.height
                    videoWidth  = sar > 1.0 ? Int(Double(dec.width) * sar) : dec.width
                    videoHeight = sar < 1.0 ? Int(Double(dec.height) / sar) : dec.height
                    let sarStr = sar != 1.0 ? " sar=\(String(format:"%.3f",sar))" : ""
                    logger.info("video: FFmpeg SW failed, VT fallback \(dec.width)x\(dec.height)\(sarStr) 10bit=\(dec.is10Bit)\(isDoVi ? " (DoVi as HDR10)" : "")")
                }
            case .ffmpegHW:
                if let dec = FFmpegVideoDecoder(stream: vs, colorParams: colorParams) {
                    videoDecoder = dec
                    codedVideoWidth  = dec.width; codedVideoHeight = dec.height
                    videoWidth  = sar > 1.0 ? Int(Double(dec.width) * sar) : dec.width
                    videoHeight = sar < 1.0 ? Int(Double(dec.height) / sar) : dec.height
                    let sarStr = sar != 1.0 ? " sar=\(String(format:"%.3f",sar))" : ""
                    logger.info("video: FFmpeg VT \(dec.width)x\(dec.height)\(sarStr) display=\(self.videoWidth)x\(self.videoHeight) hw=\(dec.isHardware)")
                } else if let dec = VTVideoDecoder(stream: vs, prefer10Bit: _renderer.prefersTenBit, colorParams: colorParams) {
                    videoDecoder = dec
                    codedVideoWidth  = dec.width; codedVideoHeight = dec.height
                    videoWidth  = sar > 1.0 ? Int(Double(dec.width) * sar) : dec.width
                    videoHeight = sar < 1.0 ? Int(Double(dec.height) / sar) : dec.height
                    let sarStr = sar != 1.0 ? " sar=\(String(format:"%.3f",sar))" : ""
                    logger.info("video: FFmpeg HW failed, VT fallback \(dec.width)x\(dec.height)\(sarStr) 10bit=\(dec.is10Bit)")
                }
            case .vtHW:
                if let dec = VTVideoDecoder(stream: vs, prefer10Bit: _renderer.prefersTenBit, colorParams: colorParams) {
                    videoDecoder = dec
                    codedVideoWidth  = dec.width; codedVideoHeight = dec.height
                    videoWidth  = sar > 1.0 ? Int(Double(dec.width) * sar) : dec.width
                    videoHeight = sar < 1.0 ? Int(Double(dec.height) / sar) : dec.height
                    let sarStr = sar != 1.0 ? " sar=\(String(format:"%.3f",sar))" : ""
                    logger.info("video: VT \(dec.width)x\(dec.height)\(sarStr) display=\(self.videoWidth)x\(self.videoHeight) 10bit=\(dec.is10Bit)\(isDoVi ? " (DoVi as HDR10)" : "")")
                } else if let dec = FFmpegVideoDecoder(stream: vs, colorParams: colorParams) {
                    videoDecoder = dec
                    codedVideoWidth  = dec.width; codedVideoHeight = dec.height
                    videoWidth  = sar > 1.0 ? Int(Double(dec.width) * sar) : dec.width
                    videoHeight = sar < 1.0 ? Int(Double(dec.height) / sar) : dec.height
                    let sarStr = sar != 1.0 ? " sar=\(String(format:"%.3f",sar))" : ""
                    logger.info("video: VT failed, FFmpeg fallback \(dec.width)x\(dec.height)\(sarStr) hw=\(dec.isHardware)")
                }
            }
        }

        // Populate state.videoInfo
        if let vs = demuxer.videoStream {
            let cp = vs.pointee.codecpar.pointee
            let codecName: String? = cp.codec_id != AV_CODEC_ID_NONE
                ? String(cString: avcodec_get_name(cp.codec_id))
                : nil
            let isHDR = colorParams.transfer == .pq || colorParams.transfer == .hlg
            state.videoInfo = VideoInfo(
                width: videoWidth,
                height: videoHeight,
                codec: codecName,
                isHDR: isHDR,
                colorMatrix: isHDR ? "\(colorParams.matrix)" : nil,
                transfer: isHDR ? "\(colorParams.transfer)" : nil,
                isDolbyVision: demuxer.isDolbyVision
            )
            if demuxer.isDolbyVision {
                logger.info("Dolby Vision detected")
            }
        }

        // Populate state.audioTracks
        if let ctx = demuxer.formatContext {
            var tracks: [TrackInfo] = []
            let nb = Int(ctx.pointee.nb_streams)
            for i in 0..<nb {
                guard let s = ctx.pointee.streams[i] else { continue }
                let cp = s.pointee.codecpar.pointee
                guard cp.codec_type == AVMEDIA_TYPE_AUDIO else { continue }

                let codecName: String? = cp.codec_id != AV_CODEC_ID_NONE
                    ? String(cString: avcodec_get_name(cp.codec_id))
                    : nil

                var title: String?
                var lang: String?
                if let meta = s.pointee.metadata {
                    if let e = av_dict_get(meta, "title", nil, 0), let v = e.pointee.value {
                        title = String(cString: v)
                    }
                    if let e = av_dict_get(meta, "language", nil, 0), let v = e.pointee.value {
                        lang = String(cString: v)
                    }
                }

                let isDefault = (s.pointee.disposition & Int32(AV_DISPOSITION_DEFAULT)) != 0
                let isAtmos = (s.pointee.index == demuxer.audioStreamIndex)
                    ? demuxer.audioIsAtmos
                    : false

                tracks.append(TrackInfo(
                    id: Int(s.pointee.index),
                    title: title,
                    lang: lang,
                    codec: codecName,
                    isDefault: isDefault,
                    isAtmos: isAtmos
                ))
            }
            state.audioTracks = tracks
            logger.info("audio tracks: \(tracks.count)")
        }

        // Populate state.subtitleTracks
        if let ctx = demuxer.formatContext {
            var subs: [TrackInfo] = []
            let nb = Int(ctx.pointee.nb_streams)
            for i in 0..<nb {
                guard let s = ctx.pointee.streams[i] else { continue }
                let cp = s.pointee.codecpar.pointee
                guard cp.codec_type == AVMEDIA_TYPE_SUBTITLE else { continue }

                let codecName: String? = cp.codec_id != AV_CODEC_ID_NONE
                    ? String(cString: avcodec_get_name(cp.codec_id))
                    : nil

                var title: String?
                var lang: String?
                if let meta = s.pointee.metadata {
                    if let e = av_dict_get(meta, "title", nil, 0), let v = e.pointee.value {
                        title = String(cString: v)
                    }
                    if let e = av_dict_get(meta, "language", nil, 0), let v = e.pointee.value {
                        lang = String(cString: v)
                    }
                }

                let isDefault = (s.pointee.disposition & Int32(AV_DISPOSITION_DEFAULT)) != 0
                subs.append(TrackInfo(
                    id: Int(s.pointee.index),
                    title: title,
                    lang: lang,
                    codec: codecName,
                    isDefault: isDefault
                ))
            }
            state.subtitleTracks = subs
            logger.info("subtitle tracks: \(subs.count)")
        }

        if let as_ = demuxer.audioStream,
           let dec = FFmpegAudioDecoder(stream: as_, sampleRate: 44100, channels: 2) {
            audioDecoder = dec
            let out = AudioUnitOutput(clock: audioClock)
            audioUnitOutput = out
            isPassthroughActive = false
            logger.info("audio: \(dec.outputSampleRate)Hz \(dec.outputChannels)ch")
            if demuxer.audioStreamIndex >= 0 {
                state.selectedAudioTrackId = Int(demuxer.audioStreamIndex)
            }
        }

        // Forward coded dimensions and SAR to the renderer for correct DAR.
        // Hardware decoders may return alignment-padded CVPixelBuffers;
        // the codec-level pixel dimensions are the ground truth.
        _renderer.configure(
            codedSize: CGSize(width: codedVideoWidth, height: codedVideoHeight),
            sampleAspectRatio: demuxer.sampleAspectRatio)

        wireJitterBuffer()
        startDemuxLoop()
        startDisplayLink()

        if let out = audioUnitOutput, let dec = audioDecoder {
            out.start(sampleRate: dec.outputSampleRate, channels: dec.outputChannels)
            // Pause immediately — jitterBuffer.onStateChange will resume when
            // enough video is buffered (resumeDuration = 2.0s). Without this,
            // audio runs freely during the initial BUFFERING phase and drifts
            // 500ms–1s ahead of video before the first frame appears.
            out.pause()
        }

        // Calibrate audioClock to first decoded frame PTS on the first display
        // tick — same as post-seek calibration. Required for H.264 B-frame streams
        // whose PTS does not start at 0 (priming delay).
        needsClockCalibration = true

        state.isPlaying = true
        notifyStateChange()

        if let seekTo { seek(to: seekTo) }
    }

    private func wireJitterBuffer() {
        jitterBuffer.onStateChange = { [weak self] newState in
            guard let self else { return }
            switch newState {
            case .buffering:
                self.audioUnitOutput?.pause()
                self._injectedAudioOutput?.pause()
                self.state.isBuffering = true
            case .playing:
                self.audioUnitOutput?.resume()
                self._injectedAudioOutput?.resume()
                self.state.isBuffering = false
            }
            self.notifyStateChange()
        }
    }

    // MARK: - Demux loop

    private func startDemuxLoop() {
        demuxCancelled = false
        let demuxer = self.demuxer!
        let audioDec = audioDecoder
        let audioOut = audioUnitOutput
        let clock = audioClock
        let jitter = jitterBuffer
        let dLock = demuxLock
        let sLock = seekLock

        DispatchQueue.global().async { [weak self, colorParams] in
            var ptsValidator = PTSValidator()
            var packetCount: Int32 = 0
            var eofRecoveryDone = false
            var lastSeenSerial: Int64 = -1

            let frameDuration: Double
            if let vs = demuxer.videoStream {
                let fr = vs.pointee.avg_frame_rate
                frameDuration = fr.num > 0 ? Double(fr.den) / Double(fr.num) : 1.0/25.0
            } else {
                frameDuration = 1.0/25.0
            }
            ptsValidator.frameDuration = frameDuration

            while true {
                guard let self, !self.demuxCancelled else { break }

                // Backpressure: when jitter buffer is full, sleep briefly to let
                // the display loop consume frames. But don't hold the demux lock
                // — audio packets interleaved in the stream still need to be read
                // and fed to AudioUnitOutput, otherwise audio runs dry.
                if jitter.duration >= jitter.maxDuration {
                    Thread.sleep(forTimeInterval: 0.005)
                    continue
                }

                dLock.lock()
                if self.demuxCancelled { dLock.unlock(); break }

                let currentSerial = sLock.withLock { self.seekSerial }

                // Reset state on seek so stale values don't affect post-seek packets.
                if currentSerial != lastSeenSerial {
                    ptsValidator.reset()
                    lastSeenSerial = currentSerial
                }

                guard let result = demuxer.readPacket() else {
                    dLock.unlock()
                    if packetCount == 0, !eofRecoveryDone {
                        eofRecoveryDone = true
                        logger.error("immediate EOF, recovering to 0")
                        dLock.lock()
                        _ = demuxer.seek(to: 0)
                        self.videoDecoder?.flush(); audioDec?.flush()
                        dLock.unlock()
                        jitter.flush()
                        clock.reset(to: 0, sampleRate: audioDec?.outputSampleRate ?? 44100)
                        audioOut?.stop()
                        if let dec = audioDec {
                            audioOut?.start(sampleRate: dec.outputSampleRate, channels: dec.outputChannels)
                        }
                        continue
                    }
                    logger.info("demux EOF after \(packetCount) packets")
                    break
                }

                packetCount += 1
                let pktSize = Int(result.packet.pointee.size)
                if pktSize > 0 { totalBytesRead += Int64(pktSize) }
                let streamIndex = result.streamIndex
                let packet = result.packet

                if streamIndex == demuxer.videoStreamIndex {
                    let rawPTS = Self.ptsFromPacket(packet, demuxer: demuxer)
                    let pts = ptsValidator.validate(rawPTS)
                    if packetCount < 5 || (packetCount % 500 == 0) {
                        logger.debug("pkt#\(packetCount) rawPTS=\(String(format:"%.3f",rawPTS)) pts=\(String(format:"%.3f",pts)) audio=\(String(format:"%.3f",clock.audioTime))")
                    }

                    // Decode every video packet in stream order — no pre-decode
                    // drop filtering.  A/V sync is enforced at render time by the
                    // display loop's freeze-ahead / skip-behind guard (±60ms),
                    // which is far tighter than any demux-level threshold and
                    // cannot cause the "skip to next I-frame" cascade that
                    // demux-level dropping produced after seek.  JitterBuffer's
                    // maxDuration backpressure caps memory growth.

                    // VT→SW fallback: when VideoToolbox repeatedly fails to decode
                    // (e.g. 4K@120fps exceeds HW limits), hot-swap to FFmpeg software
                    // decoder without restarting the demux loop.
                    if let vt = self.videoDecoder as? VTVideoDecoder, vt.needsSoftwareFallback,
                       let vs = demuxer.videoStream,
                       let sw = FFmpegVideoDecoder(stream: vs, forceSoftware: true, colorParams: colorParams) {
                        logger.notice("VT→SW fallback: \(sw.width)x\(sw.height) — HW decoder failed, using FFmpeg SW")
                        self.videoDecoder = sw
                    }

                    let decoded = self.videoDecoder?.decode(packet: packet)
                    dLock.unlock()

                    if let frame = decoded,
                       sLock.withLock({ self.seekSerial }) == currentSerial {
                        jitter.append(.init(pixelBuffer: frame.pixelBuffer, pts: pts, metadata: frame.metadata))
                        let ptsCopy = pts
                        DispatchQueue.main.async { [weak self] in
                            guard let self else { return }
                            let d = Duration.milliseconds(Int64(ptsCopy * 1000))
                            if d > self.state.duration { self.state.duration = d }
                        }
                    }

                } else if streamIndex == demuxer.audioStreamIndex {
                    let codecName = String(cString: avcodec_get_name(
                        demuxer.audioStream!.pointee.codecpar.pointee.codec_id))
                    let usePassthrough: Bool
                    if let injected = _injectedAudioOutput,
                       injected.supportsPassthrough,
                       demuxer.isPassthroughCodec {
                        // Passthrough (AC3, E-AC3, DTS, TrueHD) requires a
                        // digital audio output (HDMI ARC / SPDIF). The
                        // AudioOutputBackend.supportsPassthrough property is
                        // responsible for reporting whether the current output
                        // device can actually decode compressed audio — if not,
                        // it returns false and we fall through to PCM decode.
                        usePassthrough = true
                    } else {
                        usePassthrough = false
                    }

                    if usePassthrough {
                        isPassthroughActive = true
                        // Passthrough path: route compressed packets directly to
                        // AVSampleBufferAudioRenderer (PRO backend).
                        let pkt = packet.pointee
                        let size = Int(pkt.size)
                        let pts = NativeBackend.ptsFromPacket(packet, demuxer: demuxer)
                        var data = Data(count: size)
                        if size > 0, let buf = pkt.data {
                            data.withUnsafeMutableBytes { raw in
                                raw.baseAddress!.copyMemory(from: buf, byteCount: size)
                            }
                        }
                        dLock.unlock()
                        _injectedAudioOutput?.outputCompressed(data, pts: pts, codec: codecName)
                    } else {
                        // PCM path: decode with FFmpeg and enqueue to AudioUnit.
                        // Read decoder/output from self each iteration — selectAudioTrack
                        // may have replaced them since the loop started.
                        let currentDec = self.audioDecoder
                        let currentOut = self.audioUnitOutput
                        let pcm = currentDec?.decode(packet: packet)
                        dLock.unlock()
                        if let pcm { currentOut?.enqueue(pcm) }
                    }
                } else if streamIndex == demuxer.subtitleStreamIndex,
                          demuxer.subtitleStreamIndex >= 0 {
                    let cue = Self.parseASSCue(packet: packet, stream: demuxer.subtitleStream)
                    dLock.unlock()
                    if let cue {
                        self.subtitleLock.withLock { self.subtitleCues.append(cue) }
                    }
                } else {
                    dLock.unlock()
                }

                var p: UnsafeMutablePointer<AVPacket>? = packet
                av_packet_free(&p)
            }
        }
    }

    private nonisolated static func ptsFromPacket(_ packet: UnsafeMutablePointer<AVPacket>,
                                                   demuxer: FFmpegDemuxer) -> Double {
        guard let vs = demuxer.videoStream else { return .nan }
        let tb = vs.pointee.time_base
        let nopts = Int64(bitPattern: 0x8000000000000000)
        guard tb.den > 0, packet.pointee.pts != nopts else { return .nan }
        return Double(packet.pointee.pts) * Double(tb.num) / Double(tb.den)
    }

    /// Parse an ASS/SSA subtitle packet from MKV into a SubtitleCue.
    ///
    /// MKV stores each ASS dialogue line as a raw packet with this field layout:
    ///   ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text
    /// The Text field (index 8) may contain ASS override tags ({...}) and hardcoded
    /// line-break sequences (\N / \n). We strip tags and convert breaks to newlines.
    /// Timing comes from packet.pts/duration scaled by the subtitle stream timebase.
    private static func parseASSCue(
        packet: UnsafeMutablePointer<AVPacket>,
        stream: UnsafeMutablePointer<AVStream>?
    ) -> SubtitleCue? {
        guard let stream,
              packet.pointee.size > 0,
              let rawPtr = packet.pointee.data else { return nil }

        let codecId = stream.pointee.codecpar.pointee.codec_id
        guard codecId == AV_CODEC_ID_ASS || codecId == AV_CODEC_ID_SSA else { return nil }

        guard let raw = String(bytes: UnsafeBufferPointer(start: rawPtr,
                                                           count: Int(packet.pointee.size)),
                               encoding: .utf8) else { return nil }

        // Split on the first 8 commas only; Text (field 8) may itself contain commas.
        let parts = raw.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false)
        guard parts.count >= 9 else { return nil }

        var text = String(parts[8]).trimmingCharacters(in: .newlines)
        // Strip ASS override tags: {\an8}, {\b1}, {\1c&Hffffff&}, etc.
        text = text.replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression)
        // Hardcoded line breaks
        text = text.replacingOccurrences(of: "\\N", with: "\n")
        text = text.replacingOccurrences(of: "\\n", with: "\n")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let tb = stream.pointee.time_base
        guard tb.den > 0 else { return nil }
        let tbSecs = Double(tb.num) / Double(tb.den)
        let nopts = Int64(bitPattern: 0x8000000000000000)
        guard packet.pointee.pts != nopts else { return nil }

        let startPts = Double(packet.pointee.pts) * tbSecs
        let dur = packet.pointee.duration > 0
            ? Double(packet.pointee.duration) * tbSecs
            : 5.0
        return SubtitleCue(startPts: startPts, endPts: startPts + dur, text: text)
    }

    // MARK: - Display (CADisplayLink)

    fileprivate func displayNextFrame() {
        let now = CACurrentMediaTime()
        ticksSinceLastLog += 1

        guard jitterBuffer.state == .playing else { return }

        // Calibrate audioClock to the actual first decoded frame PTS after seek.
        // seek() resets audioClock to the target position, but FFmpeg seeks to the
        // nearest prior I-frame, so the first decodable frame's PTS < seek target.
        // Without this, PacketDropPolicy sees "video behind audio" and drops all
        // non-keyframes up to the next I-frame, causing a 6+ second overshoot.
        //
        // We re-calibrate on every tick until the first frame is actually rendered.
        // This is critical: AudioQueueStop(immediate=true) and AudioQueueStart can
        // fire callbacks asynchronously that advance the clock *after* our reset,
        // polluting audioClock to be ahead of the first video frame PTS.  If we
        // cleared the flag on peek (before render), the next tick's audioTime
        // would already be ahead and trigger skip-behind, dropping 5-10 frames
        // → the user-visible "1s 花屏/卡顿" right after seek.
        if needsClockCalibration, let firstFrame = jitterBuffer.peek(at: 0) {
            audioClock.reset(to: firstFrame.pts, sampleRate: audioDecoder?.outputSampleRate ?? 44100)
        }

        // In passthrough mode AudioUnitOutput never runs so audioClock stays at 0.
        // Use video PTS as master clock so A/V sync still advances frames.
        // On iOS/tvOS passthrough is disabled (PCM decode), so audioClock is
        // driven by AudioUnitOutput even when PassthroughOutput is injected.
        let audioTime: Double
        if _injectedAudioOutput != nil && isPassthroughActive {
            audioTime = jitterBuffer.peek(at: 0)?.pts ?? audioClock.audioTime
        } else {
            audioTime = audioClock.audioTime
        }
        let serial = seekLock.withLock { seekSerial }

        // --- Freeze-ahead / Skip-behind (commercial player A/V sync) ---
        // After the first post-seek frame has been displayed, guard against large
        // desync without changing playback speed.  Video ahead of audio: freeze
        // current frame until audio catches up.  Video behind audio: silently pop
        // stale frames.
        //
        // For high-source-fps content (120fps) on a 60Hz display, 2+ source frames
        // age per display tick.  A single pop would fall further behind each cycle
        // until almost every frame triggers the guard → the user sees a frozen image.
        // Draining ALL stale frames in one pass keeps video locked to audio regardless
        // of the source→display ratio.
        if syncController.hasDisplayedFrame, !needsClockCalibration {
            // Drain frames significantly behind audio
            while let lagging = jitterBuffer.peek(at: 0), lagging.pts < audioTime - 0.06 {
                jitterBuffer.pop()
            }
            // Freeze-ahead: if the front frame is ahead of audio, stall
            if let ahead = jitterBuffer.peek(at: 0), ahead.pts > audioTime + 0.06 {
                let pos = Duration.milliseconds(Int64(audioTime * 1000))
                if (pos - lastNotifiedPos) >= .milliseconds(500) {
                    state.position = pos; notifyStateChange(); lastNotifiedPos = pos
                }
                return
            }
        }

        guard let frame = jitterBuffer.peek(at: 0) else { return }

        let followingPTS = jitterBuffer.peek(at: 1)?.pts

        let (shouldShow, delay) = syncController.check(
            nextPTS: frame.pts,
            followingPTS: followingPTS,
            audioTime: audioTime,
            now: now,
            serial: serial
        )

        guard shouldShow else {
            let pos = Duration.milliseconds(Int64(audioTime * 1000))
            if (pos - lastNotifiedPos) >= .milliseconds(500) {
                state.position = pos; notifyStateChange(); lastNotifiedPos = pos
            }
            return
        }

        guard let popped = jitterBuffer.pop() else { return }
        syncController.advance(delay: delay, pts: popped.pts,
                               followingPTS: followingPTS, audioTime: audioTime, now: now)
        var cp = colorParams
        cp.dovi = popped.metadata.dovi
        _renderer.render(pixelBuffer: popped.pixelBuffer,
                         pts: popped.pts,
                         colorParams: cp,
                         metadata: popped.metadata,
                         strategy: rendererStrategy)
        let ptsCopy = popped.pts
        let sinks = self._frameSinks.compactMap { $0.sink }
        for sink in sinks {
            sink.receive(pixelBuffer: popped.pixelBuffer, pts: ptsCopy)
        }
        displayedVideoFrames += 1; framesSinceLastLog += 1

        // First frame rendered — calibration window is over.  Subsequent ticks
        // let audioClock advance naturally via AudioQueue callbacks.
        if needsClockCalibration {
            needsClockCalibration = false
        }

        let posDur = Duration.milliseconds(Int64(popped.pts * 1000))
        state.position = posDur
        if posDur > state.duration { state.duration = posDur }

        // Update active subtitle text. Only notify when the text actually changes
        // to avoid redundant view invalidations on every frame.
        let activeSub: String? = subtitleLock.withLock {
            subtitleCues.first { $0.startPts <= audioTime && audioTime < $0.endPts }?.text
        }
        if activeSub != lastSubtitleText {
            lastSubtitleText = activeSub
            state.currentSubtitleText = activeSub
            notifyStateChange()
        } else if (posDur - lastNotifiedPos) >= .milliseconds(500) {
            notifyStateChange()
        }
        if (posDur - lastNotifiedPos) >= .milliseconds(500) { lastNotifiedPos = posDur }

        logSync(now: now, pts: popped.pts, audioTime: audioTime)
    }

    private func logSync(now: Double, pts: Double, audioTime: Double) {
        let elapsed = now - lastLogTime
        guard elapsed > 5.0 else { return }
        let fps = Double(framesSinceLastLog) / elapsed
        let diff = Int((pts - audioTime) * 1000)
        logger.info("q=\(self.jitterBuffer.count) dur=\(Int(self.jitterBuffer.duration*1000))ms fps=\(String(format:"%.1f",fps)) diff=\(diff)ms a=\(String(format:"%.2f",audioTime))s v=\(String(format:"%.2f",pts))s buf=\(self.state.isBuffering)")

        // Throughput: bytes read since last sample / elapsed.
        let bytesDelta = totalBytesRead - lastBytesLogged
        let tpElapsed = now - lastThroughputTime
        if tpElapsed > 1.0 {
            state.cacheSpeed = Int64(Double(bytesDelta) / tpElapsed)
            lastBytesLogged = totalBytesRead
            lastThroughputTime = now
        }

        lastLogTime = now; framesSinceLastLog = 0; ticksSinceLastLog = 0
    }

    // MARK: - Controls

    public func pause() {
        logger.info("pause")
        displayLink?.invalidate(); displayLink = nil
        #if os(macOS)
        // Keep displayLinkProxy alive: CVDisplayLink's output callback holds an
        // unretained raw pointer to it. Releasing the proxy here would leave a
        // dangling pointer that gets dereferenced on the next CVDisplayLinkStart.
        if let cv = cvDisplayLink, CVDisplayLinkIsRunning(cv) { CVDisplayLinkStop(cv) }
        #else
        displayLinkProxy = nil
        #endif
        audioUnitOutput?.pause()
        state.isPlaying = false; notifyStateChange()
    }

    public func resume() {
        logger.info("resume")
        if jitterBuffer.state == .playing { audioUnitOutput?.resume() }
        startDisplayLink()
        state.isPlaying = true; notifyStateChange()
    }

    public func seek(to: Duration) {
        let secs = Double(to.components.seconds) + Double(to.components.attoseconds) * 1e-18
        logger.info("seek to \(String(format:"%.1f",secs))s")
        demuxLock.lock()
        seekLock.withLock { seekSerial += 1 }
        _ = demuxer?.seek(to: secs)
        videoDecoder?.flush(); audioDecoder?.flush()
        demuxLock.unlock()

        subtitleLock.withLock { subtitleCues.removeAll() }
        lastSubtitleText = nil

        jitterBuffer.flush()
        syncController.reset()
        // Clear the displayed frame so the pre-seek frame doesn't linger on
        // screen until the first post-seek frame is decoded and rendered.
        _renderer.flush()

        let sr = audioDecoder?.outputSampleRate ?? 44100
        let ch = audioDecoder?.outputChannels ?? 2
        // stop() BEFORE reset: AudioQueueStop(immediate=true) fires callbacks for
        // all buffered frames, each calling clock.advance().  Resetting before stop
        // would let those callbacks push the clock past secs.  Reset after stop so
        // it always lands exactly at secs regardless of how many frames were buffered.
        audioUnitOutput?.stop()
        audioClock.reset(to: secs, sampleRate: sr)
        audioUnitOutput?.start(sampleRate: sr, channels: ch)
        // Pause until jitterBuffer has enough video — same as initial play().
        audioUnitOutput?.pause()
        // Signal displayNextFrame to calibrate audioClock to actual I-frame PTS.
        // FFmpeg seek lands on the GOP boundary before secs, so audioClock(=secs)
        // would be ahead of the first decoded frame; without re-calibration the
        // display loop's skip-behind guard would drop the first few frames.
        needsClockCalibration = true
    }

    public func stop() {
        playGeneration += 1  // discard any in-flight async open
        logger.info("stop (displayed \(self.displayedVideoFrames) frames)")
        displayLink?.invalidate(); displayLink = nil; displayLinkProxy = nil
        #if os(macOS)
        if let cv = cvDisplayLink, CVDisplayLinkIsRunning(cv) { CVDisplayLinkStop(cv) }
        cvDisplayLink = nil
        #endif
        demuxCancelled = true
        audioUnitOutput?.stop()
        demuxLock.lock()
        demuxer?.close(); demuxer = nil
        videoDecoder = nil; audioDecoder = nil
        demuxLock.unlock()
        jitterBuffer.flush()
        syncController.reset()
        audioClock.reset(to: 0, sampleRate: 44100)  // critical: must reset or stale seek position
                                                     // from previous session pollutes AudioClock
        _renderer.flush()
        _renderer.clear()  // hide the previous video's last frame until the new
                           // video renders its first frame (MetalRenderer.display
                           // flips opacity back to 1 on first frame)
        displayedVideoFrames = 0
        totalBytesRead = 0; lastBytesLogged = 0; lastThroughputTime = 0
        state = PlayerState()
    }

    public func setVolume(_ volume: Double) { state.volume = volume; notifyStateChange() }
    public func setRate(_ rate: Double)     { state.rate = rate; notifyStateChange() }
    public func selectAudioTrack(id: String) {
        guard let demuxer else { return }
        guard let trackId = Int(id) else { return }
        guard trackId != demuxer.audioStreamIndex else { return }

        logger.info("selectAudioTrack id=\(trackId)")

        // 1. Stop audio output
        audioUnitOutput?.stop()

        // 2. Under lock: flush old decoder, switch stream, seek demuxer, create new decoder.
        // All decoder/stream mutations must happen inside demuxLock so the demux loop
        // (which holds demuxLock while processing audio packets) always sees a consistent
        // pair of (audioStreamIndex, audioDecoder). Creating the decoder outside the lock
        // caused the loop to feed new-stream packets into the stale old decoder.
        demuxLock.lock()
        audioDecoder?.flush()
        audioDecoder = nil
        guard demuxer.selectAudioStream(by: trackId) else {
            demuxLock.unlock()
            logger.warning("selectAudioTrack: stream \(trackId) not found, recreating original output")
            recreateAudioOutput()
            return
        }
        let posSecs = Double(state.position.components.seconds)
        _ = demuxer.seek(to: posSecs)
        if let stream = demuxer.audioStream {
            audioDecoder = FFmpegAudioDecoder(stream: stream, sampleRate: 44100, channels: 2)
        }
        seekLock.withLock { seekSerial += 1 }
        demuxLock.unlock()

        // 4. Flush video pipeline
        videoDecoder?.flush()
        jitterBuffer.flush()
        syncController.reset()
        _renderer.flush()

        // 5. Recreate audio output with new decoder's parameters
        let sr = audioDecoder?.outputSampleRate ?? 44100
        let ch = audioDecoder?.outputChannels ?? 2
        audioClock.reset(to: posSecs, sampleRate: sr)
        audioUnitOutput = AudioUnitOutput(clock: audioClock)
        audioUnitOutput?.start(sampleRate: sr, channels: ch)
        audioUnitOutput?.pause()
        needsClockCalibration = true

        // 6. Update state
        state.selectedAudioTrackId = trackId
        refreshAudioTracks()
        notifyStateChange()

        logger.info("selectAudioTrack done, new decoder sampleRate=\(self.audioDecoder?.outputSampleRate ?? 0)")
    }

    public func selectSubtitle(id: String?) {
        guard let demuxer else { return }
        let trackId = id.flatMap(Int.init)

        // Switch subtitle stream under demuxLock so the demux loop sees the new
        // subtitleStreamIndex atomically with the next readPacket call.
        demuxLock.lock()
        demuxer.selectSubtitleStream(by: trackId)
        demuxLock.unlock()

        // Discard cues from the previous track.
        subtitleLock.withLock { subtitleCues.removeAll() }

        lastSubtitleText = nil
        state.selectedSubtitleTrackId = trackId
        if state.currentSubtitleText != nil {
            state.currentSubtitleText = nil
            notifyStateChange()
        }
    }

    private func recreateAudioOutput() {
        audioUnitOutput = AudioUnitOutput(clock: audioClock)
        if let dec = audioDecoder {
            audioUnitOutput?.start(sampleRate: dec.outputSampleRate, channels: dec.outputChannels)
            audioUnitOutput?.pause()
        }
    }

    private func refreshAudioTracks() {
        guard let fmtCtx = demuxer?.formatContext else { return }
        var tracks: [TrackInfo] = []
        let nb = Int(fmtCtx.pointee.nb_streams)
        for i in 0..<nb {
            guard let s = fmtCtx.pointee.streams[i] else { continue }
            let cp = s.pointee.codecpar.pointee
            guard cp.codec_type == AVMEDIA_TYPE_AUDIO else { continue }

            let codecName: String? = cp.codec_id != AV_CODEC_ID_NONE
                ? String(cString: avcodec_get_name(cp.codec_id))
                : nil

            var title: String?
            var lang: String?
            if let meta = s.pointee.metadata {
                if let e = av_dict_get(meta, "title", nil, 0), let v = e.pointee.value {
                    title = String(cString: v)
                }
                if let e = av_dict_get(meta, "language", nil, 0), let v = e.pointee.value {
                    lang = String(cString: v)
                }
            }

            let isDefault = (s.pointee.disposition & Int32(AV_DISPOSITION_DEFAULT)) != 0
            let isAtmos = (s.pointee.index == demuxer?.audioStreamIndex)
                ? (demuxer?.audioIsAtmos ?? false)
                : false

            tracks.append(TrackInfo(
                id: Int(s.pointee.index),
                title: title,
                lang: lang,
                codec: codecName,
                isDefault: isDefault,
                isAtmos: isAtmos
            ))
        }
        state.audioTracks = tracks
    }
    public func prepareForReuse() { stop() }

    public func addFrameSink(_ sink: any FrameSink) {
        _frameSinks.removeAll { $0.sink == nil }
        _frameSinks.append(WeakFrameSink(sink: sink))
    }

    public func removeFrameSink(_ sink: any FrameSink) {
        _frameSinks.removeAll { $0.sink == nil || $0.sink === sink }
    }

    // MARK: - Display link

    private func startDisplayLink() {
        #if os(iOS) || os(tvOS)
        let proxy = DisplayLinkProxy(backend: self)
        displayLinkProxy = proxy
        displayLink?.invalidate()
        let link = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick))
        // Request high refresh rate for smooth video — 25fps/24fps content on
        // 60Hz suffers visible 3:2 pulldown judder (33/50ms alternating gaps).
        // At 120Hz the same content maps to ~5-tick gaps (41ms), near-perfect.
        if #available(iOS 15.0, tvOS 15.0, *) {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        }
        link.add(to: .main, forMode: .common)
        displayLink = link
        #elseif os(macOS)
        // CVDisplayLink runs on a high-priority background thread; the callback
        // must hop to the main actor to call displayNextFrame (which touches
        // @MainActor-isolated backend state and the Metal renderer).
        if cvDisplayLink == nil {
            var link: CVDisplayLink?
            CVDisplayLinkCreateWithActiveCGDisplays(&link)
            guard let link else {
                logger.error("CVDisplayLinkCreateWithActiveCGDisplays FAILED")
                return
            }
            cvDisplayLink = link
        }
        // Always (re)bind the output callback to the current proxy.  pause()
        // keeps displayLinkProxy alive on macOS so the raw pointer stays valid
        // across pause/resume cycles; we still reset the callback each start
        // so a fresh proxy (after stop()) is correctly wired.
        let proxy = displayLinkProxy ?? DisplayLinkProxy(backend: self)
        displayLinkProxy = proxy
        let proxyPtr = Unmanaged.passUnretained(proxy).toOpaque()
        CVDisplayLinkSetOutputCallback(cvDisplayLink!, { _, _, _, _, _, ctx in
            guard let ctx else { return kCVReturnSuccess }
            let p = Unmanaged<DisplayLinkProxy>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { p.tick() }
            return kCVReturnSuccess
        }, proxyPtr)
        if let cv = cvDisplayLink, !CVDisplayLinkIsRunning(cv) {
            CVDisplayLinkStart(cv)
        }
        #endif
    }
}

extension NSLock {
    @discardableResult
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}
