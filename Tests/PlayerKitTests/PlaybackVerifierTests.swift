import XCTest
import CoreVideo
import QuartzCore
@testable import PlayerKit
@testable import PlayerKitNative

// MARK: - Test doubles (file scope: VideoRenderer/ToneMapping requirements are
// nonisolated, so the doubles must not inherit the @MainActor test-class isolation)

/// Minimal renderer stand-in for wrapper-level unit tests. Records render calls
/// without touching any display machinery.
private final class StubRenderer: VideoRenderer {
    let layer = CALayer()
    var displayCapability: DisplayCapability = .macSDR
    private let lock = NSLock()
    private var _renderCalls = 0
    var renderCalls: Int { lock.withLock { _renderCalls } }

    func render(pixelBuffer: CVPixelBuffer,
                pts: Double,
                colorParams: VideoColorParams,
                metadata: FrameMetadata,
                strategy: RendererStrategy?) {
        lock.withLock { _renderCalls += 1 }
    }
    func flush() {}
    func clear() {}
}

/// Tone mapper whose mapped output deliberately differs from the input
/// (plane-0 luma halved into a fresh buffer) — the "healthy mapper" case.
private final class DimmingMapper: ToneMapping {
    func process(pixelBuffer: CVPixelBuffer,
                 colorParams: VideoColorParams,
                 metadata: FrameMetadata,
                 strategy: RendererStrategy?) -> ProcessedFrame {
        guard let out = Self.clone(pixelBuffer) else {
            return ProcessedFrame(pixelBuffer: pixelBuffer, colorParams: colorParams)
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        CVPixelBufferLockBaseAddress(out, [])
        defer {
            CVPixelBufferUnlockBaseAddress(out, [])
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        }
        for plane in 0..<2 {
            guard let src = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane),
                  let dst = CVPixelBufferGetBaseAddressOfPlane(out, plane) else { continue }
            let h = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
            for y in 0..<h {
                let s = src.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
                let d = dst.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
                for x in 0..<stride {
                    // Halve every byte of plane 0 (luma); copy chroma verbatim.
                    d[x] = plane == 0 ? s[x] >> 1 : s[x]
                }
            }
        }
        return ProcessedFrame(pixelBuffer: out, colorParams: colorParams)
    }

    private static func clone(_ pb: CVPixelBuffer) -> CVPixelBuffer? {
        var out: CVPixelBuffer?
        let r = CVPixelBufferCreate(nil, CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb),
                                    CVPixelBufferGetPixelFormatType(pb), nil, &out)
        return r == kCVReturnSuccess ? out : nil
    }
}

/// Tone mapper that silently returns its input unchanged — the exact shape of
/// the 2026-10-08 "silent passthrough" regression this observer must catch.
private final class IdentityMapper: ToneMapping {
    func process(pixelBuffer: CVPixelBuffer,
                 colorParams: VideoColorParams,
                 metadata: FrameMetadata,
                 strategy: RendererStrategy?) -> ProcessedFrame {
        ProcessedFrame(pixelBuffer: pixelBuffer, colorParams: colorParams)
    }
}

/// P4: in-playback HDR verification observer — pure observer, zero playback
/// behavior change, issues are report strings, never thrown.
@MainActor
final class PlaybackVerifierTests: XCTestCase {

    // MARK: - Helpers

