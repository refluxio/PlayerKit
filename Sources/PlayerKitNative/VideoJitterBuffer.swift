import Foundation
import CoreVideo
import PlayerKit

final class VideoJitterBuffer: @unchecked Sendable {

    struct Frame {
        let pixelBuffer: CVPixelBuffer
        let pts: Double
        let metadata: FrameMetadata
    }

    enum State: Equatable { case playing, buffering }

    /// Called synchronously when state transitions between .playing and
    /// .buffering. Fires on the demux thread (append) or main thread (pop),
    /// so the handler must be thread-safe. This is intentional: audio
    /// pause/resume must happen synchronously to avoid races where the
    /// AudioQueue keeps consuming buffers between the state flip and an
    /// async dispatch.
    var onStateChange: ((State) -> Void)?

    let minDuration: Double = 0.5     // 低于此值 → buffering
    let resumeDuration: Double = 1.0  // 达到此值 → playing
    let maxDuration: Double = 2.0     // demux 背压阈值（不丢帧，只是限速）
    let maxFrameCount: Int = 60       // ≈2.5s at 24fps; hard cap to bound memory

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

        // Safety cap: drop oldest frame only if count exceeds absolute maximum.
        // Duration-based dropping is intentionally removed for VOD — backpressure
        // in the demux loop (duration >= maxDuration → sleep) is the right mechanism.
        if frames.count > maxFrameCount { frames.removeFirst() }

        let dur = frames.count >= 2 ? frames.last!.pts - frames.first!.pts : 0
        if _state == .buffering, !frames.isEmpty {
            let stalled = ProcessInfo.processInfo.systemUptime - bufferingStart > slowDecoderGrace
            if dur >= resumeDuration || eofReached || stalled {
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
        let dur = frames.count >= 2 ? frames.last!.pts - frames.first!.pts : 0
        // EOF 后不再因剩余不足回 .buffering —— 末尾帧要放完,而不是
        // 播到剩 <0.5s 又卡进 buffering 黑屏。
        if _state == .playing, !eofReached, dur < minDuration {
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
        _state = .buffering
        eofReached = false
        bufferingStart = ProcessInfo.processInfo.systemUptime
    }
}
