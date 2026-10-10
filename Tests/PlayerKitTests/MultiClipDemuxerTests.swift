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

    /// A seek that lands inside the CURRENT clip must reuse the already-open
    /// demuxer instead of closing it and paying a full synchronous reopen
    /// (avformat_open_input + find_stream_info measures 1.5s+ on real media,
    /// ~5s end-to-end per seek on a BD original). Identity assertion: the
    /// demuxer instance must survive the seek.
    func testSeekWithinSameClipReusesOpenDemuxer() throws {
        let clip0 = InMemoryReader(data: loadFixture("clip0_5s"))
        let clip1 = InMemoryReader(data: loadFixture("clip1_5s"))
        let demuxer = MultiClipDemuxer(clips: [(clip0, 5.0), (clip1, 5.0)])!
        try demuxer.open()
        let opened = try XCTUnwrap(demuxer.currentDemuxer)

        XCTAssertTrue(demuxer.seek(to: 1.0)) // inside clip0 (0..<5)
        XCTAssertTrue(demuxer.currentDemuxer === opened,
            "same-clip seek must keep the already-open demuxer instead of reopening it")

        // The seek still took effect: packets flow from clip0 near the
        // target. Byte-ratio seek on this single-GOP fixture is ±1.5s
        // imprecise, so the window is [0, 3]; a clip1 packet would carry a
        // rebased PTS ≥ 6.48, so anything above 3.0 means wrong-clip data.
        let nopts = Int64(bitPattern: 0x8000000000000000)
        for _ in 0..<10 {
            guard let result = demuxer.readPacket() else {
                XCTFail("expected a packet after same-clip seek"); return
            }
            var packet: UnsafeMutablePointer<AVPacket>? = result.packet
            defer { av_packet_free(&packet) }
            guard result.packet.pointee.pts != nopts,
                  let stream = demuxer.currentDemuxer?.formatContext?.pointee
                      .streams[Int(result.streamIndex)] else { continue }
            let tb = stream.pointee.time_base
            let ptsSeconds = Double(result.packet.pointee.pts) * Double(tb.num) / Double(tb.den)
            XCTAssertTrue((0...3).contains(ptsSeconds),
                "first post-seek packet PTS \(ptsSeconds)s outside clip0's local domain near the target — seek did not take effect")
            return
        }
        XCTFail("no packet with a valid PTS within 10 reads after same-clip seek")
    }

    /// A cross-clip seek whose target IS the pre-opened next clip must reuse
    /// the background-opened demuxer (seek on a freshly-opened demuxer is
    /// exactly what the fallback path does, minus the redundant reopen).
    func testCrossClipSeekReusesPreOpenedTargetDemuxer() throws {
        let clip0 = InMemoryReader(data: loadFixture("clip0_5s"))
        let clip1 = InMemoryReader(data: loadFixture("clip1_5s"))
        let demuxer = MultiClipDemuxer(clips: [(clip0, 5.0), (clip1, 5.0)])!
        try demuxer.open()

        // Walk into the pre-open lead window (local PTS > 2.2s, see
        // testSwitchReusesPreOpenedNextClipWithoutReopening) and wait for the
        // background open of clip1 to land.
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
        var preOpened: (index: Int, demuxer: FFmpegDemuxer)?
        let deadline = Date().addingTimeInterval(15.0)
        while preOpened == nil && Date() < deadline {
            preOpened = demuxer.preOpenedNext
            if preOpened == nil { Thread.sleep(forTimeInterval: 0.01) }
        }
        let capturedPreOpened = try XCTUnwrap(preOpened,
            "background pre-open of clip1 did not land within 15s after entering the lead window")

        // Seek across the seam to clip1 — the target is the pre-opened clip.
        XCTAssertTrue(demuxer.seek(to: 7.0)) // clip1 local 2.0
        XCTAssertTrue(demuxer.currentDemuxer === capturedPreOpened.demuxer,
            "cross-clip seek into the pre-opened target clip discarded the cached demuxer and reopened synchronously")
        XCTAssertEqual(demuxer.preOpenedNext?.index, nil,
            "consumed pre-open entry should be cleared")

        // First packet lands in clip1's rebased domain (same window as the
        // routing test: [5.5, 9.5] against raw clip1 1.48–6.4 + 5.0 offset).
        for _ in 0..<10 {
            guard let result = demuxer.readPacket() else {
                XCTFail("expected a packet after cross-clip seek"); return
            }
            var packet: UnsafeMutablePointer<AVPacket>? = result.packet
            defer { av_packet_free(&packet) }
            guard result.packet.pointee.pts != nopts,
                  let stream = demuxer.currentDemuxer?.formatContext?.pointee
                      .streams[Int(result.streamIndex)] else { continue }
            let tb = stream.pointee.time_base
            let ptsSeconds = Double(result.packet.pointee.pts) * Double(tb.num) / Double(tb.den)
            XCTAssertTrue((5.5...9.5).contains(ptsSeconds),
                "first post-seek packet PTS \(ptsSeconds)s outside clip1's rebased domain [5.5, 9.5] — pre-open reuse broke routing or rebase")
            return
        }
        XCTFail("no packet with a valid PTS within 10 reads after cross-clip seek")
    }

    /// Seeking to the CURRENT clip's own local zero must still take effect on
    /// the fast path: the open demuxer's playhead is arbitrary, so unlike the
    /// fresh-open fallback (which already sits at 0 and may skip a zero seek)
    /// this path must issue the seek even for target 0. Regression guard for
    /// the `localSeekSecs > 0` gate, which silently no-op'd it.
    func testSeekToCurrentClipStartOnFastPathTakesEffect() throws {
        let clip0 = InMemoryReader(data: loadFixture("clip0_5s"))
        let clip1 = InMemoryReader(data: loadFixture("clip1_5s"))
        let demuxer = MultiClipDemuxer(clips: [(clip0, 5.0), (clip1, 5.0)])!
        try demuxer.open()
        let opened = try XCTUnwrap(demuxer.currentDemuxer)

        // Advance the playhead past 2s so an un-seeked continuation packet
        // (old behavior) lands far from a real seek-to-start landing.
        let nopts = Int64(bitPattern: 0x8000000000000000)
        var localPtsSecs = -1.0
        var n = 0
        while let result = demuxer.readPacket(), n < 500, localPtsSecs <= 2.0 {
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
        XCTAssertGreaterThan(localPtsSecs, 2.0,
            "fixture must advance past 2s before the regression seek (reached \(localPtsSecs)s)")

        XCTAssertTrue(demuxer.seek(to: 0.0)) // clip0 local 0 — the no-op case
        XCTAssertTrue(demuxer.currentDemuxer === opened,
            "seek to clip start must stay on the fast path (no reopen)")

        // The seek took effect: the first packet is back near the clip start,
        // not a continuation from ~2s+. Byte-ratio seek imprecision on this
        // single-GOP fixture is ±1.5s, so the window is [0, 1.5).
        for _ in 0..<10 {
            guard let result = demuxer.readPacket() else {
                XCTFail("expected a packet after seek to clip start"); return
            }
            var packet: UnsafeMutablePointer<AVPacket>? = result.packet
            defer { av_packet_free(&packet) }
            guard result.packet.pointee.pts != nopts,
                  let stream = demuxer.currentDemuxer?.formatContext?.pointee
                      .streams[Int(result.streamIndex)] else { continue }
            let tb = stream.pointee.time_base
            let ptsSeconds = Double(result.packet.pointee.pts) * Double(tb.num) / Double(tb.den)
            XCTAssertLessThan(ptsSeconds, 2.0,
                "first packet after seek(clip-start) is at \(ptsSeconds)s — the fast path skipped the seek (continuation, not a seek)")
            return
        }
        XCTFail("no packet with a valid PTS within 10 reads after seek to clip start")
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
