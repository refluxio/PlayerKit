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

    /// 信号域中性色 = 灰。IPTPQc2 全范围量化,中性色度在信号 0.5 中点
    /// (模拟域色度拟合 [-0.5,+0.5],量化加 0.5 偏置)——P/T 信号 0.5 经
    /// PQ EOTF 后减 0.5 才是 IPT 色度。用亮信号(0.9)保证偏差量级超过
    /// 容差:漏掉 -0.5 偏置时,lmsP 三通道出现 ~0.4% 失衡,经幂放大后
    /// r/b 失衡 ~4%,本测试即转红。
    func testIPTPQToBT2020RGBNeutralSignalMidpointIsGray() {
        let sample = DolbyVisionColorSignal.iptPQToBT2020RGB(i: 0.9, p: 0.5, t: 0.5)
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
