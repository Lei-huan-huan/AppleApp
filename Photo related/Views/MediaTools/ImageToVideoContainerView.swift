//
//  ImageToVideoContainerView.swift
//  Photo related
//
//  SwiftUI 壳：内嵌与 IosTest1 一致的 ImageToVideoMetalViewController（Metal + PHPicker）。
//

import SwiftUI

struct ImageToVideoContainerView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> ImageToVideoMetalViewController {
        ImageToVideoMetalViewController()
    }

    func updateUIViewController(_ uiViewController: ImageToVideoMetalViewController, context: Context) {}
}
