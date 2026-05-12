//
//  MetalViewAppearance.swift
//  Photo related
//

import UIKit
import Metal
import simd

enum MetalViewAppearance {
    static func letterboxSIMD4(for trait: UITraitCollection) -> SIMD4<Float> {
        let color = UIColor.systemBackground.resolvedColor(with: trait)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 1

        if !color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            var white: CGFloat = 0
            _ = color.getWhite(&white, alpha: &alpha)
            red = white
            green = white
            blue = white
        }

        return SIMD4(Float(red), Float(green), Float(blue), Float(alpha))
    }

    static func clearColor(for trait: UITraitCollection) -> MTLClearColor {
        let value = letterboxSIMD4(for: trait)
        return MTLClearColorMake(Double(value.x), Double(value.y), Double(value.z), Double(value.w))
    }
}
