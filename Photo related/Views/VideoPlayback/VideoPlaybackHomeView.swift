//
//  VideoPlaybackHomeView.swift
//  Photo related
//

import SwiftUI

struct VideoPlaybackHomeView: View {
    @State private var showSingleMetal = false
    @State private var showLearnFFmpeg = false
    @State private var showFourMetal = false
    @State private var showSixMetal = false
    @State private var showVideoSubtitle = false
    
    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 14) {
                Button {
                    showSingleMetal = true
                } label: {
                    ToolCardView(
                        title: "单路Metal",
                        subtitle: "单路视频 Metal 播放，支持基础滤镜",
                        icon: "play.rectangle"
                    )
                }
                .buttonStyle(.plain)

                Button {
                    showLearnFFmpeg = true
                } label: {
                    ToolCardView(
                        title: "LearnFFmpeg",
                        subtitle: "基于 FFmpeg 的极简播放器",
                        icon: "film.stack"
                    )
                }
                .buttonStyle(.plain)

                Button {
                    showFourMetal = true
                } label: {
                    ToolCardView(
                        title: "4路Metal",
                        subtitle: "同时渲染 4 路视频，点击区域切换主音频",
                        icon: "square.grid.2x2"
                    )
                }
                .buttonStyle(.plain)
                
                Button {
                    showSixMetal = true
                } label: {
                    ToolCardView(
                        title: "6路Metal",
                        subtitle: "同时渲染 6 路视频，支持相册和文件选取",
                        icon: "square.grid.3x2"
                    )
                }
                .buttonStyle(.plain)

                Button {
                    showVideoSubtitle = true
                } label: {
                    ToolCardView(
                        title: "视频字幕",
                        subtitle: "语音识别生成字幕，可选语言，支持预览与导出",
                        icon: "captions.bubble"
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("视频播放")
        .navigationDestination(isPresented: $showSingleMetal) {
            SingleVideoMetalContainerView()
                .toolbar(.hidden, for: .tabBar)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu("选择视频") {
                            Button("从相册选择", systemImage: "photo.on.rectangle") {
                                NotificationCenter.default.post(name: .singleVideoSelectFromPhotos, object: nil)
                            }
                            Button("从文件选择", systemImage: "folder") {
                                NotificationCenter.default.post(name: .singleVideoSelectFromFiles, object: nil)
                            }
                        }
                    }
                }
        }
        .navigationDestination(isPresented: $showLearnFFmpeg) {
            LearnFFmpegPlayerContainerView()
                .toolbar(.hidden, for: .tabBar)
                .navigationTitle("FFmpeg 播放器")
                .navigationBarTitleDisplayMode(.inline)
                .background(Color(.systemGroupedBackground).ignoresSafeArea())
        }
        .navigationDestination(isPresented: $showFourMetal) {
            FourVideoMetalContainerView()
                .toolbar(.hidden, for: .tabBar)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu("选择视频") {
                            Button("从相册选择", systemImage: "photo.on.rectangle") {
                                NotificationCenter.default.post(name: .fourVideoSelectFromPhotos, object: nil)
                            }
                            Button("从文件选择", systemImage: "folder") {
                                NotificationCenter.default.post(name: .fourVideoSelectFromFiles, object: nil)
                            }
                        }
                    }
                }
        }
        .navigationDestination(isPresented: $showSixMetal) {
            SixVideoMetalContainerView()
                .toolbar(.hidden, for: .tabBar)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu("选择视频") {
                            Button("从相册选择", systemImage: "photo.on.rectangle") {
                                NotificationCenter.default.post(name: .sixVideoSelectFromPhotos, object: nil)
                            }
                            Button("从文件选择", systemImage: "folder") {
                                NotificationCenter.default.post(name: .sixVideoSelectFromFiles, object: nil)
                            }
                        }
                    }
                }
        }
        .navigationDestination(isPresented: $showVideoSubtitle) {
            VideoSubtitleContainerView()
                .toolbar(.hidden, for: .tabBar)
        }
    }
}
