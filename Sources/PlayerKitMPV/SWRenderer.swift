import PlayerKit
// Packages/MPVKit/Sources/MPVKit/Render/SWRenderer.swift
import AVFoundation
import CoreMedia
import CoreVideo
import QuartzCore

// MARK: - SWRenderer

/// BGRA SW render → CMSampleBuffer → AVSampleBufferDisplayLayer（兜底路径）。
@MainActor
final class SWRenderer: MPVInternalRenderer {

    // MARK: VideoRenderer

    let displayLayer: AVSampleBufferDisplayLayer = {
        let l = AVSampleBufferDisplayLayer()
        l.videoGravity = .resizeAspect
        return l
    }()

    var layer: CALayer { displayLayer }

    func render(pixelBuffer: CVPixelBuffer, pts: Double) {
        // MPV renders via its own callback; CVPixelBuffer delivery not supported
    }

    // MARK: Private state

    private let renderCtx: MPVRenderContext
    private var pool:              CVPixelBufferPool?
    private var formatDescription: CMVideoFormatDescription?
    private var lastWidth  = 0
    private var lastHeight = 0
    private var frameCount = 0

    init(renderCtx: MPVRenderContext) {
        self.renderCtx = renderCtx
    }

    // MARK: - VideoRenderer

    func renderFrame(width: Int, height: Int) {
        guard renderCtx.consumeNewFrame() else { return }
        ensurePool(width: width, height: height)
        guard let pool else { return }

        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer) == kCVReturnSuccess,
              let pixelBuffer else { return }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard renderCtx.render(into: base, width: width, height: height, bytesPerRow: stride) == 0 else { return }

        if formatDescription == nil || width != lastWidth || height != lastHeight {
            var desc: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: nil, imageBuffer: pixelBuffer, formatDescriptionOut: &desc)
            formatDescription = desc
            lastWidth = width; lastHeight = height
        }
        guard let formatDesc = formatDescription else { return }

        var timing = CMSampleTimingInfo(
            duration:              CMTime(value: 1, timescale: 60),
            presentationTimeStamp: CMTime(seconds: CACurrentMediaTime(), preferredTimescale: 600),
            decodeTimeStamp:       .invalid)
        var sb: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil, imageBuffer: pixelBuffer,
            formatDescription: formatDesc, sampleTiming: &timing, sampleBufferOut: &sb)
        guard let sb else { return }

        frameCount += 1
        if frameCount <= 5 || frameCount % 300 == 0 {
            NSLog("[mpvkit][sw#\(frameCount)] status=\(displayLayer.status.rawValue)")
        }
        displayLayer.enqueue(sb)
    }

    func flush() {
        displayLayer.flushAndRemoveImage()
        _ = renderCtx.consumeNewFrame()  // 清除 mpv 残留帧标记
        renderCtx.reportSwap()
        formatDescription = nil
        lastWidth = 0; lastHeight = 0
    }

    func clear() {
        displayLayer.flushAndRemoveImage()
    }

    func updateColorParams(_ params: VideoColorParams) {
        // ASBDL 自动处理色彩管理，无需操作
    }

    // MARK: - Private

    private func ensurePool(width: Int, height: Int) {
        guard width != lastWidth || height != lastHeight else { return }
        pool = nil
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey:     kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey:               width,
            kCVPixelBufferHeightKey:              height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey:  true,
        ]
        CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            [kCVPixelBufferPoolMinimumBufferCountKey: 3] as CFDictionary,
            attrs as CFDictionary, &pool)
    }
}
