//
//  CustomCameraRepresentable.swift
//  Photo related
//

import SwiftUI

/// 全屏自定义相机：隐藏主导航与 Tab，由界面内悬浮返回关闭。
struct CustomCameraScreenView: View {
    var body: some View {
        CustomCameraContainerView()
            .toolbar(.hidden, for: .tabBar)
            .toolbar(.hidden, for: .navigationBar)
            .ignoresSafeArea(edges: .bottom)
    }
}

/// 直接嵌入 `NavigationStack`，不要包 `UINavigationController`，避免双导航栏。
struct CustomCameraContainerView: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> CustomCameraViewController {
        let vc = CustomCameraViewController()
        vc.dismissHandler = { dismiss() }
        return vc
    }

    func updateUIViewController(_ uiViewController: CustomCameraViewController, context: Context) {}
}
