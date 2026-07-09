# HDR 渲染决策

## 背景

视频格式(HDR10 / HDR10+ / DoVi P5/P7/P8 / HLG / SDR)与显示器能力(EDR / 非 EDR)、解码器能力(VT 硬解 / FFmpeg 软解)的组合空间很大。如果每个格式硬编码一条渲染路径,会出现"为了加 DoVi P8 又改一个 case"的散乱状态。

本文档定义**唯一的标准决策逻辑**:给定一条 video stream,应该用哪个 decoder、哪个 renderer entry、哪种 tone-map algorithm。所有改动必须先对照本文档判断归属,而不是直接改 `decideRendererStrategy`。

源码:`PlayerKit/Sources/PlayerKit/RendererStrategy.swift`。

## 三个正交维度

HDR 渲染决策不是"一个格式对应一种方式",而是三个独立维度的笛卡尔积。每个维度只回答一个问题,维度之间互不耦合:

| 维度 | 回答的问题 | 决策依据 | 选项 |
|------|-----------|---------|------|
| **Decoder** | 怎么解码 | 是否需要保留 RPU / ST 2094-40 元数据 | `vtHW` / `ffmpegHW` / `ffmpegSW` |
| **Renderer entry** | 往哪里画 | 显示器是否支持 EDR | `metalHDR` / `ciSDR` / `ciEDRFallback` |
| **Tone-map algorithm** | 怎么压 | 元数据来源(passthrough / 静态 / 动态) | 5 种,见下 |

**关键不变量**:三个维度由 `RendererStrategy` enum case 统一绑定,不可能出现"DoVi stream 用 SW 解但 shader 走 BT.2390 static(漏掉 L1)"这种错配。新增格式 = 新增 enum case,在 case 内同时定义三个维度的绑定。

## 完整决策表

每个 stream 类型 → decoder / renderer / tone-map 三维度的绑定。`metalHDR` 要求 10-bit VT/FFmpeg 输出 + EDR 显示器;`ciEDRFallback` 是非 EDR 显示器播 HDR 内容时的 CI fake-PQ 路径(用 `CIToneCurve` 把 PQ 压成 SDR)。

| 内容格式 | 显示器 | Decoder | Renderer Pipeline | Tone-map |
|---|---|---|---|---|
| **SDR 8-bit** (BT.709/601) | 任意 | VT 直解 (`vtHW`) | `ciSDR` | passthrough |
| **SDR 10-bit** | 任意 | VT 直解 (`vtHW`) | `ciSDR` | passthrough |
| **HDR10 PQ** (静态 mastering) | EDR | FFmpeg VT hwaccel (`ffmpegHW`) | `metalHDR` | BT.2390 static |
| HDR10 PQ | 非 EDR | FFmpeg VT hwaccel (`ffmpegHW`) | `ciEDRFallback` | 伪 PQ (CIToneCurve) |
| **HDR10+** (ST 2094-40) | EDR | **FFmpeg 软解** (`ffmpegSW`) | `metalHDR` | HDR10+ bezier |
| HDR10+ | 非 EDR | FFmpeg VT hwaccel (`ffmpegHW`) | `ciEDRFallback` | 降级为 HDR10 静态 |
| **DoVi Profile 5** | EDR | **FFmpeg 软解** (`ffmpegSW`) | `metalHDR` | BT.2390 + DoVi L1 动态 |
| DoVi Profile 5 | 非 EDR | FFmpeg 软解 (`ffmpegSW`) | `ciEDRFallback` | 降级为 HDR10 静态 |
| **DoVi Profile 7** (BL+EL) | EDR | VT 直解 (`vtHW`) | `metalHDR` | BT.2390 static (降级) |
| DoVi Profile 7 | 非 EDR | VT 直解 (`vtHW`) | `ciEDRFallback` | 降级为 HDR10 静态 |
| **DoVi Profile 8** | EDR | **FFmpeg 软解** (`ffmpegSW`) | `metalHDR` | BT.2390 + DoVi L1 (CT 模式退回静态) |
| DoVi Profile 8 | 非 EDR | FFmpeg 软解 (`ffmpegSW`) | `ciEDRFallback` | 降级为 HDR10 静态 |
| **HLG** (广播) | EDR | FFmpeg VT hwaccel (`ffmpegHW`) | `metalHDR` | HLG OOTF + BT.2390 |
| HLG | 非 EDR | FFmpeg VT hwaccel (`ffmpegHW`) | `ciEDRFallback` | 降级为 HDR10 静态 |
| **未标记 HDR10** (HEVC 10-bit + transfer=SDR) | EDR | FFmpeg VT hwaccel (`ffmpegHW`) | `metalHDR` | BT.2390 static |
| 未标记 HDR10 | 非 EDR | FFmpeg VT hwaccel (`ffmpegHW`) | `ciEDRFallback` | 伪 PQ (CIToneCurve) |

