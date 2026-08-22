import Foundation

/// Random-access byte stream reader for custom I/O playback.
///
/// Implementations feed bytes to ffmpeg via `avio_alloc_context`,
/// bypassing ffmpeg's built-in HTTP protocol. This gives full control
/// over CDN interactions: Range requests, URL refresh, connection reuse,
/// read-ahead buffering.
///
/// The reader must be `Sendable` — it is created on the MainActor but
/// called from ffmpeg's demuxer background thread.
public protocol MediaRandomAccessReader: AnyObject, Sendable {
    /// Total file size in bytes.
    /// Called once by AVIOBridge on the first seek (AVSEEK_SIZE).
    /// Synchronous — called from ffmpeg's I/O thread, must not block on async scheduling.
    var totalSize: Int64 { get throws }

    /// Read up to `length` bytes at `offset` into `buffer`.
    /// Returns the actual number of bytes read (0 = EOF).
    /// The buffer is ffmpeg's internal AVIO buffer — write directly, no copy.
    ///
    /// Synchronous — called from ffmpeg's I/O thread via avio_alloc_context
    /// callbacks. Implementations must NOT use Swift async/await internally;
    /// use synchronous APIs (e.g. URLSession data task + semaphore) instead.
    ///
    /// Concurrency contract: `read` may be invoked concurrently from
    /// multiple threads. MultiClipDemuxer, for example, pre-opens the next
    /// clip's reader in the background while the current clip's reader is
    /// still being read, and in real deployments the readers of adjacent
    /// clips may share the same underlying connection/resource.
    /// Implementations must therefore be thread-safe themselves, or the
    /// caller must guarantee external serialization of the underlying
    /// shared resource.
    func read(offset: Int64, length: Int, into buffer: UnsafeMutableRawBufferPointer) throws -> Int

    /// Release resources (close connections, invalidate sessions).
    /// Called by the player when playback stops.
    func close()

    /// Highest byte offset that has been downloaded and is available in the reader's
    /// internal buffer. Used to compute the seek-bar buffer indicator.
    /// Return -1 if unknown (default).
    var downloadedUpToOffset: Int64 { get }

    /// Total byte count if already known at reader construction time (e.g. from
    /// cloud-file metadata).  AVIOBridge uses this to pre-populate cachedSize so
    /// the buffer-progress indicator works even when FFmpeg never issues AVSEEK_SIZE
    /// (which happens for container formats that embed duration in their headers).
    /// Return -1 if unknown (default).
    var knownTotalBytes: Int64 { get }
}

public extension MediaRandomAccessReader {
    var downloadedUpToOffset: Int64 { -1 }
    var knownTotalBytes: Int64 { -1 }
}
