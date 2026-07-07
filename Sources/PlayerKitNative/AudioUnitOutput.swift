import AVFoundation
import Foundation
import AudioToolbox
import CoreAudio
import os
import PlayerKit

private let logger = Logger(subsystem: "io.reflux.PlayerKit", category: "audio.output")

public final class AudioUnitOutput: AudioOutputBackend {
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
        stop()
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

        let rc = AudioQueueNewOutput(&format, audioQueueCallback,
                                     Unmanaged.passUnretained(self).toOpaque(),
                                     nil, nil, 0, &audioQueue)
        guard rc == noErr, let queue = audioQueue else {
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
        running = true
        enqueuedFrames = 0
        bufferedFrameCount = 0
        logger.info("started: \(sr)Hz \(ch)ch")
    }

    func stop() {
        guard let queue = audioQueue else { return }
        AudioQueueStop(queue, true)
        AudioQueueDispose(queue, true)
        audioQueue = nil
        running = false
        paused = false
        bufferedFrameCount = 0
        if enqueuedFrames > 0 {
            logger.info("stopped, enqueued \(self.enqueuedFrames) frames total")
        }
    }

    /// Flush pending audio buffers. Resets state without disposing the queue.
    public func flush() {
        guard let queue = audioQueue else { return }
        AudioQueueStop(queue, true)
        bufferedFrameCount = 0
        enqueuedFrames = 0
    }

    /// Pause without destroying the queue or resetting the clock.
    public func pause() {
        guard let queue = audioQueue, !paused else { return }
        paused = true
        AudioQueuePause(queue)
    }

    /// Resume after pause().
    public func resume() {
        guard let queue = audioQueue, paused else { return }
        paused = false
        AudioQueueStart(queue, nil)
    }

    func enqueue(_ frame: PCMFrame) {
        guard let queue = audioQueue else { return }
        var buffer: AudioQueueBufferRef?
        let rc = AudioQueueAllocateBuffer(queue, UInt32(frame.data.count), &buffer)
        guard rc == noErr, let buf = buffer else {
            logger.error("AudioQueueAllocateBuffer FAILED: \(rc)")
            return
        }
        frame.data.copyBytes(to: buf.pointee.mAudioData.assumingMemoryBound(to: UInt8.self),
                             count: frame.data.count)
        buf.pointee.mAudioDataByteSize = UInt32(frame.data.count)
        AudioQueueEnqueueBuffer(queue, buf, 0, nil)
        enqueuedFrames += 1
        bufferedFrameCount += 1
        // Only (re)start if not deliberately paused by the buffering state machine.
        if !paused { AudioQueueStart(queue, nil) }
    }

    /// Called from the AudioQueue callback — do not call directly.
    func _callbackConsumed(byteCount: Int) {
        if bufferedFrameCount > 0 { bufferedFrameCount &-= 1 }
        clock.advance(byteCount: byteCount, channels: _channels)
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
