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
    public private(set) var colorParams = VideoColorParams()
    public var onStateChange: ((PlayerState) -> Void)?

    private let _renderer: MetalRenderer
    public var renderer: any VideoRenderer { _renderer }

    private var _frameSinks: [WeakFrameSink] = []
    private struct WeakFrameSink {
        weak var sink: (any FrameSink)?
    }

    private var demuxer: FFmpegDemuxer?
    private var videoDecoder: (any VideoDecoding)?
    private var audioDecoder: FFmpegAudioDecoder?

    // A/V sync modules
    private let audioClock = AudioClock()
    private var audioOutput: AudioOutput?
    private let jitterBuffer = VideoJitterBuffer()
    private let syncController = SyncController()
    // Set after seek(); cleared by displayNextFrame on first post-seek frame.
    // Calibrates audioClock to actual I-frame PTS rather than seek target,
    // preventing "video behind audio" false positive that triggers PacketDropPolicy overshoot.
    private var seekPendingClock: Bool = false

    // Pipeline control
    private let demuxLock = NSLock()
    private let seekLock = NSLock()
    private var seekSerial: Int64 = 0
    // demuxCancelled is read from DispatchQueue.global() without a lock.
    // Bool reads/writes are atomic on ARM64 in practice; a proper fix would use
    // an OSAtomicBool wrapper, but this matches the pre-refactor pattern.
    private var demuxCancelled = false
    private var displayLink: CADisplayLink?
    private var displayLinkProxy: DisplayLinkProxy?

    // Cancellation: incremented on every play()/stop() to discard stale async opens
    private var playGeneration: Int = 0

    // Logging
    private var displayedVideoFrames = 0
    private var framesSinceLastLog = 0
    private var ticksSinceLastLog = 0
    private var lastLogTime: Double = 0
    private var lastNotifiedPos: Duration = .zero

    public init() throws {
        self._renderer = try MetalRenderer()
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

        logger.info("play \(url.absoluteString.prefix(120))")

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
                try demuxer.open(url: url, headers: headers)
            } catch {
                logger.error("demuxer.open FAILED: \(error)")
                let msg = error.localizedDescription
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

        if let vs = demuxer.videoStream {
            if let dec = FFmpegVideoDecoder(stream: vs) {
                videoDecoder = dec; videoWidth = dec.width; videoHeight = dec.height
                logger.info("video: hw=\(dec.isHardware) \(dec.width)x\(dec.height)")
            } else if let dec = VTVideoDecoder(stream: vs) {
                videoDecoder = dec; videoWidth = dec.width; videoHeight = dec.height
                logger.info("video: VT \(dec.width)x\(dec.height)")
            }
        }

        if let as_ = demuxer.audioStream,
           let dec = FFmpegAudioDecoder(stream: as_, sampleRate: 44100, channels: 2) {
            audioDecoder = dec
            let out = AudioOutput(clock: audioClock)
            audioOutput = out
            logger.info("audio: \(dec.outputSampleRate)Hz \(dec.outputChannels)ch")
        }

        wireJitterBuffer()
        startDemuxLoop()
        startDisplayLink()

        if let out = audioOutput, let dec = audioDecoder {
            out.start(sampleRate: dec.outputSampleRate, channels: dec.outputChannels)
            // Pause immediately — jitterBuffer.onStateChange will resume when
            // enough video is buffered (resumeDuration = 2.0s). Without this,
            // audio runs freely during the initial BUFFERING phase and drifts
            // 500ms–1s ahead of video before the first frame appears.
            out.pause()
        }

        state.isPlaying = true
        notifyStateChange()

        if let seekTo { seek(to: seekTo) }
    }

    private func wireJitterBuffer() {
        jitterBuffer.onStateChange = { [weak self] newState in
            guard let self else { return }
            switch newState {
            case .buffering:
                self.audioOutput?.pause()
                self.state.isBuffering = true
            case .playing:
                self.audioOutput?.resume()
                self.state.isBuffering = false
            }
            self.notifyStateChange()
        }
    }

    // MARK: - Demux loop

    private func startDemuxLoop() {
        demuxCancelled = false
        let demuxer = self.demuxer!
        let videoDec = videoDecoder
        let audioDec = audioDecoder
        let audioOut = audioOutput
        let clock = audioClock
        let jitter = jitterBuffer
        let dLock = demuxLock
        let sLock = seekLock

        DispatchQueue.global().async { [weak self] in
            var dropPolicy = PacketDropPolicy()
            var ptsValidator = PTSValidator()
            var packetCount: Int32 = 0
            var eofRecoveryDone = false
            var lastSeenSerial: Int64 = -1
            // Disabled after each seek until jitterBuffer enters .playing, preventing
            // PacketDropPolicy from skipping to the next I-frame when the actual decoded
            // I-frame lands before the seek target (GOP boundary alignment).
            var droppingEnabled = true

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

                if jitter.duration >= jitter.maxDuration {
                    Thread.sleep(forTimeInterval: 0.01)
                    continue
                }

                dLock.lock()
                if self.demuxCancelled { dLock.unlock(); break }

                let currentSerial = sLock.withLock { self.seekSerial }

                // Reset state on seek so stale values don't affect post-seek packets.
                if currentSerial != lastSeenSerial {
                    ptsValidator.reset()
                    dropPolicy = PacketDropPolicy()
                    droppingEnabled = false
                    lastSeenSerial = currentSerial
                }

                // Re-enable drop policy once jitterBuffer is playing (audioClock is live).
                if !droppingEnabled && jitter.state == .playing {
                    droppingEnabled = true
                }

                guard let result = demuxer.readPacket() else {
                    dLock.unlock()
                    if packetCount == 0, !eofRecoveryDone {
                        eofRecoveryDone = true
                        logger.error("immediate EOF, recovering to 0")
                        dLock.lock()
                        _ = demuxer.seek(to: 0)
                        videoDec?.flush(); audioDec?.flush()
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
                let streamIndex = result.streamIndex
                let packet = result.packet

                if streamIndex == demuxer.videoStreamIndex {
                    let rawPTS = Self.ptsFromPacket(packet, demuxer: demuxer)
                    let pts = ptsValidator.validate(rawPTS)
                    // Debug: log large PTS jumps to detect stream discontinuities
                    if packetCount < 5 || (packetCount % 500 == 0) {
                        logger.debug("pkt#\(packetCount) rawPTS=\(String(format:"%.3f",rawPTS)) pts=\(String(format:"%.3f",pts)) audio=\(String(format:"%.3f",clock.audioTime))")
                    }
                    let isKey = (packet.pointee.flags & AV_PKT_FLAG_KEY) != 0
                    let activeSerial = sLock.withLock { self.seekSerial }

                    let skip = droppingEnabled
                        && activeSerial == currentSerial
                        && dropPolicy.shouldDrop(packetPTS: pts,
                                                 audioTime: clock.audioTime,
                                                 isKeyframe: isKey)
                    if skip {
                        dLock.unlock()
                        var p: UnsafeMutablePointer<AVPacket>? = packet
                        av_packet_free(&p)
                        continue
                    }

                    let pixelBuffer = videoDec?.decode(packet: packet)
                    dLock.unlock()

                    if let buf = pixelBuffer,
                       sLock.withLock({ self.seekSerial }) == currentSerial {
                        jitter.append(.init(pixelBuffer: buf, pts: pts))
                        let ptsCopy = pts
                        DispatchQueue.main.async { [weak self] in
                            guard let self else { return }
                            let d = Duration.milliseconds(Int64(ptsCopy * 1000))
                            if d > self.state.duration { self.state.duration = d }
                        }
                    }

                } else if streamIndex == demuxer.audioStreamIndex {
                    let pcm = audioDec?.decode(packet: packet)
                    dLock.unlock()
                    if let pcm { audioOut?.enqueue(pcm) }
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
        if seekPendingClock, let firstFrame = jitterBuffer.peek(at: 0) {
            seekPendingClock = false
            audioClock.reset(to: firstFrame.pts, sampleRate: audioDecoder?.outputSampleRate ?? 44100)
        }

        let audioTime = audioClock.audioTime
        let serial = seekLock.withLock { seekSerial }

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
        _renderer.display(pixelBuffer: popped.pixelBuffer)
        let ptsCopy = popped.pts
        let sinks = self._frameSinks.compactMap { $0.sink }
        for sink in sinks {
            sink.receive(pixelBuffer: popped.pixelBuffer, pts: ptsCopy)
        }
        displayedVideoFrames += 1; framesSinceLastLog += 1

        let posDur = Duration.milliseconds(Int64(popped.pts * 1000))
        state.position = posDur
        // Duration is kept up-to-date by the demux loop (which runs 5s ahead).
        // We only update here as a fallback if display somehow catches up to or
        // exceeds the demux-reported duration (e.g. near EOF).
        if posDur > state.duration { state.duration = posDur }
        notifyStateChange(); lastNotifiedPos = posDur

        logSync(now: now, pts: popped.pts, audioTime: audioTime)
    }

    private func logSync(now: Double, pts: Double, audioTime: Double) {
        let elapsed = now - lastLogTime
        guard elapsed > 5.0 else { return }
        let fps = Double(framesSinceLastLog) / elapsed
        let diff = Int((pts - audioTime) * 1000)
        logger.info("q=\(self.jitterBuffer.count) dur=\(Int(self.jitterBuffer.duration*1000))ms fps=\(String(format:"%.1f",fps)) diff=\(diff)ms a=\(String(format:"%.2f",audioTime))s v=\(String(format:"%.2f",pts))s buf=\(self.state.isBuffering)")
        lastLogTime = now; framesSinceLastLog = 0; ticksSinceLastLog = 0
    }

    // MARK: - Controls

    public func pause() {
        logger.info("pause")
        displayLink?.invalidate(); displayLink = nil; displayLinkProxy = nil
        audioOutput?.pause()
        state.isPlaying = false; notifyStateChange()
    }

    public func resume() {
        logger.info("resume")
        if jitterBuffer.state == .playing { audioOutput?.resume() }
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
        audioOutput?.stop()
        audioClock.reset(to: secs, sampleRate: sr)
        audioOutput?.start(sampleRate: sr, channels: ch)
        // Pause until jitterBuffer has enough video — same as initial play().
        audioOutput?.pause()
        // Signal displayNextFrame to calibrate audioClock to actual I-frame PTS.
        // FFmpeg seek lands on the GOP boundary before secs, so audioClock(=secs)
        // would be ahead of the first decoded frame, triggering PacketDropPolicy.
        seekPendingClock = true
    }

    public func stop() {
        playGeneration += 1  // discard any in-flight async open
        logger.info("stop (displayed \(self.displayedVideoFrames) frames)")
        displayLink?.invalidate(); displayLink = nil; displayLinkProxy = nil
        demuxCancelled = true
        audioOutput?.stop()
        demuxLock.lock()
        demuxer?.close(); demuxer = nil
        videoDecoder = nil; audioDecoder = nil
        demuxLock.unlock()
        jitterBuffer.flush()
        syncController.reset()
        audioClock.reset(to: 0, sampleRate: 44100)  // critical: must reset or stale seek position
                                                     // from previous session pollutes AudioClock
        _renderer.flush()
        displayedVideoFrames = 0
        state = PlayerState()
    }

    public func setVolume(_ volume: Double) { state.volume = volume; notifyStateChange() }
    public func setRate(_ rate: Double)     { state.rate = rate; notifyStateChange() }
    public func selectAudioTrack(id: String) {}
    public func selectSubtitle(id: String?) {}
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
        displayLink?.invalidate()
        let proxy = DisplayLinkProxy(backend: self)
        displayLinkProxy = proxy
        #if os(iOS) || os(tvOS)
        let link = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
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
