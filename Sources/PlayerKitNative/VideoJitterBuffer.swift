import Foundation
import CoreVideo
import PlayerKit

final class VideoJitterBuffer: @unchecked Sendable {

    struct Frame {
        let pixelBuffer: CVPixelBuffer
        let pts: Double
        let metadata: FrameMetadata

        /// Bytes this frame holds. A frame is a decoded picture, so this is what
        /// actually costs memory (a 4K 10-bit HDR frame is ~18.5 MB).
        var byteSize: Int { CVPixelBufferGetDataSize(pixelBuffer) }
    }

    enum State: Equatable { case playing, buffering }

    /// Ceiling for the decoded frames held here.
    ///
    /// The frame cap used to be fps x maxDuration (240 frames at 120 fps) with no
    /// regard for frame size. For 4K 10-bit HDR that is ~4.4 GB: on iPhone the app
    /// got a memory warning ~1 s after the first frame (q=113, ~2.1 GB) and was
    /// SIGKILLed (2026-09-30). Frames are IOSurface-backed, so this never shows in
    /// RSS on the Mac and cannot be caught there by looking at process memory.
    let memoryBudgetBytes: Int

    /// iOS extensions/apps are killed at a few GB; a Mac has room to spare.
    static var defaultMemoryBudgetBytes: Int {
        #if os(iOS)
        return 512 << 20
        #else
        return 2 << 30
        #endif
    }

    /// Frames the byte budget always leaves room for, so a very large frame can
    /// never make the buffer unusable (it must still be able to start playing).
    private static let minBudgetFrames = 6
    /// Frames that may already be in flight in the decoder (VT reorders and
    /// returns asynchronously) when `isFull` starts holding the demux loop back.
    private static let inFlightSlackFrames = 8

    init(memoryBudgetBytes: Int = VideoJitterBuffer.defaultMemoryBudgetBytes) {
        self.memoryBudgetBytes = memoryBudgetBytes
    }

    private var bufferedBytesLocked = 0
    /// Largest frame seen. Frame size is a property of the stream, so this settles
    /// after the first frame; until then the budget cannot be converted to frames.
    private var frameBytesHint = 0

    /// Bytes of decoded frames currently held.
    var bufferedBytes: Int {
        lock.lock(); defer { lock.unlock() }
        return bufferedBytesLocked
    }

    /// True when the byte budget is used up: the demux loop should stop feeding the
    /// decoder for a moment. Only ever true for byte pressure, so normal content
    /// (small frames) is unaffected. Independent of the audio clock on purpose: at
    /// start the audio clock has not advanced, the time-based throttle is inactive
    /// and decoding ran at full speed.
    var isFull: Bool {
        lock.lock(); defer { lock.unlock() }
        return frames.count >= budgetFramesLocked
    }

    /// How many frames the byte budget allows (Int.max until a frame size is known).
    private var budgetFramesLocked: Int {
        guard frameBytesHint > 0 else { return Int.max }
        return max(Self.minBudgetFrames, memoryBudgetBytes / frameBytesHint)
    }

    /// Soft capacity in frames: what the buffer is meant to hold.
    private var capacityFramesLocked: Int {
        min(max(60, Int((framesPerSecondHint * maxDuration).rounded(.up))), budgetFramesLocked)
    }

    /// The playing/buffering thresholds are durations sized for ~2 s of buffer. When
    /// the byte budget shrinks the buffer below that, scale them with it - otherwise
    /// the buffer can never reach `resumeDuration` and playback falls into the old
    /// "start, show one frame, freeze for 4 s" loop (see the 120 fps note below).
    private var thresholdScaleLocked: Double {
        min(1.0, (Double(capacityFramesLocked) / framesPerSecondHint) / maxDuration)
    }
    private var resumeDurationLocked: Double { resumeDuration * thresholdScaleLocked }
    private var minDurationLocked: Double { minDuration * thresholdScaleLocked }

    /// Called synchronously when state transitions between .playing and
    /// .buffering. Fires on the demux thread (append) or main thread (pop),
    /// so the handler must be thread-safe. This is intentional: audio
    /// pause/resume must happen synchronously to avoid races where the
    /// AudioQueue keeps consuming buffers between the state flip and an
    /// async dispatch.
    var onStateChange: ((State) -> Void)?

