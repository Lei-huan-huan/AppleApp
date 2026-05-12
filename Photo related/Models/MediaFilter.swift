//
//  MediaFilter.swift
//  Photo related
//
//  Created by 雷欢欢 on 2026/5/8.
//

import Photos

enum MediaFilter: String, CaseIterable, Hashable {
    case image = "图片"
    case video = "视频"

    var icon: String {
        switch self {
        case .image:
            return "photo"
        case .video:
            return "video"
        }
    }

    var matchingTypes: [PHAssetMediaType] {
        switch self {
        case .image:
            return [.image]
        case .video:
            return [.video]
        }
    }
}
