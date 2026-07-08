import Foundation

/// Sample-count–based audio position clock. Thread-safe.
/// The single source of truth for current audio playback position.
final class AudioClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _consumedSamples: Int64 = 0
    private(set) var sampleRate: Int32 = 44100

    /// Current playback position in seconds. Safe to call from any thread.
    var audioTime: Double {
        lock.withLock { Double(max(0, _consumedSamples)) / Double(sampleRate) }
    }

    /// Single-callback advance cap. AudioQueue normally fires one callback per
    /// enqueued buffer (~23ms for AAC), but batch callbacks can fire when:
    ///   - AudioQueueStop(immediate: true) drains all queued buffers at once
    ///   - the system is under load and AudioQueue's internal thread batches
    ///     multiple buffer completions into one callback
    /// A single outsized advance would let audioTime jump ~1s, which propagates
    /// to the display loop's skip-behind guard (guardWindow=60ms) and causes it
    /// to drop 5-10 consecutive video frames → the user-visible "1s 花屏" right
    /// after seek.  Cap each advance to 0.2s of samples — bounded enough that
    /// the skip-behind guard only pops at most 2-3 frames before audioTime
    /// re-converges with video PTS.
    private let maxAdvanceSeconds: Double = 0.2

    /// Called by AudioQueue callback when a buffer is consumed.
    func advance(byteCount: Int, channels: Int32) {
        let bytesPerSample = Int(channels) * 4  // float32 interleaved
        guard bytesPerSample > 0, sampleRate > 0 else { return }
        let samples = Int64(byteCount / bytesPerSample)
        let maxPerCall = Int64(Double(sampleRate) * maxAdvanceSeconds)
        let clamped = min(samples, maxPerCall)
        lock.withLock { _consumedSamples += clamped }
    }

    /// Call before enqueueing primer silence buffers.
    /// Creates a negative debt so audioTime reads 0 while primers play out.
    func primeDebt(bufferCount: Int, bytesPerBuffer: Int, channels: Int32) {
        let bytesPerSample = Int(channels) * 4
        guard bytesPerSample > 0 else { return }
        let samples = bufferCount * bytesPerBuffer / bytesPerSample
        lock.withLock { _consumedSamples -= Int64(samples) }
    }

    /// Reset to a specific position, e.g. after a seek.
    func reset(to time: Double, sampleRate: Int32) {
        let sr = sampleRate > 0 ? sampleRate : 44100
        lock.withLock {
            self.sampleRate = sr
            _consumedSamples = Int64(time * Double(sr))
        }
    }
}
