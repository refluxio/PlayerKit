import AVFoundation
import Foundation
import AudioToolbox
import CoreAudio
import os
import PlayerKit

private let logger = Logger(subsystem: "io.reflux.PlayerKit", category: "audio.output")

public final class AudioUnitOutput: AudioOutputBackend {
    /// Guards `audioQueue`, `running`, `paused`, `bufferedFrameCount`, `enqueuedFrames`.
    /// The AudioQueue callback runs on an internal AudioToolbox thread and calls
    /// back into `_callbackConsumed`; dispose is synchronous (inSync=true), so
    /// we must NOT hold the lock during AudioQueueDispose or we'd deadlock when
    /// the callback tries to acquire it.  See stop() for the swap-then-dispose
    /// pattern.
    private let lock = NSLock()

    private var audioQueue: AudioQueueRef?
    private let clock: AudioClock
    private var _channels: Int32 = 2
    private var enqueuedFrames = 0
    var bufferedFrameCount = 0
    private var running = false
    private var paused = false

    public let supportsPassthrough: Bool = false

    public var bufferedDuration: Double {
        // Approximate: assume 1024 samples per frame at the output sample rate.
        Double(bufferedFrameCount) * 1024.0 / Double(clock.sampleRate)
    }

    init(clock: AudioClock) {
        self.clock = clock
    }

    deinit { stop() }

    /// Configure the output for a given stream. AudioQueue is already configured
    /// in start(), so this is a no-op for AudioUnitOutput.
    public func configure(streamInfo: AudioStreamInfo) async throws {
        // no-op
    }

    /// Convert an AVAudioPCMBuffer to a PCMFrame and enqueue it.
    public func outputPCM(_ buffer: AVAudioPCMBuffer, pts: Double) {
        guard let floatData = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        let totalSamples = frameCount * channelCount
        var data = Data(count: totalSamples * 4)
        data.withUnsafeMutableBytes { raw in
            let dst = raw.assumingMemoryBound(to: Float.self)
            for ch in 0..<channelCount {
                let src = floatData[ch]
                for i in 0..<frameCount {
                    dst[i * channelCount + ch] = src[i]
                }
            }
        }
        let frame = PCMFrame(data: data, pts: pts, sampleCount: frameCount)
        enqueue(frame)
    }

    /// Compressed passthrough is not supported. No-op.
    public func outputCompressed(_ packet: Data, pts: Double, codec: String) {
        // no-op: AudioUnitOutput does not support passthrough
    }

    func start(sampleRate: Int32, channels: Int32) {
        // Dispose any pre-existing queue first (swap-then-dispose to avoid
        // holding the lock during the synchronous AudioQueueDispose).
        let (oldQueue, _) = disposeUnderLock()
        if let old = oldQueue {
            AudioQueueDispose(old, true)
        }

        let sr = sampleRate > 0 ? sampleRate : 44100
        let ch = channels > 0 ? channels : 2
        _channels = ch

        var format = AudioStreamBasicDescription(
            mSampleRate: Float64(sr),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(ch) * 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(ch) * 4,
            mChannelsPerFrame: UInt32(ch),
            mBitsPerChannel: 32,
            mReserved: 0
        )

        var newQueue: AudioQueueRef?
        let rc = AudioQueueNewOutput(&format, audioQueueCallback,
                                     Unmanaged.passUnretained(self).toOpaque(),
                                     nil, nil, 0, &newQueue)
        guard rc == noErr, let queue = newQueue else {
            logger.error("AudioQueueNewOutput FAILED: \(rc)")
            return
        }

        // Primer: 3 silence buffers to prevent initial underrun.
        // primeDebt() cancels the clock offset they would otherwise introduce.
        let primerCount = 3
        let primerBytes = 4096
        clock.primeDebt(bufferCount: primerCount, bytesPerBuffer: primerBytes, channels: ch)
        for _ in 0..<primerCount {
            var buffer: AudioQueueBufferRef?
            AudioQueueAllocateBuffer(queue, UInt32(primerBytes), &buffer)
            if let buf = buffer {
                memset(buf.pointee.mAudioData, 0, primerBytes)
                buf.pointee.mAudioDataByteSize = UInt32(primerBytes)
                AudioQueueEnqueueBuffer(queue, buf, 0, nil)
            }
        }

        AudioQueueStart(queue, nil)

        // Swap in the new queue atomically.  Any in-flight enqueue() that was
        // waiting on the lock will see the new queue, not the disposed one.
        lock.lock()
        audioQueue = queue
        running = true
        paused = false
        enqueuedFrames = 0
        bufferedFrameCount = 0
        lock.unlock()

        logger.info("started: \(sr)Hz \(ch)ch")
    }

