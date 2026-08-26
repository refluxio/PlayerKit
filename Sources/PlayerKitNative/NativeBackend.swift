import AVFoundation
import Foundation
import CoreMedia
import CoreVideo
import QuartzCore
import PlayerKit
@_exported import CFFmpeg
import os

private let logger = Logger(subsystem: "io.reflux.PlayerKit", category: "backend")

private extension Duration {
    var secondsDouble: Double {
        Double(components.seconds) + Double(components.attoseconds) * 1e-18
    }
}

/// Builds one concat-demuxer script entry: a `file` line plus per-file `option`
/// directives that carry `headers` to that specific clip's http open (see call
/// site in `NativeBackend.play(concatURLs:)` for why this is necessary).
///
/// The concat script is read line-by-line (split on raw `\n`) before each line's
/// arguments are tokenized, so a directive's value can never contain an embedded
/// `\n` — ruling out a single multi-header `option headers 'A: 1\r\nB: 2\r\n'`
/// blob. Instead this maps the two headers CDNs actually gate on (User-Agent,
/// Referer) to ffmpeg http.c's dedicated single-value AVOptions (`user_agent`,
/// `referer`), and falls back to the generic `headers` option for at most one
/// other header (currently only WebDAV's `Authorization`, which drivers never
/// combine with a second custom header).
fileprivate func concatFileEntry(url: URL, headers: [String: String]) -> String {
    var lines = ["file '\(concatEscape(url.absoluteString))'"]
    var rest: [String: String] = [:]
    for (key, value) in headers {
        switch key.lowercased() {
        case "user-agent": lines.append("option user_agent '\(concatEscape(value))'")
        case "referer":    lines.append("option referer '\(concatEscape(value))'")
        default:           rest[key] = value
        }
    }
    if let (key, value) = rest.first {
        lines.append("option headers '\(concatEscape("\(key): \(value)"))'")
    }
    return lines.joined(separator: "\n") + "\n"
}

