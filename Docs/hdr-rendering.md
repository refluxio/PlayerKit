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

每个 stream 类型 → 三维度的绑定。`metalHDR` 要求 10-bit VT/FFmpeg 输出 + EDR 显示器;`ciEDRFallback` 是非 EDR 显示器播 HDR 内容时的 CI fake-PQ 路径。

| Stream 类型 | Decoder | Renderer (EDR) | Renderer (非EDR) | Tone-map |
|------------|---------|----------------|------------------|----------|
| SDR 8-bit (BT.709/601) | `vtHW` | `ciSDR` | `ciSDR` | passthrough |
| SDR 10-bit | `vtHW` | `ciSDR` | `ciSDR` | passthrough |
| HDR10 PQ (静态 mastering) | `ffmpegHW` | `metalHDR` | `ciEDRFallback` | BT.2390 static |
| HDR10+ (ST 2094-40) | `ffmpegSW` | `metalHDR` | `ciEDRFallback` (降级为 HDR10) | HDR10+ bezier |
| DoVi Profile 5 | `ffmpegSW` | `metalHDR` | `ciEDRFallback` (降级为 HDR10) | BT.2390 + DoVi L1 |
| DoVi Profile 8 | `ffmpegSW` | `metalHDR` | `ciEDRFallback` (降级为 HDR10) | BT.2390 + DoVi L1 |
| DoVi Profile 7 (BL+EL) | `vtHW` | `metalHDR` | `ciEDRFallback` | BT.2390 static (降级) |
| HLG (广播) | `ffmpegHW` | `metalHDR` | `ciEDRFallback` (降级为 HDR10) | HLG OOTF |

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
    → sdr8Bit / sdr10Bit      (VT + ciSDR + passthrough)
```

`edrCapable = display.supportsEDR && renderer.prefersTenBit`。EDRRenderer.prefersTenBit == true,MetalRenderer.prefersTenBit == false。

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