    let minDuration: Double = 0.5     // 低于此值 → buffering
    let resumeDuration: Double = 1.0  // 达到此值 → playing
    // 2026-09-02 曾试降到 0.6s 换更快首帧,但 115 CDN 单次请求耗时观测到
    // 5~9.5s 的抖动(Cloud115StreamReader.swift 头部注释详述),0.6s 的缓冲
    // margin 扛不住,反而更频繁触发二次卡顿——已撤销回 1.0。
    let maxDuration: Double = 2.0     // demux 背压阈值（不丢帧，只是限速）
    /// 帧数硬上限，本是"限制内存占用的最后防线"——正常应由上面 maxDuration 的时长背压
    /// 先生效，这个上限极少真正绑定。但它是按固定帧数写的，原为 60（注释"≈2.5s at 24fps"）:
    /// 对 24fps 内容对应 2.5s，远高于 maxDuration/resumeDuration，安全；但对 120fps 内容
    /// 60 帧只等于 0.5s，反而先于 maxDuration 绑定，且同时低于 resumeDuration(1.0s)和
    /// minDuration(0.5s)——缓冲区永远攒不到开播门槛，只能靠 4s 慢速兜底硬开，开播后弹一帧
    /// 剩余时长又跌破 minDuration 立刻打回缓冲，形成"开播→弹一帧→冻结 4 秒"的循环，肉眼看
    /// 就是卡死（2026-09-22 用户反馈"流浪地球直接卡住不动"，4K HDR 120fps HEVC 实测复现：
    /// 60 秒内状态推进仅一次）。
    ///
    /// 修复：上限按源帧率换算 maxDuration 秒的帧数，60 帧只作为下限（保持 ≤60fps 内容的
    /// 既有行为和内存占用不变）。`configureFrameRate` 在拿到帧率之前不调用,此时用 60
    /// (对未知/低帧率场景安全;高帧率场景在拿到 demuxer 的帧率信息后会被立即纠正)。
    private var framesPerSecondHint: Double = 24.0
    /// 加锁版,给临界区外的调用方。已持 `lock` 的代码必须改用
    /// `maxFrameCountLocked`——NSLock 不可重入,持锁时再进这里的
    /// lock.lock() 是同线程二次加锁,必然死锁。
    var maxFrameCount: Int {
        lock.lock(); defer { lock.unlock() }
        return maxFrameCountLocked
    }

    /// 不加锁版,仅在已持有 `lock` 的临界区内使用。
    private var maxFrameCountLocked: Int {
        let byTime = max(60, Int((framesPerSecondHint * maxDuration).rounded(.up)))
        let budget = budgetFramesLocked
        return budget == Int.max ? byTime : min(byTime, budget + Self.inFlightSlackFrames)
    }

    /// 告知视频源的实际帧率，让 `maxFrameCount` 按真实帧率换算，而不是隐含假设
    /// ~24fps。应在拿到 demuxer 的帧率信息后、开始给这个视频 append 帧之前调用一次
    /// (每次打开新视频/新会话都要重新调用——帧率是流属性，不跨视频保留)。
    /// 非法值(≤0、NaN、无穷)忽略，保留当前值。
    func configureFrameRate(_ fps: Double) {
        guard fps.isFinite, fps > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        framesPerSecondHint = fps
    }

    private var frames: [Frame] = []
    private let lock = NSLock()
    private var _state: State = .buffering
    /// 视频流已读到 EOF(demux 线程 markEOF 置位)。此后不再要求攒满
    /// resumeDuration 才开播 —— seek 到接近文件末尾时剩余内容可能不足 1s,
    /// 永远攒不满 → displayNextFrame 永远停在 buffering 门 → 零帧黑屏。
    /// EOF 后 pop 也不再因剩余不足回 .buffering,把末尾帧放完。
    private var eofReached = false
    /// 进入 .buffering 的时刻(systemUptime)。解码/读取极慢(如 4K SW 软解
    /// 仅 1-5fps,或 115 网络慢)时 1.0s 缓冲要等几十秒,期间纯黑屏;超过
    /// slowDecoderGrace 后只要有帧就开播 —— 慢但可见,用户不会误以为卡死。
    private var bufferingStart = ProcessInfo.processInfo.systemUptime
    /// 慢速降级宽限期:进入 buffering 后超过该时长仍未攒满 resumeDuration
    /// 且有帧,直接开播。正常网络/硬解在 1-3s 内就能满足 1.0s 门槛,不受影响。
    private let slowDecoderGrace: TimeInterval = 4.0

