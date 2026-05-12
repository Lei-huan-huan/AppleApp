//
//  MetalVideoView.swift
//  Photo related
//

import UIKit
import MetalKit
import AVFoundation

final class MetalVideoView: MTKView {
    private var commandQueue: MTLCommandQueue!
    private var pipelineState: MTLRenderPipelineState!
    private var player: AVPlayer?
    private var videoOutput: AVPlayerItemVideoOutput?
    private var textureCache: CVMetalTextureCache!
    private var filterType = 0
    private var loopObserver: NSObjectProtocol?

    func setFilter(_ type: Int) {
        filterType = type
    }

    override init(frame: CGRect, device: MTLDevice?) {
        super.init(frame: frame, device: device)
        setupMetal()
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let loopObserver {
            NotificationCenter.default.removeObserver(loopObserver)
        }
    }

    private func setupMetal() {
        device = MTLCreateSystemDefaultDevice()
        commandQueue = device?.makeCommandQueue()
        colorPixelFormat = .bgra8Unorm
        clearColor = MetalViewAppearance.clearColor(for: traitCollection)
        CVMetalTextureCacheCreate(nil, nil, device!, nil, &textureCache)

        let library = device?.makeDefaultLibrary()
        let pipelineDesc = MTLRenderPipelineDescriptor()
        pipelineDesc.vertexFunction = library?.makeFunction(name: "vertex_passthrough")
        pipelineDesc.fragmentFunction = library?.makeFunction(name: "fragment_main")
        pipelineDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipelineState = try? device?.makeRenderPipelineState(descriptor: pipelineDesc)
        delegate = self
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            clearColor = MetalViewAppearance.clearColor(for: traitCollection)
        }
    }

    func loadVideo(url: URL) {
        if let loopObserver {
            NotificationCenter.default.removeObserver(loopObserver)
            self.loopObserver = nil
        }

        let item = AVPlayerItem(url: url)
        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: settings)
        item.add(output)
        videoOutput = output

        loopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.player?.seek(to: .zero)
            self?.player?.play()
        }

        player = AVPlayer(playerItem: item)
        player?.play()
        isPaused = false
    }
}

extension MetalVideoView: MTKViewDelegate {
    func draw(in view: MTKView) {
        guard let drawable = currentDrawable,
              let descriptor = currentRenderPassDescriptor,
              let output = videoOutput,
              let item = player?.currentItem,
              let pipelineState else { return }

        let time = item.currentTime()
        guard output.hasNewPixelBuffer(forItemTime: time),
              let pixelBuffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil)
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

        var filter = filterType
        encoder.setFragmentBytes(&filter, length: MemoryLayout<Int>.size, index: 0)
        encoder.setVertexBytes(&scale, length: MemoryLayout<SIMD2<Float>>.size, index: 1)

        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
}
