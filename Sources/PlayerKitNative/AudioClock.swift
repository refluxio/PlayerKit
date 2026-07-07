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

    /// Called by AudioQueue callback when a buffer is consumed.
    func advance(byteCount: Int, channels: Int32) {
        let bytesPerSample = Int(channels) * 4  // float32 interleaved
        guard bytesPerSample > 0 else { return }
        lock.withLock { _consumedSamples += Int64(byteCount / bytesPerSample) }
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
