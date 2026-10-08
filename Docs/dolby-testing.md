# 杜比视界 / HDR 功能矩阵与测试指南

功能实现状态的总账 + 人工验证的操作手册。渲染决策逻辑见
[hdr-rendering.md](hdr-rendering.md);本文回答"做到哪了"和"怎么确认它真的在跑"。

## 功能矩阵(2026-10-08)

| 能力 | 状态 | 实现位置 | 说明 |
|---|---|---|---|
| P5/P7/P8 检测分型路由 | ✅ | `RendererStrategy.swift` | DOVI_CONF 判 profile,绑定 decoder/renderer/tone-map |
| P5 IPT 转换 | ✅ | ToneMapProcessor (PlayerKitPro) | IPT→BT.2020,修复绿紫偏;GPU e2e 像素级验证 |
| L1 逐帧动态 tone map | ✅ | `DolbyVisionFrameMetadata.Level1` | 仅 mac EDR 路径可达;iOS/tvOS 走系统 |
| L2/L8 trim + L3 offset 精修 | ✅ | `parseDoviTrim`/`parseDoviLevel3` + 两 shader | libdovi 2048 中点约定;中性 trim 像素级 no-op |
| L6 (maxCLL/maxFALL) | ✅ | `EDRRenderer.swift` | 静态亮度目标 |
| HDR10+ bezier (ST 2094-40) | ✅ | `parseHDR10Plus` + EETF shader | 真 Bernstein 多锚点,逐帧 |
| EDR 探测(三端) | ✅ | `DisplayCapability.probeCurrent()` | mac NSScreen / iOS/tvOS potentialEDRHeadroom |
| P7 EL(BL+EL 双层) | ❌ 决策不做 | — | FEL 硬件稀少,降级 BL(HDR10)已可接受 |
| Dolby 官方认证 | ❌ 商业不做 | — | 含官方 logo 授权;客户端徽章用描述性文字 lockup |
| RPU reshape | ❌ 未做 | — | P5 完整还原需 Rust libdovi;当前 IPT 几何近似 + L2/L3 已接近 |
| PQ 10-bit 输出 | ❌ 未做 | — | tone map 目标现为 SDR 203 / EDR 1000 nits |
| AC-4 音频 | ❌ 零处理 | — | Apple 生态少见 |
| Atmos JOC 精确检测 | ❌ 启发式 | — | TrueHD profile / E-AC3 title 启发式够用 |

竞品坐标:Infuse/VidHub 的 DV 能力来自 Apple 系统授权管道(ATV 系统直出),
自研渲染器内的 L1/L2/L3 消费与 P5 IPT 修复是本项目独有;完整 reshape 行业
仅 mpv/libplacebo(libdovi)系实现。

## 测试分层

按成本从低到高,前两层不需要任何特殊设备。

### 第 1 层:检测与徽章(任意设备,5 分钟)

**验什么**:分型检测 → 徽章是否正确亮标。

1. 网盘里找一部**已知是杜比视界**的电影(文件名含 DV/DoVi/DV P5,或库里
   扫描后带 DV 标的)播放
2. 看播放器**顶栏标题旁**的徽章

预期:

| 片源 | 预期徽章 |
|---|---|
| DoVi P5/P8 | `DOLBY VISION`(Pro) / 降透明+锁(免费) |
| HDR10 | `HDR10` |
| HLG | `HLG` |
| SDR | 无徽章 |

反例也要测一部 HDR10 片——不该亮 DV 标(tone map 开关不影响判定,徽章
反映片源属性)。

### 第 2 层:P5 绿紫偏回归(mac,10 分钟)——最重要的画质验证

**验什么**:P5 的 IPT 色彩空间转换真的生效。

**背景**:P5 用 IPTPQc2(IPT) 色彩空间,若被当普通 BT.2020 PQ 读,
画面整体**绿紫偏**(肤色发绿、高光发紫)——这是"播放器不支持 P5"的
标志性症状,QuickTime 和多数播放器都有。

1. mac 上用本播放器播 P5 片
2. 看肤色、白色墙面、灰色场景

预期:颜色正常,无绿紫。
对照:同一文件用系统 QuickTime 或 Infuse 的非 DV 路径播,若绿紫即反证
片源确实是 P5 且我们修对了。

### 第 3 层:动态 tone map(需要 EDR 屏,XDR MacBook / 外接 HDR 显示器)

**验什么**:L1 逐帧 + L2/L3 精修的动态效果。

1. 播 DV 片,找**同一场景内明暗剧变**的片段(爆炸→黑夜、探照灯扫过)
2. 开关 设置 → 播放器 → tone mapping,对比:

预期:开 = 高光不过曝、暗部细节保留、亮暗过渡跟片源意图;关 = 系统直出
(可当作 baseline,但 EDR 屏上通常过曝更狠)。

L2/L3 是精修(±小幅修正),肉眼难单独分辨,已由第 5 层像素级验证覆盖。

### 第 4 层:HDR10+(片源稀缺,可选)

HDR10+ 片源少;有则同第 3 层方法,对比场景亮度过渡是否比普通 HDR10
更贴片源意图。

### 第 5 层:GPU 像素级(自动化,无需人眼)

shader 的正确性已由 GPU e2e 测试锁定(fixture 帧进 shader → 断言输出
像素值),改渲染代码前跑一遍:

```bash
cd /Users/francis/workspc/PlayerKitPro
xcodebuild test -scheme PlayerKitPro -destination 'platform=macOS' \
  -only-testing:PlayerKitProTests/DoViTrimShaderTests \
  -only-testing:PlayerKitProTests/HDR10PlusShaderTests
```

### tvOS / Apple TV 场景

ATV 4K + DV 电视:tvOS 走**系统直出**(Apple 是 Dolby 授权方,RPU 由系统
处理,HDMI 输出 DV)——这条路径三家播放器打平,我们只需验证第 1 层徽章
正确 + 播放正常,画质是系统责任。

## 已知边界(验证时别误判)

- L1/L2/L3 仅 **mac EDR 路径**可达;iOS/tvOS 播 DV 是系统直出,不是我们的
  tone map 在起作用
- 非 EDR mac 屏(如普通 LCD MacBook)走 `ciEDRFallback` 伪 PQ 路径,P5
  降级为 HDR10 静态——绿紫偏已修但无动态元数据
- Pro gating 挡**渲染本体**:免费用户播 DV 片先给 2 分钟全功能试用
  (`tickProTrial` 开 doviEnabled+注入 toneMapper),到期 `degradeToStandard()`
  关 DV 渲染,徽章同时降透明+锁(reflux 仓 `PlayerController.swift`)。
  注:当前客户端 `isPro` 默认 `true`(IAP 商品未配置),gating 暂未生效,
  验证时看到的都是全功能
- 徽章只反映**片源属性**:tone map 开关、EDR 与否都不影响亮标判定
