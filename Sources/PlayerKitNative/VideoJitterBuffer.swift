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

    /// Called on the main thread when state transitions between .playing and .buffering.
    var onStateChange: ((State) -> Void)?

    let minDuration: Double = 0.5     // 低于此值 → buffering
    let resumeDuration: Double = 1.0  // 达到此值 → playing
    let maxDuration: Double = 2.0     // demux 背压阈值（不丢帧，只是限速）
    let maxFrameCount: Int = 60       // ≈2.5s at 24fps; hard cap to bound memory

    private var frames: [Frame] = []
    private let lock = NSLock()
    private var _state: State = .buffering

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
        if _state == .buffering, dur >= resumeDuration {
            _state = .playing
            newState = .playing
        }
        lock.unlock()

        if let s = newState {
            DispatchQueue.main.async { [weak self] in self?.onStateChange?(s) }
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
        if _state == .playing, dur < minDuration {
            _state = .buffering
            newState = .buffering
        }
        lock.unlock()

        if let s = newState {
            DispatchQueue.main.async { [weak self] in self?.onStateChange?(s) }
        }
        return popped
    }

    func flush() {
        lock.lock(); defer { lock.unlock() }
        frames.removeAll()
        _state = .buffering
    }
}
