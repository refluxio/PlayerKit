import Foundation

/// Dolby Vision 基础层信号类型判定 + IPT(PQ)→ 线性 BT.2020 RGB 解码链。
///
/// Profile 5 及非 HDR10 兼容变体的 Profile 8,基础层不是 YCbCr 而是
/// IPTPQc2:PQ 编码的 IPT(强度-原色-三色)空间。用 BT.2020 YCbCr 矩阵
/// 解释这种信号会整体偏色(绿发青、肤色发橙、红品偏移)。正确的解码链
/// (Ebner & Fairchild 1998;矩阵常数与 libplacebo `pl_ipt_ipt2lms` /
/// `dovi_lms2rgb` 逐位一致):
///
///     每通道 PQ EOTF → IPT→L'M'S' 矩阵 → 幂 1/0.43 → HPE LMS → BT.2020 RGB
///
/// 注意 libplacebo 对 DoVi 只乘 `dovi_lms2rgb` 单矩阵,是因为它前置了
/// libdovi 的 RPU reshaping(IPT→LMS 域的非线性映射);没有 reshaping 时
/// 必须走本链路,不能把三步折叠成单个 3×3(中间隔着幂函数)。
///
/// 本类型是纯色彩科学的参考实现:无渲染依赖,供 shader 侧(PlayerKitPro)
/// 对齐常数与运算顺序,并作为单元测试基准。
public enum DolbyVisionColorSignal: Equatable {
    /// IPTPQc2 基础层:需要 IPT 解码链。
    case ipt
    /// 标准 YCbCr BT.2020 基础层(HDR10/HLG 兼容变体,及 P7/P4 等)。
    case bt2020YCbCr

    /// 按 RPU profile 与基础层信号兼容 ID 判定信号类型。两者来自
    /// `DolbyVisionFrameMetadata.profile` / `.blSignalCompatibilityId`。
    public static func resolve(profile: UInt8, blSignalCompatibilityId: UInt8) -> DolbyVisionColorSignal {
        switch profile {
        case 5:
            return .ipt
        case 8:
            // P8 compat 1/2 是 HDR10/HLG 兼容基础层(YCbCr BT.2020);
            // 0/4 是 DV 独有 IPT 基础层,无兼容回退。
            return (blSignalCompatibilityId == 1 || blSignalCompatibilityId == 2) ? .bt2020YCbCr : .ipt
        default:
            // P7 的基础层是标准 HDR10;P4/未知 profile 同样按标准 BL 解释。
            return .bt2020YCbCr
        }
    }

    /// IPT→L'M'S':`pl_ipt_lms2ipt`(Ebner & Fairchild 1998)的数值逆,
    /// libplacebo verbatim。
    public static let iptToLMS: [[Double]] = [
        [1.0, 0.0975689, 0.205226],
        [1.0, -0.1138760, 0.133217],
        [1.0, 0.0326151, -0.676887],
    ]

    /// HPE LMS→线性 BT.2020 RGB:libplacebo `dovi_lms2rgb` verbatim
    /// ("Dolby Vision always outputs BT.2020-referred HPE LMS")。
    public static let lmsToBT2020RGB: [[Double]] = [
        [3.06441879, -2.16597676, 0.10155818],
        [-0.65612108, 1.78554118, -0.12943749],
        [0.01736321, -0.04725154, 1.03004253],
    ]

    /// IPT 非线性幂(Ebner 实验拟合 0.43 的逆),非 sRGB 家族的 2.4。
    public static let iptPowerExponent: Double = 1.0 / 0.43

    /// 参考解码链:PQ 编码 IPTPQc2 信号 → 线性 BT.2020 RGB。输入为全范围
    /// PQ 编码信号(非 YCbCr limited range)。IPTPQc2 全范围量化,中性
    /// 色度在数字码域中点 0.5,故 P/T 经 PQ EOTF 后减去 EOTF(0.5) 归零
    /// 中性(偏置发生在码域中心,不是 EOTF 后的线性 0.5——PQ EOTF(0.5)
    /// ≈ 0.0088,码域中点在线性域深压缩区)。shader 端逐位对齐此实现。
    public static func iptPQToBT2020RGB(i: Double, p: Double, t: Double) -> (r: Double, g: Double, b: Double) {
        let neutral = pqEotf(0.5)
        let ipt = [pqEotf(i), pqEotf(p) - neutral, pqEotf(t) - neutral]
        let lmsP = matVec(iptToLMS, ipt)
        let lms = lmsP.map { pow(max($0, 0), iptPowerExponent) }
        let rgb = matVec(lmsToBT2020RGB, lms)
        return (rgb[0], rgb[1], rgb[2])
    }

    /// SMPTE ST 2084 EOTF,输入/输出均 [0,1](1.0 = 10000 cd/m²)。
    private static func pqEotf(_ x: Double) -> Double {
        let m1 = 2610.0 / 16384.0
        let m2 = 2523.0 / 4096.0 * 128.0
        let c1 = 3424.0 / 4096.0
        let c2 = 2413.0 / 4096.0 * 32.0
        let c3 = 2392.0 / 4096.0 * 32.0
        let xp = pow(max(x, 0), 1.0 / m2)
        return pow(max(xp - c1, 0) / (c2 - c3 * xp), 1.0 / m1)
    }

    static func matMul(_ a: [[Double]], _ b: [[Double]]) -> [[Double]] {
        (0..<3).map { i in
            (0..<3).map { j in
                (0..<3).reduce(0) { $0 + a[i][$1] * b[$1][j] }
            }
        }
    }

    static func matVec(_ m: [[Double]], _ v: [Double]) -> [Double] {
        (0..<3).map { i in
            (0..<3).reduce(0) { $0 + m[i][$1] * v[$1] }
        }
    }
}
