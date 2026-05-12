//
//  PhotoToolsHomeView.swift
//  Photo related
//
//  Created by 雷欢欢 on 2026/5/8.
//

import SwiftUI

struct PhotoToolsHomeView: View {
    @State private var showNonCameraMedia = false
    @State private var showAudioTrackMerge = false
    @State private var showImageToVideo = false

    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 14) {
                Button {
                    showNonCameraMedia = true
                } label: {
                    ToolCardView(
                        title: "非相机照片视频",
                        subtitle: "排除系统相机直出，仅看其它来源",
                        icon: "square.grid.3x3.square"
                    )
                }
                .buttonStyle(.plain)

                Button {
                    showAudioTrackMerge = true
                } label: {
                    ToolCardView(
                        title: "音轨合并",
                        subtitle: "把音频合并到视频，导出为新文件",
                        icon: "waveform.badge.plus"
                    )
                }
                .buttonStyle(.plain)

                Button {
                    showImageToVideo = true
                } label: {
                    ToolCardView(
                        title: "图生视频",
                        subtitle: "多图转视频并合入音轨",
                        icon: "photo.stack"
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("相册工具")
        .navigationDestination(isPresented: $showNonCameraMedia) {
            NonCameraMediaView()
                .toolbar(.hidden, for: .tabBar)
        }
        .navigationDestination(isPresented: $showAudioTrackMerge) {
            AudioTrackMergeView()
                .toolbar(.hidden, for: .tabBar)
        }
        .navigationDestination(isPresented: $showImageToVideo) {
            ImageToVideoContainerView()
                .toolbar(.hidden, for: .tabBar)
                .navigationBarTitleDisplayMode(.inline)
        }
    }
}
