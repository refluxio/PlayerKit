import XCTest
import CFFmpeg
import PlayerKit
@testable import PlayerKitNative

/// In-memory MediaRandomAccessReader wrapping a Data blob — enough for
/// FFmpegDemuxer to open/probe/demux, no network involved.
final class InMemoryReader: MediaRandomAccessReader, @unchecked Sendable {
    private let data: Data
    init(data: Data) { self.data = data }
    var totalSize: Int64 { Int64(data.count) }
    func read(offset: Int64, length: Int, into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard offset < data.count else { return 0 }
        let end = min(Int(offset) + length, data.count)
        let n = end - Int(offset)
        data.copyBytes(to: buffer.bindMemory(to: UInt8.self), from: Int(offset)..<end)
        return n
    }
    func close() {}
}

/// Models a cloud CDN session whose close is TERMINAL for every reader that
/// shares it — the Cloud115StreamReader semantics behind C1: once any reader
/// closes the connection, every read on every reader sharing it returns 0
/// (EOF). InMemoryReader.close() being a no-op is exactly why the existing
/// tests could not expose the seam-close bug; these tests must fail before
/// the fix and pass after.
final class TerminatingConnection: @unchecked Sendable {
    private let lock = NSLock()
    private var isClosed = false
    private var closes = 0

    var closed: Bool { lock.lock(); defer { lock.unlock() }; return isClosed }
    var closeCount: Int { lock.lock(); defer { lock.unlock() }; return closes }

    func close() {
        lock.lock(); defer { lock.unlock() }
        isClosed = true
        closes += 1
    }
}

/// A clip reader over a shared `TerminatingConnection`. After the connection
/// is closed, read() returns 0 — EOF for every clip, matching
/// Cloud115StreamReader's post-close behavior.
final class TerminatingReader: MediaRandomAccessReader, @unchecked Sendable {
    private let data: Data
    private let connection: TerminatingConnection
    init(data: Data, connection: TerminatingConnection) {
        self.data = data
        self.connection = connection
    }
    var totalSize: Int64 { Int64(data.count) }
    func read(offset: Int64, length: Int, into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard !connection.closed else { return 0 }
        guard offset < data.count else { return 0 }
        let end = min(Int(offset) + length, data.count)
        let n = end - Int(offset)
        data.copyBytes(to: buffer.bindMemory(to: UInt8.self), from: Int(offset)..<end)
        return n
    }
    func close() { connection.close() }
}

final class MultiClipDemuxerTests: XCTestCase {
    /// Two tiny, independently-generated MPEG-TS clips (each starting its
    /// own PTS near 0 — exactly the "no shared PTS base" scenario this
    /// class exists to handle). Generated fixtures checked into the repo
    /// under Tests/PlayerKitTests/Fixtures/ — see Step 0 below.
    private func loadFixture(_ name: String) -> Data {
        let url = Bundle.module.url(forResource: name, withExtension: "ts", subdirectory: "Fixtures")!
        return try! Data(contentsOf: url)
    }

    func testInitFailsWithMismatchedEmptyClips() {
        XCTAssertNil(MultiClipDemuxer(clips: []))
    }

    func testSequentialPacketsHaveMonotonicRebasedPTS() throws {
        let clip0 = InMemoryReader(data: loadFixture("clip0_5s"))
        let clip1 = InMemoryReader(data: loadFixture("clip1_5s"))
        // Real per-clip durations — this is what drives the rebase offset,
        // deliberately NOT reprobed from the fixture's own (likely
        // near-zero-based) internal PTS.
        let demuxer = MultiClipDemuxer(clips: [(clip0, 5.0), (clip1, 5.0)])!
        try demuxer.open()

        var lastPtsSeconds: Double = -1
        var sawSwitch = false
        var n = 0
        while let result = demuxer.readPacket(), n < 500 {
            n += 1
            if result.didSwitchClip { sawSwitch = true }
            let nopts = Int64(bitPattern: 0x8000000000000000)
            guard result.packet.pointee.pts != nopts,
                  let stream = demuxer.currentDemuxer?.formatContext?.pointee
                      .streams[Int(result.streamIndex)] else { continue }
            let tb = stream.pointee.time_base
            let ptsSeconds = Double(result.packet.pointee.pts) * Double(tb.num) / Double(tb.den)
            // The whole point: pts must never go backwards across the
            // clip1-after-clip0 switch, even though clip1's own raw PTS
            // starts back near 0.
            XCTAssertGreaterThanOrEqual(ptsSeconds, lastPtsSeconds - 0.5,
                "pts went backwards: \(ptsSeconds) after \(lastPtsSeconds)")
            lastPtsSeconds = max(lastPtsSeconds, ptsSeconds)
            var packet: UnsafeMutablePointer<AVPacket>? = result.packet
            av_packet_free(&packet)
        }
        XCTAssertTrue(sawSwitch, "expected at least one clip switch to have occurred")
        // clip0 is 5s; some packet after the switch should report a
        // rebased pts at or beyond that.
        XCTAssertGreaterThan(lastPtsSeconds, 4.0)
    }

