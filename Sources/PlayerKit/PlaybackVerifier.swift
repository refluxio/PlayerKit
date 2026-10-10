import Foundation
import CoreVideo
import QuartzCore

// MARK: - PlaybackVerificationReport

/// Structured result of one playback verification session (P4 observer).
///
/// Everything in here is *observational*: the player pipeline never reads it,
/// playback behavior is unaffected, and every problem surfaces as a string in
/// `issues` — never as an error thrown into the render path.
///
/// Consumed by the reflux client (session-end archive + upload, plan §13 P5)
/// and the Tools issue pipeline (P6/P7); must stay `Codable` and
/// JSON-round-trip stable.
public struct PlaybackVerificationReport: Codable, Equatable {

    /// Aggregate luma statistics over every sampled frame of the session.
    public struct LumaStats: Codable, Equatable {
        /// Fraction of sampled luma values below the near-black threshold.
        public var blackRatio: Double
        /// Fraction of sampled luma values above the near-clip threshold.
        public var clipRatio: Double
        /// Median sampled luma, normalized 0..1.
        public var median: Double

        public init(blackRatio: Double, clipRatio: Double, median: Double) {
            self.blackRatio = blackRatio
            self.clipRatio = clipRatio
            self.median = median
        }
    }

    /// Result of one `ProbeToneMapping` double-render (mapped vs bypass checksum).
    public struct LivenessProbe: Codable, Equatable {
        /// FNV-1a checksum (hex) of the tone-mapped output.
        public var mappedChecksum: String
        /// FNV-1a checksum (hex) of the untouched input ("what passthrough yields").
        public var bypassChecksum: String
        /// `mappedChecksum != bypassChecksum` — a live mapper must differ.
        public var differ: Bool

        public init(mappedChecksum: String, bypassChecksum: String, differ: Bool) {
            self.mappedChecksum = mappedChecksum
            self.bypassChecksum = bypassChecksum
            self.differ = differ
        }
    }

    /// Source URL when the host reported one (`PlaybackVerifier.noteSource`);
    /// nil otherwise. Field-minimized upload drops this (see plan constraints).
    public var source: URL?
    /// Canonical name of the last observed `RendererStrategy`
    /// (e.g. "doviProfile5"), nil before the first strategy-bearing frame.
    public var strategy: String?
    /// Decoder preference implied by that strategy ("ffmpegSW"/"ffmpegHW"/"vtHW").
    public var decoderPreference: String?
    /// Pixel format FourCC of the last sampled frame ("420v"/"x420"/"BGRA"/...).
    public var pixelFormat: String?
    /// Total frames handed to `render` this session.
    public var framesObserved: Int
    /// Frames actually sampled/probed (≤ 1 per `probeIntervalFrames` observed).
    public var framesProbed: Int
    /// Whether any DV-strategy frame carried `metadata.dovi`. nil when the
    /// session never played under a DV strategy.
    public var doviRPUSeen: Bool?
    /// One of "sw-kept" | "vt-stripped" | "not-dv" | "unknown".
    public var rpuRetention: String
    public var luma: LumaStats
    /// Last probe result; nil when no probe was installed / no HDR frame probed.
    public var liveness: LivenessProbe?
    /// Human-readable problem strings. Never throws, never interrupts playback.
    /// Known values: "no-frames", "tone-map-silent-passthrough", "dv-rpu-stripped",
    /// "hdr-black-screen", "sdr-clipping", "report-truncated". Open-ended by design.
    public var issues: [String]

    public init(source: URL? = nil,
                strategy: String? = nil,
                decoderPreference: String? = nil,
                pixelFormat: String? = nil,
                framesObserved: Int = 0,
                framesProbed: Int = 0,
                doviRPUSeen: Bool? = nil,
                rpuRetention: String = "not-dv",
                luma: LumaStats = .init(blackRatio: 0, clipRatio: 0, median: 0),
                liveness: LivenessProbe? = nil,
                issues: [String] = []) {
        self.source = source
        self.strategy = strategy
        self.decoderPreference = decoderPreference
        self.pixelFormat = pixelFormat
        self.framesObserved = framesObserved
        self.framesProbed = framesProbed
        self.doviRPUSeen = doviRPUSeen
        self.rpuRetention = rpuRetention
        self.luma = luma
        self.liveness = liveness
        self.issues = issues
    }
}

