//
//  VideoMetalViewController.swift
//  Photo related
//

import UIKit
import PhotosUI
import MetalKit

final class VideoMetalViewController: UIViewController {
    private let metalView = MetalVideoView(frame: .zero)
    private let filterControl = UISegmentedControl(items: ["正常", "红", "绿", "蓝", "灰"])
    private var observers: [NSObjectProtocol] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "单路 Metal 播放"
        setupUI()
        bindSelectionNotifications()
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver(_:))
    }

    private func setupUI() {
        metalView.translatesAutoresizingMaskIntoConstraints = false
        filterControl.translatesAutoresizingMaskIntoConstraints = false
        filterControl.selectedSegmentIndex = 0
        filterControl.addTarget(self, action: #selector(filterChanged), for: .valueChanged)

        view.addSubview(metalView)
        view.addSubview(filterControl)

        NSLayoutConstraint.activate([
            metalView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            metalView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            metalView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            metalView.bottomAnchor.constraint(equalTo: filterControl.topAnchor, constant: -12),

            filterControl.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            filterControl.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            filterControl.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            filterControl.heightAnchor.constraint(equalToConstant: 32)
        ])
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

    @objc private func filterChanged() {
        metalView.setFilter(filterControl.selectedSegmentIndex)
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
