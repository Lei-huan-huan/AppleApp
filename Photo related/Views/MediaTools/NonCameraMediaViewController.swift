//
//  NonCameraMediaViewController.swift
//  Photo related
//
//  Created by 雷欢欢 on 2026/5/8.
//

import Photos
import SwiftUI
import UIKit

private final class NonCameraAssetCell: UICollectionViewCell {
    static let reuseId = "NonCameraAssetCell"

    let imageView = UIImageView()
    let badgeLabel = UILabel()
    let selectButton = UIButton(type: .system)
    var representedAssetId = ""
    var onToggleSelection: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)

        contentView.backgroundColor = .secondarySystemFill
        contentView.layer.cornerRadius = 14
        contentView.layer.masksToBounds = true

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        contentView.addSubview(imageView)

        let gradient = CAGradientLayer()
        gradient.colors = [UIColor.clear.cgColor, UIColor.black.withAlphaComponent(0.65).cgColor]
        gradient.startPoint = CGPoint(x: 0.5, y: 0.2)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
        gradient.name = "bottomGradient"
        contentView.layer.addSublayer(gradient)

        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        badgeLabel.textColor = .white
        badgeLabel.numberOfLines = 1
        badgeLabel.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        badgeLabel.layer.cornerRadius = 4
        badgeLabel.clipsToBounds = true
        badgeLabel.isHidden = true
        contentView.addSubview(badgeLabel)

        selectButton.translatesAutoresizingMaskIntoConstraints = false
        selectButton.addTarget(self, action: #selector(toggleSelectionTapped), for: .touchUpInside)
        selectButton.isHidden = true
        contentView.addSubview(selectButton)

        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            badgeLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            badgeLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -8),
            badgeLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),

            selectButton.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            selectButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4),
            selectButton.widthAnchor.constraint(equalToConstant: 32),
            selectButton.heightAnchor.constraint(equalToConstant: 32)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        contentView.layer.sublayers?.first(where: { $0.name == "bottomGradient" })?.frame = contentView.bounds
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        representedAssetId = ""
        imageView.image = nil
        badgeLabel.text = nil
        badgeLabel.isHidden = true
        onToggleSelection = nil
    }

    func configure(asset: MediaAsset, selectionMode: Bool, selected: Bool) {
        if asset.asset.mediaType == .video {
            let seconds = Int(round(asset.asset.duration))
            badgeLabel.isHidden = false
            badgeLabel.text = String(format: " %d:%02d ", seconds / 60, seconds % 60)
        } else {
            badgeLabel.isHidden = true
        }
        selectButton.isHidden = !selectionMode

        let config = UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)
        let imageName = selected ? "checkmark.circle.fill" : "circle"
        selectButton.setImage(UIImage(systemName: imageName, withConfiguration: config), for: .normal)
        selectButton.tintColor = .white
        selectButton.backgroundColor = selected ? .systemBlue : UIColor.black.withAlphaComponent(0.45)
        selectButton.layer.cornerRadius = 16

        contentView.layer.borderWidth = selected ? 2 : 0
        contentView.layer.borderColor = selected ? UIColor.systemBlue.cgColor : nil
    }

    @objc private func toggleSelectionTapped() {
        onToggleSelection?()
    }
}

final class NonCameraMediaViewController: UIViewController {
    weak var bridge: NonCameraMediaScreenBridge?

    private var allAssets: [MediaAsset] = []
    private var filteredAssets: [MediaAsset] = []
    private var selectedIds = Set<String>()
    private var selectionMode = false
    private var selectedFilters = Set(MediaFilter.allCases)

    private let imageManager = PHCachingImageManager()
    private var thumbnailSize = CGSize(width: 300, height: 300)
    private lazy var thumbOptions: PHImageRequestOptions = {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        return options
    }()

    private lazy var imageFilterButton = makeFilterButton(title: "图片", systemName: "photo")
    private lazy var videoFilterButton = makeFilterButton(title: "视频", systemName: "video")

    private lazy var collectionView: UICollectionView = {
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 8
        let view = UICollectionView(frame: .zero, collectionViewLayout: layout)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .systemBackground
        view.alwaysBounceVertical = true
        view.register(NonCameraAssetCell.self, forCellWithReuseIdentifier: NonCameraAssetCell.reuseId)
        view.dataSource = self
        view.delegate = self
        view.prefetchDataSource = self
        return view
    }()

