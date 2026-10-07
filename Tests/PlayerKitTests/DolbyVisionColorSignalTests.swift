import XCTest
@testable import PlayerKit

/// Dolby Vision 基础层信号判定 + IPT(PQ)→ BT.2020 RGB 解码链的纯 Swift
/// 参考实现测试。渲染侧(PlayerKitPro shader)逐位对齐这里的常数与顺序。
final class DolbyVisionColorSignalTests: XCTestCase {

    // MARK: - 信号类型判定

    /// P5 的基础层恒为 IPTPQc2(无兼容回退变体)。
    func testResolveProfile5IsIPT() {
        for compat: UInt8 in [0, 1, 2, 4] {
            XCTAssertEqual(
                DolbyVisionColorSignal.resolve(profile: 5, blSignalCompatibilityId: compat),
                .ipt,
                "P5 compat \(compat) 应判为 IPT"
            )
        }
    }

    /// P8 compat 1/2 是 HDR10/HLG 兼容基础层(YCbCr BT.2020);0/4 是
    /// DV 独有 IPT 基础层。这是 P8.1 网络片源(最常见)不受伤的关键:
    /// compat 1 必须继续走既有 YCbCr 路径。
    func testResolveProfile8CompatVariants() {
        XCTAssertEqual(DolbyVisionColorSignal.resolve(profile: 8, blSignalCompatibilityId: 0), .ipt)
        XCTAssertEqual(DolbyVisionColorSignal.resolve(profile: 8, blSignalCompatibilityId: 1), .bt2020YCbCr)
        XCTAssertEqual(DolbyVisionColorSignal.resolve(profile: 8, blSignalCompatibilityId: 2), .bt2020YCbCr)
        XCTAssertEqual(DolbyVisionColorSignal.resolve(profile: 8, blSignalCompatibilityId: 4), .ipt)
    }

    /// P7(BL 为标准 HDR10)/P4/未知 profile 按标准 BL 解释。
    func testResolveOtherProfilesAreYCbCr() {
        XCTAssertEqual(DolbyVisionColorSignal.resolve(profile: 7, blSignalCompatibilityId: 6), .bt2020YCbCr)
        XCTAssertEqual(DolbyVisionColorSignal.resolve(profile: 4, blSignalCompatibilityId: 0), .bt2020YCbCr)
        XCTAssertEqual(DolbyVisionColorSignal.resolve(profile: 0, blSignalCompatibilityId: 0), .bt2020YCbCr)
    }

    // MARK: - 矩阵常数

    /// iptToLMS 应是 lms2ipt(Ebner & Fairchild 1998)的数值逆:两者复合
    /// ≈ 单位阵。libplacebo pl_ipt_lms2ipt verbatim 作对照。
    func testIPTToLMSInvertsLMS2IPT() {
        let lms2ipt: [[Double]] = [
            [0.4000, 0.4000, 0.2000],
            [4.4550, -4.8510, 0.3960],
            [0.8056, 0.3572, -1.1628],
        ]
        let product = DolbyVisionColorSignal.matMul(
            DolbyVisionColorSignal.iptToLMS, lms2ipt
        )
        for (i, row) in product.enumerated() {
            for (j, value) in row.enumerated() {
                XCTAssertEqual(value, i == j ? 1.0 : 0.0, accuracy: 1e-4,
                               "复合矩阵[\(i)][\(j)] 偏离单位阵")
            }
        }
    }

    /// dovi_lms2rgb 行和 ≈ 1:等能白 LMS(1,1,1) 映射到 BT.2020 D65 白。
    /// 抄错任一行都会破坏白点。
    func testLMS2RGBPreservesWhite() {
        let rgb = DolbyVisionColorSignal.matVec(
            DolbyVisionColorSignal.lmsToBT2020RGB, [1.0, 1.0, 1.0]
        )
        XCTAssertEqual(rgb[0], 1.0, accuracy: 2e-3)
        XCTAssertEqual(rgb[1], 1.0, accuracy: 2e-3)
        XCTAssertEqual(rgb[2], 1.0, accuracy: 2e-3)
    }

    /// 幂指数是 IPT 非线性标准 1/0.43(Ebner),不是 sRGB 家族的 2.4。
    func testIPTPowerExponent() {
        XCTAssertEqual(DolbyVisionColorSignal.iptPowerExponent, 1.0 / 0.43, accuracy: 1e-12)
    }

    // MARK: - 参考解码链

    /// 灰轴不变性:PQ 编码的 IPT 无彩信号(I=P=T)解出 R=G=B。
    /// IPT 第一分量携带全部亮度、P/T 为色度,I=P=T 意味着经 ipt2lms 后
    /// L'M'S' 三通道相等(iptToLMS 每行和为 1),再经白保持矩阵出灰。
    func testIPTPQToBT2020RGBNeutralAxisStaysGray() {
        let sample = DolbyVisionColorSignal.iptPQToBT2020RGB(i: 0.5, p: 0.5, t: 0.5)
        XCTAssertEqual(sample.r, sample.g, accuracy: 2e-3)
        XCTAssertEqual(sample.g, sample.b, accuracy: 2e-3)
        XCTAssertEqual(sample.r, sample.b, accuracy: 2e-3)
    }

    /// 链路单调递增:输入 I 分量越亮,输出 RGB 各通道不降。
    func testIPTPQToBT2020RGBMonotonicInIntensity() {
        let dim = DolbyVisionColorSignal.iptPQToBT2020RGB(i: 0.3, p: 0.5, t: 0.5)
        let bright = DolbyVisionColorSignal.iptPQToBT2020RGB(i: 0.6, p: 0.5, t: 0.5)
        XCTAssertLessThanOrEqual(dim.r, bright.r + 1e-9)
        XCTAssertLessThanOrEqual(dim.g, bright.g + 1e-9)
        XCTAssertLessThanOrEqual(dim.b, bright.b + 1e-9)
    }

    /// 饱和信号解出有效线性值:不超过 ±2(IPT 端点值域内矩阵映射有限),
    /// 且不为 NaN(链路中的幂运算对负数输入依赖 max(·,0) 钳制)。
    func testIPTPQToBT2020RGBOutputFinite() {
        for input in [(0.0, 0.5, 0.5), (1.0, 0.5, 0.5), (0.5, 0.0, 0.5), (0.5, 1.0, 0.5), (0.5, 0.5, 0.0), (0.5, 0.5, 1.0)] {
            let rgb = DolbyVisionColorSignal.iptPQToBT2020RGB(i: input.0, p: input.1, t: input.2)
            for channel in [rgb.r, rgb.g, rgb.b] {
                XCTAssertFalse(channel.isNaN, "输入 \(input) 解出 NaN")
                XCTAssertLessThanOrEqual(abs(channel), 2.0, "输入 \(input) 解出异常值 \(channel)")
            }
        }
    }
}
