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
    private var toneMapPipeline: MTLComputePipelineState?
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

        // Load HDR tone-mapping compute pipeline
        if let lib = device.makeDefaultLibrary(),
           let fn = lib.makeFunction(name: "hdr_to_sdr") {
            toneMapPipeline = try? device.makeComputePipelineState(function: fn)
        }

        logger.info("init OK, device=\(device.name)")
    }

    func display(pixelBuffer: CVPixelBuffer, colorParams: VideoColorParams = VideoColorParams()) {
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

        let needsToneMap = (colorParams.transfer == .pq || colorParams.transfer == .hlg) && toneMapPipeline != nil

        if needsToneMap {
            // HDR path: CIImage → compute shader (tone-map) → drawable
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            let texDesc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float, width: srcW, height: srcH, mipmapped: false)
            texDesc.usage = [.shaderRead, .shaderWrite]
            guard let pipeline = toneMapPipeline,
                  let inTex = device.makeTexture(descriptor: texDesc),
                  let outTex = device.makeTexture(descriptor: texDesc) else { return }

            ciContext.render(ciImage, to: inTex, commandBuffer: commandBuffer,
                             bounds: ciImage.extent, colorSpace: CGColorSpace(name: CGColorSpace.itur_2020)!)

            guard let computeEncoder = commandBuffer.makeComputeCommandEncoder() else { return }
            computeEncoder.setTexture(inTex, index: 0)
            computeEncoder.setTexture(outTex, index: 1)
            var transferVal: Int32 = (colorParams.transfer == .hlg) ? 1 : 0
            var doMatrix: Bool = (colorParams.matrix == .bt2020)
            computeEncoder.setBytes(&transferVal, length: MemoryLayout<Int32>.size, index: 0)
            computeEncoder.setBytes(&doMatrix, length: MemoryLayout<Bool>.size, index: 1)
            let tgSize = MTLSize(width: 16, height: 16, depth: 1)
            let tgCount = MTLSize(width: (srcW + 15) / 16, height: (srcH + 15) / 16, depth: 1)
            computeEncoder.setComputePipelineState(pipeline)
            computeEncoder.dispatchThreadgroups(tgCount, threadsPerThreadgroup: tgSize)
            computeEncoder.endEncoding()

            // Blit tone-mapped texture to drawable
            guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else { return }
            blitEncoder.copy(from: outTex, sourceSlice: 0, sourceLevel: 0,
                             sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                             sourceSize: MTLSize(width: srcW, height: srcH, depth: 1),
                             to: drawable.texture, destinationSlice: 0, destinationLevel: 0,
                             destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blitEncoder.endEncoding()
        } else {
            // SDR path: CIImage → drawable directly
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            ciContext.render(ciImage,
                             to: drawable.texture,
                             commandBuffer: commandBuffer,
                             bounds: ciImage.extent,
                             colorSpace: CGColorSpaceCreateDeviceRGB())
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()

        displayedFrames += 1
        if displayedFrames <= 3 {
            logger.info("displayed frame #\(self.displayedFrames): \(srcW)x\(srcH)")
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
