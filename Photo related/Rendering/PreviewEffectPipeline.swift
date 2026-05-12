//
//  PreviewEffectPipeline.swift
//  Photo related
//
//  与自定义相机 `applyPreviewFilterChain` 相同的 Core Image + Metal 特效链路，供单路播放等复用。
//

import CoreImage
import Foundation
import Metal
import UIKit
import Vision

// MARK: - 单色（与相机一致）

enum MonochromePreviewEffect: Int, CaseIterable {
    case normal = 0
    case red = 1
    case green = 2
    case blue = 3
    case gray = 4

    var displayName: String {
        switch self {
        case .normal: return "正常"
        case .red: return "红色"
        case .green: return "绿色"
        case .blue: return "蓝色"
        case .gray: return "灰色"
        }
    }

    var dot: String {
        switch self {
        case .normal: return "⚪"
        case .red: return "🔴"
        case .green: return "🟢"
        case .blue: return "🔵"
        case .gray: return "⚫"
        }
    }
}

// MARK: - 一次预览/一帧的配置

struct PreviewEffectConfiguration {
    var monochrome: MonochromePreviewEffect = .normal
    var crayon = false
    var catFace = false
    var thermal = false
    var gongbi = false
    var oilPainting = false
    var watercolor = false
    var muralPainting = false
    var magicCrayon = false
    var magicSketch = false
    var magicSketchStrength: Float = 0.5
    var cartoon3 = false

    /// 单路 Metal 页 `filterIndex` → 与自定义相机逐项对应的独占预设（一次只开一类风格/Metal 特效）。
    static func singleVideo(filterIndex: Int) -> PreviewEffectConfiguration {
        var c = PreviewEffectConfiguration()
        c.monochrome = .normal
        switch filterIndex {
        case 0: break
        case 1: c.monochrome = .red
        case 2: c.monochrome = .green
        case 3: c.monochrome = .blue
        case 4: c.monochrome = .gray
        case 5: c.thermal = true
        case 6: c.gongbi = true
        case 7: c.oilPainting = true
        case 8: c.watercolor = true
        case 9: c.muralPainting = true
        case 10: c.crayon = true
        case 11: c.magicSketch = true; c.magicSketchStrength = 0.5
        case 12: c.cartoon3 = true
        case 13: c.magicCrayon = true
        case 14: c.magicSketch = true; c.magicSketchStrength = 0.88
        case 15: c.cartoon3 = true
        case 16: c.catFace = true
        default: break
        }
        return c
    }
}

// MARK: - Pipeline

final class PreviewEffectPipeline {
    private let ciContext: CIContext

    private lazy var thermalGradientLUT: CIImage = Self.makeThermalGradientLUT()
    private lazy var catStickerImage: CIImage = Self.makeCatStickerCIImage()

    private let faceBoxesLock = NSLock()
    private var latestDetectedFaceBoxes: [CGRect] = []
    private var lastFaceDetectionTime: CFTimeInterval = 0
    private var lastVisionFaceDetectionExtent: CGRect = .zero
    private let minFaceDetectionInterval: CFTimeInterval = 1.0 / 10.0

    private lazy var magicCrayonProcessor: MagicCrayonMetalProcessor? = MagicCrayonMetalProcessor()
    private lazy var magicSketchProcessor: MagicSketchMetalProcessor? = MagicSketchMetalProcessor()
    private lazy var cartoon3Processor: Cartoon3MetalProcessor? = Cartoon3MetalProcessor()

    init(ciContext: CIContext) {
        self.ciContext = ciContext
    }

    func apply(to input: CIImage, configuration c: PreviewEffectConfiguration) -> CIImage {
        var result = applyMonochrome(input, effect: c.monochrome)
        if c.crayon {
            result = applyCrayonEffect(result)
        }
        if c.catFace {
            result = applyCatFaceEffect(result)
        }
        if c.thermal {
            result = applyThermalImaging(result)
        }
        if c.gongbi {
            result = applyGongbiEffect(result)
        }
        if c.oilPainting {
            result = applyOilPaintingEffect(result)
        }
        if c.watercolor {
            result = applyWatercolorEffect(result)
        }
        if c.muralPainting {
            result = applyMuralPaintingEffect(result)
        }
        if c.magicCrayon {
            if let proc = magicCrayonProcessor {
                result = proc.applyIfPossible(to: result, context: ciContext)
            }
        }
        if c.magicSketch {
            if let proc = magicSketchProcessor {
                proc.strength = c.magicSketchStrength
                result = proc.applyIfPossible(to: result, context: ciContext)
            }
        }
        if c.cartoon3 {
            if let proc = cartoon3Processor {
                result = proc.applyIfPossible(to: result, context: ciContext)
            }
        }
        return result.cropped(to: input.extent)
    }

