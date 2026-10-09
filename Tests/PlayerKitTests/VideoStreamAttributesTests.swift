import XCTest
import CFFmpeg
import PlayerKit
@testable import PlayerKitNative

/// `videoStreamAttributes()` 是层 1 策略对账的输入入口:
/// NativeBackend 与语料 conformance 测试共用同一构造,防止双份漂移。
final class VideoStreamAttributesTests: XCTestCase {
    private func corpusURL(_ name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        return Bundle.module.url(forResource: base, withExtension: ext, subdirectory: "Fixtures/corpus")!
    }

    func testHDR10StreamAttributes() throws {
        let url = corpusURL("c2_hdr10.mp4")
        let demuxer = FFmpegDemuxer()
        try demuxer.open(url: url, headers: [:])
        let attrs = try XCTUnwrap(demuxer.videoStreamAttributes())
        XCTAssertEqual(attrs.transfer, .pq)
        XCTAssertEqual(attrs.colorMatrix, .bt2020)
        XCTAssertEqual(attrs.range, .limited)
        XCTAssertEqual(attrs.codecID, UInt32(AV_CODEC_ID_HEVC.rawValue))
        XCTAssertTrue(attrs.isHEVC10Bit)
        XCTAssertFalse(attrs.isDolbyVision)
        XCTAssertEqual(attrs.doviProfile, 0)
        XCTAssertFalse(attrs.hasHDR10Plus)
    }

    func testSDRStreamAttributes() throws {
        let url = corpusURL("c1_sdr_bt709.mp4")
        let demuxer = FFmpegDemuxer()
        try demuxer.open(url: url, headers: [:])
        let attrs = try XCTUnwrap(demuxer.videoStreamAttributes())
        XCTAssertEqual(attrs.transfer, .sdr)
        XCTAssertEqual(attrs.colorMatrix, .bt709)
        XCTAssertFalse(attrs.isHEVC10Bit)
        XCTAssertFalse(attrs.isHEVC10BitSDRHint)
    }

    func testReturnsNilWithoutVideoStream() {
        let demuxer = FFmpegDemuxer()
        XCTAssertNil(demuxer.videoStreamAttributes())
    }
}
