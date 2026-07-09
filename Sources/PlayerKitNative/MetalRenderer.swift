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

    private var codedSize: CGSize = .zero
    private var sampleAspectRatio: Double = 1.0

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

        // Apply PQ→sRGB tone curve for HDR content.  We use an explicit
        // CIToneCurve rather than relying on CoreImage automatic colour management,
        // because VT's 8-bit output may not carry BT.2020/PQ attachments reliably.
        if colorParams.transfer == .pq || colorParams.transfer == .hlg {
            let toneCurve = CIFilter(name: "CIToneCurve")!
            toneCurve.setValue(ciImage, forKey: kCIInputImageKey)
            toneCurve.setValue(CIVector(x: 0.0, y: 0.0),  forKey: "inputPoint0")
            toneCurve.setValue(CIVector(x: 0.15, y: 0.08), forKey: "inputPoint1")
            toneCurve.setValue(CIVector(x: 0.4, y: 0.25),  forKey: "inputPoint2")
            toneCurve.setValue(CIVector(x: 0.7, y: 0.68),  forKey: "inputPoint3")
            toneCurve.setValue(CIVector(x: 1.0, y: 1.0),   forKey: "inputPoint4")
            ciImage = toneCurve.outputImage ?? ciImage
        }
        ciContext.render(ciImage,
                         to: drawable.texture,
                         commandBuffer: commandBuffer,
                         bounds: CGRect(x: 0, y: 0, width: dispW, height: dispH),
                         colorSpace: CGColorSpaceCreateDeviceRGB())

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

    func configure(codedSize: CGSize, sampleAspectRatio: Double) {
        self.codedSize = codedSize
        self.sampleAspectRatio = sampleAspectRatio
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