    private func applyMonochrome(_ image: CIImage, effect: MonochromePreviewEffect) -> CIImage {
        switch effect {
        case .normal:
            return image
        case .red:
            return image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            ])
        case .green:
            return image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            ])
        case .blue:
            return image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 1, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            ])
        case .gray:
            let third: CGFloat = 1.0 / 3.0
            return image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: third, y: third, z: third, w: 0),
                "inputGVector": CIVector(x: third, y: third, z: third, w: 0),
                "inputBVector": CIVector(x: third, y: third, z: third, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            ])
        }
    }

    private func applyThermalImaging(_ image: CIImage) -> CIImage {
        let extent = image.extent
        let gray = image.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0.0,
            kCIInputContrastKey: 1.22,
            kCIInputBrightnessKey: 0.0,
        ])
        return gray
            .applyingFilter("CIColorMap", parameters: [kCIInputGradientImageKey: thermalGradientLUT])
            .cropped(to: extent)
    }

    private static func makeThermalGradientLUT() -> CIImage {
        let width = 256
        let height = 1
        var data = Data(count: width * height * 4)
        data.withUnsafeMutableBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            for x in 0..<width {
                let t = CGFloat(x) / CGFloat(max(width - 1, 1))
                let (r, g, b) = thermalFalseColor(at: t)
                let o = x * 4
                base[o + 0] = UInt8(clamping: Int((b * 255.0).rounded()))
                base[o + 1] = UInt8(clamping: Int((g * 255.0).rounded()))
                base[o + 2] = UInt8(clamping: Int((r * 255.0).rounded()))
                base[o + 3] = 255
            }
        }
        let bitmapInfo = CGBitmapInfo(rawValue:
            CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: data as CFData),
              let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let cgImage = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: cs,
                bitmapInfo: bitmapInfo,
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              )
        else {
            return CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 256, height: 1))
        }
        return CIImage(cgImage: cgImage)
    }

    private static func thermalFalseColor(at t: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
        let x = max(0, min(1, t))
        struct Key { let p: CGFloat; let r: CGFloat; let g: CGFloat; let b: CGFloat }
        let keys: [Key] = [
            Key(p: 0.00, r: 0.02, g: 0.02, b: 0.08),
            Key(p: 0.12, r: 0.00, g: 0.00, b: 0.55),
            Key(p: 0.28, r: 0.00, g: 0.75, b: 0.95),
            Key(p: 0.44, r: 0.00, g: 0.88, b: 0.25),
            Key(p: 0.58, r: 0.95, g: 0.95, b: 0.00),
            Key(p: 0.74, r: 1.00, g: 0.45, b: 0.00),
            Key(p: 0.88, r: 1.00, g: 0.12, b: 0.05),
            Key(p: 1.00, r: 1.00, g: 1.00, b: 0.98),
        ]
        guard let first = keys.first else { return (0, 0, 0) }
        if x <= first.p { return (first.r, first.g, first.b) }
        for i in 0..<(keys.count - 1) {
            let a = keys[i], b = keys[i + 1]
            if x <= b.p {
                let u = (x - a.p) / max(b.p - a.p, 1e-6)
                return (
                    a.r + (b.r - a.r) * u,
                    a.g + (b.g - a.g) * u,
                    a.b + (b.b - a.b) * u
                )
            }
        }
        let last = keys[keys.count - 1]
        return (last.r, last.g, last.b)
    }

    private func applyCrayonEffect(_ image: CIImage) -> CIImage {
        let extent = image.extent
        let poster = image.applyingFilter("CIColorPosterize", parameters: ["inputLevels": 12])
        let edgeWork = poster.applyingFilter("CIEdgeWork", parameters: [kCIInputRadiusKey: 2.2])
        let blended = poster.applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey: edgeWork])
        return blended.cropped(to: extent)
    }

    private func applyCatFaceEffect(_ image: CIImage) -> CIImage {
        let extent = image.extent.integral
        guard extent.width > 8, extent.height > 8 else { return image }

        updateDetectedFacesIfNeeded(for: image, extent: extent)
        let faceBoxes = currentDetectedFaceBoxes()
        guard !faceBoxes.isEmpty else { return image }

        let sticker = catStickerImage
        let stickerSize = sticker.extent.size
        guard stickerSize.width > 0, stickerSize.height > 0 else { return image }

        var output = image
        for face in faceBoxes {
            let w = face.width
            let h = face.height
            if w < 24 || h < 24 { continue }

            let target = CGRect(
                x: face.minX - w * 0.22,
                y: face.minY - h * 0.12,
                width: w * 1.44,
                height: h * 1.55
            )
            let sx = target.width / stickerSize.width
            let sy = target.height / stickerSize.height
            let t = CGAffineTransform(scaleX: sx, y: sy)
                .translatedBy(x: target.minX / sx, y: target.minY / sy)
            let transformed = sticker.transformed(by: t)
            output = transformed.composited(over: output)
        }
        return output.cropped(to: extent)
    }

    private func faceCacheExtentDiffers(_ current: CGRect, from cached: CGRect) -> Bool {
        if cached.width < 1 || cached.height < 1 { return true }
        return abs(current.width - cached.width) > 2 || abs(current.height - cached.height) > 2
    }

    private func updateDetectedFacesIfNeeded(for image: CIImage, extent: CGRect) {
        let now = CACurrentMediaTime()
        faceBoxesLock.lock()
        let cachedVisionExtent = lastVisionFaceDetectionExtent
        faceBoxesLock.unlock()
        let extentChanged = faceCacheExtentDiffers(extent, from: cachedVisionExtent)
        if !extentChanged && now - lastFaceDetectionTime < minFaceDetectionInterval { return }
        lastFaceDetectionTime = now

        let integral = extent.integral
        guard integral.width > 32, integral.height > 32 else {
            faceBoxesLock.lock()
            latestDetectedFaceBoxes = []
            lastVisionFaceDetectionExtent = .zero
            faceBoxesLock.unlock()
            return
        }

        let maxSide = max(integral.width, integral.height)
        let downsample = min(CGFloat(1), CGFloat(720) / maxSide)
        let dw = max(32, Int((integral.width * downsample).rounded(.down)))
        let dh = max(32, Int((integral.height * downsample).rounded(.down)))
        let toDetect = CGAffineTransform(translationX: -integral.minX, y: -integral.minY)
            .scaledBy(x: downsample, y: downsample)
        let scaledImage = image.transformed(by: toDetect).cropped(to: CGRect(x: 0, y: 0, width: CGFloat(dw), height: CGFloat(dh)))
        let fromRect = CGRect(x: 0, y: 0, width: CGFloat(dw), height: CGFloat(dh))

        guard let cgImage = ciContext.createCGImage(scaledImage, from: fromRect) else {
            faceBoxesLock.lock()
            latestDetectedFaceBoxes = []
            lastVisionFaceDetectionExtent = integral
            faceBoxesLock.unlock()
            return
        }

        let req = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([req])
            let observations = (req.results as? [VNFaceObservation]) ?? []
            let iw = CGFloat(cgImage.width)
            let ih = CGFloat(cgImage.height)
            let inv = 1 / downsample
            let mapped = observations.map { obs -> CGRect in
                let box = obs.boundingBox
                let px = CGRect(
                    x: box.minX * iw,
                    y: box.minY * ih,
                    width: box.width * iw,
                    height: box.height * ih
                )
                return CGRect(
                    x: integral.minX + px.minX * inv,
                    y: integral.minY + px.minY * inv,
                    width: px.width * inv,
                    height: px.height * inv
                )
            }
            faceBoxesLock.lock()
            latestDetectedFaceBoxes = mapped
            lastVisionFaceDetectionExtent = integral
            faceBoxesLock.unlock()
        } catch {
            faceBoxesLock.lock()
            latestDetectedFaceBoxes = []
            lastVisionFaceDetectionExtent = .zero
            faceBoxesLock.unlock()
        }
    }

    private func currentDetectedFaceBoxes() -> [CGRect] {
        faceBoxesLock.lock()
        let v = latestDetectedFaceBoxes
        faceBoxesLock.unlock()
        return v
    }

    private static func makeCatStickerCIImage() -> CIImage {
        let size = CGSize(width: 300, height: 300)
        let renderer = UIGraphicsImageRenderer(size: size)
        let img = renderer.image { ctx in
            let cg = ctx.cgContext
            cg.clear(CGRect(origin: .zero, size: size))
            cg.setAllowsAntialiasing(true)

            let earColor = UIColor(red: 1.0, green: 0.82, blue: 0.74, alpha: 0.95)
            let faceColor = UIColor(red: 1.0, green: 0.9, blue: 0.82, alpha: 0.96)
            let lineColor = UIColor(red: 0.15, green: 0.14, blue: 0.16, alpha: 0.85)

            func triangle(_ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, fill: UIColor) {
                cg.beginPath()
                cg.move(to: p1)
                cg.addLine(to: p2)
                cg.addLine(to: p3)
                cg.closePath()
                cg.setFillColor(fill.cgColor)
                cg.fillPath()
            }

            triangle(CGPoint(x: 72, y: 96), CGPoint(x: 124, y: 32), CGPoint(x: 148, y: 116), fill: earColor)
            triangle(CGPoint(x: 228, y: 96), CGPoint(x: 176, y: 32), CGPoint(x: 152, y: 116), fill: earColor)

            let faceRect = CGRect(x: 58, y: 74, width: 184, height: 182)
            cg.setFillColor(faceColor.cgColor)
            cg.fillEllipse(in: faceRect)
            cg.setStrokeColor(lineColor.cgColor)
            cg.setLineWidth(4)
            cg.strokeEllipse(in: faceRect)

            cg.setFillColor(UIColor.white.cgColor)
            cg.fillEllipse(in: CGRect(x: 100, y: 136, width: 34, height: 26))
            cg.fillEllipse(in: CGRect(x: 166, y: 136, width: 34, height: 26))
            cg.setFillColor(lineColor.cgColor)
            cg.fillEllipse(in: CGRect(x: 113, y: 146, width: 12, height: 12))
            cg.fillEllipse(in: CGRect(x: 179, y: 146, width: 12, height: 12))

            triangle(CGPoint(x: 150, y: 166), CGPoint(x: 138, y: 184), CGPoint(x: 162, y: 184), fill: UIColor(red: 0.93, green: 0.45, blue: 0.55, alpha: 0.95))

            cg.setStrokeColor(lineColor.cgColor)
            cg.setLineWidth(3)
            cg.addArc(center: CGPoint(x: 140, y: 194), radius: 12, startAngle: 0.2 * .pi, endAngle: 0.95 * .pi, clockwise: false)
            cg.strokePath()
            cg.addArc(center: CGPoint(x: 160, y: 194), radius: 12, startAngle: 0.05 * .pi, endAngle: 0.8 * .pi, clockwise: true)
            cg.strokePath()

            cg.setLineWidth(2)
            let whiskers: [(CGPoint, CGPoint)] = [
                (CGPoint(x: 132, y: 186), CGPoint(x: 80, y: 176)),
                (CGPoint(x: 132, y: 194), CGPoint(x: 78, y: 194)),
                (CGPoint(x: 132, y: 202), CGPoint(x: 82, y: 212)),
                (CGPoint(x: 168, y: 186), CGPoint(x: 220, y: 176)),
                (CGPoint(x: 168, y: 194), CGPoint(x: 222, y: 194)),
                (CGPoint(x: 168, y: 202), CGPoint(x: 218, y: 212)),
            ]
            for w in whiskers {
                cg.move(to: w.0)
                cg.addLine(to: w.1)
                cg.strokePath()
            }
        }
        if let ci = CIImage(image: img) {
            return ci
        }
        return CIImage(color: .clear).cropped(to: CGRect(x: 0, y: 0, width: 300, height: 300))
    }

    private func applyGongbiEffect(_ image: CIImage) -> CIImage {
        let extent = image.extent
        let cleaned = image.applyingFilter("CINoiseReduction", parameters: [
            "inputNoiseLevel": 0.02,
            "inputSharpness": 0.55,
        ])
        let softened = cleaned.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 0.65]).cropped(to: extent)
        let evenColor = cleaned.applyingFilter("CILuminosityBlendMode", parameters: [
            kCIInputBackgroundImageKey: softened,
        ]).cropped(to: extent)
        let sweetened = evenColor.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 1.14,
            kCIInputContrastKey: 0.96,
            kCIInputBrightnessKey: 0.015,
        ])
        let edge = sweetened.applyingFilter("CIEdgeWork", parameters: [kCIInputRadiusKey: 1.15])
        let lined = sweetened
            .applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey: edge])
            .cropped(to: extent)
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1.02,
                kCIInputContrastKey: 1.04,
                kCIInputBrightnessKey: 0.0,
            ])
        return lined
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1.04, y: 0.0, z: 0.0, w: 0.0),
                "inputGVector": CIVector(x: 0.0, y: 1.01, z: 0.0, w: 0.0),
                "inputBVector": CIVector(x: 0.0, y: 0.0, z: 0.97, w: 0.0),
                "inputAVector": CIVector(x: 0.0, y: 0.0, z: 0.0, w: 1.0),
                "inputBiasVector": CIVector(x: 0.012, y: 0.008, z: 0.004, w: 0.0),
            ])
            .cropped(to: extent)
    }

    private func applyOilPaintingEffect(_ image: CIImage) -> CIImage {
        let extent = image.extent
        let poster = image.applyingFilter("CIColorPosterize", parameters: ["inputLevels": 14])
        let thick = poster
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 3.2])
            .cropped(to: extent)
        let mixed = poster.applyingFilter("CIOverlayBlendMode", parameters: [
            kCIInputBackgroundImageKey: thick,
        ]).cropped(to: extent)
        let brushed = mixed.applyingFilter("CIUnsharpMask", parameters: [
            kCIInputRadiusKey: 2.8,
            kCIInputIntensityKey: 0.85,
        ])
        return brushed
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1.18,
                kCIInputContrastKey: 1.06,
                kCIInputBrightnessKey: -0.02,
            ])
            .cropped(to: extent)
    }

    private func applyWatercolorEffect(_ image: CIImage) -> CIImage {
        let extent = image.extent
        let bloom = image
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 5.2])
            .cropped(to: extent)
        let wash = image
            .applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey: bloom])
            .cropped(to: extent)
        let vivid = wash.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 1.26,
            kCIInputContrastKey: 0.87,
            kCIInputBrightnessKey: 0.05,
        ])
        let gran = vivid.applyingFilter("CIColorPosterize", parameters: ["inputLevels": 24])
        let edge = gran.applyingFilter("CIEdgeWork", parameters: [kCIInputRadiusKey: 2.4])
        let withEdge = gran
            .applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey: edge])
            .cropped(to: extent)
        return withEdge
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1.02, y: 0.0, z: 0.0, w: 0.0),
                "inputGVector": CIVector(x: 0.0, y: 1.03, z: 0.0, w: 0.0),
                "inputBVector": CIVector(x: 0.0, y: 0.0, z: 1.06, w: 0.0),
                "inputAVector": CIVector(x: 0.0, y: 0.0, z: 0.0, w: 1.0),
                "inputBiasVector": CIVector(x: 0.018, y: 0.022, z: 0.032, w: 0.0),
            ])
            .cropped(to: extent)
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1.04,
                kCIInputContrastKey: 1.0,
                kCIInputBrightnessKey: 0.0,
            ])
            .cropped(to: extent)
    }

    private func applyMuralPaintingEffect(_ image: CIImage) -> CIImage {
        let extent = image.extent
        let base = image.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0.92,
            kCIInputContrastKey: 1.08,
            kCIInputBrightnessKey: -0.03,
        ])
        let weathered = base.applyingFilter("CIDiscBlur", parameters: [kCIInputRadiusKey: 4.8]).cropped(to: extent)
        let mineral = base
            .applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey: weathered])
            .cropped(to: extent)
        let strata = mineral.applyingFilter("CIColorPosterize", parameters: ["inputLevels": 24])
        let vein = mineral
            .applyingFilter("CIEdgeWork", parameters: [kCIInputRadiusKey: 2.1])
            .cropped(to: extent)
        let veinNeutral = vein
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0.0,
                kCIInputContrastKey: 1.15,
                kCIInputBrightnessKey: 0.0,
            ])
            .cropped(to: extent)
        return strata
            .applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey: veinNeutral])
            .cropped(to: extent)
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1.0,
                kCIInputContrastKey: 1.05,
                kCIInputBrightnessKey: 0.01,
            ])
            .cropped(to: extent)
    }
}