    private let statusLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = .secondaryLabel
        label.font = .preferredFont(forTextStyle: .body)
        return label
    }()

    private let activity = UIActivityIndicatorView(style: .large)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let filterStack = UIStackView(arrangedSubviews: [imageFilterButton, videoFilterButton])
        filterStack.translatesAutoresizingMaskIntoConstraints = false
        filterStack.axis = .horizontal
        filterStack.spacing = 10
        filterStack.distribution = .fillEqually

        activity.translatesAutoresizingMaskIntoConstraints = false
        activity.hidesWhenStopped = true

        view.addSubview(filterStack)
        view.addSubview(collectionView)
        view.addSubview(statusLabel)
        view.addSubview(activity)

        NSLayoutConstraint.activate([
            filterStack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            filterStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            filterStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            filterStack.heightAnchor.constraint(equalToConstant: 44),

            collectionView.topAnchor.constraint(equalTo: filterStack.bottomAnchor, constant: 12),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),

            activity.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            activity.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])

        updateFilterButtons()
        updateSelectionChrome()
        requestAccessAndLoadIfNeeded()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateItemLayout()
    }

    private func makeFilterButton(title: String, systemName: String) -> UIButton {
        var config = UIButton.Configuration.filled()
        config.cornerStyle = .large
        config.image = UIImage(systemName: systemName)
        config.imagePadding = 6
        config.title = title
        let button = UIButton(configuration: config)
        button.addTarget(self, action: #selector(filterButtonTapped(_:)), for: .touchUpInside)
        return button
    }

    private func updateItemLayout() {
        let spacing: CGFloat = 8
        let columns: CGFloat = 3
        let width = collectionView.bounds.width
        guard width > 0 else { return }
        let side = floor((width - spacing * (columns - 1)) / columns)
        if let layout = collectionView.collectionViewLayout as? UICollectionViewFlowLayout {
            layout.itemSize = CGSize(width: side, height: side)
        }
        let scale = max(traitCollection.displayScale, 1)
        thumbnailSize = CGSize(width: side * scale, height: side * scale)
    }

    private func requestAccessAndLoadIfNeeded() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch status {
        case .authorized, .limited:
            loadAssets()
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] newStatus in
                DispatchQueue.main.async {
                    if newStatus == .authorized || newStatus == .limited {
                        self?.loadAssets()
                    } else {
                        self?.showDenied()
                    }
                }
            }
        default:
            showDenied()
        }
    }

    private func showDenied() {
        statusLabel.isHidden = false
        statusLabel.text = "需要访问照片权限以列出与删除项目。"
        collectionView.isHidden = true
    }

    private func loadAssets() {
        statusLabel.isHidden = true
        collectionView.isHidden = false
        activity.startAnimating()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            options.predicate = NSPredicate(
                format: "mediaType == %d OR mediaType == %d",
                PHAssetMediaType.image.rawValue,
                PHAssetMediaType.video.rawValue
            )

            let fetch = PHAsset.fetchAssets(with: options)
            var loaded: [MediaAsset] = []
            loaded.reserveCapacity(fetch.count / 2)

            fetch.enumerateObjects { asset, _, _ in
                let filename = Self.originalFilename(for: asset)
                guard !Self.isLikelyAppleCamera(filename) else { return }
                loaded.append(MediaAsset(asset: asset, filename: filename))
            }

            DispatchQueue.main.async {
                self.activity.stopAnimating()
                self.allAssets = loaded
                self.applyFilters()
            }
        }
    }

    private func applyFilters() {
        let allowedTypes = Set(selectedFilters.flatMap(\.matchingTypes))
        filteredAssets = allAssets.filter { allowedTypes.contains($0.asset.mediaType) }
        collectionView.reloadData()
        if filteredAssets.isEmpty {
            statusLabel.isHidden = false
            statusLabel.text = "没有符合条件的非相机图片或视频。"
        } else {
            statusLabel.isHidden = true
        }
        updateSelectionChrome()
    }

    private func updateFilterButtons() {
        configureFilterButton(imageFilterButton, active: selectedFilters.contains(.image))
        configureFilterButton(videoFilterButton, active: selectedFilters.contains(.video))
    }

    private func configureFilterButton(_ button: UIButton, active: Bool) {
        button.configuration?.baseBackgroundColor = active ? .systemBlue : .secondarySystemBackground
        button.configuration?.baseForegroundColor = active ? .white : .label
    }

    private func updateSelectionChrome() {
        let selectionMode = selectionMode
        let selectedCount = selectedIds.count
        let allSelected = !filteredAssets.isEmpty && selectedIds.count == filteredAssets.count
        DispatchQueue.main.async { [weak bridge] in
            bridge?.selectionMode = selectionMode
            bridge?.selectedCount = selectedCount
            bridge?.allSelected = allSelected
        }
    }

    @objc private func filterButtonTapped(_ sender: UIButton) {
        if sender === imageFilterButton {
            toggleFilter(.image)
        } else if sender === videoFilterButton {
            toggleFilter(.video)
        }
    }

    private func toggleFilter(_ filter: MediaFilter) {
        if selectedFilters.contains(filter) {
            selectedFilters.remove(filter)
        } else {
            selectedFilters.insert(filter)
        }
        if selectedFilters.isEmpty {
            selectedFilters = Set(MediaFilter.allCases)
        }
        updateFilterButtons()
        applyFilters()
    }

    @objc private func toggleSelectionMode() {
        selectionMode.toggle()
        if !selectionMode { selectedIds.removeAll() }
        collectionView.reloadData()
        updateSelectionChrome()
    }

    @objc private func toggleSelectAll() {
        let allSelected = !filteredAssets.isEmpty && selectedIds.count == filteredAssets.count
        if allSelected {
            selectedIds.removeAll()
        } else {
            selectedIds = Set(filteredAssets.map(\.id))
        }
        collectionView.reloadData()
        updateSelectionChrome()
    }

    @objc private func deleteSelected() {
        guard !selectedIds.isEmpty else { return }
        let alert = UIAlertController(
            title: "删除所选",
            message: "将删除选中的 \(selectedIds.count) 项。删除后仍可在“最近删除”中恢复。",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in
            self?.performDelete()
        })
        present(alert, animated: true)
    }

    func toggleSelectionModeFromBridge() {
        toggleSelectionMode()
    }

    func toggleSelectAllFromBridge() {
        toggleSelectAll()
    }

    func deleteSelectedFromBridge() {
        deleteSelected()
    }

    private func performDelete() {
        let ids = Array(selectedIds)
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.deleteAssets(assets)
        }) { [weak self] success, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if success {
                    self.selectedIds.removeAll()
                    self.selectionMode = false
                    self.loadAssets()
                }
            }
        }
    }

    private func openDetail(for mediaAsset: MediaAsset) {
        let hosting = UIHostingController(rootView: MediaDetailView(mediaAsset: mediaAsset).toolbar(.hidden, for: .tabBar))
        hosting.hidesBottomBarWhenPushed = true
        navigationController?.pushViewController(hosting, animated: true)
    }

    private static func originalFilename(for asset: PHAsset) -> String {
        let resources = PHAssetResource.assetResources(for: asset)
        if asset.mediaType == .video, let r = resources.first(where: { $0.type == .video }) {
            return r.originalFilename
        }
        if let r = resources.first(where: { $0.type == .photo || $0.type == .video }) {
            return r.originalFilename
        }
        return resources.first?.originalFilename ?? ""
    }

    private static func isLikelyAppleCamera(_ filename: String) -> Bool {
        let base = (filename as NSString).lastPathComponent
        return base.range(of: "^IMG_[0-9]+\\.", options: [.regularExpression, .caseInsensitive]) != nil
    }
}