    func testSwitchReusesPreOpenedNextClipWithoutReopening() throws {
        let clip0 = InMemoryReader(data: loadFixture("clip0_5s"))
        let clip1 = InMemoryReader(data: loadFixture("clip1_5s"))
        let demuxer = MultiClipDemuxer(clips: [(clip0, 5.0), (clip1, 5.0)])!
        try demuxer.open()

        // NOTE: the first didSwitchClip returned by readPacket() is the
        // pendingSwitchFlag set by open() → switchTo(0) — a Task 3 artifact,
        // NOT the real clip0→clip1 seam. This test deliberately skips it and
        // walks the true seam below.

        // Step 1 — read into the pre-open lead window (clip0 duration 5.0,
        // preOpenLeadSecs 3.0 → maybeTriggerPreOpen fires once local PTS
        // passes 5.0 − 3.0 = 2.0s; 2.2s leaves margin). Compute local PTS
        // exactly like the demuxer does; clip0 has offset 0 so raw PTS is
        // already the local PTS.
        let nopts = Int64(bitPattern: 0x8000000000000000)
        var localPtsSecs: Double = -1
        var n = 0
        while let result = demuxer.readPacket(), n < 500, localPtsSecs <= 2.2 {
            n += 1
            var packet: UnsafeMutablePointer<AVPacket>? = result.packet
            defer { av_packet_free(&packet) }
            if result.packet.pointee.pts != nopts,
               let stream = demuxer.currentDemuxer?.formatContext?.pointee
                   .streams[Int(result.streamIndex)] {
                let tb = stream.pointee.time_base
                localPtsSecs = Double(result.packet.pointee.pts) * Double(tb.num) / Double(tb.den)
            }
        }
        XCTAssertGreaterThan(localPtsSecs, 2.2,
            "never read a packet with local PTS > 2.2s within 500 reads — cannot enter the pre-open lead window")

        // Step 2 — the trigger has fired; wait for the background open to
        // land. The signal is preOpenedNext becoming non-nil, not a fixed
        // sleep: on a slow CI this waits, on a fast machine it returns
        // immediately. 15s bound guards against a regression where the
        // pre-open never completes.
        var preOpened: (index: Int, demuxer: FFmpegDemuxer)?
        let deadline = Date().addingTimeInterval(15.0)
        while preOpened == nil && Date() < deadline {
            preOpened = demuxer.preOpenedNext
            if preOpened == nil { Thread.sleep(forTimeInterval: 0.01) }
        }
        let capturedPreOpened = try XCTUnwrap(preOpened,
            "background pre-open of clip1 did not land within 15s after entering the lead window")
        XCTAssertEqual(capturedPreOpened.index, 1)

        // Step 3 — keep reading to the REAL EOF seam (clip0 exhausted →
        // switchTo(1), the second didSwitchClip in the stream, ~packet 343).
        var seamPacket: Int?
        var m = 0
        while let result = demuxer.readPacket(), m < 2000 {
            m += 1
            var packet: UnsafeMutablePointer<AVPacket>? = result.packet
            if result.didSwitchClip { seamPacket = m; av_packet_free(&packet); break }
            av_packet_free(&packet)
        }
        let seam = try XCTUnwrap(seamPacket,
            "expected the real EOF seam switch to clip1 within 2000 packets after the lead window")

        // Step 4 — the seam must have REUSED the instance captured in step 2.
        // If the pre-open had not been ready, switchTo would have discarded
        // it and fallen back to a synchronous open (a fresh FFmpegDemuxer),
        // and this identity assertion fails — the exact regression this test
        // exists to catch.
        XCTAssertTrue(demuxer.currentDemuxer === capturedPreOpened.demuxer,
            "seam switch at packet \(seam) did not reuse the pre-opened demuxer — fell back to a synchronous open")

        // Packets keep flowing past the seam (correctness unchanged by
        // pre-opening).
        var packet: UnsafeMutablePointer<AVPacket>? = demuxer.readPacket()?.packet
        XCTAssertNotNil(packet)
        av_packet_free(&packet)
    }

