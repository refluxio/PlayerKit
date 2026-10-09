import XCTest
import PlayerKit
@testable import PlayerKitNative

/// FFmpegMediaProbe 曾把 isHDR 硬编码 false(FFmpegMediaProbe.swift:45),
/// hdrFormat/colorTransfer 恒 nil——层 1 用它做"客户端快速预检"断言前必须先修。
final class FFmpegMediaProbeTests: XCTestCase {
    private func corpusURL(_ name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        return Bundle.module.url(forResource: base, withExtension: ext, subdirectory: "Fixtures/corpus")!
    }

    func testHDR10MarkedHDR() async throws {
        let result = try await FFmpegMediaProbe().probe(url: corpusURL("c2_hdr10.mp4"), headers: [:])
        let v = try XCTUnwrap(result.videoStreams.first)
        XCTAssertTrue(v.isHDR)
        XCTAssertEqual(v.hdrFormat, "hdr10")
        XCTAssertEqual(v.colorTransfer, "smpte2084")
    }

    func testDoViMarkedDolbyVision() async throws {
        let result = try await FFmpegMediaProbe().probe(url: corpusURL("c5_dv_p81.mp4"), headers: [:])
        let v = try XCTUnwrap(result.videoStreams.first)
        XCTAssertTrue(v.isHDR)
        XCTAssertEqual(v.hdrFormat, "dolbyVision")
        XCTAssertEqual(v.colorTransfer, "smpte2084")
    }

    func testHLGMarkedHLG() async throws {
        let result = try await FFmpegMediaProbe().probe(url: corpusURL("c4_hlg.mp4"), headers: [:])
        let v = try XCTUnwrap(result.videoStreams.first)
        XCTAssertTrue(v.isHDR)
        XCTAssertEqual(v.hdrFormat, "hlg")
        XCTAssertEqual(v.colorTransfer, "arib-std-b67")
    }

    func testSDRNotHDR() async throws {
        let result = try await FFmpegMediaProbe().probe(url: corpusURL("c1_sdr_bt709.mp4"), headers: [:])
        let v = try XCTUnwrap(result.videoStreams.first)
        XCTAssertFalse(v.isHDR)
        XCTAssertNil(v.hdrFormat)
        XCTAssertEqual(v.colorTransfer, "bt709")
    }
}
