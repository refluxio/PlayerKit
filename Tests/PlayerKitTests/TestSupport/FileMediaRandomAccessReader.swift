import Foundation
import PlayerKit
@testable import PlayerKitNative

/// 文件版 MediaRandomAccessReader —— 语料 conformance 测试用,
/// 让合成/真盘语料走 FFmpegDemuxer.open(reader:) 的自定义 IO 路径
/// (含 maybeInjectDoviConfigFromDisc 的 2MB 头部 DV 探测)。
final class FileMediaRandomAccessReader: MediaRandomAccessReader {
    private let data: Data

    init(url: URL) {
        self.data = try! Data(contentsOf: url)
    }

    var totalSize: Int64 { Int64(data.count) }

    func read(offset: Int64, length: Int, into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard offset >= 0, offset < Int64(data.count) else { return 0 }
        let end = min(Int(offset) + length, data.count)
        let n = end - Int(offset)
        data.copyBytes(to: buffer.bindMemory(to: UInt8.self), from: Int(offset)..<end)
        return n
    }

    /// 顺序读全(上限 maxBytes)——DiscDoviProbe 断言用(与生产侧 2MB 头部探测同参)。
    func readHead(maxBytes: Int = 2 * 1024 * 1024) -> Data {
        Data(data.prefix(maxBytes))
    }

    func close() {}
}