// MARK: - ProbeToneMapping

/// Wraps any `ToneMapping` and adds double-render checksumming for probe frames.
///
/// Two call paths, deliberately separate:
/// - **Display path** (`process`) — plain forward to the wrapped mapper. The
///   `NativeBackend.toneMapperProvider` injection installs this wrapper on the
///   `ASBDLRenderer`, so production tone-mapping behavior is bit-identical to
///   the unwrapped mapper. Zero extra work per hot frame.
/// - **Observer path** (`probe`) — called by `PlaybackVerifier` *off the render
///   thread* for probe frames only (≤ 1/probeIntervalFrames). Computes the
///   bypass (input) and mapped (output) FNV-1a checksums with the same shared
///   sampler function ("双路径同函数") and reports whether they differ.
public final class ProbeToneMapping: ToneMapping {

    private let wrapped: any ToneMapping
    private let lock = NSLock()
    private var _lastProbe: PlaybackVerificationReport.LivenessProbe?

    /// Most recent probe result (read by tests / diagnostics).
    public var lastProbe: PlaybackVerificationReport.LivenessProbe? {
        lock.withLock { _lastProbe }
    }

    public init(wrapping: any ToneMapping) {
        self.wrapped = wrapping
    }

    /// Display path — untouched forward (hot path, zero added cost).
    public func process(pixelBuffer: CVPixelBuffer,
                        colorParams: VideoColorParams,
                        metadata: FrameMetadata,
                        strategy: RendererStrategy?) -> ProcessedFrame {
        wrapped.process(pixelBuffer: pixelBuffer, colorParams: colorParams,
                        metadata: metadata, strategy: strategy)
    }

    /// Observer path — double checksum for one probe frame. Called off the
    /// render thread; mappers are thread-safe by PlayerKit contract
    /// (NativeBackend already runs them from arbitrary display threads).
    public func probe(pixelBuffer: CVPixelBuffer,
                      colorParams: VideoColorParams,
                      metadata: FrameMetadata,
                      strategy: RendererStrategy?) -> PlaybackVerificationReport.LivenessProbe {
        let bypass = PlaybackVerifier.Checksum.of(pixelBuffer)
        let out = wrapped.process(pixelBuffer: pixelBuffer, colorParams: colorParams,
                                  metadata: metadata, strategy: strategy)
        let mapped = PlaybackVerifier.Checksum.of(out.pixelBuffer)
        let result = PlaybackVerificationReport.LivenessProbe(
            mappedChecksum: String(format: "%016llx", mapped),
            bypassChecksum: String(format: "%016llx", bypass),
            differ: mapped != bypass)
        lock.withLock { _lastProbe = result }
        return result
    }
}

// MARK: - PlaybackVerifier

/// In-playback HDR verification observer (P4).
///
/// A `VideoRenderer` decorator: inject it via `NativeBackend(renderer:)` (or
/// `init(renderer:audioOutput:)`) and it forwards every call verbatim to the
/// wrapped renderer while counting/observing frames. Four checks produce one
/// `PlaybackVerificationReport` per session:
///
/// 1. **Frames** — session opens on the first `render` call, so "no frames" is
///    directly visible (`issues: ["no-frames"]` on a never-fed verifier).
/// 2. **DV RPU retention** — under a DV strategy (`doviProfile5/8`) the share
///    of frames carrying `metadata.dovi` distinguishes SW-kept RPU from
///    VT-strip / silent fallback (`NativeBackend`'s hot-swap has no public
///    signal — this observes the outcome instead).
/// 3. **Tone-map liveness** — every `probeIntervalFrames`-th frame of an HDR
///    strategy goes through the installed `ProbeToneMapping` double-render;
///    two consecutive `differ == false` probes raise
///    `"tone-map-silent-passthrough"` (the 2026-10-08 regression sentinel).
/// 4. **Luma health** — sampled scanlines build a luma histogram; HDR
///    strategies black > 0.9 and SDR strategies clip > 0.5, each sustained for
///    30 consecutive samples (3 × `healthSampleFrames` windows), raise
///    `"hdr-black-screen"` / `"sdr-clipping"`.
///
/// Session boundaries follow the backend's own lifecycle: `play*()` begins
/// with an implicit `stop()`, which calls the renderer's `flush()` + `clear()`
/// — either finalizes the current session (guarded by "has samples", so the
/// flush+clear pair emits exactly one report). A seek's bare `flush()` also
/// closes the sampling window; the next frame opens a new one ("首帧重启会话").
///
/// Threading: `render` runs on the display-link thread. The every-frame hot
/// path does no allocations (one lock-guarded counter + modulo). Sampled
/// frames memcpy a few scanlines into a pre-allocated slot and the histogram /
/// checksum / mapper work is digested on a private serial queue; the pixel
/// buffer is retained only for the duration of that async hop.
public final class PlaybackVerifier: VideoRenderer {

