# VT → FFmpeg 软件解码回退

## 背景

VTVideoDecoder 使用 VideoToolbox 硬件解码 HEVC/H.264。当遇到超出硬件能力的参数时（如 4K@120fps），VT 创建 session 成功但每帧 decode 返回 nil，画面卡住。

Apple Silicon HEVC 硬解 ASIC 设计上限约 4K@60fps。120fps 时帧间隔 ~8ms，硬解单元来不及完成解码再接收下一帧，VTDecompressionSessionDecodeFrame 静默失败。

## 设计

### 1. VTVideoDecoder — 失败计数

- `consecutiveFailures`：连续 decode 失败计数，成功时归零
- `needsSoftwareFallback: Bool { consecutiveFailures >= 50 || initFailed }`
- `needsParamSetInit == true` 时不计数（参数采集阶段的 nil 是正常行为）
- 阈值 50 帧：120fps 下 ~0.4s，25fps 下 ~2s

### 2. FFmpegVideoDecoder — 强制软件模式

- init 新增 `forceSoftware: Bool = false`
- 为 true 时跳过 HEVC/H.264 的 VT 委托逻辑，跳过 hwaccel，直接 avcodec_open2 软解
- 默认行为不变

### 3. NativeBackend — 热替换

- `videoDecoder` 标记为 `nonisolated(unsafe)`（参考 seekSerial / demuxCancelled）
- demux loop 每帧 decode 前检查 needsSoftwareFallback，触发时创建 SW 解码器替换
- 无需重启 demux loop，下一帧直接走 SW 路径

```
if let vt = videoDecoder as? VTVideoDecoder, vt.needsSoftwareFallback {
    if let sw = FFmpegVideoDecoder(stream: demuxer.videoStream!, forceSoftware: true) {
        videoDecoder = sw
    }
}
```

## 涉及文件

| 文件 | 改动 |
|------|------|
| `PlayerKit/Sources/PlayerKitNative/VTVideoDecoder.swift` | 新增 failure counting 字段 |
| `PlayerKit/Sources/PlayerKitNative/FFmpegVideoDecoder.swift` | 新增 forceSoftware 参数 |
| `PlayerKit/Sources/PlayerKitNative/NativeBackend.swift` | videoDecoder 热替换逻辑 |