最后一行见下文"未标记 HDR10 的判定"。

## 决策树(`decideRendererStrategy` 实现)

```
if stream.isDolbyVision:
    match stream.doviProfile:
        5 → doviProfile5      (SW + MetalHDR + L1)
        8 → doviProfile8      (SW + MetalHDR + L1, bl_compat_id==2 时 tonemapCompat=true)
        7 → degradedHDR10     (VT 当 HDR10 处理,SW 双层解超出范围)
        _ → degradedHDR10
elif stream.transfer == .pq:
    if stream.hasHDR10Plus && edrCapable:
        → hdr10Plus           (SW + MetalHDR + bezier)
    else:
        → hdr10Static(1000)   (HW + MetalHDR + BT.2390 static)
elif stream.transfer == .hlg:
    edrCapable ? hlgOOTF      (HW + MetalHDR + OOTF)
               : hdr10Static   (降级)
else:  # .sdr
    # 未标记 HDR10 兜底:HEVC + 10-bit + transfer=SDR 视为 PQ 漏标(见下节)
    if stream.isHEVC10BitSDRHint && (edrCapable || display.supportsEDR):
        → hdr10Static(1000)   (HW + MetalHDR + BT.2390 static)
    else:
        → sdr8Bit / sdr10Bit  (VT + ciSDR + passthrough)
```

`edrCapable = display.supportsEDR && renderer.prefersTenBit`。EDRRenderer.prefersTenBit == true,MetalRenderer.prefersTenBit == false。

## 未标记 HDR10 的判定

### 背景

很多老 Blu-ray remux(尤其是 2018 年前压制的 HEVC 10-bit MKV)在容器层**没有写 `color_trc` 标签**。FFmpeg 读 codecpar 时 `color_trc = AVCOL_TRC_UNSPECIFIED`(数值 0),`decideRendererStrategy` 把它归到 `.sdr` 分支,选 `sdr8Bit` strategy → 走 8-bit CI SDR pipeline → 把 PQ 像素当 sRGB 线性值渲染 → **人脸发红过曝、高光死白、暗部死黑**。

这是 PlayerKit 历史上一个真实的回归 bug:1918x1036 HEVC + AC3 + PGS 字幕的蓝光 remux,日志同时报:

```
renderer strategy: sdr8Bit(matrix: bt709)        ← 判定 SDR
video: VT 1918x1036 10bit=true                   ← 但 VT 输出 10-bit
```

两者矛盾:`sdr8Bit` 走 8-bit CI pipeline,但 VT 给的是 10-bit 像素,说明 codecpar 里 `bits_per_raw_sample=10`。HEVC 10-bit 在真实片源里几乎只有 HDR10(PQ)或 DoVi,真 SDR 10-bit HEVC 基本不存在(广电 SDR 是 8-bit H.264 或 10-bit H.265 但带显式 transfer 标签)。

### 兜底规则

在 `decideRendererStrategy` 的 `.sdr` 分支加一条:

```
若 stream.isHEVC10Bit && stream.transfer == .sdr && (edrCapable || display.supportsEDR)
    → 走 hdr10Static(peakNits: 1000)
```

- `isHEVC10Bit` 由 `NativeBackend` 构造 `VideoStreamAttributes` 时根据 `cp.codec_id == AV_CODEC_ID_HEVC && cp.bits_per_raw_sample == 10` 填入
- 只对 EDR 显示器(或 EDR-capable renderer)生效——非 EDR 显示器即便走 `hdr10Static`,rendererEntry 也会自动退到 `ciEDRFallback`,不会假装 HDR
- H.264 不套用此规则(H.264 没有 HDR10 profile,真 HDR10 都是 HEVC Main 10)
- DoVi stream 优先级在前面,不受影响(DoVi conf 比 transfer 字段更可靠)

### 边界与误伤分析

| 场景 | 是否误伤 | 说明 |
|---|---|---|
| 真 HDR10 remux,容器漏标 `color_trc` | ✅ 正确修复 | 走 `hdr10Static` + BT.2390,人脸不再发红 |
| 真 HDR10 remux,容器标了 `color_trc=PQ` | 无影响 | `transfer == .pq` 分支直接命中,不走兜底 |
| 真 SDR 8-bit H.264 | 无影响 | `isHEVC10Bit=false`,走原 SDR 路径 |
| 真 SDR 10-bit HEVC(罕见,如某些 BT.709 10-bit 制作) | ⚠️ 可能误判 | 走 `hdr10Static`,PQ EOTF 把 sRGB 当 PQ 解 → 偏暗。可接受:此类源极少,且用户可手动在容器补 `color_trc=bt709` 修正 |
| DoVi Profile 7 stream | 无影响 | `isDolbyVision=true` 优先命中 DoVi 分支 |

