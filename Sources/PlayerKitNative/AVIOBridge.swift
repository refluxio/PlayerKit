// Sources/PlayerKitNative/AVIOBridge.swift
import Foundation
import PlayerKit
import CFFmpeg

/// Bridges a Swift `MediaRandomAccessReader` to ffmpeg's synchronous C I/O callbacks.
///
/// ffmpeg's `read_packet` and `seek` are C function pointers (`@convention(c)`).
/// They cannot call Swift async functions directly. This class uses a
/// `DispatchSemaphore` to block the C callback thread while a `Task.detached`
/// executes the async `reader.read()` / `reader.totalSize`. When the Task
/// completes, it signals the semaphore and the C callback returns.
///
/// Lifecycle: owned by `FFmpegDemuxer`. `createAVIOContext()` is called
/// before `avformat_open_input`. `free()` is called in `FFmpegDemuxer.close()`.
/// `AVFMT_FLAG_CUSTOM_IO` prevents ffmpeg from auto-closing the pb.
final class AVIOBridge: @unchecked Sendable {
    // AVERROR_EOF, mirrored from libavutil/error.h (FFERRTAG('E','O','F',' ')).
    // The Swift importer can't bridge that macro (function-like macro chain),
    // so it's reproduced here rather than hardcoding the resulting literal.
    private static let averrorEOF: Int32 = {
        let tag = Int32(bitPattern: UInt32(UInt8(ascii: "E"))
            | (UInt32(UInt8(ascii: "O")) << 8)
            | (UInt32(UInt8(ascii: "F")) << 16)
            | (UInt32(UInt8(ascii: " ")) << 24))
        return -tag
    }()

    private let reader: any MediaRandomAccessReader
    private let bufferSize: Int = 32768  // 32KB — ffmpeg standard AVIO buffer
    private var ioContext: UnsafeMutablePointer<AVIOContext>?
    private var buffer: UnsafeMutablePointer<UInt8>?
    private var selfPointer: Unmanaged<AVIOBridge>?

    /// Current read position (byte offset). Updated by read (increment)
    /// and seek (set). Only accessed from ffmpeg's I/O thread — no lock needed.
    private var currentOffset: Int64 = 0

    /// Cached file size. Fetched on first AVSEEK_SIZE query.
    private var cachedSize: Int64 = -1

    /// Highest byte offset available in the reader's internal buffer (for buffer bar).
    var downloadedUpToOffset: Int64 { reader.downloadedUpToOffset }
    var totalBytes: Int64 { cachedSize }

    init(reader: any MediaRandomAccessReader) {
        self.reader = reader
        // Pre-populate from reader's known size so the buffer-progress indicator
        // works when FFmpeg never issues AVSEEK_SIZE (common for MKV/MP4 streams
        // that embed duration in container headers — FFmpeg skips the size query).
        let known = reader.knownTotalBytes
        if known > 0 { cachedSize = known }
    }

    /// Allocate an AVIOContext with read/seek callbacks.
    /// The returned pointer should be assigned to `formatCtx.pointee.pb`.
    func createAVIOContext() -> UnsafeMutablePointer<AVIOContext>? {
        let buf: UnsafeMutablePointer<UInt8> = .allocate(capacity: bufferSize)
        buffer = buf

        selfPointer = Unmanaged.passUnretained(self)
        let opaque = selfPointer!.toOpaque()

        guard let ctx = avio_alloc_context(
            buf,
            Int32(bufferSize),
            0,           // write_flag = 0 (read-only)
            opaque,
            AVIOBridge.readCallback,
            nil,         // write_packet (not needed)
            AVIOBridge.seekCallback
        ) else {
            buf.deallocate()
            buffer = nil
            selfPointer = nil
            return nil
        }

        // Mark as seekable so ffmpeg uses Range-based seeks.
        ctx.pointee.seekable = Int32(AVIO_SEEKABLE_NORMAL)

        ioContext = ctx
        return ctx
    }

    /// Free the AVIOContext and release resources.
    /// Called by FFmpegDemuxer.close(). avio_context_free also frees the buffer.
    func free() {
        if ioContext != nil {
            avio_context_free(&ioContext)
            ioContext = nil
            buffer = nil  // freed by avio_context_free
        }
        // passUnretained does NOT increment the retain count, so we must NOT
        // call release() here — doing so would over-release the AVIOBridge and
        // cause EXC_BAD_ACCESS when the owning FFmpegDemuxer releases its strong
        // reference. Just clear the pointer so no dangling C callback can fire.
        selfPointer = nil
        reader.close()
    }

    // MARK: - C Callbacks (@convention(c))

    private static let readCallback: @convention(c) (
        UnsafeMutableRawPointer?,  // opaque
        UnsafeMutablePointer<UInt8>?,  // buf
        Int32  // buf_size
    ) -> Int32 = { opaque, buf, bufSize in
        guard let opaque, let buf else { return -1 }
        let bridge = Unmanaged<AVIOBridge>.fromOpaque(opaque).takeUnretainedValue()
        return bridge.doRead(into: buf, length: Int(bufSize))
    }

    private static let seekCallback: @convention(c) (
        UnsafeMutableRawPointer?,  // opaque
        Int64,  // offset
        Int32   // whence
    ) -> Int64 = { opaque, offset, whence in
        guard let opaque else { return -1 }
        let bridge = Unmanaged<AVIOBridge>.fromOpaque(opaque).takeUnretainedValue()
        return bridge.doSeek(offset: offset, whence: whence)
    }

    // MARK: - Sync calls (reader is synchronous, called directly from C callbacks)

    private func doRead(into buf: UnsafeMutablePointer<UInt8>, length: Int) -> Int32 {
        let offset = currentOffset
        let bufferPtr = UnsafeMutableRawBufferPointer(start: buf, count: length)

        do {
            let n = try reader.read(offset: offset, length: length, into: bufferPtr)
            // avio.h: read_packet "must never return 0 but rather a proper
            // AVERROR code" for stream protocols. A bare 0 leaves ffmpeg's
            // fill_buffer() without a terminal signal, so it keeps
            // re-invoking this callback at the same offset forever instead
            // of treating the stream as ended.
            guard n > 0 else { return AVIOBridge.averrorEOF }
            currentOffset += Int64(n)
            return Int32(n)
        } catch {
            return -1  // AVERROR
        }
    }

    private func doSeek(offset: Int64, whence: Int32) -> Int64 {
        // AVSEEK_SIZE (0x10000): return total file size
        if whence == 0x10000 {
            if cachedSize < 0 {
                do {
                    cachedSize = try reader.totalSize
                } catch {
                    cachedSize = -1
                }
            }
            return cachedSize
        }

        // SEEK_SET(0) / SEEK_CUR(1) / SEEK_END(2)
        var newPos: Int64 = 0
        switch whence {
        case 0:  newPos = offset                          // SEEK_SET
        case 1:  newPos = currentOffset + offset          // SEEK_CUR
        case 2:  newPos = (cachedSize >= 0 ? cachedSize : 0) + offset  // SEEK_END
        default: return -1
        }
        currentOffset = newPos
        return newPos
    }
}
