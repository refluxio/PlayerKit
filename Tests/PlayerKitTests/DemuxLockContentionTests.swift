import XCTest
import Foundation
@testable import PlayerKitNative

/// Regression test for the 2026-09-30 "Reflux is killed by the watchdog while
/// casting" crash (0x8BADF00D, scene-update transgression, 10 s).
///
/// The demux loop holds `demuxLock` across `demuxer.readPacket()`, which for an
/// HTTP source is a blocking network read. `pause()`, `resume()` and
/// `startDemuxLoop()` run on the MAIN thread (app lifecycle / PiP callbacks) and
/// only need to read or write the loop's state flags, but took the same
/// `demuxLock` — so a stalled network read froze the main thread until iOS
/// killed the app. The crash report showed exactly that: main thread in
/// `NativeBackend.resume()` → `NSLock.withLock` (`__psynch_mutexwait`), demux
/// thread in `FFmpegDemuxer.readPacket()` → `poll`.
///
/// The test serves the fixture over a local HTTP server that stops sending
/// part-way (keeps the socket open, sends nothing), waits for the demux loop to
/// be blocked in that read, then requires lifecycle calls on the main thread to
/// return promptly.
final class DemuxLockContentionTests: XCTestCase {

    private var savedMute = false
    override func setUp() {
        continueAfterFailure = false
        savedMute = AudioUnitOutput.mutedForTesting
        AudioUnitOutput.mutedForTesting = true
    }
    override func tearDown() { AudioUnitOutput.mutedForTesting = savedMute }

    private func startStalledPlayback(_ server: StallingHTTPServer) async throws -> NativeBackend {
        let backend = try await MainActor.run { try NativeBackend() }
        let url = URL(string: "http://127.0.0.1:\(server.port)/f.mkv")!
        await MainActor.run { backend.play(url: url, headers: [:], seekTo: nil) }

        // Wait until the loop has drained everything the server will send and is
        // sitting in the blocking read.
        let deadline = Date().addingTimeInterval(25)
        while !server.mainConnectionStalled && Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(server.mainConnectionStalled, "the demux loop never reached the stalled read")
        // The loop reads ahead only ~2 s of media and sleeps when it is ahead of the
        // audio clock (lock released); give it time to consume what was served and
        // block in the stalled read (lock held).
        try await Task.sleep(nanoseconds: 7_000_000_000)
        return backend
    }

    /// Runs `body` on the main thread and reports whether it returned within `seconds`.
    /// (Waits from a non-main thread: if the main thread blocks, the test must fail
    /// instead of hanging the runner.)
    private func returnsPromptlyOnMain(within seconds: Double,
                                       _ body: @escaping @MainActor () -> Void) -> Bool {
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            MainActor.assumeIsolated { body() }
            done.signal()
        }
        return done.wait(timeout: .now() + seconds) == .success
    }

    func testResumeDoesNotBlockMainThreadWhileDemuxReadIsStalled() async throws {
        let server = try StallingHTTPServer(fixture: "speed_dts48_51", ext: "mkv", stallAfter: 700_000)
        defer { server.close() }
        let backend = try await startStalledPlayback(server)

        let ok = returnsPromptlyOnMain(within: 3) { backend.resume() }
        server.close()   // unblock the read so a failing run can still clean up
        XCTAssertTrue(ok, "resume() blocked the main thread on demuxLock while the demux loop was stuck in a network read")
        await MainActor.run { backend.stop() }
    }

    func testPauseDoesNotBlockMainThreadWhileDemuxReadIsStalled() async throws {
        let server = try StallingHTTPServer(fixture: "speed_dts48_51", ext: "mkv", stallAfter: 700_000)
        defer { server.close() }
        let backend = try await startStalledPlayback(server)

        let ok = returnsPromptlyOnMain(within: 3) { backend.pause() }
        server.close()
        XCTAssertTrue(ok, "pause() blocked the main thread on demuxLock while the demux loop was stuck in a network read")
        await MainActor.run { backend.stop() }
    }
}