/// Escapes a value for embedding in a single-quoted concat script token, using
/// the same close-quote/escape/reopen-quote trick the format's own `av_get_token`
/// parser expects (`it's` → `it'\''s'`).
private func concatEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "'", with: "'\\''")
}

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

    /// Preferred maximum video width (0 = unlimited). When >0, the demuxer
    /// picks the highest-resolution video stream not exceeding this width.
    /// Set by PlayerController based on the user's quality preference.
    public nonisolated(unsafe) var preferredMaxVideoWidth: Int = 0

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

    private var demuxer: (any PacketDemuxing)?
    /// VT may fail on extreme-parameter streams (e.g. 4K@120fps).
    /// When that happens the demux loop hot-swaps in a software FFmpegVideoDecoder.
    /// Written once in _finishOpen(), then swapped from the demux queue on fallback.
    private nonisolated(unsafe) var videoDecoder: (any VideoDecoding)?
    private var audioDecoder: FFmpegAudioDecoder?
    /// Serial queue audio packets are decoded on, off the demux/video loop's
    /// thread. FFmpeg's software DTS-HD MA decode can be CPU-heavy enough
    /// per packet to starve video decode when both ran serially on the same
    /// thread — measured on-device: reads served instantly from a warm
    /// prefetch buffer (network fully ruled out) yet video fps still sat at
    /// 1-10fps. Also, decode staying serial with the demux loop meant a slow
    /// audio decode directly delayed audioClock, which then throttled video
    /// via the "stay within 2s of audio" sleep below — so a slow audio
    /// decoder was doubly capping video: starving its CPU time *and* pacing
    /// it down to match. Serial (not concurrent) so packet order — and
    /// therefore audio sample order — is preserved; flush() call sites are
    /// routed through this same queue (via .sync) so they can't race a
    /// still-in-flight decode() of an earlier packet.
    private let audioDecodeQueue = DispatchQueue(label: "io.reflux.PlayerKit.audioDecode")

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
    // Above this, a video/audio PTS gap at calibration time is no longer a
    // normal "nearest keyframe was slightly before the seek target" rounding
    // (typically well under a second for BD content) — see displayNextFrame().
    // 15s:覆盖 4K HEVC 大 GOP(可达 5-10s)的 seek 对齐差。seek 落点
    // (目标前最近 I 帧)与目标差小于该值就校准 audioClock 到落点,避免
    // 大 GOP 时"校准失败 → audioClock 停在目标 → 视频帧全被 drain →
    // seek 后黑屏/位置跳变"。
    private let maxCalibrationGap: Double = 15.0

    // Subtitle cue buffer — written from demux loop, read from display loop.
    private struct SubtitleCue {
        let startPts: Double
        let endPts: Double
        let text: String
    }
    private let subtitleLock = NSLock()
    private nonisolated(unsafe) var subtitleCues: [SubtitleCue] = []
    private nonisolated(unsafe) var lastSubtitleText: String? = nil

    private struct SubtitleImageCue {
        let startPts: Double
        let endPts: Double
        let image: CGImage
        let rect: CGRect
    }
    private let subtitleImageLock = NSLock()
    private nonisolated(unsafe) var subtitleImageCues: [SubtitleImageCue] = []
    private nonisolated(unsafe) var lastSubtitleImage: CGImage? = nil

    private nonisolated(unsafe) var subtitleDecoder: FFmpegSubtitleDecoder?

    // Pipeline control
    private let demuxLock = NSLock()
    private let seekLock = NSLock()
    // Guarded by seekLock — safe to access from any thread holding the lock.
    private nonisolated(unsafe) var seekSerial: Int64 = 0
    /// Set true after seek()/play(), cleared on first frame render + audioClock advance.
    /// While true, freeze-ahead guard is bypassed so primer callbacks have time to
    /// fire and advance audioClock past 0 — without this, seek-to-0 freezes because
    /// primer debt keeps audioClock at 0 while video PTS advances past the 60ms threshold.
    private nonisolated(unsafe) var audioClockReady: Bool = false
    // demuxCancelled is read from DispatchQueue.global() under demuxLock.
    // Bool reads/writes are atomic on ARM64 in practice; nonisolated(unsafe) makes
    // that contract explicit for the compiler's concurrency checker.
    private nonisolated(unsafe) var demuxCancelled = false
    private var displayLink: CADisplayLink?
    private var displayLinkProxy: DisplayLinkProxy?
    #if os(macOS)
    private var cvDisplayLink: CVDisplayLink?
    /// macOS 兜底渲染驱动。CVDisplayLink 在 stop→start 之后可能延迟数秒才恢复
    /// 回调(实测:CVDisplayLinkStart 后 6.3s 才收到 first tick),期间视频冻结、
    /// state.position 不更新 → app 层 UpNext 检测读到 ~0 的初始值误触发 EOF。
    /// 用主 queue 的 DispatchSourceTimer 兜底驱动 displayNextFrame —— 它幂等
    /// (每 tick 最多 pop 一帧),与 CVDisplayLink 竞争无害;link 恢复后自然占主导,
    /// 兜底 timer 空转。
    private var fallbackRenderTimer: DispatchSourceTimer?
    #endif

    // Cancellation: incremented on every play()/stop() to discard stale async opens
    private var playGeneration: Int = 0

    // Logging
    private var displayedVideoFrames = 0
    private var framesSinceLastLog = 0
    private var ticksSinceLastLog = 0
    private var lastLogTime: Double = 0
    // Diagnostic: see the gap-detection note in displayNextFrame().
    private var lastTickWallTime: Double?
    private let tickGapWarnThreshold: Double = 0.05
    // Diagnostic: wall time startDisplayLink() was called, so the first tick
    // can log how long it took to actually arrive — distinguishes "the link
    // itself didn't fire for N seconds" (real main-thread/runloop stall) from
    // "ticks were firing fine but one later tick got delayed" (the existing
    // gap check only ever compares tick-to-tick, so a slow *first* tick was
    // invisible: lastTickWallTime starts nil, so tick #1 never gets a gap
    // check — it just silently sets the baseline).
    private var displayLinkStartWallTime: Double?
    private var firstTickLogged = false
    /// 同步旁路(audioClockReady=false)弹帧的节拍基准:上一帧实际弹出的
    /// 墙钟时刻。旁路不再每个显示驱动 tick 都弹帧,而是按源 PTS 间隔 pacing。
    /// 初始 0 → 首个 tick 立即弹出;seek/resume/stop/flush 后复位同样立即
    /// 弹出,不会等待。
    private var lastBypassPopTime: Double = 0
    private var lastNotifiedPos: Duration = .zero

    // Throughput tracking. Written from demux queue, read on main actor.
    private nonisolated(unsafe) var totalBytesRead: Int64 = 0
    private nonisolated(unsafe) var lastBytesLogged: Int64 = 0
    private nonisolated(unsafe) var lastThroughputTime: Double = 0
    /// Highest PTS (seconds) of packets read by the demux loop — used to compute bufferedDuration.
    private nonisolated(unsafe) var maxDownloadedPts: Double = 0

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
        Task.detached(priority: .userInitiated) { [weak self, preferredMaxVideoWidth] in
            let demuxer = FFmpegDemuxer()
            demuxer.preferredMaxVideoWidth = preferredMaxVideoWidth
            do {
                try demuxer.open(url: url, headers: headers,
                                 skipDurationProbe: knownDuration != nil,
                                 knownDurationSecs: knownDuration?.secondsDouble)
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

    public func play(reader: any MediaRandomAccessReader,
                     seekTo: Duration?,
                     knownDuration: Duration? = nil) {
        stop()
        state = PlayerState()
        state.isBuffering = true
        notifyStateChange()

        let t0 = Date()
        logger.notice("play (custom I/O reader)")

        playGeneration += 1
        let gen = playGeneration

        // Use GCD instead of Task.detached — Swift Concurrency's cooperative
        // thread pool can be starved by other async work (auto-scan, keepalive),
        // causing the demuxer open to be delayed 10-15s. GCD's dedicated thread
        // pool is not affected by cooperative scheduling.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let t1 = Date()
            logger.info("GCD block started, delay=\(String(format: "%.0f", t1.timeIntervalSince(t0) * 1000))ms")

            let demuxer = FFmpegDemuxer()
            demuxer.preferredMaxVideoWidth = self.preferredMaxVideoWidth
            do {
                try demuxer.open(reader: reader,
                                 skipDurationProbe: knownDuration != nil,
                                 knownDurationSecs: knownDuration?.secondsDouble)
            } catch {
                logger.error("demuxer.open (reader) FAILED: \(error)")
                let msg = (error as? CustomStringConvertible)?.description
                    ?? String(describing: error)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.playGeneration == gen else { return }
                    self.state.error = msg
                    self.notifyStateChange()
                }
                return
            }
            let t2 = Date()
            logger.info("demuxer.open done in \(String(format: "%.0f", t2.timeIntervalSince(t1) * 1000))ms")

            DispatchQueue.main.async { [weak self] in
                guard let self, self.playGeneration == gen else {
                    demuxer.close()
                    return
                }
                self._finishOpen(demuxer: demuxer, url: URL(string: "custom-io://reader")!,
                                 headers: [:], seekTo: seekTo, knownDuration: knownDuration)
            }
        }
    }

    public func play(concatURLs: [URL], headers: [String: String],
                     seekTo: Duration?, knownDuration: Duration? = nil) {
        stop()
        state = PlayerState()
        state.isBuffering = true
        notifyStateChange()

        guard !concatURLs.isEmpty else {
            state.error = "concat: no URLs"
            notifyStateChange()
            return
        }

        // Single URL — skip concat overhead, play directly.
        if concatURLs.count == 1 {
            play(url: concatURLs[0], headers: headers, seekTo: seekTo,
                 knownDuration: knownDuration)
            return
        }

        logger.notice("play concat \(concatURLs.count) urls")

        playGeneration += 1
        let gen = playGeneration

        let urls = concatURLs  // capture
        let hdrs = headers
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            // Write concat list to a temp file. Per-file `option` directives carry
            // auth headers to each clip's http open — the concat demuxer's own
            // `headers` AVOption (set on the outer avformat_open_input below) only
            // applies to opening this local list file, NOT to the nested per-clip
            // URLs it opens internally (ffmpeg concatdec.c: each file gets its own
            // AVDictionary built solely from that file's `option` lines). Without
            // this, CDNs that gate on User-Agent/Referer (e.g. 115: mismatched UA
            // → 403) reject every clip and the whole concat open fails.
            let listContent = urls.map { concatFileEntry(url: $0, headers: hdrs) }.joined()
            let tmpDir = FileManager.default.temporaryDirectory
            let listFile = tmpDir.appendingPathComponent("reflux-concat-\(UUID().uuidString).txt")
            do {
                try listContent.write(to: listFile, atomically: true, encoding: .utf8)
            } catch {
                let msg = "concat: failed to write list file: \(error.localizedDescription)"
                await MainActor.run { [weak self] in
                    guard let self, self.playGeneration == gen else { return }
                    self.state.error = msg
                    self.notifyStateChange()
                }
                return
            }
            defer { try? FileManager.default.removeItem(at: listFile) }

            let demuxer = FFmpegDemuxer()
            demuxer.preferredMaxVideoWidth = self.preferredMaxVideoWidth
            do {
                try demuxer.openConcat(listFileURL: listFile, headers: hdrs,
                                       skipDurationProbe: knownDuration != nil,
                                       knownDurationSecs: knownDuration?.secondsDouble)
            } catch {
                logger.error("demuxer.openConcat FAILED: \(error)")
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
                self._finishOpen(demuxer: demuxer,
                                 url: URL(string: "concat://list")!,
                                 headers: hdrs, seekTo: seekTo,
                                 knownDuration: knownDuration)
            }
        }
    }

    /// Start playback of an ordered sequence of independently-timed clips
    /// (BDMV disc playback) as one continuous presentation timeline, using
    /// MultiClipDemuxer's per-clip demux + PTS rebase instead of ffmpeg's
    /// concat demuxer (these readers are custom-I/O, not URL-openable by
    /// ffmpeg — see `play(concatURLs:)` for the URL-based alternative).
    /// - Parameters:
    ///   - clips: Ordered clips; `reader` feeds each clip's bytes to ffmpeg,
    ///     `durationSecs` is the clip's own real duration (caller-supplied,
    ///     e.g. from BD playlist metadata). Must be non-empty with all
    ///     durations > 0.
    ///   - seekTo: Optional start position (global timeline).
    ///   - knownDuration: Pre-known total duration, skips probe if non-nil.
    public func play(clips: [(reader: any MediaRandomAccessReader, durationSecs: Double)],
                     seekTo: Duration?,
                     knownDuration: Duration? = nil) {
        stop()
        state = PlayerState()
        state.isBuffering = true
        notifyStateChange()

        guard !clips.isEmpty else {
            state.error = "play(clips:): no clips"
            notifyStateChange()
            return
        }

        logger.notice("play \(clips.count) clips")

        playGeneration += 1
        let gen = playGeneration

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            let demuxer = MultiClipDemuxer(clips: clips)
            guard let demuxer else {
                let msg = "play(clips:): MultiClipDemuxer init failed (empty clips or non-positive duration)"
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.playGeneration == gen else { return }
                    self.state.error = msg
                    self.notifyStateChange()
                }
                return
            }
            do {
                // MultiClipDemuxer has no finishOpen of its own — open()
                // already drives FFmpegDemuxer.open(reader:) for clip 0, which
                // runs the full avformat_find_stream_info probe, so decoder
                // setup below can read stream metadata off it directly.
                try demuxer.open()
            } catch {
                logger.error("demuxer.open (clips) FAILED: \(error)")
                let msg = (error as? CustomStringConvertible)?.description
                    ?? String(describing: error)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.playGeneration == gen else { return }
                    self.state.error = msg
                    self.notifyStateChange()
                }
                return
            }

            DispatchQueue.main.async { [weak self] in
                guard let self, self.playGeneration == gen else {
                    demuxer.close()
                    return
                }
                self._finishOpen(demuxer: demuxer,
                                 url: URL(string: "clips://multi")!,
                                 headers: [:], seekTo: seekTo,
                                 knownDuration: knownDuration)
            }
        }
    }

    private func _finishOpen(demuxer: any PacketDemuxing, url: URL, headers: [String: String],
                              seekTo: Duration?, knownDuration: Duration?) {
        let t0 = Date()
        self.demuxer = demuxer
        // PacketDemuxing deliberately has no `duration` member (MultiClip's
        // total timeline length lives on ClipTimeline, not on the current
        // clip's demuxer), so recover it from the concrete types.
        let demuxDur: Double
        if let fd = demuxer as? FFmpegDemuxer {
            demuxDur = fd.duration
        } else if let mc = demuxer as? MultiClipDemuxer {
            demuxDur = mc.timeline.totalDurationSecs
        } else {
            demuxDur = 0
        }
        if let kd = knownDuration, kd > .zero {
            state.duration = kd
        } else if demuxDur > 0 {
            // demuxDur is refined by seekRefine() inside FFmpegDemuxer.open() —
            // it already reflects the true end-of-stream PTS, not the container placeholder.
            state.duration = Duration.seconds(demuxDur)
        }
        logger.info("duration: knownDuration=\(knownDuration.map{"\(Double($0.components.seconds))s"} ?? "nil") demuxer=\(String(format:"%.1f",demuxDur))s → using \(String(format:"%.1f",Double(self.state.duration.components.seconds)))s self=\(String(format:"%p", UInt(bitPattern: Unmanaged.passUnretained(self).toOpaque())))")

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
            let tVDec = Date()
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
            logger.info("video decoder init took \(String(format: "%.0f", Date().timeIntervalSince(tVDec) * 1000))ms")
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

            // Auto-select a subtitle stream if the demuxer hasn't already.
            // Without this, applyStreamDiscard() sets AVDISCARD_ALL on every
            // subtitle stream (because subtitleStream == nil), so PGS packets
            // are never read and bitmap subtitles never appear. Prefer the
            // stream with AV_DISPOSITION_DEFAULT; fall back to the first
            // subtitle stream of any type.
            if demuxer.subtitleStreamIndex < 0, !subs.isEmpty {
                let defaultSub = subs.first(where: { $0.isDefault }) ?? subs.first
                if let id = defaultSub?.id {
                    demuxer.selectSubtitleStream(by: id)
                    state.selectedSubtitleTrackId = id
                    logger.info("[sub] auto-selected stream \(id) (default=\(defaultSub?.isDefault ?? false))")
                }
            }
        }

        // Initialize graphic subtitle decoder for PGS/VOBSUB streams
        subtitleDecoder = nil
        if let defaultSubStream = demuxer.subtitleStream {
            let codecId = defaultSubStream.pointee.codecpar.pointee.codec_id
            if codecId == AV_CODEC_ID_HDMV_PGS_SUBTITLE || codecId == AV_CODEC_ID_DVD_SUBTITLE {
                let vSize = CGSize(width: codedVideoWidth, height: codedVideoHeight)
                subtitleDecoder = FFmpegSubtitleDecoder(stream: defaultSubStream, videoSize: vSize)
            }
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

        // 音频队列必须先于 demux/display 启动建好并暂停。否则 demux 线程把
        // jitterBuffer 翻到 .playing(onStateChange → resume())时,音频队列
        // 尚未创建(start() 未跑)或本次 pause() 晚于那次 resume() 而覆盖了
        // 它 —— 两种情况下 resume() 都丢失,状态不再翻转 → 音频永久暂停,
        // audioClock 永远为 0 → audioClockReady=false → 同步旁路以显示驱动
        // 频率弹帧(macOS 双驱动最高 ~90Hz)≈ 2.4-3.6x 加速,并因排空
        // jitterBuffer 卡死 —— 即"自动播下一集加速/卡住"与偶发默认加速。
        // 主线程在两者之间稍有延迟(如自动播下一集的开场负载)就会把这个
        // 微秒级窗口放大到秒级,竞态几乎必现。
        if let out = audioUnitOutput, let dec = audioDecoder {
            out.start(sampleRate: dec.outputSampleRate, channels: dec.outputChannels)
            // Pause immediately — jitterBuffer.onStateChange will resume when
            // enough video is buffered (resumeDuration = 2.0s). Without this,
            // audio runs freely during the initial BUFFERING phase and drifts
            // 500ms–1s ahead of video before the first frame appears.
            out.pause()
        }

        startDemuxLoop()
        startDisplayLink()

        // Calibrate audioClock to first decoded frame PTS on the first display
        // tick — same as post-seek calibration. Required for H.264 B-frame streams
        // whose PTS does not start at 0 (priming delay).
        needsClockCalibration = true
        audioClockReady = false

        state.isPlaying = true
        notifyStateChange()
        let t1 = Date()
        logger.info("_finishOpen done in \(String(format: "%.0f", t1.timeIntervalSince(t0) * 1000))ms")

        if let seekTo { seek(to: seekTo) }
    }

    private func wireJitterBuffer() {
        jitterBuffer.onStateChange = { [weak self] newState in
            guard let self else { return }
            switch newState {
            case .buffering:
                self.audioUnitOutput?.pause()
                self._injectedAudioOutput?.pause()
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.state.isBuffering = true
                    // Drop the tick-gap baseline so the refill-triggered resume
                    // isn't misreported as a main-thread stall by the gap
                    // diagnostic in displayNextFrame().
                    self.lastTickWallTime = nil
                    self.notifyStateChange()
                }
            case .playing:
                self.audioUnitOutput?.resume()
                self._injectedAudioOutput?.resume()
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.state.isBuffering = false
                    self.notifyStateChange()
                }
            }
        }
    }

    // MARK: - Demux loop

    private func startDemuxLoop() {
        demuxCancelled = false
        guard let demuxer = self.demuxer else {
            logger.error("startDemuxLoop: demuxer is nil (stop was called?)")
            return
        }
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
            // Diagnostic-only: confirms whether jitterBuffer append order is
            // truly monotonic (or regresses/repeats) — see the "mouth keeps
            // repeating" report.
            var diagAppendCount = 0
            var diagLastAppendedPts = -Double.infinity
            var lastThrottleAudioPos: Double = 0

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

                dLock.lock()
                if self.demuxCancelled { dLock.unlock(); break }

                let currentSerial = sLock.withLock { self.seekSerial }

                // Reset state on seek so stale packets don't affect post-seek packets.
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
                        self.videoDecoder?.flush()
                        // Routed through audioDecodeQueue so this can't race a
                        // still-in-flight decode() of an earlier packet on that
                        // queue (see audioDecodeQueue's doc comment).
                        self.audioDecodeQueue.sync { audioDec?.flush() }
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
                    // 告知 jitterBuffer 视频流已结束:若剩余帧不足 resumeDuration
                    // (seek 到接近末尾),立即开播渲染,而不是永远停在 buffering
                    // 黑屏(displayNextFrame 的 guard jitterBuffer.state == .playing
                    // 直接 return,零帧显示)。
                    jitter.markEOF()
                    break
                }

                packetCount += 1
                let pktSize = Int(result.packet.pointee.size)
                if pktSize > 0 { totalBytesRead += Int64(pktSize) }
                let streamIndex = result.streamIndex
                let packet = result.packet
                // Set true by the audio branch when it hands packet ownership
                // to audioDecodeQueue — the tail av_packet_free below must not
                // also free it in that case (audioDecodeQueue frees it once
                // decode actually runs).
                var handedOffPacket = false

                if streamIndex == demuxer.videoStreamIndex {
                    let rawPTS = Self.ptsFromPacket(packet, demuxer: demuxer)
                    // MultiClipDemuxer rebases every packet's PTS onto the
                    // continuous global timeline before handing it out, so the
                    // packet right after a clip boundary carries a known-good
                    // jump — not the kind of >5s anomaly validate() exists to
                    // detect. Write it in as the new trusted baseline directly
                    // instead of sending it through blind-clock detection.
                    let pts: Double
                    if result.didSwitchClip, rawPTS.isFinite {
                        ptsValidator.forceRebase(to: rawPTS)
                        pts = rawPTS
                    } else {
                        pts = ptsValidator.validate(rawPTS)
                    }
                    // Track download progress (highest video PTS read so far)
                    if rawPTS.isFinite && rawPTS > maxDownloadedPts { maxDownloadedPts = rawPTS }
                    if packetCount < 5 || (packetCount % 500 == 0) {
                        logger.debug("pkt#\(packetCount) rawPTS=\(String(format:"%.3f",rawPTS)) pts=\(String(format:"%.3f",pts)) audio=\(String(format:"%.3f",clock.audioTime))")
                    }

                    // VT→SW fallback: when VideoToolbox repeatedly fails to decode
                    // (e.g. 4K@120fps exceeds HW limits), hot-swap to FFmpeg software
                    // decoder without restarting the demux loop.
                    if let vt = self.videoDecoder as? VTVideoDecoder, vt.needsSoftwareFallback,
                       let vs = demuxer.videoStream,
                       let sw = FFmpegVideoDecoder(stream: vs, forceSoftware: true, colorParams: colorParams) {
                        logger.notice("VT→SW fallback: \(sw.width)x\(sw.height) — HW decoder failed, using FFmpeg SW")
                        self.videoDecoder = sw
                    }

                    // Always decode — VTVideoDecoder needs every packet for its RPS.
                    let decoded = self.videoDecoder?.decode(packet: packet)
                    dLock.unlock()

                    if let frame = decoded,
                       sLock.withLock({ self.seekSerial }) == currentSerial {
                        // With B-frames, the pixel buffer returned by THIS
                        // decode() call can correspond to an earlier-submitted
                        // packet (decoder-internal reorder) — pairing it with
                        // this packet's own `pts` mislabels it by a few frame
                        // durations. When the decoder reports its own
                        // display-order pts (currently: FFmpegVideoDecoder SW
                        // fallback path; VTVideoDecoder returns nil here and
                        // this is a no-op), correct `pts` by the measured
                        // delta rather than recomputing it from scratch, so
                        // clip-rebase/anomaly-detection state from the
                        // rawPTS→pts pipeline above still applies.
                        // Sanity-bound the correction: a genuine reorder delay is at
                        // most a handful of frame durations (well under 1s for any
                        // real GOP structure) and the returned frame is always from
                        // the SAME position or earlier than the packet just sent
                        // (never later). Outside that — e.g. the decoder's first
                        // few outputs right after a mid-stream codec swap, before
                        // its internal reorder state has a clean run to interpolate
                        // from — trust the packet-based pts unmodified rather than
                        // risk a wild correction that strands the sync gate (a
                        // frame miscomputed as far in the future never becomes
                        // "not ahead of audio" and permanently stalls playback).
                        let framePts: Double
                        let diagBounded: Bool
                        if let decoderPts = frame.pts, decoderPts.isFinite,
                           decoderPts <= rawPTS, rawPTS - decoderPts < 1.0 {
                            framePts = pts - (rawPTS - decoderPts)
                            diagBounded = true
                        } else {
                            framePts = pts
                            diagBounded = false
                        }
                        diagAppendCount += 1
                        if diagAppendCount <= 200 {
                            let regressed = framePts < diagLastAppendedPts
                            logger.info("[diag] append#\(diagAppendCount) framePts=\(String(format:"%.3f",framePts)) decoderPts=\(frame.pts.map { String(format:"%.3f",$0) } ?? "nil") bounded=\(diagBounded) rawPTS=\(String(format:"%.3f",rawPTS)) REGRESSED=\(regressed)")
                        }
                        diagLastAppendedPts = framePts
                        jitter.append(.init(pixelBuffer: frame.pixelBuffer, pts: framePts, metadata: frame.metadata))
                        let ptsCopy = framePts
                        DispatchQueue.main.async { [weak self] in
                            guard let self else { return }
                            let d = Duration.milliseconds(Int64(ptsCopy * 1000))
                            if d > self.state.duration { self.state.duration = d }
                        }
                    }
                    // Throttle: keep video demux within 2s of the audio clock.
                    // HW decode runs ~4× real-time; without throttling the demux
                    // would advance 30+ seconds ahead of audio. maxFrameCount then
                    // evicts old frames, leaving the jitter buffer with only
                    // far-future frames — needsClockCalibration resets audioClock
                    // to that far-future PTS, causing A/V desync / black screen.
                    //
                    // We sleep AT MOST 50ms per video packet so the outer loop
                    // continues reading audio/subtitle packets in between, keeping
                    // the AudioUnit queue fed and subtitle cues pre-read.
                    //
                    // CRITICAL: skip the throttle when audioClock has not advanced
                    // since the last iteration (AudioQueue underrun). If we sleep
                    // while audio is stalled, the demux loop never reads audio
                    // packets (they're next in the TS interleave), the AudioQueue
                    // stays empty, and audioClock never recovers — a deadlock.
                    // Observed on 4K HEVC UHD remuxes where VT decode is slow
                    // enough that the 50ms throttle × 24fps = 1.2s/s of sleep
                    // starves the audio path entirely.
                    let audioPos = clock.audioTime
                    if pts.isFinite && pts > audioPos + 2.0,
                       audioPos > lastThrottleAudioPos {
                        Thread.sleep(forTimeInterval: min(pts - audioPos - 2.0, 0.050))
                    }
                    lastThrottleAudioPos = audioPos

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
                        // PCM path: decode with FFmpeg and enqueue to AudioUnit,
                        // off the demux/video thread (see audioDecodeQueue's doc
                        // comment). Capture decoder/output now — selectAudioTrack
                        // may replace self.audioDecoder/audioUnitOutput before
                        // this actually runs on the queue; currentDec/currentOut
                        // stay bound to whatever was current when this packet was
                        // read, matching the previous synchronous behavior.
                        let currentDec = self.audioDecoder
                        let currentOut = self.audioUnitOutput
                        dLock.unlock()
                        handedOffPacket = true
                        audioDecodeQueue.async {
                            let pcm = currentDec?.decode(packet: packet)
                            if let pcm { currentOut?.enqueue(pcm) }
                            var p: UnsafeMutablePointer<AVPacket>? = packet
                            av_packet_free(&p)
                        }
                    }
                } else if streamIndex == demuxer.subtitleStreamIndex,
                          demuxer.subtitleStreamIndex >= 0 {
                    let stream = demuxer.subtitleStream
                    let codecId = stream?.pointee.codecpar.pointee.codec_id
                    let codecName = codecId.map { String(cString: avcodec_get_name($0)) } ?? "nil"
                    if codecId == AV_CODEC_ID_ASS || codecId == AV_CODEC_ID_SSA {
                        let cue = Self.parseASSCue(packet: packet, stream: stream)
                        dLock.unlock()
                        if let cue {
                            self.subtitleLock.withLock { self.subtitleCues.append(cue) }
                            logger.debug("[sub] ASS cue appended: pts=\(String(format:"%.2f",cue.startPts))-\(String(format:"%.2f",cue.endPts)) text=\(cue.text.prefix(30))")
                        } else {
                            logger.warning("[sub] ASS parseASSCue returned nil (streamIdx=\(streamIndex))")
                        }
                    } else if codecId == AV_CODEC_ID_SUBRIP || codecId == AV_CODEC_ID_TEXT {
                        // AV_CODEC_ID_TEXT carries raw UTF-8 with no HTML tags; routing here is safe
                        // since the HTML-strip regex is a no-op when no tags are present.
                        let cue = Self.parseSRTCue(packet: packet, stream: stream)
                        dLock.unlock()
                        if let cue {
                            self.subtitleLock.withLock { self.subtitleCues.append(cue) }
                            logger.debug("[sub] SRT cue appended: pts=\(String(format:"%.2f",cue.startPts))-\(String(format:"%.2f",cue.endPts))")
                        } else {
                            logger.warning("[sub] SRT parseSRTCue returned nil")
                        }
                    } else if codecId == AV_CODEC_ID_HDMV_PGS_SUBTITLE || codecId == AV_CODEC_ID_DVD_SUBTITLE {
                        let dec = self.subtitleDecoder
                        let audioPos = clock.audioTime
                        dLock.unlock()
                        if let cue = dec?.decode(packet: packet) {
                            // If the cue's startPts is already in the past (demux
                            // read the subtitle packet late due to video throttle),
                            // adjust startPts to current audioTime so the subtitle
                            // displays immediately instead of being skipped.
                            let adjustedStart = cue.startPts < audioPos ? audioPos : cue.startPts
                            self.subtitleImageLock.withLock {
                                // Truncate existing cues' endPts to the new cue's
                                // startPts so the old subtitle stops displaying
                                // when the new one starts. Without this, the old
                                // cue (with a long endPts from PGS UINT32_MAX
                                // fallback) would shadow the new cue —
                                // first(where:) matches the old one first since
                                // its endPts hasn't been reached yet.
                                let cutoff = adjustedStart
                                for i in self.subtitleImageCues.indices {
                                    if self.subtitleImageCues[i].endPts > cutoff {
                                        self.subtitleImageCues[i] = SubtitleImageCue(
                                            startPts: self.subtitleImageCues[i].startPts,
                                            endPts: cutoff,
                                            image: self.subtitleImageCues[i].image,
                                            rect: self.subtitleImageCues[i].rect)
                                    }
                                }
                                self.subtitleImageCues.append(
                                    SubtitleImageCue(startPts: adjustedStart, endPts: cue.endPts,
                                                     image: cue.image, rect: cue.rect)
                                )
                            }
                            logger.debug("[sub] PGS cue appended: pts=\(String(format:"%.2f",adjustedStart))-\(String(format:"%.2f",cue.endPts))")
                        } else if dec == nil {
                            logger.warning("[sub] PGS packet received but subtitleDecoder is nil")
                        }
                    } else if codecId == AV_CODEC_ID_WEBVTT {
                        let cue = Self.parseWebVTTCue(packet: packet, stream: stream)
                        dLock.unlock()
                        if let cue {
                            self.subtitleLock.withLock { self.subtitleCues.append(cue) }
                            logger.debug("[sub] WebVTT cue appended: pts=\(String(format:"%.2f",cue.startPts))-\(String(format:"%.2f",cue.endPts))")
                        } else {
                            logger.warning("[sub] WebVTT parseWebVTTCue returned nil")
                        }
                    } else if codecId == AV_CODEC_ID_MOV_TEXT {
                        let cue = Self.parseMOVTextCue(packet: packet, stream: stream)
                        dLock.unlock()
                        if let cue {
                            self.subtitleLock.withLock { self.subtitleCues.append(cue) }
                            logger.debug("[sub] MOVText cue appended: pts=\(String(format:"%.2f",cue.startPts))-\(String(format:"%.2f",cue.endPts))")
                        } else {
                            logger.warning("[sub] MOVText parseMOVTextCue returned nil")
                        }
                    } else {
                        logger.warning("[sub] unsupported subtitle codec=\(codecName) streamIdx=\(streamIndex)")
                        dLock.unlock()
                    }
                } else {
                    dLock.unlock()
                }

                if !handedOffPacket {
                    var p: UnsafeMutablePointer<AVPacket>? = packet
                    av_packet_free(&p)
                }
            }
        }
    }

    private nonisolated static func ptsFromPacket(_ packet: UnsafeMutablePointer<AVPacket>,
                                                   demuxer: any PacketDemuxing) -> Double {
        guard let vs = demuxer.videoStream else { return .nan }
        let tb = vs.pointee.time_base
        let nopts = Int64(bitPattern: 0x8000000000000000)
        guard tb.den > 0, packet.pointee.pts != nopts else { return .nan }
        let pts = Double(packet.pointee.pts) * Double(tb.num) / Double(tb.den)
        // Subtract the stream's start_time so video PTS is relative to t=0.
        // HEVC/MP4 often has a non-zero video start_time (e.g. 4096 ticks at 90000 Hz ≈ 46ms)
        // while the audio stream starts at 0, causing persistent audio-ahead if uncorrected.
        if vs.pointee.start_time != nopts {
            let startOffset = Double(vs.pointee.start_time) * Double(tb.num) / Double(tb.den)
            return pts - startOffset
        }
        return pts
    }

    /// Parse an ASS/SSA subtitle packet from MKV into a SubtitleCue.
    ///
    /// MKV stores each ASS dialogue line as a raw packet with this field layout:
    ///   ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text
    /// The Text field (index 8) may contain ASS override tags ({...}) and hardcoded
    /// line-break sequences (\N / \n). We strip tags and convert breaks to newlines.
    /// Timing comes from packet.pts/duration scaled by the subtitle stream timebase.
    private nonisolated static func parseASSCue(
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

    /// Parse a SubRip (SRT) subtitle packet from an MKV container.
    /// MKV stores SRT as raw text in packet data with timing from PTS/duration.
    /// Strips HTML-like tags (<i>, <b>, <font ...>) commonly found in SRT files.
    private nonisolated static func parseSRTCue(
        packet: UnsafeMutablePointer<AVPacket>,
        stream: UnsafeMutablePointer<AVStream>?
    ) -> SubtitleCue? {
        guard let stream,
              packet.pointee.size > 0,
              let rawPtr = packet.pointee.data else { return nil }

        let codecId = stream.pointee.codecpar.pointee.codec_id
        guard codecId == AV_CODEC_ID_SUBRIP || codecId == AV_CODEC_ID_TEXT else { return nil }

        guard var text = String(bytes: UnsafeBufferPointer(start: rawPtr,
                                                            count: Int(packet.pointee.size)),
                                encoding: .utf8) else { return nil }
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
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

    /// Parse a WebVTT subtitle packet (AV_CODEC_ID_WEBVTT) from an MKV container.
    /// The cue body may contain WebVTT inline tags (<b>, <i>, <c.class>, etc.); we strip them.
    private nonisolated static func parseWebVTTCue(
        packet: UnsafeMutablePointer<AVPacket>,
        stream: UnsafeMutablePointer<AVStream>?
    ) -> SubtitleCue? {
        guard let stream,
              packet.pointee.size > 0,
              let rawPtr = packet.pointee.data else { return nil }

        guard var text = String(bytes: UnsafeBufferPointer(start: rawPtr,
                                                            count: Int(packet.pointee.size)),
                                encoding: .utf8) else { return nil }
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
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

    /// Parse a QuickTime/MP4 timed-text packet (AV_CODEC_ID_MOV_TEXT).
    /// Packet layout: 2-byte big-endian text length, then UTF-8 text, then optional style boxes.
    private nonisolated static func parseMOVTextCue(
        packet: UnsafeMutablePointer<AVPacket>,
        stream: UnsafeMutablePointer<AVStream>?
    ) -> SubtitleCue? {
        guard let stream,
              packet.pointee.size > 2,
              let rawPtr = packet.pointee.data else { return nil }

        let textLen = Int(rawPtr[0]) << 8 | Int(rawPtr[1])
        guard textLen > 0, textLen <= packet.pointee.size - 2 else { return nil }

        guard var text = String(bytes: UnsafeBufferPointer(start: rawPtr + 2,
                                                            count: textLen),
                                encoding: .utf8) else { return nil }
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
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

        // Diagnostic: CADisplayLink runs on the main run loop. If the main thread
        // is busy with other work (background scan/enrich, SwiftUI updates, disk/DB
        // I/O, ...) ticks get delayed or dropped, producing visible video judder
        // while audio (separate real-time AudioUnit thread) stays smooth. Logging
        // outsized tick-to-tick gaps — only while jitterBuffer actually has frames
        // ready to show — isolates "main thread was blocked" from "video is
        // legitimately buffering" as the stutter cause.
        if let last = lastTickWallTime {
            let gap = now - last
            if gap > tickGapWarnThreshold && jitterBuffer.state == .playing {
                logger.warning("display tick gap \(Int(gap * 1000))ms (main thread stall?)")
            }
        } else if !firstTickLogged, let linkStart = displayLinkStartWallTime {
            // First-ever tick: no prior baseline to diff against, so the check
            // above is structurally blind to this one. Log it explicitly —
            // this is the only way to tell whether a "gap" reported once
            // jitterBuffer flips to .playing was actually one late tick, or
            // whether CADisplayLink genuinely never fired until now.
            firstTickLogged = true
            logger.info("first display tick \(Int((now - linkStart) * 1000))ms after startDisplayLink()")
        }
        lastTickWallTime = now

        guard jitterBuffer.state == .playing else { return }

        // Calibrate audioClock to the actual first decoded frame PTS after seek.
        // seek() resets audioClock to the target position, but FFmpeg seeks to the
        // nearest prior I-frame, so the first decodable frame's PTS < seek target.
        // Without this, PacketDropPolicy sees "video behind audio" and drops all
        // non-keyframes up to the next I-frame, causing a 6+ second overshoot.
        //
        // IMPORTANT: calibrate at most once.  Repeatedly calling calibrate() on
        // every tick causes a primer-debt death loop when seeking to ~0: each
        // calibrate re-subtracts _primerPendingSamples from the target, wiping out
        // the progress made by primer callbacks that fired between ticks.  The
        // audioClock never advances past 0, and displayNextFrame's skip-behind
        // guard drops all frames → playback stalls permanently.
        // AudioQueueStop/Start can fire async callbacks that advance the clock
        // *after* our reset; by calibrating exactly once (not clearing the flag
        // until first render), we tolerate that race without the death loop.
        if needsClockCalibration, let firstFrame = jitterBuffer.peek(at: 0) {
            // Only apply the small-rounding correction this was designed for.
            // A byte-domain seek (FFmpegDemuxer.seekByByteOffset, used for raw
            // indexless MPEG-TS) has no keyframe awareness and can land tens
            // of seconds from the target on VBR content. Blindly relabeling
            // audioClock to match a wildly-displaced video PTS doesn't fix
            // that — it hides it: the audio hardware keeps playing real
            // content from near the seek target while the clock claims to be
            // wherever video landed, and the gap never closes (observed: a
            // persistent, non-recovering audio-behind-video desync). For a
            // large gap, skip calibration and let the freeze-ahead guard hold
            // video until the real audioClock catches up instead — a one-time
            // stall, but it converges on what's actually audible.
            if abs(firstFrame.pts - audioClock.audioTime) < maxCalibrationGap {
                audioClock.calibrate(to: firstFrame.pts, sampleRate: audioDecoder?.outputSampleRate ?? 44100)
            }
            needsClockCalibration = false
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
        if syncController.hasDisplayedFrame, !needsClockCalibration, audioClockReady {
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

        // Detect when audioClock has started advancing (primer callbacks fired).
        // Until then, bypass syncController timing and display frames as fast as
        // they're decoded so video doesn't stall waiting for audio to catch up.
        if !audioClockReady, audioTime > 0.001 {
            audioClockReady = true
        }

        guard let frame = jitterBuffer.peek(at: 0) else { return }

        let followingPTS = jitterBuffer.peek(at: 1)?.pts

        // Before audioClock starts advancing (primer pending), display frames
        // at nominal rate without waiting for audio sync.  Without this the
        // syncController sees video far ahead of audio(audio=0) and holds
        // frames indefinitely → "首帧后不播放" bug.
        let (shouldShow, delay): (Bool, Double)
        if audioClockReady {
            (shouldShow, delay) = syncController.check(
                nextPTS: frame.pts,
                followingPTS: followingPTS,
                audioTime: audioTime,
                now: now,
                serial: serial
            )
        } else {
            // 旁路不再每 tick 弹帧:音频时钟卡死时 audioClockReady 永远为
            // false,原来每个显示驱动 tick 都直接弹帧 —— macOS 双驱动
            // (CVDisplayLink 60Hz + 兜底 timer 30Hz)最高 ~90Hz ≈ 2.4-3.6x
            // 加速("自动播下一集加速"的直接放大器),且弹帧快于 demux
            // 补充率会排空 jitterBuffer → .buffering → 卡死。改为按源
            // PTS 间隔 pacing:首帧立即显示,后续帧等足源帧间隔,永远不
            // 高于 1x;主线程长卡顿积压的 tick 也只会弹出一帧,不爆发。
            let srcGap = followingPTS.map { max(0.01, min(0.5, $0 - frame.pts)) }
                ?? (1.0 / 25.0)
            if now - lastBypassPopTime >= srcGap {
                lastBypassPopTime = now
                (shouldShow, delay) = (true, 0)
            } else {
                (shouldShow, delay) = (false, 0)
            }
        }

        guard shouldShow else {
            // 旁路 pacing 等待时视频帧已在正确位置,用帧 PTS 而非 audioTime
            // (音频卡死时恒为 0,会把进度条打回 0)。
            let pos = Duration.milliseconds(Int64((audioClockReady ? audioTime : frame.pts) * 1000))
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

        // needsClockCalibration is already cleared in the calibrate block above.
        // First frame has been rendered; subsequent ticks let audioClock advance
        // naturally via AudioQueue callbacks.

        let posDur = Duration.milliseconds(Int64(popped.pts * 1000))
        state.position = posDur
        if posDur > state.duration { state.duration = posDur }
        if displayedVideoFrames == 1 {
            // 诊断:首帧写入 state 时的实际值与 backend 身份,
            // 用于核对 app 层 timer 读到的 state 是否同一个对象。
            logger.info("[diag] first frame written pos=\(String(format:"%.3f", Double(posDur.components.seconds)))s dur=\(String(format:"%.3f", Double(self.state.duration.components.seconds)))s self=\(String(format:"%p", UInt(bitPattern: Unmanaged.passUnretained(self).toOpaque())))")
        }

        // Update bufferedDuration.
        // Prefer reader-level download offset (reflects actual pre-fetched bytes, not just
        // the demux-loop's throttled read position which is capped at ~2s).
        let currentSecs = Double(posDur.components.seconds)
        let dlOffset = demuxer?.downloadedUpToOffset ?? -1
        let fileBytes = demuxer?.totalFileBytes ?? -1
        if dlOffset > 0, fileBytes > 0, state.duration > .zero {
            let dlFraction = min(1.0, Double(dlOffset) / Double(fileBytes))
            let dlSecs = dlFraction * Double(state.duration.components.seconds)
            let bufferedSecs = max(0, dlSecs - currentSecs)
            state.bufferedDuration = .milliseconds(Int64(bufferedSecs * 1000))
        } else {
            // Fallback for URL-based streams without a custom reader.
            let downloaded = maxDownloadedPts
            if downloaded > currentSecs {
                state.bufferedDuration = .milliseconds(Int64((downloaded - currentSecs) * 1000))
            } else {
                state.bufferedDuration = .zero
            }
        }

        // Update active subtitle text. Only notify when the text actually changes
        // to avoid redundant view invalidations on every frame.
        // Use the displayed frame's PTS (not audioTime) for subtitle matching —
        // this keeps subtitles in sync with the video, not the audio clock.
        // Audio clock can lag behind video (seek, primer, underrun) causing
        // subtitles to appear late when matched against audioTime.
        let displayPts = popped.pts
        let activeSub: String? = subtitleLock.withLock {
            subtitleCues.first { $0.startPts <= displayPts && displayPts < $0.endPts }?.text
        }
        if activeSub != lastSubtitleText {
            lastSubtitleText = activeSub
            state.currentSubtitleText = activeSub
            notifyStateChange()
        } else if (posDur - lastNotifiedPos) >= .milliseconds(500) {
            notifyStateChange()
        }
        if (posDur - lastNotifiedPos) >= .milliseconds(500) { lastNotifiedPos = posDur }

        let (newImage, newRect): (CGImage?, CGRect) = subtitleImageLock.withLock {
            // Prune expired cues so first(where:) doesn't scan a growing list.
            // Keep only cues whose endPts hasn't passed yet.
            if subtitleImageCues.count > 4 {
                subtitleImageCues.removeAll { $0.endPts < displayPts - 1.0 }
            }
            if let c = subtitleImageCues.first(where: { $0.startPts <= displayPts && displayPts < $0.endPts }) {
                return (c.image, c.rect)
            }
            return (nil, .zero)
        }
        if newImage !== lastSubtitleImage {
            lastSubtitleImage = newImage
            state.currentSubtitleImage = newImage
            state.currentSubtitleImageRect = newRect
            notifyStateChange()
        }

        logSync(now: now, pts: popped.pts, audioTime: audioTime)
    }

    private func logSync(now: Double, pts: Double, audioTime: Double) {
        let elapsed = now - lastLogTime
        guard elapsed > 5.0 else { return }
        let fps = Double(framesSinceLastLog) / elapsed
        let diff = Int((pts - audioTime) * 1000)
        let subCueCount = subtitleLock.withLock { subtitleCues.count }
        let subImgCount = subtitleImageLock.withLock { subtitleImageCues.count }
        let subStreamIdx = demuxer?.subtitleStreamIndex ?? -1
        logger.info("q=\(self.jitterBuffer.count) dur=\(Int(self.jitterBuffer.duration*1000))ms fps=\(String(format:"%.1f",fps)) diff=\(diff)ms a=\(String(format:"%.2f",audioTime))s v=\(String(format:"%.2f",pts))s buf=\(self.state.isBuffering) subStream=\(subStreamIdx) subCues=\(subCueCount) subImgCues=\(subImgCount)")

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
        fallbackRenderTimer?.cancel()
        fallbackRenderTimer = nil
        #else
        displayLinkProxy = nil
        #endif
        audioUnitOutput?.pause()
        // Stop the demux loop so jitterBuffer doesn't fill up while audio is
        // paused. Without this, the demux loop keeps reading packets and
        // appending frames (video throttle skips sleep when audioClock is
        // stalled), accumulating tens of seconds of video ahead of the paused
        // audio position. On resume, freeze-ahead guard holds all frames
        // → stutter/卡顿.
        demuxLock.lock()
        demuxCancelled = true
        demuxLock.unlock()
        state.isPlaying = false; notifyStateChange()
    }

    public func resume() {
        guard demuxer != nil else {
            logger.warning("resume: demuxer is nil, player was stopped — ignoring")
            // Don't leave demuxCancelled=true if there's no demuxer —
            // otherwise the next play() won't start the demux loop.
            demuxLock.lock()
            demuxCancelled = false
            demuxLock.unlock()
            return
        }
        logger.info("resume")
        // Re-activate the AudioSession.  After a background/PiP transition iOS may
        // deactivate the session, which silently prevents AudioQueue callbacks
        // from firing — the audio clock freezes and A/V sync stalls.
        #if canImport(UIKit)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        // Always resume audio output regardless of jitter buffer state.
        // If the player was paused while the jitter buffer was in .buffering state,
        // the conditional guard (state == .playing) would leave audio silently stopped.
        // audioClock would stay frozen → demux backpressure (pts > audioPos+2.0) would
        // never release → no new frames appended → no .buffering→.playing transition
        // possible → permanent deadlock.  Resuming audio unconditionally lets audioClock
        // advance, which unblocks the demux loop.  onStateChange(.buffering) will pause
        // audio again if the buffer drains below minDuration, and onStateChange(.playing)
        // will resume it; those two form the normal steady-state feedback loop.
        audioUnitOutput?.resume()
        // Invalidate any existing display link before creating a new one.
        // Without this, calling resume() on an already-playing player (e.g. when
        // pip.start() was attempted but PiP never fully activated) would leave
        // the old link running and add a second one — both pop frames, draining
        // the jitter buffer at 2× speed → stuck.
        displayLink?.invalidate()
        displayLink = nil
        #if os(iOS)
        displayLinkProxy = nil
        #endif
        // Restart the demux loop (pause() set demuxCancelled=true).
        // Flush stale frames that accumulated during pause to prevent
        // freeze-ahead stutter on resume.
        jitterBuffer.flush()
        syncController.reset()
        lastBypassPopTime = 0
        startDemuxLoop()
        startDisplayLink()
        // Calibrate audioClock to the first post-resume frame (like post-seek).
        needsClockCalibration = true
        audioClockReady = false
        state.isPlaying = true; notifyStateChange()
    }

    public func seek(to: Duration) {
        let secs = to.secondsDouble
        logger.info("seek to \(String(format:"%.1f",secs))s")
        demuxLock.lock()
        seekLock.withLock { seekSerial += 1 }
        _ = demuxer?.seek(to: secs)
        videoDecoder?.flush()
        // Routed through audioDecodeQueue so this can't race a still-in-flight
        // decode() of a pre-seek packet on that queue.
        audioDecodeQueue.sync { audioDecoder?.flush() }
        demuxLock.unlock()

        subtitleLock.withLock { subtitleCues.removeAll() }
        lastSubtitleText = nil
        state.currentSubtitleText = nil
        subtitleImageLock.withLock { subtitleImageCues.removeAll() }
        lastSubtitleImage = nil
        state.currentSubtitleImage = nil
        state.currentSubtitleImageRect = .zero

        jitterBuffer.flush()
        syncController.reset()
        lastBypassPopTime = 0
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
        // Reset download tracking for the new seek position
        maxDownloadedPts = secs
        // Signal displayNextFrame to calibrate audioClock to actual I-frame PTS.
        // FFmpeg seek lands on the GOP boundary before secs, so audioClock(=secs)
        // would be ahead of the first decoded frame; without re-calibration the
        // display loop's skip-behind guard would drop the first few frames.
        needsClockCalibration = true
        audioClockReady = false
        // 立即把 position 置为 seek 目标并通知:seek 到首帧渲染之间
        // displayNextFrame 不更新 position(渲染恢复后才写实际落点),
        // 不置位的话进度条/快进基准会停留在 seek 前的位置(旧值漂移,
        // "15s 快进实际跳 100s"的根因之一)。首帧渲染后覆盖为落点。
        state.position = .seconds(secs)
        notifyStateChange()
    }

    public func stop() {
        playGeneration += 1  // discard any in-flight async open
        logger.info("stop (displayed \(self.displayedVideoFrames) frames)")
        displayLink?.invalidate(); displayLink = nil; displayLinkProxy = nil
        #if os(macOS)
        if let cv = cvDisplayLink, CVDisplayLinkIsRunning(cv) { CVDisplayLinkStop(cv) }
        cvDisplayLink = nil
        fallbackRenderTimer?.cancel()
        fallbackRenderTimer = nil
        #endif
        demuxCancelled = true
        audioUnitOutput?.stop()
        demuxLock.lock()
        demuxer?.close(); demuxer = nil
        videoDecoder = nil; audioDecoder = nil
        demuxLock.unlock()
        jitterBuffer.flush()
        syncController.reset()
        lastBypassPopTime = 0
        audioClock.reset(to: 0, sampleRate: 44100)  // critical: must reset or stale seek position
                                                     // from previous session pollutes AudioClock
        _renderer.flush()
        _renderer.clear()  // hide the previous video's last frame until the new
                           // video renders its first frame (MetalRenderer.display
                           // flips opacity back to 1 on first frame)
        displayedVideoFrames = 0
        totalBytesRead = 0; lastBytesLogged = 0; lastThroughputTime = 0
        maxDownloadedPts = 0
        subtitleLock.withLock { subtitleCues.removeAll() }
        lastSubtitleText = nil
        state.currentSubtitleText = nil
        subtitleImageLock.withLock { subtitleImageCues.removeAll() }
        lastSubtitleImage = nil
        state.currentSubtitleImage = nil
        state.currentSubtitleImageRect = .zero
        subtitleDecoder = nil
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
        // Routed through audioDecodeQueue so this can't race a still-in-flight
        // decode() of an old-track packet on that queue.
        audioDecodeQueue.sync { audioDecoder?.flush() }
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
        lastBypassPopTime = 0
        _renderer.flush()

        // 5. Recreate audio output with new decoder's parameters
        let sr = audioDecoder?.outputSampleRate ?? 44100
        let ch = audioDecoder?.outputChannels ?? 2
        audioClock.reset(to: posSecs, sampleRate: sr)
        audioUnitOutput = AudioUnitOutput(clock: audioClock)
        audioUnitOutput?.start(sampleRate: sr, channels: ch)
        audioUnitOutput?.pause()
        needsClockCalibration = true
        // Reset audioClockReady — TrueHD has significant decoder delay (first
        // several packets produce no PCM output), so audioClock stays frozen at
        // posSecs while video PTS advances.  Without this reset, the display
        // loop's freeze-ahead/skip-behind guard uses the stale audioClock and
        // produces a persistent A/V desync that never converges.  Mirrors the
        // seek()/play() paths which both set audioClockReady = false.
        audioClockReady = false
        // Reset download tracking for the new seek position (same as seek()).
        maxDownloadedPts = posSecs

        // 6. Update state
        state.selectedAudioTrackId = trackId
        refreshAudioTracks()
        notifyStateChange()

        logger.info("selectAudioTrack done, new decoder sampleRate=\(self.audioDecoder?.outputSampleRate ?? 0)")
    }

    public func selectSubtitle(id: String?) {
        guard let demuxer else { return }
        let trackId = id.flatMap(Int.init)

        // Log codec name of selected track for diagnostics
        if let resolvedId = trackId, let fmtCtx = demuxer.formatContext {
            let nb = Int(fmtCtx.pointee.nb_streams)
            for i in 0..<nb {
                guard let s = fmtCtx.pointee.streams[i],
                      Int(s.pointee.index) == resolvedId else { continue }
                let cp = s.pointee.codecpar.pointee
                let codecName = cp.codec_id != AV_CODEC_ID_NONE
                    ? String(cString: avcodec_get_name(cp.codec_id)) : "none"
                logger.notice("[sub] selectSubtitle trackId=\(resolvedId) codec=\(codecName) tb=\(s.pointee.time_base.num)/\(s.pointee.time_base.den)")
                break
            }
        } else {
            logger.notice("[sub] selectSubtitle → disabled")
        }

        // Switch subtitle stream under demuxLock so the demux loop sees the new
        // subtitleStreamIndex atomically with the next readPacket call.
        demuxLock.lock()
        demuxer.selectSubtitleStream(by: trackId)
        let resolvedIdx = demuxer.subtitleStreamIndex
        demuxLock.unlock()
        logger.notice("[sub] subtitleStreamIndex after select=\(resolvedIdx)")

        // Discard cues from the previous track.
        let hadText = state.currentSubtitleText != nil
        let hadImage = state.currentSubtitleImage != nil
        subtitleLock.withLock { subtitleCues.removeAll() }
        subtitleImageLock.withLock { subtitleImageCues.removeAll() }
        lastSubtitleImage = nil
        state.currentSubtitleImage = nil
        state.currentSubtitleImageRect = .zero

        lastSubtitleText = nil
        state.currentSubtitleText = nil
        state.selectedSubtitleTrackId = trackId
        if hadText || hadImage {
            notifyStateChange()
        }

        subtitleDecoder = nil
        if let resolvedTrackId = trackId {
            let nb = Int(demuxer.formatContext?.pointee.nb_streams ?? 0)
            for i in 0..<nb {
                guard let s = demuxer.formatContext?.pointee.streams[i],
                      Int(s.pointee.index) == resolvedTrackId else { continue }
                let codecId = s.pointee.codecpar.pointee.codec_id
                if codecId == AV_CODEC_ID_HDMV_PGS_SUBTITLE || codecId == AV_CODEC_ID_DVD_SUBTITLE {
                    subtitleDecoder = FFmpegSubtitleDecoder(
                        stream: s,
                        videoSize: CGSize(width: codedVideoWidth, height: codedVideoHeight)
                    )
                    logger.notice("[sub] PGS/DVD decoder created: \(self.subtitleDecoder != nil ? "OK" : "FAILED")")
                }
                break
            }
            // No seek here: seeking would flush the video pipeline and cause 2-5s
            // re-buffering on network streams, which users misread as "subtitle failed
            // to load." The demux loop is already 2s ahead of playback; future subtitle
            // packets for the newly selected stream are processed naturally. The
            // currently-active cue (whose packet was already read) may not appear until
            // the next subtitle event — an acceptable trade-off vs. visible re-buffering.
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
        displayLinkStartWallTime = CACurrentMediaTime()
        firstTickLogged = false
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
        // 兜底驱动(见 fallbackRenderTimer 属性注释)。主 queue 保证与
        // MainActor 隔离一致;displayNextFrame 幂等,双驱动无副作用。
        fallbackRenderTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.05, repeating: 0.033)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated { self.displayNextFrame() }
        }
        timer.resume()
        fallbackRenderTimer = timer
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
