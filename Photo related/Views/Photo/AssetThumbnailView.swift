//
//  AssetThumbnailView.swift
//  Photo related
//
//  Created by 雷欢欢 on 2026/5/8.
//

import Photos
import SwiftUI

struct AssetThumbnailView: View {
    let mediaAsset: MediaAsset
    let showsSelectionControl: Bool
    let isSelected: Bool
    let onOpen: () -> Void
    let onToggleSelection: () -> Void

    @State private var image: UIImage?

    private let imageManager = PHCachingImageManager()
    private let targetSize = CGSize(width: 300, height: 300)

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle()
                        .fill(Color(.secondarySystemFill))
                        .overlay {
                            ProgressView()
                        }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            LinearGradient(
                colors: [.clear, .black.opacity(0.55)],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 4) {
                if mediaAsset.asset.mediaType == .video {
                    Label("视频", systemImage: "video.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                } else {
                    Label("图片", systemImage: "photo.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                }

                Text(mediaAsset.filename)
                    .font(.caption2)
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .padding(8)
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)
        .background(Color(.secondarySystemFill))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        }
        .overlay(alignment: .topTrailing) {
            if showsSelectionControl {
                Button(action: onToggleSelection) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(Color.white)
                        .frame(width: 32, height: 32)
                        .background(isSelected ? Color.accentColor : Color.black.opacity(0.4), in: Circle())
                }
                .buttonStyle(.plain)
                .padding(4)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture {
            onOpen()
        }
        .task(id: mediaAsset.id) {
            loadThumbnail()
        }
    }

    private func loadThumbnail() {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false

        imageManager.requestImage(
            for: mediaAsset.asset,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: options
        ) { image, _ in
            self.image = image
        }
    }
}