    // MARK: Tuning (thresholds are deliberate constants — see plan Global
    // Constraints: the verifier introduces no changes to any existing gate).

    public struct Config {
        /// Probe every N-th observed frame (≤ 1/30 frames per plan constraint).
        public var probeIntervalFrames: Int
        /// Sampled frames aggregated per health evaluation window; 3 consecutive
        /// bad windows = the plan's "持续 30 采样" streak.
        public var healthSampleFrames: Int
        /// Serialized report size ceiling; extra issues are truncated.
        public var reportLimitBytes: Int

        public init(probeIntervalFrames: Int = 30,
                    healthSampleFrames: Int = 10,
                    reportLimitBytes: Int = 1 << 20) {
            self.probeIntervalFrames = probeIntervalFrames
            self.healthSampleFrames = healthSampleFrames
            self.reportLimitBytes = reportLimitBytes
        }
    }

    // Luma thresholds (documented constants, not configurable on purpose).
    private static let blackThreshold = 0.1
    private static let clipThreshold = 0.95
    private static let blackWindowRatio = 0.9   // HDR black-screen trigger
    private static let clipWindowRatio = 0.5    // SDR clipping trigger
    private static let badWindowsForIssue = 3   // 3 × healthSampleFrames = 30 samples
    private static let consecutiveSilentProbesForIssue = 2

    // Sampling geometry: 8 scanlines × 64 strided values per probed frame.
    private static let sampleRows = 8
    private static let sampleCols = 64
    private static let slotCount = 2

    // MARK: State

    private let wrapped: any VideoRenderer
    private let config: Config
    private let stateLock = NSLock()
    private let processingQueue = DispatchQueue(label: "io.reflex.PlayerKit.PlaybackVerifier", qos: .utility)

    // Session state — guarded by stateLock.
    private var sessionActive = false
    private var framesObserved = 0
    private var framesProbed = 0
    private var doviFramesSeen = 0
    private var sawDVStrategy = false
    private var lastStrategy: RendererStrategy?
    private var lastPixelFormat: String?
    private var sourceURL: URL?
    private var histogram = [Double](repeating: 0, count: 64)  // 64 buckets over [0,1)
    private var histogramTotal = 0
    private var windowBlack: [Double] = []
    private var windowClip: [Double] = []
    private var badBlackWindows = 0
    private var badClipWindows = 0
    private var silentProbeStreak = 0
    private var issues: [String] = []
    private var liveness: PlaybackVerificationReport.LivenessProbe?
    private var lastFinalized: PlaybackVerificationReport?
    private var _onReport: ((PlaybackVerificationReport) -> Void)?

    // Pre-allocated sample slots (render-thread copies; consumer reads under lock).
    // Worst case: 8 rows × 64 samples × 2 bytes (10-bit MSB-aligned plane 0).
    private static let slotBytes = sampleRows * sampleCols * 2
    private let sampleRegion: UnsafeMutableRawPointer
    private var slotMeta = [SlotMeta](repeating: .empty, count: slotCount)
    private var slotWriteIndex = 0

