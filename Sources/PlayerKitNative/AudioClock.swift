import Foundation

/// Sample-count–based audio position clock. Thread-safe.
/// The single source of truth for current audio playback position.
final class AudioClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _consumedSamples: Int64 = 0
    private(set) var sampleRate: Int32 = 44100

    /// Tracks how many primer-buffer samples have not yet fired their callbacks.
    /// Used by calibrate() to re-apply the exact remaining debt so that upcoming
    /// primer callbacks cancel out rather than spuriously advancing audioTime.
    private var _primerPendingSamples: Int64 = 0

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

    /// Called by AudioQueue callback when a real (non-primer) buffer is consumed.
    func advance(byteCount: Int, channels: Int32) {
        let bytesPerSample = Int(channels) * 4  // float32 interleaved
        guard bytesPerSample > 0, sampleRate > 0 else { return }
        let samples = Int64(byteCount / bytesPerSample)
        let maxPerCall = Int64(Double(sampleRate) * maxAdvanceSeconds)
        let clamped = min(samples, maxPerCall)
        lock.withLock { _consumedSamples += clamped }
    }

    /// Called by AudioQueue callback when a primer (silence) buffer is consumed.
    /// Identical to advance() but also decrements _primerPendingSamples so that
    /// calibrate() always sees the correct remaining primer debt.
    func advancePrimer(byteCount: Int, channels: Int32) {
        let bytesPerSample = Int(channels) * 4
        guard bytesPerSample > 0, sampleRate > 0 else { return }
        let samples = Int64(byteCount / bytesPerSample)
        let maxPerCall = Int64(Double(sampleRate) * maxAdvanceSeconds)
        let clamped = min(samples, maxPerCall)
        lock.withLock {
            _consumedSamples += clamped
            _primerPendingSamples -= min(clamped, _primerPendingSamples)
        }
    }

    /// Register a primer sequence and apply the corresponding negative debt.
    /// Call before enqueueing primer silence buffers into the AudioQueue.
    /// Replaces primeDebt(); also records _primerPendingSamples so calibrate()
    /// can re-apply the exact remaining debt after a position reset.
    func startPrimer(bufferCount: Int, bytesPerBuffer: Int, channels: Int32) {
        let bytesPerSample = Int(channels) * 4
        guard bytesPerSample > 0 else { return }
        let samples = Int64(bufferCount * bytesPerBuffer / bytesPerSample)
        lock.withLock {
            _primerPendingSamples = samples
            _consumedSamples -= samples
        }
    }

    /// Hard reset to a specific position. Clears all primer tracking.
    /// Use for stop() and the initial seek() call — situations where the audio
    /// queue is fully disposed and rebuilt from scratch with fresh primers.
    func reset(to time: Double, sampleRate: Int32) {
        let sr = sampleRate > 0 ? sampleRate : 44100
        lock.withLock {
            self.sampleRate = sr
            _consumedSamples = Int64(time * Double(sr))
            _primerPendingSamples = 0
        }
    }

    /// Calibration reset: atomically move the playback position to `time`
    /// while re-applying the remaining primer debt.
    ///
    /// After a seek, AudioUnitOutput enqueues 3 silence primer buffers before
    /// real audio, then needsClockCalibration fires to align the clock to the
    /// first decoded video frame.  A plain reset() wipes the primer debt, so
    /// when the still-pending primer callbacks fire they push audioTime past
    /// the calibration target by up to 32ms — the user-visible AV desync.
    ///
    /// calibrate() fixes this by reading _primerPendingSamples atomically and
    /// subtracting it from the new position.  Any primer callback that fires
    /// before this call already decremented _primerPendingSamples (via
    /// advancePrimer), so only the truly remaining debt is re-applied.  After
    /// all pending primers complete, audioTime converges exactly to `time`.
    func calibrate(to time: Double, sampleRate: Int32) {
        let sr = sampleRate > 0 ? sampleRate : 44100
        lock.withLock {
            self.sampleRate = sr
            _consumedSamples = Int64(time * Double(sr)) - _primerPendingSamples
        }
    }
}
