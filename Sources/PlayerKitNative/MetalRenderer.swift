import Foundation
import CoreVideo
import CoreImage
import Metal
import QuartzCore
import PlayerKit

final class MetalRenderer: VideoRenderer {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let metalLayer: CAMetalLayer
    private let ciContext: CIContext
    private var displayedFrames = 0

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
        NSLog("[MetalRenderer] init OK, device=\(device.name)")
    }

    func display(pixelBuffer: CVPixelBuffer) {
        let srcW = CVPixelBufferGetWidth(pixelBuffer)
        let srcH = CVPixelBufferGetHeight(pixelBuffer)
        guard srcW > 0, srcH > 0 else { return }

        // Keep drawableSize in sync with video frame dimensions so the blit is always
        // 1:1. The UIView/NSView layer sets contentsGravity to resizeAspect, so the
        // OS compositor handles the final aspect-ratio scaling to the screen.
        let videoSize = CGSize(width: srcW, height: srcH)
        if metalLayer.drawableSize != videoSize {
            metalLayer.drawableSize = videoSize
        }

        guard let drawable = metalLayer.nextDrawable(),
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        // CIContext.render handles any pixel format (BGRA, NV12, YUV) and renders
        // via the GPU command buffer, avoiding any CPU pixel copies.
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        ciContext.render(ciImage,
                         to: drawable.texture,
                         commandBuffer: commandBuffer,
                         bounds: ciImage.extent,
                         colorSpace: CGColorSpaceCreateDeviceRGB())

        commandBuffer.present(drawable)
        commandBuffer.commit()

        displayedFrames += 1
        if displayedFrames <= 3 {
            NSLog("[MetalRenderer] displayed frame #\(displayedFrames): \(srcW)x\(srcH)")
        }
    }

    func render(pixelBuffer: CVPixelBuffer, pts: Double) {
        display(pixelBuffer: pixelBuffer)
    }

    func flush() {
        if displayedFrames > 0 {
            NSLog("[MetalRenderer] flush, displayed \(displayedFrames) frames total")
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

    func updateColorParams(_ params: VideoColorParams) {
        // No-op: MetalRenderer uses CIContext which handles color automatically.
    }
}
