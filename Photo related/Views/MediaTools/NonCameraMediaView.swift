//
//  NonCameraMediaView.swift
//  Photo related
//
//  Created by 雷欢欢 on 2026/5/8.
//

import Combine
import SwiftUI

final class NonCameraMediaScreenBridge: ObservableObject {
    @Published var selectionMode = false
    @Published var selectedCount = 0
    @Published var allSelected = false

    weak var controller: NonCameraMediaViewController?

    func toggleSelectionMode() {
        controller?.toggleSelectionModeFromBridge()
    }

    func toggleSelectAll() {
        controller?.toggleSelectAllFromBridge()
    }

    func requestDelete() {
        controller?.deleteSelectedFromBridge()
    }
}

struct NonCameraMediaView: View {
    @StateObject private var bridge = NonCameraMediaScreenBridge()

    var body: some View {
        NonCameraMediaControllerRepresentable(bridge: bridge)
            .navigationTitle("非相机照片视频")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if bridge.selectionMode {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("删除\(bridge.selectedCount == 0 ? "" : "(\(bridge.selectedCount))")") {
                            bridge.requestDelete()
                        }
                        .disabled(bridge.selectedCount == 0)
                        .tint(.red)
                    }

                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button(bridge.allSelected ? "取消全选" : "全选") {
                            bridge.toggleSelectAll()
                        }

                        Button("完成") {
                            bridge.toggleSelectionMode()
                        }
                        .fontWeight(.semibold)
                    }
                } else {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("选择") {
                            bridge.toggleSelectionMode()
                        }
                    }
                }
            }
    }
}

private struct NonCameraMediaControllerRepresentable: UIViewControllerRepresentable {
    @ObservedObject var bridge: NonCameraMediaScreenBridge

    func makeUIViewController(context: Context) -> NonCameraMediaViewController {
        let controller = NonCameraMediaViewController()
        controller.bridge = bridge
        bridge.controller = controller
        return controller
    }

    func updateUIViewController(_ uiViewController: NonCameraMediaViewController, context: Context) {
        uiViewController.bridge = bridge
        bridge.controller = uiViewController
    }
}
