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

        // Compile the HDR tone-mapping shader at runtime.
        // Shaders.metal is not auto-compiled by SPM (it warns "unhandled"),
        // so we embed the source inline and use makeLibrary(source:).
        let mtlSource = """
        #include <metal_stdlib>
        using namespace metal;

        constant float PQ_m1 = 0.1593017578125;
        constant float PQ_m2 = 78.84375;
        constant float PQ_c1 = 0.8359375;
        constant float PQ_c2 = 18.8515625;
        constant float PQ_c3 = 18.6875;

        float pq_to_linear(float x) {
            float xp = pow(max(x, 0.0f), 1.0f / PQ_m2);
            float num = max(xp - PQ_c1, 0.0f);
            float den = PQ_c2 - PQ_c3 * xp;
            return pow(num / max(den, 0.0001f), 1.0f / PQ_m1);
        }
        float3 pq_to_linear(float3 rgb) {
            return float3(pq_to_linear(rgb.r), pq_to_linear(rgb.g), pq_to_linear(rgb.b));
        }

        float hlg_ootf(float x) {
            float a = 0.17883277f;
            float b = 1.0f - 4.0f * a;
            float c = 0.5f - a * log(4.0f * a);
            if (x <= 1.0f / 12.0f) return sqrt(3.0f * x);
            else return a * log(12.0f * x - b) + c;
        }
        float3 hlg_to_linear(float3 rgb) {
            return float3(hlg_ootf(rgb.r), hlg_ootf(rgb.g), hlg_ootf(rgb.b));
        }

        constant float3x3 bt2020_to_bt709 = float3x3(
            float3( 1.6605f, -0.5876f, -0.0728f),
            float3(-0.1246f,  1.1329f, -0.0083f),
            float3(-0.0182f, -0.1006f,  1.1187f)
        );

        float3 bt2390_eetf(float3 rgb) {
            // Simple Reinhard tone-map: x is linear light in nits (0–10 000 for PQ).
            // SDR white ≈ 80 nits gives mid-gray at ~0.5, highlights compress toward 1.0.
            float exposure = 1.0f / 80.0f;
            float luma = dot(rgb, float3(0.2627f, 0.6780f, 0.0593f));
            if (luma < 0.0001f) return float3(0.0f);
            float xp = luma * exposure;
            float s = (xp / (1.0f + xp)) / luma;
            return rgb * s;
        }

        kernel void hdr_to_sdr(texture2d<float, access::read>  in  [[texture(0)]],
                                texture2d<float, access::write> out [[texture(1)]],
                                constant int  &transfer     [[buffer(0)]],
                                constant bool &doColorMatrix [[buffer(1)]],
                                uint2 gid [[thread_position_in_grid]]) {
            if (gid.x >= in.get_width() || gid.y >= in.get_height()) return;
            float3 rgb = in.read(gid).rgb;
            if (transfer == 0)      rgb = pq_to_linear(rgb);
            else if (transfer == 1) rgb = hlg_to_linear(rgb);
            rgb = bt2390_eetf(rgb);
            if (doColorMatrix) rgb = bt2020_to_bt709 * rgb;
            rgb = clamp(rgb, 0.0f, 1.0f);
            out.write(float4(rgb, 1.0f), gid);
        }
        """
        if let lib = try? device.makeLibrary(source: mtlSource, options: nil),
           let fn  = lib.makeFunction(name: "hdr_to_sdr") {
            toneMapPipeline = try? device.makeComputePipelineState(function: fn)
            logger.info("HDR tone-map shader compiled OK")
        } else {
            logger.warning("HDR tone-map shader compile failed — HDR will display as SDR")
        }

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

        // Tone-map only when we have native 10-bit HDR pixel data.
        // With 8-bit VT output, VT handles 10→8 conversion internally and the output
        // is SDR-ready — applying another tone map would over-darken.
        let pixelIs10Bit = CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        let needsToneMap = pixelIs10Bit && (colorParams.transfer == .pq || colorParams.transfer == .hlg) && toneMapPipeline != nil

        if needsToneMap {
            // HDR path: CIImage → compute shader (tone-map) → drawable
            let texDesc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float, width: dispW, height: dispH, mipmapped: false)
            texDesc.usage = [.shaderRead, .shaderWrite]
            guard let pipeline = toneMapPipeline,
                  let inTex = device.makeTexture(descriptor: texDesc),
                  let outTex = device.makeTexture(descriptor: texDesc) else { return }

            ciContext.render(ciImage, to: inTex, commandBuffer: commandBuffer,
                             bounds: CGRect(x: 0, y: 0, width: dispW, height: dispH),
                             colorSpace: CGColorSpace(name: CGColorSpace.itur_2020)!)

            guard let computeEncoder = commandBuffer.makeComputeCommandEncoder() else { return }
            computeEncoder.setTexture(inTex, index: 0)
            computeEncoder.setTexture(outTex, index: 1)
            var transferVal: Int32 = (colorParams.transfer == .hlg) ? 1 : 0
            var doMatrix: Bool = (colorParams.matrix == .bt2020)
            computeEncoder.setBytes(&transferVal, length: MemoryLayout<Int32>.size, index: 0)
            computeEncoder.setBytes(&doMatrix, length: MemoryLayout<Bool>.size, index: 1)
            let tgSize = MTLSize(width: 16, height: 16, depth: 1)
            let tgCount = MTLSize(width: (dispW + 15) / 16, height: (dispH + 15) / 16, depth: 1)
            computeEncoder.setComputePipelineState(pipeline)
            computeEncoder.dispatchThreadgroups(tgCount, threadsPerThreadgroup: tgSize)
            computeEncoder.endEncoding()

            guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else { return }
            blitEncoder.copy(from: outTex, sourceSlice: 0, sourceLevel: 0,
                             sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                             sourceSize: MTLSize(width: dispW, height: dispH, depth: 1),
                             to: drawable.texture, destinationSlice: 0, destinationLevel: 0,
                             destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blitEncoder.endEncoding()
        } else {
            // SDR path: CIImage → drawable directly
            ciContext.render(ciImage,
                             to: drawable.texture,
                             commandBuffer: commandBuffer,
                             bounds: CGRect(x: 0, y: 0, width: dispW, height: dispH),
                             colorSpace: CGColorSpaceCreateDeviceRGB())
        }

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
