//
//  PhotoLibraryViewModel.swift
//  Photo related
//
//  Created by 雷欢欢 on 2026/5/8.
//

import Combine
import Photos

@MainActor
final class PhotoLibraryViewModel: ObservableObject {
    @Published var authorizationState: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Published var selectedFilters: Set<MediaFilter> = Set(MediaFilter.allCases)
    @Published var selectionMode = false
    @Published var isLoading = false
    @Published private(set) var selectedAssetIDs: Set<String> = []
    @Published private(set) var allAssets: [MediaAsset] = []

    var filteredAssets: [MediaAsset] {
        guard !selectedFilters.isEmpty else { return allAssets }

        let allowedTypes = Set(selectedFilters.flatMap(\.matchingTypes))
        return allAssets.filter { allowedTypes.contains($0.asset.mediaType) }
    }

    func requestAccessIfNeeded() async {
        let currentStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        authorizationState = currentStatus

        guard currentStatus == .notDetermined else { return }

        let newStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        authorizationState = newStatus
    }

    func loadAssetsIfPossible() async {
        guard authorizationState == .authorized || authorizationState == .limited else { return }
        isLoading = true
        defer { isLoading = false }

        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        fetchOptions.predicate = NSPredicate(
            format: "mediaType == %d OR mediaType == %d",
            PHAssetMediaType.image.rawValue,
            PHAssetMediaType.video.rawValue
        )

        let result = PHAsset.fetchAssets(with: fetchOptions)
        var loadedAssets: [MediaAsset] = []

        result.enumerateObjects { asset, _, _ in
            guard let filename = PHAssetResource.assetResources(for: asset).first?.originalFilename else {
                return
            }

            guard !Self.isLikelySystemCameraFile(named: filename) else {
                return
            }

            loadedAssets.append(MediaAsset(asset: asset, filename: filename))
        }

        allAssets = loadedAssets
    }

    func toggleFilter(_ filter: MediaFilter) {
        if selectedFilters.contains(filter) {
            selectedFilters.remove(filter)
        } else {
            selectedFilters.insert(filter)
        }
    }

    func isSelected(_ asset: MediaAsset) -> Bool {
        selectedAssetIDs.contains(asset.id)
    }

    func toggleSelection(for asset: MediaAsset) {
        guard selectionMode else { return }
        if selectedAssetIDs.contains(asset.id) {
            selectedAssetIDs.remove(asset.id)
        } else {
            selectedAssetIDs.insert(asset.id)
        }
    }

    func toggleSelectionMode() {
        selectionMode.toggle()
        if !selectionMode {
            selectedAssetIDs.removeAll()
        }
    }

    func toggleSelectAllFilteredAssets() {
        let filteredIDs = Set(filteredAssets.map(\.id))
        let allSelected = !filteredIDs.isEmpty && filteredIDs.isSubset(of: selectedAssetIDs)
        if allSelected {
            selectedAssetIDs.subtract(filteredIDs)
        } else {
            selectedAssetIDs.formUnion(filteredIDs)
        }
    }

    var allFilteredAssetsSelected: Bool {
        let filteredIDs = Set(filteredAssets.map(\.id))
        return !filteredIDs.isEmpty && filteredIDs.isSubset(of: selectedAssetIDs)
    }

    func deleteSelectedAssets() async {
        let identifiers = selectedAssetIDs
        guard !identifiers.isEmpty else { return }

        let assetsToDelete = PHAsset.fetchAssets(withLocalIdentifiers: Array(identifiers), options: nil)

        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assetsToDelete)
            }
            selectedAssetIDs.removeAll()
            selectionMode = false
            await loadAssetsIfPossible()
        } catch {
            print("Failed to delete assets: \(error)")
        }
    }

    private static func isLikelySystemCameraFile(named filename: String) -> Bool {
        let name = ((filename as NSString).deletingPathExtension).uppercased()

        let directCameraPatterns = [
            #"^IMG_\d+$"#,
            #"^IMG_E\d+$"#,
            #"^VID_\d+$"#,
            #"^MOV_\d+$"#,
            #"^DSC_\d+$"#
        ]

        return directCameraPatterns.contains { pattern in
            name.range(of: pattern, options: .regularExpression) != nil
        }
    }
}
