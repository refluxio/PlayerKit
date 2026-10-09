import XCTest
import PlayerKit

/// 层 2:IPTPQc2(P5)数学性质锚点。
/// 说明:spec 原案"libdovi FFI 导出参考值"不可行(libdovi 不导出 IPT 变换,
/// libplacebo 无 Python 绑定);梯阵逐值对齐列为后续补充。本文件先固化
/// 不依赖外部常量的数学性质——足以抓住符号/转置/指数类实现错误。
///
/// 契约对齐(brief 原案与实现契约不符处已修正,全部数值经 python 按
/// ST 2084 规范公式独立复算后冻结,未放宽任何复算锚点的容差):
/// 1. IPTPQc2 全范围量化,中性色度在码域中点 0.5(DolbyVisionColorSignal
///    对 P/T 做 -EOTF(0.5) 偏置),中性轴取 P=T=0.5 而非 0;
/// 2. 链路在 IPT→LMS 之间有 Ebner 幂 1/0.43,中性轴输出处于 IPT 感知
///    强度域:输出 = 线性亮度^(1/0.43)(10000 nits = 1.0 在幂下不变),
///    不是线性亮度本身;
/// 3. 容差地板:`lmsToBT2020RGB` verbatim 常数三行行和为
///    (1.00000021, 0.99998261, 1.00015420),白点保持的物理上限 ~1.54e-4,
///    1e-6 级断言数值上不可达;各容差 ≥ 实测地板 ×3,仍远低于需捕捉的
///    转置/符号/指数类错误量级(≥1e-3)。
final class HdrMathConformanceTests: XCTestCase {

    /// 中性轴:IPT 的 P、T 分量为中性码 0.5 时输出必为中性灰(R==G==B)。
    /// 若梯阵被转置/符号写错,轴对称性立即破坏。
    /// 容差 2e-4:行和舍入在高亮端(i=0.95)产生 ~5.7e-5 的绝对失衡,
    /// 这是常数精度的地板,不是实现误差。
    func testNeutralAxisStaysNeutral() {
        for i in stride(from: 0.05, through: 0.95, by: 0.05) {
            let rgb = DolbyVisionColorSignal.iptPQToBT2020RGB(i: i, p: 0.5, t: 0.5)
            XCTAssertEqual(rgb.r, rgb.g, accuracy: 2e-4, "i=\(i) 红绿分量应相等")
            XCTAssertEqual(rgb.g, rgb.b, accuracy: 2e-4, "i=\(i) 绿蓝分量应相等")
        }
    }

    /// 黑点与白点:PQ 域 i=0 → 0;i=1(PQ 满码 = 10000 nits → 归一化 1.0,
    /// 幂 1/0.43 下 1.0 保持不变)时 IPT(1,0,0) 映射到 BT.2020 白 (1,1,1)。
    /// 白点容差 5e-4:行和 (1.00000021, 0.99998261, 1.00015420),G/B 偏离
    /// 1 的地板 1.54e-4。
    func testBlackAndWhiteEndpoints() {
        let black = DolbyVisionColorSignal.iptPQToBT2020RGB(i: 0, p: 0.5, t: 0.5)
        XCTAssertEqual(black.r, 0, accuracy: 1e-9)
        XCTAssertEqual(black.g, 0, accuracy: 1e-9)
        XCTAssertEqual(black.b, 0, accuracy: 1e-9)
        let white = DolbyVisionColorSignal.iptPQToBT2020RGB(i: 1, p: 0.5, t: 0.5)
        XCTAssertEqual(white.r, 1, accuracy: 5e-4)
        XCTAssertEqual(white.g, 1, accuracy: 5e-4)
        XCTAssertEqual(white.b, 1, accuracy: 5e-4)
    }

    /// 单调性:中性轴上 I 递增 → 线性 RGB 严格递增。
    func testMonotonicAlongNeutralAxis() {
        var prev = DolbyVisionColorSignal.iptPQToBT2020RGB(i: 0, p: 0.5, t: 0.5).r
        for i in stride(from: 0.05, through: 0.95, by: 0.05) {
            let cur = DolbyVisionColorSignal.iptPQToBT2020RGB(i: i, p: 0.5, t: 0.5).r
            XCTAssertGreaterThan(cur, prev, "i=\(i) 中性轴应严格单调")
            prev = cur
        }
    }

    /// ST 2084 锚点(线性 → PQ 信号,按规范公式独立复算:
    /// m1=0.1593017578125, m2=78.84375, c1=0.8359375,
    /// c2=18.8515625, c3=18.6875):
    /// 100 nits → 0.50807842、203 nits(SDR 参考白)→ 0.58068888、
    /// 1000 nits → 0.75182710。brief 原案的 0.5074/0.5801/0.7513 偏差
    /// ~6e-4(自称 1e-4),经幂 1/0.43 放大为 ~1.5% 输出偏差,已按复算值冻结。
    /// 期望输出 = 线性亮度^(1/0.43)×各通道行和(R/G/B 行和
    /// 1.00000021 / 0.99998261 / 1.00015420),按冻结信号字面量逐通道复算:
    /// 0.01 → 2.2327e-05、0.0203 → 1.1586e-04、0.1 → 4.7252e-03 量级。
    func testPQAnchorLuminances() {
        let cases: [(signal: Double, r: Double, g: Double, b: Double)] = [
            (0.5080784215, 2.232735616752e-05, 2.232696320613e-05, 2.233079435637e-05),   // 100 nits(线性 0.01)
            (0.5806888810, 1.158628921320e-04, 1.158608529455e-04, 1.158807338550e-04),   // 203 nits(线性 0.0203)
            (0.7518270962, 4.725183681134e-03, 4.725100517918e-03, 4.725911312016e-03),   // 1000 nits(线性 0.1)
        ]
        for c in cases {
            let rgb = DolbyVisionColorSignal.iptPQToBT2020RGB(i: c.signal, p: 0.5, t: 0.5)
            XCTAssertEqual(rgb.r, c.r, accuracy: 1e-9, "PQ \(c.signal) R 通道应解出 \(c.r)")
            XCTAssertEqual(rgb.g, c.g, accuracy: 1e-9, "PQ \(c.signal) G 通道应解出 \(c.g)")
            XCTAssertEqual(rgb.b, c.b, accuracy: 1e-9, "PQ \(c.signal) B 通道应解出 \(c.b)")
        }
    }
}