### 决策日志

`NativeBackend._finishOpen` 在定 strategy 后打一行完整决策日志,把"为什么选这个 strategy"在一行内说清:

```
strategy decision: codec=hvc1 1918x1036 bits_per_raw=10 trc=0 matrix=1 range=1 \
  → resolved(transfer=sdr matrix=bt709 range=limited) \
  isHEVC10Bit=true isDoVi=false profile=0 hasHDR10Plus=false \
  displayEDR=true renderer10bit=true \
  → hdr10Static(peakNits: 1000)
```

- `trc` / `matrix` / `range` 是 FFmpeg codecpar 原始 raw 值(0=UNSPECIFIED, 1=BT.709, ...)
- `resolved(...)` 是 `VideoColorParams` 转换后的语义值
- 末尾 `→ hdr10Static(...)` 是最终 strategy

排查"为什么这个视频人脸发红"时,先 grep `strategy decision:` 这行,看 `trc` 和 `isHEVC10Bit` 即可定位。

## 排查历史:人脸发红过曝

### 症状

某 1918x1036 HEVC + AC3 + PGS 字幕的 MKV 在 macOS XDR 屏上播放,人脸发红、高光死白。

### 日志关键证据

```
renderer strategy: sdr8Bit(matrix: bt709)        ← 判 SDR
video: VT 1918x1036 10bit=true                   ← VT 输出 10-bit
CI SDR: coded=1918x1036                          ← 走 8-bit CI SDR pipeline
```

三个事实放一起矛盾:strategy 说 SDR 8-bit,VT 却给 10-bit 像素。这只能说明 codecpar 的 `bits_per_raw_sample=10` 但 `color_trc=UNSPECIFIED`(0)。

### 根因

`decideRendererStrategy` 的 `.sdr` 分支只看 `stream.transfer`,不看 codec 也不看 bit depth。漏标 `color_trc` 的 HEVC 10-bit HDR10 remux 被误判为 SDR 8-bit → `MetalRenderer.display` 走 8-bit CI SDR pipeline → 把 PQ 像素(0..1 但实际是 PQ 编码的绝对亮度值)当 sRGB 线性值直接渲染 → PQ 的 mid-tone(0.5 PQ ≈ 92 cd/m²)被当成 sRGB 0.5 → **人脸肤色被拉到接近白色,红通道饱和爆掉**。

### 系统性排查步骤

1. **读 strategy 日志** — `renderer strategy: sdr8Bit(matrix: bt709)` 立刻说明走错路径
2. **对比解码器实际输出** — `VT 10bit=true` 和 strategy 不符,说明 strategy 判定与实际像素格式脱钩
3. **回溯数据流** — strategy 由 `decideRendererStrategy(stream:, prefersTenBit:, display:)` 决定;`stream.transfer` 由 `NativeBackend._finishOpen` 从 `cp.color_trc` 转换;`cp.color_trc` 是 FFmpeg 从 MKV 容器读的原始值
4. **验证假设** — 容器漏标 `color_trc` 是老 remux 常见现象。`ffprobe` 该文件确认 `color_trc=unknown`
5. **设计修复** — 在 SDR 分支加 HEVC 10-bit 兜底,视为未标记 HDR10(见上节"未标记 HDR10 的判定")
6. **加决策日志** — 把 stream 原始 color_trc / matrix / range + 转换后值 + 最终 strategy 一起打出来,后续类似问题可一行定位

### 反面教训

- **strategy 不能只看 transfer**。`bits_per_raw_sample` 和 codec 是同样强的信号。HEVC 10-bit + transfer=SDR 在真实片源里几乎不存在的反证,比"容器写了 transfer=SDR"的正证更可信。
- **strategy 决策和实际像素格式必须自洽**。如果 strategy 说 SDR 8-bit 但 decoder 输出 10-bit,说明中间有信息丢失——要么 strategy 漏判,要么 decoder 没按 strategy 走。这条不变量应该被日志直接暴露。

## 三条简化原则

### 1. 优先级:DoVi > HDR10+ > HLG > HDR10 > SDR

越靠前元数据越"动态"(per-frame 变化),必须走 FFmpeg SW + Metal HDR pipeline 才能拿到 `FrameMetadata.dovi.level1` / `hdr10Plus.bezierCurve`。SDR 没有元数据,passthrough 最快。

### 2. 能力降级:任何 HDR 在非 EDR 显示器上都降级为 `hdr10Static` + `ciEDRFallback`

