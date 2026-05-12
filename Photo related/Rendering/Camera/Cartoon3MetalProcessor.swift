//
//  Cartoon3MetalProcessor.swift
//  IosTest1
//
//  OpenGL ES cartoon3 的 Metal 版：posterize + Sobel(luma) + threshold(mix)
//

import CoreImage
import CoreVideo
import Foundation
import Metal

/// BGRA 同尺寸 in/out；在 `Shaders.metal` 的 `fragment_cartoon3` 上渲染全屏四边形
final class Cartoon3MetalProcessor {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache!

    /// 对应 GLES `uLevels`
    var levels: Float = 6.0
    /// 对应 GLES `uEdgeThreshold`
    var edgeThreshold: Float = 0.2

    private var scratchIn: CVPixelBuffer?
    private var scratchOut: CVPixelBuffer?
    private var scratchWidth: Int = 0
    private var scratchHeight: Int = 0

    init?() {
        guard let dev = MTLCreateSystemDefaultDevice(),
              let queue = dev.makeCommandQueue(),
              let lib = MetalDefaultLibraryCache.library(for: dev),
              let vfn = lib.makeFunction(name: "vertex_passthrough"),
              let ffn = lib.makeFunction(name: "fragment_cartoon3")
        else { return nil }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vfn
        desc.fragmentFunction = ffn
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm

        do {
            pipeline = try dev.makeRenderPipelineState(descriptor: desc)
        } catch {
            return nil
        }

        device = dev
        commandQueue = queue

        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(nil, nil, dev, nil, &cache)
        guard status == kCVReturnSuccess, let c = cache else { return nil }
        textureCache = c
    }

    func render(input: CVPixelBuffer, into output: CVPixelBuffer) {
        let w = CVPixelBufferGetWidth(input)
        let h = CVPixelBufferGetHeight(input)
        guard w == CVPixelBufferGetWidth(output), h == CVPixelBufferGetHeight(output) else { return }

        guard let inTex = metalTexture(from: input, width: w, height: h),
              let outTex = metalTexture(from: output, width: w, height: h),
              let inMTL = CVMetalTextureGetTexture(inTex),
              let outMTL = CVMetalTextureGetTexture(outTex)
        else { return }

        guard let cmd = commandQueue.makeCommandBuffer(),
              let passDesc = makePass(outputTexture: outMTL),
              let enc = cmd.makeRenderCommandEncoder(descriptor: passDesc)
        else { return }

        var scale = SIMD2<Float>(1, 1)
        var step = SIMD2<Float>(1 / Float(w), 1 / Float(h))
        var lv = levels
        var threshold = edgeThreshold

        let vp = MTLViewport(originX: 0, originY: 0, width: Double(w), height: Double(h), znear: 0, zfar: 1)
        enc.setViewport(vp)
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBytes(&scale, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        enc.setFragmentTexture(inMTL, index: 0)
        enc.setFragmentBytes(&step, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
        enc.setFragmentBytes(&lv, length: MemoryLayout<Float>.stride, index: 1)
        enc.setFragmentBytes(&threshold, length: MemoryLayout<Float>.stride, index: 2)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
    }

    private func metalTexture(from buffer: CVPixelBuffer, width: Int, height: Int) -> CVMetalTexture? {
        var out: CVMetalTexture?
        let r = CVMetalTextureCacheCreateTextureFromImage(
            nil,
            textureCache,
            buffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &out
        )
        guard r == kCVReturnSuccess else { return nil }
        return out
    }

    private func makePass(outputTexture: MTLTexture) -> MTLRenderPassDescriptor? {
        let d = MTLRenderPassDescriptor()
        d.colorAttachments[0].texture = outputTexture
        d.colorAttachments[0].loadAction = .dontCare
        d.colorAttachments[0].storeAction = .store
        return d
    }

    private func ensureScratchBuffers(width: Int, height: Int) -> Bool {
        if scratchWidth == width, scratchHeight == height, scratchIn != nil, scratchOut != nil {
            return true
        }
        scratchIn = nil
        scratchOut = nil
        scratchWidth = width
        scratchHeight = height

        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var a: CVPixelBuffer?
        var b: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &a
        ) == kCVReturnSuccess,
            CVPixelBufferCreate(
                kCFAllocatorDefault, width, height,
                kCVPixelFormatType_32BGRA,
                attrs as CFDictionary,
                &b
            ) == kCVReturnSuccess,
            let ia = a, let ib = b
        else { return false }
        scratchIn = ia
        scratchOut = ib
        return true
    }

    /// CIImage → 临时 BGRA → Metal → 输出 CIImage（失败时返回原图）
    func applyIfPossible(to image: CIImage, context: CIContext) -> CIImage {
        let bounds = image.extent.integral
        let iw = max(1, Int(bounds.width))
        let ih = max(1, Int(bounds.height))
        guard ensureScratchBuffers(width: iw, height: ih),
              let inputPB = scratchIn,
              let outputPB = scratchOut
        else { return image }

        let cs = CGColorSpaceCreateDeviceRGB()
        let normalized = image.transformed(by: CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
        let zeroBounds = CGRect(x: 0, y: 0, width: iw, height: ih)
        context.render(normalized, to: inputPB, bounds: zeroBounds, colorSpace: cs)
        render(input: inputPB, into: outputPB)
        return CIImage(cvPixelBuffer: outputPB)
            .transformed(by: CGAffineTransform(translationX: bounds.minX, y: bounds.minY))
            .cropped(to: bounds)
    }
}
