import AVFoundation
import Foundation
import AudioToolbox
import CoreAudio
import os
import PlayerKit

private let logger = Logger(subsystem: "io.reflex.PlayerKit", category: "audio.output")

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
    /// How many primer-buffer callbacks have not yet fired. Guarded by lock.
    /// Decremented in _callbackConsumed; used to route primer callbacks to
    /// clock.advancePrimer() so _primerPendingSamples stays accurate.
    private var pendingPrimerCallbacks: Int = 0

    // Test seams (off by default; production never sets them). With
    // `tracksPlayedContent` on, the source-content PTS of every enqueued buffer is
    // queued (buffers complete in order) and, as buffers finish playing, the content
    // position the device has actually played is recorded — so tests can compare what
    // is HEARD with what is SHOWN. `mutedForTesting` sets the queue volume to 0 so
    // tests can play real content silently. Guarded by lock.
    nonisolated(unsafe) static var tracksPlayedContent = false
    nonisolated(unsafe) static var mutedForTesting = false

    /// Test seams for the AudioQueue control entry points. Production uses the
    /// real functions; tests substitute slow/stuck implementations to prove the
    /// control calls never block their caller (see the non-blocking contract
    /// tests). Reset in test tearDown.
    nonisolated(unsafe) static var pauseImpl: (AudioQueueRef) -> OSStatus = { AudioQueuePause($0) }
    nonisolated(unsafe) static var startImpl: (AudioQueueRef) -> OSStatus = { AudioQueueStart($0, nil) }

    /// Serial queue that owns every AudioQueue control call (Pause/Start).
    ///
    /// These calls dispatch_sync into AudioToolbox's internal server context —
    /// the same serial context the macOS CVDisplayLink tick runs on. The
    /// 2026-10-10 seek freeze: the display tick (jitter pop → underrun) called
    /// pause() and its AudioQueuePause got stuck in BeginPause's IO-cycle wait
    /// on that context, while the demux thread (jitter append → refill resume)
    /// dispatch_sync'd AudioQueueStart behind it — pipeline-wide deadlock, no
    /// supply, silent logs, ~50% CPU. Hot paths (jitter append/pop callbacks,
    /// seek path) must therefore never block on a control call: the flag flips
    /// synchronously (enqueue cap / clock semantics unchanged) and only the
    /// AudioQueue call is dispatched here. Serial ⇒ pause→resume order is
    /// preserved; the queue ref is re-read under the lock inside the block so
    /// a stop()/flush() that ran first is skipped.
    private let controlQueue = DispatchQueue(label: "io.reflex.PlayerKit.audio.control")

    private func currentQueueLocked() -> AudioQueueRef? {
        lock.lock(); defer { lock.unlock() }
        return audioQueue
    }
    private var contentFifo: [(pts: Double, dur: Double)] = []
    private var playedContentEndPTS: Double = .nan

    /// Test seam: source-content PTS (seconds) up to which audio has been fully
    /// played by the device; NaN until a buffer with a known PTS completed.
    func playedContentEnd() -> Double {
        lock.lock(); defer { lock.unlock() }
        return playedContentEndPTS
    }

    /// Test seam: whether a live AudioQueue exists (start() succeeded). Tests
    /// skip the control-call contracts when the environment has no device.
    var hasQueueForTesting: Bool {
        lock.lock(); defer { lock.unlock() }
        return audioQueue != nil
    }

    /// Upper bound (seconds of audio) the queue may hold while it is paused.
    var maxPausedBufferSeconds: Double = 5.0

    /// Samples (per channel) currently queued and not yet played, excluding the
    /// silent primer buffers. Guarded by lock. Lets the paused cap be expressed
    /// in seconds instead of in buffers — a buffer is 512 samples (10.7 ms) for
    /// DTS but 1024 (21 ms) for AAC, so a buffer-count cap meant wildly
    /// different amounts of audio per codec.
    private var bufferedSamples = 0

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

        if Self.mutedForTesting { AudioQueueSetParameter(queue, kAudioQueueParam_Volume, 0) }

        // Primer: 3 silence buffers to prevent initial underrun.
        // startPrimer() creates a negative debt and records the pending count so
        // AudioClock.calibrate() can re-apply the exact remaining debt after a
        // position reset without losing the primer cancellation.
        let primerCount = 3
        let primerBytes = 4096
        clock.startPrimer(bufferCount: primerCount, bytesPerBuffer: primerBytes, channels: ch)
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
        pendingPrimerCallbacks = primerCount
        bufferedSamples = 0
        contentFifo.removeAll(); playedContentEndPTS = .nan
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
        pendingPrimerCallbacks = 0
        bufferedSamples = 0
        contentFifo.removeAll(); playedContentEndPTS = .nan
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

    /// Pause without destroying the queue or resetting the clock. Non-blocking:
    /// the AudioQueuePause is dispatched onto `controlQueue` (see its doc).
    public func pause() {
        lock.lock()
        let queue = audioQueue
        if !paused { paused = true }
        lock.unlock()
        guard queue != nil else { return }
        controlQueue.async { [weak self] in
            guard let self, let q = self.currentQueueLocked() else { return }
            _ = Self.pauseImpl(q)
        }
    }

    /// Resume after pause(). Non-blocking, same dispatch as pause().
    public func resume() {
        lock.lock()
        let queue = audioQueue
        if paused { paused = false }
        lock.unlock()
        guard queue != nil else {
            // 音频队列尚不存在时被要求恢复:start() 未跑或队列已 dispose。
            // 若此后不再有 .playing 翻转,音频会永久暂停 → audioClock 卡 0
            // → 同步旁路加速/卡死。这是 _finishOpen 竞态的直接症状。
            logger.warning("resume() called but audioQueue is nil")
            return
        }
        controlQueue.async { [weak self] in
            guard let self, let q = self.currentQueueLocked() else { return }
            let rc = Self.startImpl(q)
            if rc != noErr {
                logger.error("AudioQueueStart(resume) FAILED: \(rc)")
            }
        }
    }

    func enqueue(_ frame: PCMFrame, contentPts: Double = .nan) {
        // Hold the lock across allocate+copy+enqueue so the dispose path can't
        // tear down the queue between the guard and the AudioQueue calls.
        // disposeUnderLock() also takes this lock, so it waits for any in-flight
        // enqueue() to finish before nulling the queue and disposing it.
        lock.lock()
        guard let queue = audioQueue else {
            lock.unlock()
            return
        }
        // Drop frames when the queue is paused and has accumulated too much audio.
        // The demux has no audio throttle and reads from cache at many ×real-time,
        // so without this cap the AudioQueue accumulates minutes of audio while
        // buffering. When resume() is called, all frames drain at real-time,
        // advancing the audio clock far ahead of video — the skip-behind guard
        // then dumps all video frames from the jitter buffer → stuck.
        //
        // The cap is in SECONDS of audio. It used to be "60 buffers", which was
        // meant as ≈2 s but is only 0.64 s for 512-sample DTS frames — shorter
        // than the ~1.2–1.4 s the video jitter buffer needs to fill after every
        // start/resume. Every frame beyond it was silently discarded, so the
        // audible content jumped ahead of the picture by the dropped span
        // (measured: 0.555 s at each start, 0.57–0.74 s more after each resume).
        // The default (5 s) is well above any normal buffering window and keeps
        // the accumulation bounded.
        if paused, Double(bufferedSamples) >= maxPausedBufferSeconds * Double(max(1, clock.sampleRate)) {
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
        if Self.tracksPlayedContent { contentFifo.append((contentPts, Double(frame.sampleCount) / Double(max(1, clock.sampleRate)))) }
        enqueuedFrames += 1
        bufferedFrameCount += 1
        bufferedSamples += frame.sampleCount
        let shouldRestart = !paused
        lock.unlock()

        // Only (re)start if not deliberately paused by the buffering state machine.
        if shouldRestart {
            let rc = AudioQueueStart(queue, nil)
            if rc != noErr {
                logger.error("AudioQueueStart(enqueue) FAILED: \(rc)")
            }
        }
    }

    /// Called from the AudioQueue callback — do not call directly.
    func _callbackConsumed(byteCount: Int) {
        lock.lock()
        if bufferedFrameCount > 0 { bufferedFrameCount &-= 1 }
        let ch = _channels
        let isPrimer = pendingPrimerCallbacks > 0
        if isPrimer { pendingPrimerCallbacks -= 1 }
        else {
            bufferedSamples = max(0, bufferedSamples - byteCount / (max(1, Int(ch)) * 4))
            if Self.tracksPlayedContent, !contentFifo.isEmpty {
                let done = contentFifo.removeFirst()
                if done.pts.isFinite { playedContentEndPTS = done.pts + done.dur }
            }
        }
        lock.unlock()
        // Route primer callbacks to advancePrimer() so _primerPendingSamples in
        // AudioClock stays accurate for calibrate() after a position reset.
        if isPrimer {
            clock.advancePrimer(byteCount: byteCount, channels: ch)
        } else {
            clock.advance(byteCount: byteCount, channels: ch)
        }
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
