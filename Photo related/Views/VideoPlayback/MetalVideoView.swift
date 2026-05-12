//
//  MetalVideoView.swift
//  Photo related
//
//  单路视频：NV12 → CIImage → 与自定义相机相同的 `PreviewEffectPipeline`（Core Image + Metal 特效），再经 CIContext 渲染到 Metal 纹理。
//

import AVFoundation
import CoreImage
import MetalKit
import UIKit

final class MetalVideoView: MTKView, MTKViewDelegate {
    private var commandQueue: MTLCommandQueue!
    private var ciContext: CIContext!
    private var effectPipeline: PreviewEffectPipeline!
    private var player: AVPlayer?
    private var videoOutput: AVPlayerItemVideoOutput?
    private var filterType = 0
    private var loopObserver: NSObjectProtocol?

    func setFilter(_ type: Int) {
        filterType = type
    }

    override init(frame: CGRect, device: MTLDevice?) {
        super.init(frame: frame, device: device)
        setupRendering()
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let loopObserver {
            NotificationCenter.default.removeObserver(loopObserver)
        }
    }

    private func setupRendering() {
        device = MTLCreateSystemDefaultDevice()
        commandQueue = device?.makeCommandQueue()
        colorPixelFormat = .bgra8Unorm
        clearColor = MetalViewAppearance.clearColor(for: traitCollection)
        framebufferOnly = false
        isPaused = false
        enableSetNeedsDisplay = false
        delegate = self

        guard let dev = device else { return }
        ciContext = CIContext(mtlDevice: dev, options: [.cacheIntermediates: false])
        effectPipeline = PreviewEffectPipeline(ciContext: ciContext)
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

    func draw(in view: MTKView) {
        guard let drawable = currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let output = videoOutput,
              let item = player?.currentItem
        else { return }

        let time = item.currentTime()
        guard output.hasNewPixelBuffer(forItemTime: time),
              let pixelBuffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil)
        else { return }

        if let pass = currentRenderPassDescriptor {
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            let clearEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass)
            clearEncoder?.endEncoding()
        }

        let base = CIImage(cvPixelBuffer: pixelBuffer)
        let cfg = PreviewEffectConfiguration.singleVideo(filterIndex: filterType)
        let filtered = effectPipeline.apply(to: base, configuration: cfg)

        let srcRect = filtered.extent
        guard srcRect.width > 1, srcRect.height > 1,
              srcRect.width.isFinite, srcRect.height.isFinite
        else {
            commandBuffer.present(drawable)
            commandBuffer.commit()
            return
        }

        let drawableW = max(1, CGFloat(drawable.texture.width))
        let drawableH = max(1, CGFloat(drawable.texture.height))
        let scale = max(drawableW / srcRect.width, drawableH / srcRect.height)
        let scaledW = srcRect.width * scale
        let scaledH = srcRect.height * scale
        let ox = (drawableW - scaledW) * 0.5
        let oy = (drawableH - scaledH) * 0.5
        let transform = CGAffineTransform(translationX: -srcRect.minX, y: -srcRect.minY)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: ox, y: oy)
        let outputImage = filtered.transformed(by: transform)

        let bounds = CGRect(origin: .zero, size: CGSize(width: drawableW, height: drawableH))
        ciContext.render(outputImage, to: drawable.texture, commandBuffer: commandBuffer, bounds: bounds, colorSpace: CGColorSpaceCreateDeviceRGB())
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
}