非 EDR 显示器无法直接显示 PQ/HLG 信号,只能用 CI 的 `CIToneCurve` 把 HDR 压成 SDR 假装渲染。此时 DoVi/HDR10+ 的动态元数据完全失效(没有 EDR headroom,压不动)。`rendererEntry(display:)` 内部根据 `display.supportsEDR` 自动选 `metalHDR` 或 `ciEDRFallback`,caller 不用单独判断。

### 3. 解码器铁律:需要保留 RPU 或 ST 2094-40 → 必须 FFmpeg SW

- VT 硬解对 DV stream 会**剥离 RPU**(`AV_FRAME_DATA_DOVI_RPU_BUFFER` / `AV_FRAME_DATA_DOVI_METADATA` 都拿不到),DoVi stream 走 VT 等于丢掉所有动态元数据 → 退化成 HDR10 static
- VT 硬解对 HDR10+ stream 会**剥离 ST 2094-40** SEI,同理退化成 HDR10 static
- HDR10 / HLG 的 mastering display 和 content light level 是 stream 级静态元数据,VT 不剥,可以走 `ffmpegHW`(FFmpeg VT hwaccel,给 IOSurface-backed 10-bit CVPixelBuffer)
- SDR 走 `vtHW`(VTVideoDecoder 直连,最快,零拷贝 IOSurface → Metal)

## 渲染管线物理路径

```
┌─────────────┐     ┌──────────────────┐     ┌──────────────────────┐
│ FFmpeg SW   │ ──→ │ YCbCr 10-bit     │ ──→ │ EDRRenderer           │
│ (DoVi/HDR10+)│    │ planar (CPU RAM)  │     │ Metal HDR pipeline   │
└─────────────┘     └──────────────────┘     │ + ToneMapUniform      │
                                              │ + per-frame metadata  │
┌─────────────┐     ┌──────────────────┐     │                        │
│ FFmpeg HW   │ ──→ │ IOSurface-backed │ ──→ │                        │
│ (HDR10/HLG) │     │ 10-bit biplanar   │     │                        │
└─────────────┘     └──────────────────┘     └──────────────────────┘
                                               ↓ MTLDrawable
┌─────────────┐     ┌──────────────────┐     ┌──────────────────────┐
│ VT direct   │ ──→ │ IOSurface-backed │ ──→ │ CIContext (SDR/EDR    │
│ (SDR)       │     │ 8-bit             │     │ fallback)            │
└─────────────┘     └──────────────────┘     └──────────────────────┘
```

## 涉及文件

| 文件 | 作用 |
|------|------|
| `PlayerKit/Sources/PlayerKit/RendererStrategy.swift` | `VideoStreamAttributes` / `RendererStrategy` enum / `decideRendererStrategy` 纯函数 |
| `PlayerKit/Sources/PlayerKit/FrameMetadata.swift` | `FrameMetadata` / `DolbyVisionFrameMetadata` / `HDR10PlusFrameMetadata` / `MasteringDisplayMetadata` |
| `PlayerKit/Sources/PlayerKit/VideoRenderer.swift` | `VideoRenderer` 协议,`VideoColorParams`,`DisplayCapability` |
| `PlayerKit/Sources/PlayerKitNative/NativeBackend.swift` | decoder 选择、jitter buffer、render 调用 |
| `PlayerKit/Sources/PlayerKitNative/FFmpegVideoDecoder.swift` | FFmpeg SW/HW 解码,提取 `FrameMetadata` |
| `PlayerKit/Sources/PlayerKitNative/VTVideoDecoder.swift` | VT 直解,返回 `FrameMetadata()` 空 |
| `PlayerKitPro/Sources/PlayerKitPro/EDRRenderer.swift` | Metal 10-bit HDR pipeline + 5 种 tone-map algorithm |

## 新增 HDR 格式时的流程

1. 判断该格式是否有 per-frame 动态元数据 → 决定走 SW 还是 HW
2. 在 `RendererStrategy` enum 新增 case,同时绑定三个维度(`pixelFormat10Bit` / `decoderPreference` / `rendererEntry(display:)` / `toneMapAlgorithm`)
3. 在 `decideRendererStrategy` 的决策树里加分支
4. 如有新元数据类型,在 `FrameMetadata` 加 struct,FFmpegVideoDecoder 提取
5. EDRRenderer 的 `makeToneMapUniform` 加 `algorithm` 分支,shader `fs_main` 加对应 switch case
6. 更新本文档的决策表

## 不做

- DoVi Profile 7 BL+EL 双层软件解码(复杂,留后续)
- AV1 HDR(等 AV1 decoder 接入后再加 case)
- HDR Vivid(国内标准,等需求)
- DisplayCapability 的实时 NSScreen 监听(初版硬编码 1000 nits target,后续接 `NSScreen.maximumExtendedDynamicRangeColorComponentValue`)
