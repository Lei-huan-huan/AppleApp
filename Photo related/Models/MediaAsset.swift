//
//  MediaAsset.swift
//  Photo related
//
//  Created by 雷欢欢 on 2026/5/8.
//

import Photos

struct MediaAsset: Identifiable, Hashable {
    let id: String
    let asset: PHAsset
    let filename: String

    init(asset: PHAsset, filename: String) {
        self.id = asset.localIdentifier
        self.asset = asset
        self.filename = filename
    }
}
