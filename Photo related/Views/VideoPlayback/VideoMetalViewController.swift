//
//  VideoMetalViewController.swift
//  Photo related
//

import UIKit
import PhotosUI
import MetalKit

final class VideoMetalViewController: UIViewController {
    private let metalView = MetalVideoView(frame: .zero)
    private let filterScrollView = UIScrollView()
    private let filterStackView: UIStackView = {
        let s = UIStackView()
        s.axis = .horizontal
        s.spacing = 8
        s.alignment = .center
        s.distribution = .fill
        return s
    }()

    private static let filterTitles: [String] = [
        "正常", "红", "绿", "蓝", "灰",
        "热感", "工笔", "油画", "水彩", "壁画",
        "蜡笔", "线描", "卡通", "Crayon", "强线描", "卡通3", "猫脸"
    ]

    private var selectedFilterIndex = 0
    private var observers: [NSObjectProtocol] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "单路 Metal 播放"
        navigationItem.prompt = "特效与自定义相机同源（Core Image + Metal）。再次点击已选滤镜可恢复「正常」。"
        setupUI()
        bindSelectionNotifications()
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver(_:))
    }

    private func setupUI() {
        metalView.translatesAutoresizingMaskIntoConstraints = false
        filterScrollView.translatesAutoresizingMaskIntoConstraints = false
        filterScrollView.showsHorizontalScrollIndicator = true
        filterScrollView.alwaysBounceHorizontal = true
        filterStackView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(metalView)
        view.addSubview(filterScrollView)
        filterScrollView.addSubview(filterStackView)

        for (i, title) in Self.filterTitles.enumerated() {
            let btn = UIButton(type: .system)
            btn.tag = i
            btn.configuration = Self.filterButtonConfiguration(title: title, selected: i == 0)
            btn.addTarget(self, action: #selector(filterButtonTapped(_:)), for: .touchUpInside)
            filterStackView.addArrangedSubview(btn)
        }

        NSLayoutConstraint.activate([
            metalView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            metalView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            metalView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            metalView.bottomAnchor.constraint(equalTo: filterScrollView.topAnchor, constant: -12),

            filterScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            filterScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            filterScrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            filterScrollView.heightAnchor.constraint(equalToConstant: 48),

            filterStackView.topAnchor.constraint(equalTo: filterScrollView.contentLayoutGuide.topAnchor),
            filterStackView.leadingAnchor.constraint(equalTo: filterScrollView.contentLayoutGuide.leadingAnchor, constant: 12),
            filterStackView.trailingAnchor.constraint(equalTo: filterScrollView.contentLayoutGuide.trailingAnchor, constant: -12),
            filterStackView.bottomAnchor.constraint(equalTo: filterScrollView.contentLayoutGuide.bottomAnchor),
            filterStackView.heightAnchor.constraint(equalTo: filterScrollView.frameLayoutGuide.heightAnchor)
        ])
    }

    private static func filterButtonConfiguration(title: String, selected: Bool) -> UIButton.Configuration {
        var cfg = UIButton.Configuration.plain()
        cfg.title = title
        cfg.cornerStyle = .medium
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
        var titleAttr = AttributeContainer()
        titleAttr.font = .systemFont(ofSize: 13, weight: .medium)
        titleAttr.foregroundColor = selected ? UIColor.label : UIColor.secondaryLabel
        cfg.attributedTitle = AttributedString(title, attributes: titleAttr)
        cfg.background.backgroundColor = selected ? .secondarySystemFill : .tertiarySystemFill
        return cfg
    }

    private func refreshFilterButtonAppearance() {
        for case let btn as UIButton in filterStackView.arrangedSubviews {
            guard btn.tag >= 0, btn.tag < Self.filterTitles.count else { continue }
            let title = Self.filterTitles[btn.tag]
            btn.configuration = Self.filterButtonConfiguration(title: title, selected: btn.tag == selectedFilterIndex)
        }
    }

    @objc private func filterButtonTapped(_ sender: UIButton) {
        if sender.tag == selectedFilterIndex, selectedFilterIndex != 0 {
            selectedFilterIndex = 0
            refreshFilterButtonAppearance()
            metalView.setFilter(0)
            filterScrollView.setContentOffset(.zero, animated: true)
            return
        }
        selectedFilterIndex = sender.tag
        refreshFilterButtonAppearance()
        metalView.setFilter(selectedFilterIndex)
    }

    private func bindSelectionNotifications() {
        observers.append(
            NotificationCenter.default.addObserver(
                forName: .singleVideoSelectFromPhotos,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.selectVideoFromPhotoLibrary()
            }
        )

        observers.append(
            NotificationCenter.default.addObserver(
                forName: .singleVideoSelectFromFiles,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.selectVideoFromFiles()
            }
        )
    }

    private func selectVideoFromPhotoLibrary() {
        var config = PHPickerConfiguration()
        config.filter = .videos
        config.selectionLimit = 1

        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }

    private func selectVideoFromFiles() {
        let picker = VideoDocumentPickerSupport.makePicker(allowsMultipleSelection: false)
        picker.delegate = self
        present(picker, animated: true)
    }
}

extension VideoMetalViewController: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        dismiss(animated: true)
        guard let item = results.first else { return }

        item.itemProvider.loadFileRepresentation(forTypeIdentifier: "public.movie") { [weak self] url, _ in
            guard let url else { return }
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: tempURL)
            try? FileManager.default.copyItem(at: url, to: tempURL)

            DispatchQueue.main.async {
                self?.metalView.loadVideo(url: tempURL)
            }
        }
    }
}

extension VideoMetalViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        metalView.loadVideo(url: url)
    }
}