    /// Atomically null out `audioQueue` and return the previous value (plus the
    /// final enqueued-frame count for logging) so the queue can be disposed
    /// outside the lock.  After this returns, no enqueue() can observe the old
    /// queue pointer, so disposing it is safe from the producer side; and
    /// because enqueue() holds the lock across its AudioQueue calls, dispose
    /// won't start until any in-flight enqueue() finishes.
    private func disposeUnderLock() -> (AudioQueueRef?, Int) {
        lock.lock()
        let old = audioQueue
        let finalEnqueued = enqueuedFrames
        audioQueue = nil
        running = false
        paused = false
        bufferedFrameCount = 0
        enqueuedFrames = 0
        lock.unlock()
        return (old, finalEnqueued)
    }

    func stop() {
        let (oldQueue, finalEnqueued) = disposeUnderLock()
        if let old = oldQueue {
            AudioQueueDispose(old, true)
            if finalEnqueued > 0 {
                logger.info("stopped, enqueued \(finalEnqueued) frames total")
            }
        }
    }

    /// Flush pending audio buffers. Resets state without disposing the queue.
    public func flush() {
        // Same swap-then-dispose as stop(): null the queue reference under the
        // lock, then dispose outside the lock so the AudioQueue callback can't
        // deadlock against us.  A fresh queue will be created by start().
        let (oldQueue, _) = disposeUnderLock()
        if let old = oldQueue {
            AudioQueueDispose(old, true)
        }
    }

    /// Pause without destroying the queue or resetting the clock.
    public func pause() {
        lock.lock()
        let queue = audioQueue
        if !paused { paused = true }
        lock.unlock()
        if let queue {
            AudioQueuePause(queue)
        }
    }

    /// Resume after pause().
    public func resume() {
        lock.lock()
        let queue = audioQueue
        if paused { paused = false }
        lock.unlock()
        if let queue {
            AudioQueueStart(queue, nil)
        }
    }

    func enqueue(_ frame: PCMFrame) {
        // Hold the lock across allocate+copy+enqueue so the dispose path can't
        // tear down the queue between the guard and the AudioQueue calls.
        // disposeUnderLock() also takes this lock, so it waits for any in-flight
        // enqueue() to finish before nulling the queue and disposing it.
        lock.lock()
        guard let queue = audioQueue else {
            lock.unlock()
            return
        }
        var buffer: AudioQueueBufferRef?
        let rc = AudioQueueAllocateBuffer(queue, UInt32(frame.data.count), &buffer)
        guard rc == noErr, let buf = buffer else {
            lock.unlock()
            logger.error("AudioQueueAllocateBuffer FAILED: \(rc)")
            return
        }
        frame.data.copyBytes(to: buf.pointee.mAudioData.assumingMemoryBound(to: UInt8.self),
                             count: frame.data.count)
        buf.pointee.mAudioDataByteSize = UInt32(frame.data.count)
        AudioQueueEnqueueBuffer(queue, buf, 0, nil)
        enqueuedFrames += 1
        bufferedFrameCount += 1
        let shouldRestart = !paused
        lock.unlock()

        // Only (re)start if not deliberately paused by the buffering state machine.
        if shouldRestart { AudioQueueStart(queue, nil) }
    }

    /// Called from the AudioQueue callback — do not call directly.
    func _callbackConsumed(byteCount: Int) {
        lock.lock()
        if bufferedFrameCount > 0 { bufferedFrameCount &-= 1 }
        let ch = _channels
        lock.unlock()
        clock.advance(byteCount: byteCount, channels: ch)
    }

    /// Proxy for clock.audioTime.
    var audioTime: Double {
        clock.audioTime
    }

    /// Proxy for clock.reset(to:sampleRate:).
    func resetClock(to time: Double, sampleRate: Int32 = 44100) {
        clock.reset(to: time, sampleRate: sampleRate)
    }
}

private func audioQueueCallback(_ userData: UnsafeMutableRawPointer?,
                                 _ queue: AudioQueueRef,
                                 _ buffer: AudioQueueBufferRef) {
    guard let p = userData else { AudioQueueFreeBuffer(queue, buffer); return }
    let output = Unmanaged<AudioUnitOutput>.fromOpaque(p).takeUnretainedValue()
    output._callbackConsumed(byteCount: Int(buffer.pointee.mAudioDataByteSize))
    AudioQueueFreeBuffer(queue, buffer)
}
