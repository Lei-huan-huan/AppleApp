//
//  PhotoTab.swift
//  Photo related
//
//  Created by 雷欢欢 on 2026/5/8.
//

enum PhotoTab: String, CaseIterable {
    case photos = "照片"
    case categories = "视频播放"
    case camera = "相机"

    var icon: String {
        switch self {
        case .photos:
            return "photo.on.rectangle"
        case .categories:
            return "square.grid.2x2"
        case .camera:
            return "camera.fill"
        }
    }
}