    private struct SlotMeta {
        var rows: Int
        var cols: Int
        var rowStrideBytes: Int   // bytes per sampled row INSIDE the slot
        var sourceBytesPerPixel: Int
        var fourCC: FourCharCode
        static let empty = SlotMeta(rows: 0, cols: 0, rowStrideBytes: 0, sourceBytesPerPixel: 1, fourCC: 0)
    }

    /// Fires with the finalized report when a session ends (flush/clear with
    /// samples). Delivered asynchronously on a global queue — keep the closure
    /// thread-safe (it never runs on the render thread mid-frame).
    public var onReport: ((PlaybackVerificationReport) -> Void)? {
        get { stateLock.withLock { _onReport } }
        set { stateLock.withLock { _onReport = newValue } }
    }

    // MARK: Init

    public init(wrapping: any VideoRenderer, config: Config = .init()) {
        self.wrapped = wrapping
        self.config = config
        self.sampleRegion = UnsafeMutableRawPointer.allocate(byteCount: Self.slotBytes * Self.slotCount,
                                                             alignment: MemoryLayout<UInt16>.alignment)
    }

    deinit {
        sampleRegion.deallocate()
    }

    // MARK: Public observer API

    /// Live snapshot of the current session; after a finalize (and before any
    /// new frame) returns the last finalized report.
    public func currentReport() -> PlaybackVerificationReport {
        stateLock.lock()
        if sessionActive {
            let report = assembleReportLocked()
            stateLock.unlock()
            return report
        }
        let finalized = lastFinalized
        stateLock.unlock()
        return finalized ?? PlaybackVerificationReport(issues: ["no-frames"])
    }

    /// Last finalized report, if any session has completed.
    public var finalizedReport: PlaybackVerificationReport? {
        stateLock.withLock { lastFinalized }
    }

    /// Host-supplied source identity (the renderer protocol never sees URLs).
    public func noteSource(_ url: URL) {
        stateLock.withLock { sourceURL = url }
    }

    /// Creates (and installs) the probe wrapper around a host-provided mapper.
    /// Typical wiring from the app side:
    ///
    ///     backend.toneMapperProvider = { [weak verifier] strategy, attrs in
    ///         verifier?.makeProbeToneMapper(wrapping: RealMapper(strategy, attrs)) }
    ///
    /// The returned wrapper is what gets installed on the ASBDLRenderer — the
    /// display path stays a plain forward — while the verifier keeps a strong
    /// reference and drives `probe(...)` on its background queue.
    @discardableResult
    public func makeProbeToneMapper(wrapping mapper: any ToneMapping) -> ProbeToneMapping {
        let probe = ProbeToneMapping(wrapping: mapper)
        stateLock.withLock { _probeMapping = probe }  // probeMapping.set re-takes stateLock — assign the backing var directly
        return probe
    }

    /// Installs an already-built probe wrapper.
    public func installProbeToneMapping(_ probe: ProbeToneMapping) {
        stateLock.withLock { _probeMapping = probe }
    }

    /// Lock discipline: writes go through `_probeMapping` under `stateLock`
    /// directly (callers already hold the lock); a computed setter here would
    /// re-take the non-recursive lock from inside `withLock` closures.
    private var probeMapping: ProbeToneMapping? { stateLock.withLock { _probeMapping } }
    private var _probeMapping: ProbeToneMapping?

    // MARK: VideoRenderer (forwarding + observation)

    public var layer: CALayer { wrapped.layer }

    public var prefersTenBit: Bool { wrapped.prefersTenBit }

    public var displayCapability: DisplayCapability {
        get { wrapped.displayCapability }
        set { wrapped.displayCapability = newValue }
    }

    public func configure(codedSize: CGSize, sampleAspectRatio: Double) {
        wrapped.configure(codedSize: codedSize, sampleAspectRatio: sampleAspectRatio)
    }