// MARK: - Test server

/// Minimal HTTP/1.1 server (Range-aware). The FIRST connection serves the file
/// linearly and then goes silent after `stallAfter` bytes, holding the socket open
/// — a network read that never completes. Any later connection (FFmpeg reopens
/// for seeks / duration probing) is served in full so opening the stream works.
private final class StallingHTTPServer: @unchecked Sendable {
    private let data: Data
    private let stallAfter: Int
    private var listenFD: Int32 = -1
    private(set) var port: UInt16 = 0
    private let lock = NSLock()
    private var connections: [Int32] = []
    private var closed = false
    private var connectionCount = 0
    private var stalled = false

    var mainConnectionStalled: Bool { lock.lock(); defer { lock.unlock() }; return stalled }

    init(fixture: String, ext: String, stallAfter: Int) throws {
        let url = Bundle.module.url(forResource: fixture, withExtension: ext, subdirectory: "Fixtures")!
        self.data = try Data(contentsOf: url)
        self.stallAfter = stallAfter

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 8) == 0 else { throw NSError(domain: "StallingHTTPServer", code: 1) }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(fd, $0, &len) }
        }
        self.port = UInt16(bigEndian: addr.sin_port)
        self.listenFD = fd
        Thread { [self] in acceptLoop() }.start()
    }

    func close() {
        lock.lock()
        closed = true
        let fds = connections
        connections.removeAll()
        let l = listenFD
        listenFD = -1
        lock.unlock()
        for fd in fds { shutdown(fd, SHUT_RDWR); Darwin.close(fd) }
        if l >= 0 { shutdown(l, SHUT_RDWR); Darwin.close(l) }
    }

    private func acceptLoop() {
        while true {
            lock.lock(); let l = listenFD; lock.unlock()
            guard l >= 0 else { return }
            let conn = accept(l, nil, nil)
            guard conn >= 0 else { return }
            lock.lock()
            connections.append(conn)
            connectionCount += 1
            let isMain = connectionCount == 1
            lock.unlock()
            Thread { [self] in serve(conn, isMain: isMain) }.start()
        }
    }

    private func serve(_ conn: Int32, isMain: Bool) {
        var request = Data()
        var byte: UInt8 = 0
        while !request.suffix(4).elementsEqual([13, 10, 13, 10]) {
            guard recv(conn, &byte, 1, 0) == 1 else { return }
            request.append(byte)
        }
        var start = 0
        var hasRange = false
        if let text = String(data: request, encoding: .utf8),
           let line = text.split(separator: "\r\n").first(where: { $0.lowercased().hasPrefix("range:") }),
           let eq = line.firstIndex(of: "="), let dash = line.firstIndex(of: "-") {
            hasRange = true
            start = Int(line[line.index(after: eq)..<dash]) ?? 0
        }
        let total = data.count
        var head = hasRange ? "HTTP/1.1 206 Partial Content\r\n" : "HTTP/1.1 200 OK\r\n"
        head += "Content-Type: video/x-matroska\r\nAccept-Ranges: bytes\r\n"
        head += "Content-Length: \(total - start)\r\n"
        if hasRange { head += "Content-Range: bytes \(start)-\(total - 1)/\(total)\r\n" }
        head += "Connection: keep-alive\r\n\r\n"
        _ = head.withCString { send(conn, $0, strlen($0), 0) }

        let limit = isMain ? min(total, stallAfter) : total
        var offset = start
        while offset < limit {
            let n = min(16 * 1024, limit - offset)
            let sent = data.withUnsafeBytes { send(conn, $0.baseAddress!.advanced(by: offset), n, 0) }
            if sent <= 0 { return }
            offset += sent
        }
        if isMain {
            lock.lock(); stalled = true; lock.unlock()
            // Hold the connection open and silent until close().
            while true {
                lock.lock(); let c = closed; lock.unlock()
                if c { return }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
    }
}
