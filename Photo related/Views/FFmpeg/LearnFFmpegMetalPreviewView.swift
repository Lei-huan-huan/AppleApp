//
//  LearnFFmpegMetalPreviewView.swift
//  Photo related
//
//  LearnFFmpeg 专用预览（仅 FFmpeg NV12 → Metal），与单路 Metal（AVPlayer）分离。
//

import AVFoundation
import MetalKit
import UIKit

final class LearnFFmpegMetalPreviewView: MTKView, MTKViewDelegate {
    weak var ffmpegPlayer: FFmpegDemuxerPlayer?

    private var commandQueue: MTLCommandQueue!
    private var pipelineState: MTLRenderPipelineState!
    private var textureCache: CVMetalTextureCache!

    override init(frame: CGRect, device: MTLDevice?) {
        super.init(frame: frame, device: device)
        setupMetal()
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupMetal() {
        device = MTLCreateSystemDefaultDevice()
        commandQueue = device?.makeCommandQueue()
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0x0F / 255, green: 0x0E / 255, blue: 0x1A / 255, alpha: 1)
        CVMetalTextureCacheCreate(nil, nil, device!, nil, &textureCache)

        let library = MetalDefaultLibraryCache.library(for: device!)
        let pipelineDesc = MTLRenderPipelineDescriptor()
        pipelineDesc.vertexFunction = library?.makeFunction(name: "vertex_passthrough")
        pipelineDesc.fragmentFunction = library?.makeFunction(name: "fragment_main")
        pipelineDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipelineState = try? device?.makeRenderPipelineState(descriptor: pipelineDesc)
        delegate = self
        isPaused = false
        enableSetNeedsDisplay = false
        framebufferOnly = false
    }

    /// 切视频时调用，释放缓存里指向已释放 pixel buffer 的 Metal 纹理，避免引发 GPU 错误。
    func flushTextureCache() {
        if let cache = textureCache {
            CVMetalTextureCacheFlush(cache, 0)
        }
    }

    func draw(in view: MTKView) {
        guard let drawable = currentDrawable,
              let descriptor = currentRenderPassDescriptor,
              let pipelineState,
              let pixelBuffer = ffmpegPlayer?.copyLatestPixelBuffer()
        else { return }

        let videoW = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let videoH = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        let viewW = drawableSize.width
        let viewH = drawableSize.height
        let videoRatio = videoW / videoH
        let viewRatio = viewW / viewH

        var scale = SIMD2<Float>(1, 1)
        if videoRatio > viewRatio {
            scale = SIMD2<Float>(1, Float(viewRatio / videoRatio))
        } else {
            scale = SIMD2<Float>(Float(videoRatio / viewRatio), 1)
        }

        var yTexRef: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, pixelBuffer, nil, .r8Unorm,
            CVPixelBufferGetWidthOfPlane(pixelBuffer, 0),
            CVPixelBufferGetHeightOfPlane(pixelBuffer, 0), 0, &yTexRef
        )

        var uvTexRef: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, pixelBuffer, nil, .rg8Unorm,
            CVPixelBufferGetWidthOfPlane(pixelBuffer, 1),
            CVPixelBufferGetHeightOfPlane(pixelBuffer, 1), 1, &uvTexRef
        )

        guard let yRef = yTexRef,
              let yTex = CVMetalTextureGetTexture(yRef),
              let uvRef = uvTexRef,
              let uvTex = CVMetalTextureGetTexture(uvRef)
        else { return }

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
        else { return }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentTexture(yTex, index: 0)
        encoder.setFragmentTexture(uvTex, index: 1)

        var filter = 0
        encoder.setFragmentBytes(&filter, length: MemoryLayout<Int>.size, index: 0)
        encoder.setVertexBytes(&scale, length: MemoryLayout<SIMD2<Float>>.size, index: 1)

        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
}