extension NonCameraMediaViewController: UICollectionViewDataSource, UICollectionViewDelegate, UICollectionViewDataSourcePrefetching {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        filteredAssets.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: NonCameraAssetCell.reuseId, for: indexPath) as! NonCameraAssetCell
        let mediaAsset = filteredAssets[indexPath.item]
        cell.representedAssetId = mediaAsset.id
        cell.configure(asset: mediaAsset, selectionMode: selectionMode, selected: selectedIds.contains(mediaAsset.id))
        cell.onToggleSelection = { [weak self] in
            guard let self else { return }
            if self.selectedIds.contains(mediaAsset.id) {
                self.selectedIds.remove(mediaAsset.id)
            } else {
                self.selectedIds.insert(mediaAsset.id)
            }
            self.updateSelectionChrome()
            if let current = collectionView.cellForItem(at: indexPath) as? NonCameraAssetCell {
                current.configure(asset: mediaAsset, selectionMode: self.selectionMode, selected: self.selectedIds.contains(mediaAsset.id))
            }
        }

        imageManager.requestImage(
            for: mediaAsset.asset,
            targetSize: thumbnailSize,
            contentMode: .aspectFill,
            options: thumbOptions
        ) { [weak cell] image, _ in
            guard let cell, cell.representedAssetId == mediaAsset.id else { return }
            cell.imageView.image = image
        }

        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        let mediaAsset = filteredAssets[indexPath.item]
        openDetail(for: mediaAsset)
    }

    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        let assets = indexPaths.compactMap { indexPath -> PHAsset? in
            guard indexPath.item < filteredAssets.count else { return nil }
            return filteredAssets[indexPath.item].asset
        }
        guard !assets.isEmpty else { return }
        imageManager.startCachingImages(for: assets, targetSize: thumbnailSize, contentMode: .aspectFill, options: thumbOptions)
    }

    func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        let assets = indexPaths.compactMap { indexPath -> PHAsset? in
            guard indexPath.item < filteredAssets.count else { return nil }
            return filteredAssets[indexPath.item].asset
        }
        guard !assets.isEmpty else { return }
        imageManager.stopCachingImages(for: assets, targetSize: thumbnailSize, contentMode: .aspectFill, options: thumbOptions)
    }
}