    /// 8-bit 420v ('420v') buffer with a constant luma fill.
    private func makeLumaBuffer(width: Int = 128, height: Int = 128, fill: UInt8 = 128) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        let r = CVPixelBufferCreate(nil, width, height,
                                    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                    attrs as CFDictionary, &pb)
        XCTAssertEqual(r, kCVReturnSuccess)
        guard let buffer = pb else { fatalError("no pixel buffer") }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            for y in 0..<height {
                memset(base.advanced(by: y * stride), Int32(fill), stride)
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    private func pqColorParams() -> VideoColorParams {
        var cp = VideoColorParams()
        cp.matrix = .bt2020
        cp.transfer = .pq
        cp.range = .limited
        return cp
    }

    // MARK: - ① Integration: real NativeBackend renders through the wrapper

    func testReportAfterShortPlayback() async throws {
        // Single-backend: wrap a standalone ASBDLRenderer and hand it to
        // NativeBackend at init. (Two live NativeBackends contend for the
        // audio device and deadlock — verified empirically.)
        let verifier = PlaybackVerifier(wrapping: try ASBDLRenderer())
        let wrapped = try await MainActor.run { try NativeBackend(renderer: verifier, audioOutput: nil) }
        defer { Task { @MainActor in wrapped.stop() } }
        let url = Bundle.module.url(forResource: "speed_dts48_51", withExtension: "mkv", subdirectory: "Fixtures")!
        verifier.noteSource(url)
        await MainActor.run { wrapped.play(url: url, headers: [:], seekTo: nil) }

        // Poll (instead of a blind sleep) so CI startup latency can't flake the
        // >30-frames assertion; 6s wall ceiling ≈ skeleton's 4s budget + margin.
        let deadline = Date().addingTimeInterval(6.0)
        while Date() < deadline, verifier.currentReport().framesObserved <= 30 {
            try await Task.sleep(nanoseconds: 200_000_000)
        }

        let report = verifier.currentReport()
        XCTAssertGreaterThan(report.framesObserved, 30, "4s of realtime playback must surface >30 frames")
        XCTAssertFalse(report.issues.contains("no-frames"))
        XCTAssertNotNil(report.strategy)
        XCTAssertNotNil(report.decoderPreference)
        XCTAssertNotNil(report.pixelFormat, "sampled frames should record the buffer format")
        XCTAssertEqual(report.source, url)
        // The fixture is SDR h264 → strategy resolves to sdr8Bit and DV checks are N/A.
        XCTAssertEqual(report.strategy, "sdr8Bit")
        XCTAssertEqual(report.rpuRetention, "not-dv")
        XCTAssertNil(report.doviRPUSeen)
        XCTAssertNil(report.liveness, "no probe installed on this session")
        XCTAssertGreaterThan(report.framesProbed, 0)
    }

    /// Pure-observer guarantee at wrapper level: every frame handed to the
    /// verifier reaches the wrapped renderer (no frames swallowed or delayed).
    func testEveryObservedFrameIsForwarded() {
        let stub = StubRenderer()
        let verifier = PlaybackVerifier(wrapping: stub, config: .init(probeIntervalFrames: 1))
        let buffer = makeLumaBuffer()
        var cp = VideoColorParams()
        cp.matrix = .bt709
        cp.transfer = .sdr
        for i in 0..<10 {
            verifier.render(pixelBuffer: buffer, pts: Double(i) / 24.0,
                            colorParams: cp, metadata: FrameMetadata(),
                            strategy: .sdr8Bit(matrix: .bt709))
        }
        XCTAssertEqual(stub.renderCalls, 10)
        XCTAssertEqual(verifier.currentReport().framesObserved, 10)
    }

    // MARK: - ② DV RPU retention signal (synthetic DV-strategy frames)

    func testDoviRPUTaggedOnDVFixture() {
        let verifier = PlaybackVerifier(wrapping: StubRenderer(), config: .init(probeIntervalFrames: 2))
        let buffer = makeLumaBuffer()
        var metadata = FrameMetadata()
        metadata.dovi = DolbyVisionFrameMetadata(profile: 8, blSignalCompatibilityId: 1)
        let cp = pqColorParams()

        for i in 0..<6 {
            verifier.render(pixelBuffer: buffer, pts: Double(i) / 24.0,
                            colorParams: cp, metadata: metadata, strategy: .doviProfile5)
        }
        verifier.flush()  // simulate stop → finalize session

        let report = verifier.currentReport()
        XCTAssertEqual(report.framesObserved, 6)
        XCTAssertEqual(report.strategy, "doviProfile5")
        XCTAssertEqual(report.decoderPreference, "ffmpegSW")
        XCTAssertEqual(report.doviRPUSeen, true, "SW decoder keeps the RPU → metadata.dovi per frame")
        XCTAssertEqual(report.rpuRetention, "sw-kept")
        XCTAssertFalse(report.issues.contains("dv-rpu-stripped"))
    }

    func testRPUVTStrippedWhenDoviMetadataMissing() {
        let verifier = PlaybackVerifier(wrapping: StubRenderer(), config: .init(probeIntervalFrames: 2))
        let buffer = makeLumaBuffer()
        let cp = pqColorParams()

        // DV strategy resolved, but every frame arrives without RPU side data —
        // the VT-strip / silent-fallback signature (generalizes the 2026-10-08 finding).
        for i in 0..<6 {
            verifier.render(pixelBuffer: buffer, pts: Double(i) / 24.0,
                            colorParams: cp, metadata: FrameMetadata(),
                            strategy: .doviProfile8(tonemapCompat: false))
        }
        verifier.flush()

        let report = verifier.currentReport()
        XCTAssertEqual(report.framesObserved, 6)
        XCTAssertEqual(report.rpuRetention, "vt-stripped")
        XCTAssertEqual(report.doviRPUSeen, false)
        XCTAssertTrue(report.issues.contains("dv-rpu-stripped"))
    }

    // MARK: - ③ Tone-map liveness probe (silent-passthrough sentinel)

    func testLivenessProbeDiffer() {
        let verifier = PlaybackVerifier(wrapping: StubRenderer(), config: .init(probeIntervalFrames: 2))
        // No concrete ToneMapping ships in open-source PlayerKit (Pro mappers live
        // in PlayerKitPro), so per the task decision we wrap a stub whose mapped
        // output differs from passthrough.
        _ = verifier.makeProbeToneMapper(wrapping: DimmingMapper())
        let buffer = makeLumaBuffer()
        let cp = pqColorParams()

        for i in 0..<6 {
            verifier.render(pixelBuffer: buffer, pts: Double(i) / 24.0,
                            colorParams: cp, metadata: FrameMetadata(),
                            strategy: .hdr10Static(peakNits: 1000))
        }
        verifier.flush()

        let report = verifier.currentReport()
        XCTAssertEqual(report.framesProbed, 3, "every probeIntervalFrames-th frame is probed")
        guard let liveness = report.liveness else {
            return XCTFail("probed session must carry a liveness result")
        }
        XCTAssertTrue(liveness.differ, "a real tone-map must change PQ pixels vs passthrough")
        XCTAssertNotEqual(liveness.mappedChecksum, liveness.bypassChecksum)
        XCTAssertFalse(report.issues.contains("tone-map-silent-passthrough"))
    }

    func testToneMapSilentPassthroughIssue() {
        let verifier = PlaybackVerifier(wrapping: StubRenderer(), config: .init(probeIntervalFrames: 2))
        _ = verifier.makeProbeToneMapper(wrapping: IdentityMapper())
        let buffer = makeLumaBuffer()
        let cp = pqColorParams()

        for i in 0..<6 {
            verifier.render(pixelBuffer: buffer, pts: Double(i) / 24.0,
                            colorParams: cp, metadata: FrameMetadata(),
                            strategy: .hdr10Static(peakNits: 1000))
        }
        verifier.flush()

        let report = verifier.currentReport()
        XCTAssertEqual(report.liveness?.differ, false)
        XCTAssertEqual(report.liveness?.mappedChecksum, report.liveness?.bypassChecksum)
        XCTAssertTrue(report.issues.contains("tone-map-silent-passthrough"),
                      "2 consecutive differ==false probes must raise the silent-passthrough issue")
    }

    // MARK: - ④ Luma health thresholds (HDR black screen / SDR clipping)

    func testHDRBlackScreenIssue() {
        // 45 sampled frames ÷ healthSampleFrames(10) = 4 windows; 3 consecutive
        // bad windows = the plan's "持续 30 采样" threshold.
        let verifier = PlaybackVerifier(wrapping: StubRenderer(), config: .init(probeIntervalFrames: 1))
        let black = makeLumaBuffer(fill: 16)  // limited-range black
        var cp = VideoColorParams()
        cp.matrix = .bt2020
        cp.transfer = .pq

        for i in 0..<45 {
            verifier.render(pixelBuffer: black, pts: Double(i) / 24.0,
                            colorParams: cp, metadata: FrameMetadata(),
                            strategy: .hdr10Static(peakNits: 1000))
        }
        verifier.flush()

        let report = verifier.currentReport()
        XCTAssertTrue(report.issues.contains("hdr-black-screen"))
        XCTAssertGreaterThan(report.luma.blackRatio, 0.9)
    }

    func testSDRClippingIssue() {
        let verifier = PlaybackVerifier(wrapping: StubRenderer(), config: .init(probeIntervalFrames: 1))
        let white = makeLumaBuffer(fill: 255)
        var cp = VideoColorParams()
        cp.matrix = .bt709
        cp.transfer = .sdr

        for i in 0..<45 {
            verifier.render(pixelBuffer: white, pts: Double(i) / 24.0,
                            colorParams: cp, metadata: FrameMetadata(),
                            strategy: .sdr8Bit(matrix: .bt709))
        }
        verifier.flush()

        let report = verifier.currentReport()
        XCTAssertTrue(report.issues.contains("sdr-clipping"))
        XCTAssertGreaterThan(report.luma.clipRatio, 0.5)
    }

    // MARK: - Report shape / codability

    func testFreshVerifierReportsNoFrames() {
        let verifier = PlaybackVerifier(wrapping: StubRenderer())
        let report = verifier.currentReport()
        XCTAssertEqual(report.framesObserved, 0)
        XCTAssertTrue(report.issues.contains("no-frames"))
        XCTAssertEqual(report.rpuRetention, "not-dv")
        XCTAssertNil(report.strategy)
        XCTAssertNil(report.liveness)
    }

    func testReportCodableRoundTrip() {
        let verifier = PlaybackVerifier(wrapping: StubRenderer(), config: .init(probeIntervalFrames: 2))
        _ = verifier.makeProbeToneMapper(wrapping: DimmingMapper())
        var metadata = FrameMetadata()
        metadata.dovi = DolbyVisionFrameMetadata(profile: 5, blSignalCompatibilityId: 0)
        let buffer = makeLumaBuffer()
        let cp = pqColorParams()
        for i in 0..<4 {
            verifier.render(pixelBuffer: buffer, pts: Double(i) / 24.0,
                            colorParams: cp, metadata: metadata, strategy: .doviProfile5)
        }
        verifier.flush()
        let report = verifier.currentReport()

        let data = try! JSONEncoder().encode(report)
        let decoded = try! JSONDecoder().decode(PlaybackVerificationReport.self, from: data)
        XCTAssertEqual(decoded, report, "report must survive a JSON round-trip verbatim")
        XCTAssertNotNil(decoded.luma)
        XCTAssertNotNil(decoded.liveness)
    }
}