    /// Display-link thread. Every-frame path: one lock + counters (zero
    /// allocations). Every `probeIntervalFrames`-th frame additionally copies
    /// sampled scanlines into a pre-allocated slot (≤1KB memcpy) and hands the
    /// digest off to the processing queue.
    public func render(pixelBuffer: CVPixelBuffer,
                       pts: Double,
                       colorParams: VideoColorParams,
                       metadata: FrameMetadata,
                       strategy: RendererStrategy?) {
        stateLock.lock()
        if !sessionActive {
            sessionActive = true
            resetSessionCountersLocked()
        }
        framesObserved += 1
        if strategy != nil { lastStrategy = strategy }
        let isDV = Self.isDVStrategy(strategy)
        if isDV {
            sawDVStrategy = true
            if metadata.dovi != nil { doviFramesSeen += 1 }
        }
        let shouldSample = (framesObserved % max(1, config.probeIntervalFrames)) == 0
        stateLock.unlock()

        if shouldSample {
            let wantsProbe = (probeMapping != nil) && Self.isHDRStrategy(strategy)
            let slot = copySample(from: pixelBuffer)  // pre-allocated slot, no allocation
            // Retain the buffer past this call only when a probe needs it.
            let probeBuffer: CVPixelBuffer? = wantsProbe ? pixelBuffer : nil
            processingQueue.async { [weak self] in
                self?.consumeSample(slot: slot, probeBuffer: probeBuffer,
                                    colorParams: colorParams, metadata: metadata,
                                    strategy: strategy)
            }
        }

        // Forward unchanged — pure observer.
        wrapped.render(pixelBuffer: pixelBuffer, pts: pts, colorParams: colorParams,
                       metadata: metadata, strategy: strategy)
    }

    /// `NativeBackend.stop()` calls `flush()` then `clear()`; `seek()` calls
    /// `flush()` alone. Both finalize (guarded by "has samples", so the
    /// stop-pair emits exactly one report); the next frame opens a new session.
    public func flush() {
        finalizeSession()
        wrapped.flush()
    }

    public func clear() {
        finalizeSession()
        wrapped.clear()
    }

    // MARK: Session finalize

    private func finalizeSession() {
        // Drain in-flight samples/probes first (holds no locks while waiting —
        // safe: finalize is called from flush/clear, never from the queue).
        processingQueue.sync { }

        stateLock.lock()
        guard sessionActive else {
            stateLock.unlock()
            return  // no samples since the last finalize → nothing to report
        }
        var report = assembleReportLocked()
        report = truncateIssuesIfNeeded(report)
        resetSessionLocked()
        sessionActive = false
        lastFinalized = report
        let callback = _onReport
        stateLock.unlock()

        if let callback {
            DispatchQueue.global(qos: .utility).async { callback(report) }
        }
    }

    /// Caller holds stateLock.
    private func assembleReportLocked() -> PlaybackVerificationReport {
        var issuesOut = issues
        if framesObserved == 0 && !issuesOut.contains("no-frames") {
            issuesOut.insert("no-frames", at: 0)
        }
        if sawDVStrategy && framesObserved > 0 && doviFramesSeen == 0 {
            issuesOut.append("dv-rpu-stripped")
        }

        let rpu: String
        if !sawDVStrategy {
            rpu = "not-dv"
        } else if framesObserved == 0 {
            rpu = "unknown"
        } else if doviFramesSeen > 0 {
            rpu = "sw-kept"
        } else {
            rpu = "vt-stripped"
        }

        let strategyName = lastStrategy.map(Self.strategyName)
        let decoder = lastStrategy.map { Self.decoderName($0.decoderPreference) }

        return PlaybackVerificationReport(
            source: sourceURL,
            strategy: strategyName,
            decoderPreference: decoder,
            pixelFormat: lastPixelFormat,
            framesObserved: framesObserved,
            framesProbed: framesProbed,
            doviRPUSeen: sawDVStrategy ? (doviFramesSeen > 0) : nil,
            rpuRetention: rpu,
            luma: lumaStatsLocked(),
            liveness: liveness,
            issues: issuesOut)
    }

