//
//  CameraHomeView.swift
//  Photo related
//

import SwiftUI

struct CameraHomeView: View {
    @State private var showCustomCamera = false

    var body: some View {
        List {
            Section {
                Button {
                    showCustomCamera = true
                } label: {
                    HStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color(.systemTeal).opacity(0.85),
                                            Color(.systemBlue).opacity(0.75),
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 48, height: 48)
                            Image(systemName: "camera.aperture")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("自定义相机")
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text("实时特效 · 拍照与录像")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color(.secondarySystemGroupedBackground))
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            } header: {
                Text("拍摄")
            } footer: {
                Text("使用 Metal 预览与特效； pinch 可缩放画面。")
                    .font(.footnote)
            }
        }
        .navigationTitle("相机")
        .navigationDestination(isPresented: $showCustomCamera) {
            CustomCameraScreenView()
        }
    }
}
