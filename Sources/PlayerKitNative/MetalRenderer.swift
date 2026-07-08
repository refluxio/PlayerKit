import Foundation
import CoreVideo
import CoreImage
import Metal
import QuartzCore
import PlayerKit
import os

private let logger = Logger(subsystem: "io.reflux.PlayerKit", category: "renderer")

final class MetalRenderer: VideoRenderer {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let metalLayer: CAMetalLayer
    private let ciContext: CIContext
    private var displayedFrames = 0
    private var lastVideoSize: CGSize = .zero

    /// Sample (pixel) aspect ratio from the video stream.  Default 1.0 = square
    /// pixels.  Non-square pixels (common in H.264 SD) require horizontal or
    /// vertical scaling so the displayed frame has the correct DAR.
    var sampleAspectRatio: Double = 1.0

    /// Coded (bitstream) dimensions from the decoder.  Hardware decoders may
    /// return alignment-padded CVPixelBuffers (e.g. 736×576 for 720×576); we
    /// use the codec-level dimensions to crop and compute the correct DAR.
    var codedSize: CGSize = .zero

    var layer: CALayer { metalLayer }

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw NSError(domain: "NativeBackend", code: -1, userInfo: [NSLocalizedDescriptionKey: "Metal unavailable"])
        }
        self.device = device
        self.commandQueue = device.makeCommandQueue()!
        self.metalLayer = CAMetalLayer()
        self.metalLayer.device = device
        self.metalLayer.pixelFormat = .bgra8Unorm
        self.metalLayer.framebufferOnly = false
        // contentsGravity is irrelevant here because we control drawableSize ourselves,
        // but set it as a hint to the compositor.
        self.metalLayer.contentsGravity = .resizeAspect
        self.ciContext = CIContext(mtlDevice: device, options: [.workingColorSpace: NSNull()])

        logger.info("init OK, device=\(device.name)")
    }

    func display(pixelBuffer: CVPixelBuffer, colorParams: VideoColorParams = VideoColorParams()) {
        // Use coded dimensions from the decoder — hardware may return
        // alignment-padded CVPixelBuffers (e.g. 736×576 for 720×576).
        // codedSize is authoritative and consistent across all frames.
        let codedW: Int
        let codedH: Int
        if codedSize.width > 0, codedSize.height > 0 {
            codedW = Int(codedSize.width); codedH = Int(codedSize.height)
        } else {
            codedW = CVPixelBufferGetWidth(pixelBuffer)
            codedH = CVPixelBufferGetHeight(pixelBuffer)
        }
        guard codedW > 0, codedH > 0 else { return }
        let pbW = CVPixelBufferGetWidth(pixelBuffer)
        let pbH = CVPixelBufferGetHeight(pixelBuffer)
        let needsCrop = (codedW != pbW || codedH != pbH)

        // Apply sample aspect ratio (SAR) — non-square pixels are common in
        // H.264 SD content (e.g. 720×576 SAR 16:15 → 768×576 display).
        let sar = sampleAspectRatio
        let (dispW, dispH): (Int, Int)
        if sar > 1.0 {
            dispW = Int(Double(codedW) * sar); dispH = codedH
        } else if sar < 1.0 {
            dispW = codedW; dispH = Int(Double(codedH) / sar)
        } else {
            dispW = codedW; dispH = codedH
        }
        let needsScale = (dispW != codedW || dispH != codedH)

        let videoSize = CGSize(width: dispW, height: dispH)
        if videoSize != lastVideoSize {
            metalLayer.drawableSize = videoSize
            lastVideoSize = videoSize
        }

        guard let drawable = metalLayer.nextDrawable(),
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        // Build CIImage, cropped to coded size then scaled for SAR if needed
        var ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        if needsCrop {
            ciImage = ciImage.cropped(to: CGRect(x: 0, y: 0, width: codedW, height: codedH))
        }
        if needsScale {
            let sx = CGFloat(dispW) / CGFloat(codedW)
            let sy = CGFloat(dispH) / CGFloat(codedH)
            ciImage = ciImage.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        }

        // Color-space-aware rendering.
        // For HDR content (PQ/HLG transfer), tell CoreImage the destination is
        // extended linear sRGB.  CoreImage applies the EOTF from the CIImage's
        // embedded colour space (BT.2020/PQ via VT attachments) → linear, then
        // maps to extended sRGB.  The bgra8Unorm drawable clips values > 1.0
        // which acts as a simple hard-clip tone-map.
        let dstColorSpace: CGColorSpace
        if colorParams.transfer == .pq || colorParams.transfer == .hlg {
            dstColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        } else {
            dstColorSpace = CGColorSpaceCreateDeviceRGB()
        }
        ciContext.render(ciImage,
                         to: drawable.texture,
                         commandBuffer: commandBuffer,
                         bounds: CGRect(x: 0, y: 0, width: dispW, height: dispH),
                         colorSpace: dstColorSpace)

        commandBuffer.present(drawable)

        // Hold a retain on pixelBuffer for the lifetime of the GPU work.
        // ciContext.render() and the blit encoder only *encode* reads into
        // commandBuffer; the actual GPU reads happen asynchronously after
        // commit(). The caller (displayNextFrame) releases its Frame — and
        // hence the pixelBuffer — as soon as this method returns, so without
        // an extra retain here the buffer could be freed (or recycled by the
        // VT pool) while the GPU is still sampling it → torn frames / 花屏.
        let pbUnmanaged = Unmanaged<CVPixelBuffer>.passRetained(pixelBuffer)
        commandBuffer.addCompletedHandler { _ in
            pbUnmanaged.release()
        }

        commandBuffer.commit()

        displayedFrames += 1
        if displayedFrames <= 3 {
            logger.info("displayed frame #\(self.displayedFrames): \(dispW)x\(dispH)")
        }
        // Reveal the layer on the first frame after a flush/clear.  We keep
        // opacity = 0 between stop() and the first new frame so the previous
        // video's last frame doesn't linger on screen during the (potentially
        // slow) demux + decode of the new video's first frame.
        if metalLayer.opacity == 0 {
            metalLayer.opacity = 1
        }
    }

    func render(pixelBuffer: CVPixelBuffer, pts: Double, colorParams: VideoColorParams) {
        display(pixelBuffer: pixelBuffer, colorParams: colorParams)
    }

    func flush() {
        if displayedFrames > 0 {
            logger.info("flush, displayed \(self.displayedFrames) frames total")
        }
        displayedFrames = 0
        // Don't set contents = nil — CAMetalLayer's contents is not a CGImage like
        // a normal CALayer; nilling it breaks the drawable presentation pipeline
        // and the layer stops updating entirely. The pre-seek frame will linger
        // briefly until the first post-seek frame is rendered, which is the lesser
        // evil compared to a permanently blank screen.
    }

    func clear() {
        metalLayer.opacity = 0
    }
}