    /// Safety valve for the report size ceiling (plan constraint).
    private func truncateIssuesIfNeeded(_ report: PlaybackVerificationReport) -> PlaybackVerificationReport {
        var out = report
        let encoder = JSONEncoder()
        func size(_ r: PlaybackVerificationReport) -> Int {
            (try? encoder.encode(r).count) ?? Int.max
        }
        guard size(out) > config.reportLimitBytes else { return out }
        out.issues = ["report-truncated"]
        if size(out) > config.reportLimitBytes {
            out.issues = []
        }
        return out
    }

    /// Caller holds stateLock.
    private func resetSessionCountersLocked() {
        framesObserved = 0
        framesProbed = 0
        doviFramesSeen = 0
        sawDVStrategy = false
        lastStrategy = nil
        lastPixelFormat = nil
        histogram = [Double](repeating: 0, count: 64)
        histogramTotal = 0
        windowBlack = []
        windowClip = []
        badBlackWindows = 0
        badClipWindows = 0
        silentProbeStreak = 0
        issues = []
        liveness = nil
    }

    private func resetSessionLocked() {
        resetSessionCountersLocked()
    }

    /// Caller holds stateLock.
    private func lumaStatsLocked() -> PlaybackVerificationReport.LumaStats {
        guard histogramTotal > 0 else {
            return .init(blackRatio: 0, clipRatio: 0, median: 0)
        }
        let total = Double(histogramTotal)
        let blackCut = Int(Self.blackThreshold * 64)
        let clipCut = Int(Self.clipThreshold * 64)
        var black = 0.0, clip = 0.0, cumulative = 0.0, median = 0.0
        for (bucket, count) in histogram.enumerated() {
            if bucket < blackCut { black += count }
            if bucket >= clipCut { clip += count }
            cumulative += count
            if median == 0, cumulative >= total / 2 {
                median = (Double(bucket) + 0.5) / 64.0
            }
        }
        return .init(blackRatio: black / total, clipRatio: clip / total, median: median)
    }

    // MARK: Sampling (render thread → slot)

    /// Copies ≤ 8 strided scanlines of plane 0 into the next pre-allocated
    /// slot. Render thread; the only per-probed-frame cost is this ≤1KB memcpy
    /// plus a metadata struct write, both under stateLock. Returns the slot
    /// index the consumer must read.
    @discardableResult
    private func copySample(from pixelBuffer: CVPixelBuffer) -> Int {
        let fourCC = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let bytesPerPixel = Self.plane0BytesPerPixel(fourCC)
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else {
            stateLock.lock()
            defer { stateLock.unlock() }
            lastPixelFormat = Self.fourCCName(fourCC)
            return slotWriteIndex
        }
        let sourceStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)

        let rows = min(Self.sampleRows, max(1, height))
        let cols = Self.sampleCols
        let rowStep = max(1, height / rows)
        let colStepBytes = max(bytesPerPixel, (width * bytesPerPixel) / cols)

