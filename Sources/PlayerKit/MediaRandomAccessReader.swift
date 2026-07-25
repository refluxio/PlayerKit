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
    var totalSize: Int64 { get async throws }

    /// Read up to `length` bytes at `offset` into `buffer`.
    /// Returns the actual number of bytes read (0 = EOF).
    /// The buffer is ffmpeg's internal AVIO buffer — write directly, no copy.
    func read(offset: Int64, length: Int, into buffer: UnsafeMutableRawBufferPointer) async throws -> Int

    /// Release resources (close connections, invalidate sessions).
    /// Called by the player when playback stops.
    func close()
}
