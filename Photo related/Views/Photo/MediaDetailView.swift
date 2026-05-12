//
//  MediaDetailView.swift
//  Photo related
//
//  Created by 雷欢欢 on 2026/5/8.
//

import AVKit
import Photos
import SwiftUI

struct MediaDetailView: View {
    let mediaAsset: MediaAsset

    @State private var image: UIImage?
    @State private var previewImage: UIImage?
    @State private var player: AVPlayer?
    @State private var showingDetails = false
    @State private var imageScale: CGFloat = 1
    @State private var lastImageScale: CGFloat = 1
    @State private var imageOffset: CGSize = .zero
    @State private var lastImageOffset: CGSize = .zero

    private let imageManager = PHCachingImageManager()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            Group {
                if mediaAsset.asset.mediaType == .video {
                    if let player {
                        VideoPlayer(player: player)
                            .onAppear {
                                player.play()
                            }
                    } else if let previewImage {
                        Image(uiImage: previewImage)
                            .resizable()
                            .scaledToFit()
                    } else {
                        ProgressView("正在加载视频…")
                            .tint(.white)
                    }
                } else if let image {
                    GeometryReader { geometry in
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .scaleEffect(imageScale)
                            .offset(imageOffset)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .gesture(
                                MagnificationGesture()
                                    .onChanged { value in
                                        let nextScale = lastImageScale * value
                                        imageScale = min(max(nextScale, 1), 4)
                                        imageOffset = clampedOffset(
                                            imageOffset,
                                            containerSize: geometry.size,
                                            imageSize: image.size
                                        )
                                    }
                                    .onEnded { _ in
                                        if imageScale <= 1.01 {
                                            imageScale = 1
                                            imageOffset = .zero
                                        } else {
                                            imageOffset = clampedOffset(
                                                imageOffset,
                                                containerSize: geometry.size,
                                                imageSize: image.size
                                            )
                                        }
                                        lastImageScale = imageScale
                                        lastImageOffset = imageOffset
                                    }
                            )
                            .simultaneousGesture(
                                DragGesture()
                                    .onChanged { value in
                                        guard imageScale > 1 else { return }
                                        let nextOffset = CGSize(
                                            width: lastImageOffset.width + value.translation.width,
                                            height: lastImageOffset.height + value.translation.height
                                        )
                                        imageOffset = clampedOffset(
                                            nextOffset,
                                            containerSize: geometry.size,
                                            imageSize: image.size
                                        )
                                    }
                                    .onEnded { _ in
                                        lastImageOffset = imageOffset
                                    }
                            )
                            .onTapGesture(count: 2) {
                                imageScale = 1
                                lastImageScale = 1
                                imageOffset = .zero
                                lastImageOffset = .zero
                            }
                    }
                } else {
                    ProgressView("正在加载图片…")
                        .tint(.white)
                }
            }
        }
        .navigationTitle(mediaAsset.filename)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("详情") {
                    showingDetails = true
                }
            }
        }
        .sheet(isPresented: $showingDetails) {
            MediaAssetDetailSheet(mediaAsset: mediaAsset)
                .presentationDetents([.medium, .large])
        }
        .task {
            loadPreview()
            if mediaAsset.asset.mediaType == .video {
                loadVideo()
            } else {
                loadImage()
            }
        }
    }

    private func loadPreview() {
        let scale = UIScreen.main.scale
        let screen = UIScreen.main.bounds.size
        let targetSize = CGSize(width: screen.width * scale, height: screen.height * scale)
        let options = PHImageRequestOptions()
        options.deliveryMode = .fastFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false

        imageManager.requestImage(
            for: mediaAsset.asset,
            targetSize: targetSize,
            contentMode: .aspectFit,
            options: options
        ) { image, _ in
            self.previewImage = image
        }
    }

    private func loadImage() {
        let scale = UIScreen.main.scale
        let screen = UIScreen.main.bounds.size
        let targetSize = CGSize(width: screen.width * scale, height: screen.height * scale)
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = false

        imageManager.requestImage(
            for: mediaAsset.asset,
            targetSize: targetSize,
            contentMode: .aspectFit,
            options: options
        ) { image, _ in
            self.image = image
        }
    }

    private func loadVideo() {
        let options = PHVideoRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = false

        imageManager.requestPlayerItem(forVideo: mediaAsset.asset, options: options) { item, _ in
            guard let item else { return }
            DispatchQueue.main.async {
                self.player = AVPlayer(playerItem: item)
            }
        }
    }

    private func clampedOffset(_ offset: CGSize, containerSize: CGSize, imageSize: CGSize) -> CGSize {
        guard containerSize.width > 0, containerSize.height > 0, imageSize.width > 0, imageSize.height > 0 else {
            return .zero
        }

        let fittedSize = aspectFitSize(for: imageSize, in: containerSize)
        let maxX = max((fittedSize.width * imageScale - fittedSize.width) / 2, 0)
        let maxY = max((fittedSize.height * imageScale - fittedSize.height) / 2, 0)

        return CGSize(
            width: min(max(offset.width, -maxX), maxX),
            height: min(max(offset.height, -maxY), maxY)
        )
    }

    private func aspectFitSize(for imageSize: CGSize, in containerSize: CGSize) -> CGSize {
        let widthRatio = containerSize.width / imageSize.width
        let heightRatio = containerSize.height / imageSize.height
        let scale = min(widthRatio, heightRatio)
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }
}

private struct MediaAssetDetailSheet: View {
    let mediaAsset: MediaAsset

    private var asset: PHAsset { mediaAsset.asset }

    var body: some View {
        NavigationStack {
            List {
                Section("基本信息") {
                    detailRow(title: "文件名", value: mediaAsset.filename)
                    detailRow(title: "类型", value: asset.mediaType == .video ? "视频" : "图片")
                    detailRow(title: "像素尺寸", value: "\(asset.pixelWidth) x \(asset.pixelHeight)")
                    detailRow(title: "创建时间", value: formatted(asset.creationDate))
                    detailRow(title: "修改时间", value: formatted(asset.modificationDate))
                }

                Section("媒体信息") {
                    if asset.mediaType == .video {
                        detailRow(title: "时长", value: formattedDuration(asset.duration))
                    }
                    detailRow(title: "是否收藏", value: asset.isFavorite ? "是" : "否")
                    detailRow(title: "是否隐藏", value: asset.isHidden ? "是" : "否")
                    detailRow(title: "本地资源 ID", value: asset.localIdentifier)
                }

                if let location = asset.location {
                    Section("位置信息") {
                        detailRow(title: "纬度", value: String(format: "%.6f", location.coordinate.latitude))
                        detailRow(title: "经度", value: String(format: "%.6f", location.coordinate.longitude))
                    }
                }
            }
            .navigationTitle("详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
    }

    @Environment(\.dismiss) private var dismiss

    private func detailRow(title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .multilineTextAlignment(.trailing)
        }
    }

    private func formatted(_ date: Date?) -> String {
        guard let date else { return "未知" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        let total = Int(round(duration))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
