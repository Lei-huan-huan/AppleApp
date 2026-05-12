//
//  MetalDefaultLibraryCache.swift
//  Photo related
//

import Foundation
import Metal

/// 全工程共享同一份 `makeDefaultLibrary()` 结果，避免多处重复加载/解析同一套 metallib（体感「单路 Metal 变慢」常见原因之一）。
enum MetalDefaultLibraryCache {
    private static let lock = NSLock()
    private static var cachedDevice: MTLDevice?
    private static var cachedLibrary: MTLLibrary?

    static func library(for device: MTLDevice) -> MTLLibrary? {
        lock.lock()
        defer { lock.unlock() }
        if let d = cachedDevice, d === device, let lib = cachedLibrary {
            return lib
        }
        guard let lib = device.makeDefaultLibrary() else { return nil }
        cachedDevice = device
        cachedLibrary = lib
        return lib
    }

    /// 后台预热，减轻首次进入单路/多路/相机时的主线程卡顿。
    static func warmUp() {
        DispatchQueue.global(qos: .utility).async {
            guard let dev = MTLCreateSystemDefaultDevice() else { return }
            _ = library(for: dev)
        }
    }
}
