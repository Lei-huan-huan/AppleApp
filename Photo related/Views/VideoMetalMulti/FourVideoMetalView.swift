//
//  FourVideoMetalView.swift
//  Photo related
//

import UIKit
import MetalKit
import AVFoundation
import simd

final class FourVideoMetalView: MTKView {
    private var commandQueue: MTLCommandQueue!
    private var pipelineState: MTLRenderPipelineState!
    private var textureCache: CVMetalTextureCache!

    private var players: [AVPlayer] = []
    private var outputs: [AVPlayerItemVideoOutput] = []
    private var yTextures: [MTLTexture?] = Array(repeating: nil, count: 4)
    private var uvTextures: [MTLTexture?] = Array(repeating: nil, count: 4)
    private var videoAspectRatios: [Float] = Array(repeating: 16.0 / 9.0, count: 4)
    private var activeAudioIndex = 0
    private var suppressPlayerAutoActions = false

    override init(frame: CGRect, device: MTLDevice?) {
        super.init(frame: frame, device: device)
        setupMetal()
        setupTap()
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupMetal() {
        device = MTLCreateSystemDefaultDevice()
        colorPixelFormat = .bgra8Unorm
        clearColor = MetalViewAppearance.clearColor(for: traitCollection)
        commandQueue = device?.makeCommandQueue()
        CVMetalTextureCacheCreate(nil, nil, device!, nil, &textureCache)

        let library = MetalDefaultLibraryCache.library(for: device!)
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library?.makeFunction(name: "vertex_passthrough_A")
        desc.fragmentFunction = library?.makeFunction(name: "fragment_main_A")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipelineState = try? device?.makeRenderPipelineState(descriptor: desc)
        delegate = self
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            clearColor = MetalViewAppearance.clearColor(for: traitCollection)
        }
    }

    private func setupTap() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: self)
        guard bounds.width > 0, bounds.height > 0 else { return }
        let nx = point.x / bounds.width
        let ny = point.y / bounds.height

        let index: Int
        if nx >= 0.5 && ny <= 0.5 {
            index = 1
        } else if nx < 0.5 && ny > 0.5 {
            index = 2
        } else if nx >= 0.5 && ny > 0.5 {
            index = 3
        } else {
            index = 0
        }
        setActiveAudio(index: index)
    }

    private func setActiveAudio(index: Int) {
        activeAudioIndex = index
        for (i, player) in players.enumerated() {
            player.volume = i == index ? 1.0 : 0.0
        }
    }

    func pauseAllPlayers() {
        suppressPlayerAutoActions = true
        players.forEach {
            $0.pause()
            $0.isMuted = true
        }
        isPaused = true
    }

    func resumeAllPlayers() {
        suppressPlayerAutoActions = false
        players.forEach { $0.isMuted = false }
        setActiveAudio(index: activeAudioIndex)
        players.forEach { $0.play() }
        isPaused = false
    }

    func loadVideos(urls: [URL]) {
        suppressPlayerAutoActions = false
        players.forEach { $0.pause() }
        players.removeAll()
        outputs.removeAll()

        for (i, url) in urls.prefix(4).enumerated() {
            let item = AVPlayerItem(url: url)
            let settings: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            ]
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: settings)
            item.add(output)

            let player = AVPlayer(playerItem: item)
            player.volume = i == 0 ? 1.0 : 0.0
            player.play()

            players.append(player)
            outputs.append(output)
            videoAspectRatios[i] = computeAspectRatio(for: item.asset)

            NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self, weak player] _ in
                guard let self, !self.suppressPlayerAutoActions else { return }
                player?.seek(to: .zero)
                player?.play()
            }
        }
        isPaused = false
    }

    private func computeAspectRatio(for asset: AVAsset) -> Float {
        guard let track = asset.tracks(withMediaType: .video).first else { return 16.0 / 9.0 }
        let size = track.naturalSize.applying(track.preferredTransform)
        let width = abs(size.width)
        let height = abs(size.height)
        guard width > 0, height > 0 else { return 16.0 / 9.0 }
        return Float(width / height)
    }
}

extension FourVideoMetalView: MTKViewDelegate {
    func draw(in view: MTKView) {
        guard let drawable = currentDrawable,
              let descriptor = currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor),
              let pipelineState else { return }

        for i in 0..<min(players.count, 4) {
            let output = outputs[i]
            guard let item = players[i].currentItem else { continue }
            let time = item.currentTime()
            guard output.hasNewPixelBuffer(forItemTime: time),
                  let pixelBuffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil)
            else { continue }

            var yRef: CVMetalTexture?
            CVMetalTextureCacheCreateTextureFromImage(
                nil, textureCache, pixelBuffer, nil, .r8Unorm,
                CVPixelBufferGetWidthOfPlane(pixelBuffer, 0),
                CVPixelBufferGetHeightOfPlane(pixelBuffer, 0), 0, &yRef
            )

            var uvRef: CVMetalTexture?
            CVMetalTextureCacheCreateTextureFromImage(
                nil, textureCache, pixelBuffer, nil, .rg8Unorm,
                CVPixelBufferGetWidthOfPlane(pixelBuffer, 1),
                CVPixelBufferGetHeightOfPlane(pixelBuffer, 1), 1, &uvRef
            )

            if let yRef, let yTex = CVMetalTextureGetTexture(yRef) {
                yTextures[i] = yTex
            }
            if let uvRef, let uvTex = CVMetalTextureGetTexture(uvRef) {
                uvTextures[i] = uvTex
            }
        }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentTexture(yTextures[0], index: 0)
        encoder.setFragmentTexture(uvTextures[0], index: 1)
        encoder.setFragmentTexture(yTextures[1], index: 2)
        encoder.setFragmentTexture(uvTextures[1], index: 3)
        encoder.setFragmentTexture(yTextures[2], index: 4)
        encoder.setFragmentTexture(uvTextures[2], index: 5)
        encoder.setFragmentTexture(yTextures[3], index: 6)
        encoder.setFragmentTexture(uvTextures[3], index: 7)

        var shaderAspects = SIMD4<Float>(
            videoAspectRatios[0],
            videoAspectRatios[1],
            videoAspectRatios[2],
            videoAspectRatios[3]
        )
        var cellAspect = Float(drawableSize.width / max(drawableSize.height, 1.0))
        var letterbox = MetalViewAppearance.letterboxSIMD4(for: traitCollection)
        encoder.setFragmentBytes(&shaderAspects, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.setFragmentBytes(&cellAspect, length: MemoryLayout<Float>.stride, index: 1)
        encoder.setFragmentBytes(&letterbox, length: MemoryLayout<SIMD4<Float>>.stride, index: 2)

        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
}