    var state: State {
        lock.lock(); defer { lock.unlock() }
        return _state
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return frames.count
    }

    var duration: Double {
        lock.lock(); defer { lock.unlock() }
        guard frames.count >= 2 else { return 0 }
        return frames.last!.pts - frames.first!.pts
    }

    // MARK: - Write (demux thread)

    func append(_ frame: Frame) {
        var newState: State?
        lock.lock()

        // Insert in PTS-sorted order so pop() always returns the next display frame.
        // VTVideoDecoder returns B-frames in decode order (not display order); without
        // sorting, jitterBuffer PTS values are scrambled, causing backwards progress
        // and wrong nominalDelay in SyncController.
        let insertIdx = frames.firstIndex(where: { $0.pts > frame.pts }) ?? frames.endIndex
        frames.insert(frame, at: insertIdx)
        let size = frame.byteSize
        bufferedBytesLocked += size
        if size > frameBytesHint { frameBytesHint = size }

        // Safety cap: drop oldest frame only if count exceeds absolute maximum.
        // Duration-based dropping is intentionally removed for VOD — backpressure
        // in the demux loop (duration >= maxDuration → sleep) is the right mechanism.
        if frames.count > maxFrameCountLocked { bufferedBytesLocked -= frames.removeFirst().byteSize }

        let dur = frames.count >= 2 ? frames.last!.pts - frames.first!.pts : 0
        if _state == .buffering, !frames.isEmpty {
            let stalled = ProcessInfo.processInfo.systemUptime - bufferingStart > slowDecoderGrace
            if dur >= resumeDurationLocked || eofReached || stalled {
                _state = .playing
                newState = .playing
            }
        }
        lock.unlock()

        if let s = newState {
            onStateChange?(s)
        }
    }

    // MARK: - Read (main thread)

    func peek(at index: Int = 0) -> Frame? {
        lock.lock(); defer { lock.unlock() }
        return index < frames.count ? frames[index] : nil
    }

    @discardableResult
    func pop() -> Frame? {
        var popped: Frame?
        var newState: State?
        lock.lock()
        guard !frames.isEmpty else { lock.unlock(); return nil }
        popped = frames.removeFirst()
        bufferedBytesLocked -= popped?.byteSize ?? 0
        let dur = frames.count >= 2 ? frames.last!.pts - frames.first!.pts : 0
        // EOF 后不再因剩余不足回 .buffering —— 末尾帧要放完,而不是
        // 播到剩 <0.5s 又卡进 buffering 黑屏。
        if _state == .playing, !eofReached, dur < minDurationLocked {
            _state = .buffering
            newState = .buffering
        }
        lock.unlock()

        if let s = newState {
            onStateChange?(s)
        }
        return popped
    }

    /// 视频流已读取到 EOF。若此刻仍在 .buffering 且已有帧(剩余内容不足
    /// resumeDuration,正常门槛永远无法满足),立即转 .playing 开始渲染,
    /// 避免 seek 到接近末尾时零帧黑屏。
    func markEOF() {
        var newState: State?
        lock.lock()
        eofReached = true
        if _state == .buffering, !frames.isEmpty {
            _state = .playing
            newState = .playing
        }
        lock.unlock()

        if let s = newState {
            onStateChange?(s)
        }
    }

    func flush() {
        lock.lock(); defer { lock.unlock() }
        frames.removeAll()
        bufferedBytesLocked = 0
        _state = .buffering
        eofReached = false
        bufferingStart = ProcessInfo.processInfo.systemUptime
    }
}