        stateLock.lock()
        defer { stateLock.unlock() }
        lastPixelFormat = Self.fourCCName(fourCC)
        let slot = slotWriteIndex
        slotWriteIndex = (slotWriteIndex + 1) % Self.slotCount
        let meta = SlotMeta(rows: rows, cols: cols, rowStrideBytes: cols * bytesPerPixel,
                            sourceBytesPerPixel: bytesPerPixel, fourCC: fourCC)
        let slotBase = sampleRegion.advanced(by: slot * Self.slotBytes)
        for r in 0..<rows {
            let y = min(height - 1, r * rowStep)
            let src = base.advanced(by: y * sourceStride).assumingMemoryBound(to: UInt8.self)
            let dst = slotBase.advanced(by: r * meta.rowStrideBytes).assumingMemoryBound(to: UInt8.self)
            for c in 0..<cols {
                let x = min(width * bytesPerPixel - bytesPerPixel, c * colStepBytes)
                for b in 0..<bytesPerPixel {
                    dst[c * bytesPerPixel + b] = src[x + b]
                }
            }
        }
        slotMeta[slot] = meta
        return slot
    }

    // MARK: Digest (processing queue — off the render thread)

    private func consumeSample(slot: Int, probeBuffer: CVPixelBuffer?,
                               colorParams: VideoColorParams,
                               metadata: FrameMetadata,
                               strategy: RendererStrategy?) {
        // 1. Read the designated slot out under the lock (small fixed copy).
        stateLock.lock()
        let meta = slotMeta[slot]
        let byteCount = meta.rows * meta.rowStrideBytes
        var bytes = [UInt8](repeating: 0, count: byteCount)
        if byteCount > 0 {
            let slotBase = sampleRegion.advanced(by: slot * Self.slotBytes)
            bytes.withUnsafeMutableBytes { raw in
                raw.baseAddress!.copyMemory(from: slotBase, byteCount: byteCount)
            }
        }
        framesProbed += 1
        stateLock.unlock()

        // 2. Interpret luma off-lock (allocation fine here — background queue).
        let lumas = Self.interpretLuma(bytes: bytes, meta: meta)
        let blackRatio = lumas.isEmpty ? 0 : Double(lumas.filter { $0 < Self.blackThreshold }.count) / Double(lumas.count)
        let clipRatio = lumas.isEmpty ? 0 : Double(lumas.filter { $0 >= Self.clipThreshold }.count) / Double(lumas.count)

        // 3. Probe double-render (mapper work stays off the render thread).
        var probeResult: PlaybackVerificationReport.LivenessProbe?
        if let probeBuffer, let probe = probeMapping {
            probeResult = probe.probe(pixelBuffer: probeBuffer,
                                      colorParams: colorParams,
                                      metadata: metadata,
                                      strategy: strategy)
        }

        // 4. Merge into session state.
        stateLock.lock()
        defer { stateLock.unlock() }
        for value in lumas {
            let bucket = min(63, max(0, Int(value * 64)))
            histogram[bucket] += 1
        }
        histogramTotal += lumas.count
        if let probeResult { liveness = probeResult }

        // Health windows: healthSampleFrames sampled frames per window; 3
        // consecutive bad windows == 30 consecutive samples (plan threshold).
        windowBlack.append(blackRatio)
        windowClip.append(clipRatio)
        if windowBlack.count >= max(1, config.healthSampleFrames) {
            let wBlack = windowBlack.reduce(0, +) / Double(windowBlack.count)
            let wClip = windowClip.reduce(0, +) / Double(windowClip.count)
            badBlackWindows = wBlack > Self.blackWindowRatio ? badBlackWindows + 1 : 0
            badClipWindows = wClip > Self.clipWindowRatio ? badClipWindows + 1 : 0
            if badBlackWindows >= Self.badWindowsForIssue {
                appendIssueOnce("hdr-black-screen")
            }
            if badClipWindows >= Self.badWindowsForIssue {
                appendIssueOnce("sdr-clipping")
            }
            windowBlack = []
            windowClip = []
        }

        // Tone-map liveness: 2 consecutive silent probes → issue.
        if let probeResult {
            silentProbeStreak = probeResult.differ ? 0 : silentProbeStreak + 1
            if silentProbeStreak >= Self.consecutiveSilentProbesForIssue {
                appendIssueOnce("tone-map-silent-passthrough")
            }
        }
    }

    /// Caller holds stateLock.
    private func appendIssueOnce(_ issue: String) {
        if !issues.contains(issue) { issues.append(issue) }
    }

    // MARK: Shared checksum (both probe paths use this exact function)

    enum Checksum {
        /// FNV-1a 64 over `sampleRows`×`sampleCols` strided plane-0 bytes.
        static func of(_ pixelBuffer: CVPixelBuffer) -> UInt64 {
            let bytesPerPixel = PlaybackVerifier.plane0BytesPerPixel(
                CVPixelBufferGetPixelFormatType(pixelBuffer))
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return 0 }
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            let rows = min(PlaybackVerifier.sampleRows, max(1, height))
            let rowStep = max(1, height / rows)
            let colStepBytes = max(bytesPerPixel,
                                   (width * bytesPerPixel) / PlaybackVerifier.sampleCols)

            var hash: UInt64 = 0xcbf29ce484222325
            for r in 0..<rows {
                let y = min(height - 1, r * rowStep)
                let src = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
                for c in 0..<PlaybackVerifier.sampleCols {
                    let x = min(width * bytesPerPixel - bytesPerPixel, c * colStepBytes)
                    for b in 0..<bytesPerPixel {
                        hash = (hash ^ UInt64(src[x + b])) &* 0x100000001b3
                    }
                }
            }
            return hash
        }
    }

    // MARK: Format helpers

    static func plane0BytesPerPixel(_ fourCC: FourCharCode) -> Int {
        switch fourCC {
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
            return 2   // 'x420' / 'xf20': 10-bit MSB-aligned in UInt16
        case kCVPixelFormatType_32BGRA, kCVPixelFormatType_32RGBA:
            return 4
        default:
            return 1   // '420v' / '420f' 8-bit biplanar luma, and best-effort others
        }
    }

    /// Normalized luma values (0..1) from one sampled slot.
    private static func interpretLuma(bytes: [UInt8], meta: SlotMeta) -> [Double] {
        guard meta.rows > 0, meta.cols > 0, meta.sourceBytesPerPixel > 0 else { return [] }
        var out = [Double]()
        out.reserveCapacity(meta.rows * meta.cols)
        switch meta.sourceBytesPerPixel {
        case 2:
            // 10-bit MSB-aligned (decoder packs << 6): take the 16-bit LE word.
            for r in 0..<meta.rows {
                for c in 0..<meta.cols {
                    let i = r * meta.rowStrideBytes + c * 2
                    guard i + 1 < bytes.count else { continue }
                    let word = UInt16(bytes[i]) | (UInt16(bytes[i + 1]) << 8)
                    out.append(Double(word >> 6) / 1023.0)
                }
            }
        case 4:
            // BGRA single plane → Rec.709 luma.
            for r in 0..<meta.rows {
                for c in 0..<meta.cols {
                    let i = r * meta.rowStrideBytes + c * 4
                    guard i + 2 < bytes.count else { continue }
                    let b = Double(bytes[i]), g = Double(bytes[i + 1]), r8 = Double(bytes[i + 2])
                    out.append((0.2126 * r8 + 0.7152 * g + 0.0722 * b) / 255.0)
                }
            }
        default:
            for r in 0..<meta.rows {
                for c in 0..<meta.cols {
                    let i = r * meta.rowStrideBytes + c
                    guard i < bytes.count else { continue }
                    out.append(Double(bytes[i]) / 255.0)
                }
            }
        }
        return out
    }

    static func fourCCName(_ code: FourCharCode) -> String {
        let bytes = [
            UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF),
        ]
        let chars = bytes.map { b in
            (b >= 0x20 && b < 0x7F) ? Character(UnicodeScalar(b)) : "·"
        }
        return String(chars)
    }

    static func strategyName(_ strategy: RendererStrategy) -> String {
        switch strategy {
        case .sdr8Bit:                          return "sdr8Bit"
        case .sdr10Bit:                         return "sdr10Bit"
        case .hdr10Static:                      return "hdr10Static"
        case .hdr10Plus:                        return "hdr10Plus"
        case .doviProfile5:                     return "doviProfile5"
        case .doviProfile8:                     return "doviProfile8"
        case .hlgOOTF:                          return "hlgOOTF"
        case .degradedHDR10:                    return "degradedHDR10"
        }
    }

    static func decoderName(_ preference: DecoderPreference) -> String {
        switch preference {
        case .ffmpegSW: return "ffmpegSW"
        case .ffmpegHW: return "ffmpegHW"
        case .vtHW:     return "vtHW"
        }
    }

    static func isHDRStrategy(_ strategy: RendererStrategy?) -> Bool {
        switch strategy {
        case .hdr10Static, .hdr10Plus, .doviProfile5, .doviProfile8, .hlgOOTF, .degradedHDR10:
            return true
        case .sdr8Bit, .sdr10Bit, nil:
            return false
        }
    }

    static func isDVStrategy(_ strategy: RendererStrategy?) -> Bool {
        switch strategy {
        case .doviProfile5, .doviProfile8: return true
        default: return false
        }
    }
}