    func testSeekRoutesToCorrectClipAndRebasesFromThere() throws {
        let clip0 = InMemoryReader(data: loadFixture("clip0_5s"))
        let clip1 = InMemoryReader(data: loadFixture("clip1_5s"))
        let demuxer = MultiClipDemuxer(clips: [(clip0, 5.0), (clip1, 5.0)])!
        try demuxer.open()

        XCTAssertTrue(demuxer.seek(to: 7.0)) // locate → clip1 (index 1, local 2.0)

        // The real assertion: the first packet delivered after the seek must
        // carry a REBASED PTS in clip1's time domain. Fixture: two 5s clips,
        // clip1 offset = +5.0s → rebased clip1 domain ≈ [6.48, 11.4] (raw
        // 1.48–6.4 + 5.0), while clip0's un-rebased domain tops out at 6.4s.
        // The byte-ratio seek on this single-GOP fixture is ±1.5s+ imprecise
        // (empirical landing for seek(7.0): ~8.56s), so the assertion window
        // is [5.5, 9.5]: wide enough to never flake on seek precision, narrow
        // enough that a packet from the wrong place (routing into clip0's
        // head/body, offset dropped, or rebase skipped) fails the test.
        let nopts = Int64(bitPattern: 0x8000000000000000)
        for _ in 0..<10 {
            guard let result = demuxer.readPacket() else {
                XCTFail("expected a packet after seek"); return
            }
            var packet: UnsafeMutablePointer<AVPacket>? = result.packet
            defer { av_packet_free(&packet) }
            guard result.packet.pointee.pts != nopts,
                  let stream = demuxer.currentDemuxer?.formatContext?.pointee
                      .streams[Int(result.streamIndex)] else { continue }
            let tb = stream.pointee.time_base
            let ptsSeconds = Double(result.packet.pointee.pts) * Double(tb.num) / Double(tb.den)
            XCTAssertTrue((5.5...9.5).contains(ptsSeconds),
                "first post-seek packet PTS \(ptsSeconds)s is outside clip1's rebased domain [5.5, 9.5] — seek did not route + rebase into clip1")
            return
        }
        XCTFail("no packet with a valid PTS within 10 reads after seek")
    }

    /// C1 regression: the EOF seam switch must NOT close the shared
    /// underlying connection. Before the fix, switchTo's first line
    /// `current?.close()` released the clip's reader (terminally closing the
    /// shared connection for every clip), so the clip1 demuxer — whether
    /// reused from the pre-open or opened synchronously — read pure EOF and
    /// playback died silently at the very first seam.
    func testSeamSwitchDoesNotCloseSharedReaderConnection() throws {
        let connection = TerminatingConnection()
        let clip0 = TerminatingReader(data: loadFixture("clip0_5s"), connection: connection)
        let clip1 = TerminatingReader(data: loadFixture("clip1_5s"), connection: connection)
        let demuxer = MultiClipDemuxer(clips: [(clip0, 5.0), (clip1, 5.0)])!
        try demuxer.open()
        XCTAssertEqual(connection.closeCount, 0, "open must not close the shared connection")

        // Walk to the REAL clip0→clip1 EOF seam. open() sets
        // pendingSwitchFlag, so the first didSwitchClip is a Task 3 artifact;
        // the seam is the second one (the first packet of clip1).
        var seamsSeen = 0
        var n = 0
        while let result = demuxer.readPacket(), n < 2000 {
            n += 1
            var packet: UnsafeMutablePointer<AVPacket>? = result.packet
            if result.didSwitchClip {
                seamsSeen += 1
                if seamsSeen == 2 {
                    av_packet_free(&packet)
                    break
                }
            }
            av_packet_free(&packet)
        }
        XCTAssertEqual(seamsSeen, 2,
            "never reached the clip0→clip1 EOF seam within 2000 reads — seam switch killed the shared connection and playback terminated")

        // The seam must NOT have closed the connection.
        XCTAssertEqual(connection.closeCount, 0,
            "seam switch closed the shared connection — every subsequent clip read returns EOF (C1)")

        // Packets from clip1 keep flowing on the still-open connection.
        var postSeamPackets = 0
        while let result = demuxer.readPacket(), postSeamPackets < 100 {
            postSeamPackets += 1
            var packet: UnsafeMutablePointer<AVPacket>? = result.packet
            av_packet_free(&packet)
        }
        XCTAssertGreaterThan(postSeamPackets, 0,
            "no packets from clip1 after the seam — the shared connection was terminally closed by the switch (C1)")

        // Reader release happens exactly once per clip, in close().
        demuxer.close()
        XCTAssertEqual(connection.closeCount, 2,
            "close() must release each clip reader exactly once, only when playback stops")
    }

    /// C1 regression, seek variant: a cross-clip seek must not close the
    /// shared connection either. Before the fix, seek → switchTo →
    /// current?.close() → connection terminally closed → the target clip's
    /// synchronous open read pure EOF → open threw → seek returned false.
    func testSeekAcrossClipDoesNotCloseSharedReaderConnection() throws {
        let connection = TerminatingConnection()
        let clip0 = TerminatingReader(data: loadFixture("clip0_5s"), connection: connection)
        let clip1 = TerminatingReader(data: loadFixture("clip1_5s"), connection: connection)
        let demuxer = MultiClipDemuxer(clips: [(clip0, 5.0), (clip1, 5.0)])!
        try demuxer.open()

        XCTAssertTrue(demuxer.seek(to: 7.0),
            "cross-clip seek failed — the switch closed the shared connection and the target clip open read EOF (C1)")
        XCTAssertEqual(connection.closeCount, 0,
            "cross-clip seek closed the shared connection (C1)")

        // The first packet after the seek still arrives from clip1's reader.
        var packet: UnsafeMutablePointer<AVPacket>? = demuxer.readPacket()?.packet
        XCTAssertNotNil(packet,
            "no packet after cross-clip seek — the shared connection was terminally closed (C1)")
        av_packet_free(&packet)

        demuxer.close()
        XCTAssertEqual(connection.closeCount, 2,
            "close() must release each clip reader exactly once")
    }
}
