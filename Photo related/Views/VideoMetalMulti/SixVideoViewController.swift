//
//  SixVideoViewController.swift
//  Photo related
//

import UIKit
import PhotosUI
import MetalKit

final class SixVideoViewController: UIViewController {
    private let metalView = SixVideoMetalView(frame: .zero)
    private var observers: [NSObjectProtocol] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "6 路 Metal 播放"

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "选择视频",
            menu: UIMenu(children: [
                UIAction(title: "从相册选择", image: UIImage(systemName: "photo.on.rectangle")) { [weak self] _ in
                    self?.selectVideosFromPhotoLibrary()
                },
                UIAction(title: "从文件选择", image: UIImage(systemName: "folder")) { [weak self] _ in
                    self?.selectVideosFromFiles()
                }
            ])
        )

        metalView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(metalView)
        NSLayoutConstraint.activate([
            metalView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            metalView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            metalView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            metalView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12)
        ])
        
        observers.append(
            NotificationCenter.default.addObserver(
                forName: .sixVideoSelectFromPhotos,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.selectVideosFromPhotoLibrary()
            }
        )
        observers.append(
            NotificationCenter.default.addObserver(
                forName: .sixVideoSelectFromFiles,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.selectVideosFromFiles()
            }
        )
    }
    
    deinit {
        observers.forEach(NotificationCenter.default.removeObserver(_:))
    }

    func selectVideosFromPhotoLibrary() {
        var config = PHPickerConfiguration()
        config.filter = .videos
        config.selectionLimit = 6

        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }

    func selectVideosFromFiles() {
        let picker = VideoDocumentPickerSupport.makePicker(allowsMultipleSelection: true)
        picker.delegate = self
        present(picker, animated: true)
    }

}

extension SixVideoViewController: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        dismiss(animated: true)
        guard !results.isEmpty else { return }

        let selected = Array(results.prefix(6))
        var orderedURLs = Array<URL?>(repeating: nil, count: selected.count)
        let group = DispatchGroup()

        for (index, item) in selected.enumerated() {
            group.enter()
            item.itemProvider.loadFileRepresentation(forTypeIdentifier: "public.movie") { url, _ in
                defer { group.leave() }
                guard let url else { return }

                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("\(UUID().uuidString).mov")
                try? FileManager.default.removeItem(at: tempURL)
                try? FileManager.default.copyItem(at: url, to: tempURL)
                orderedURLs[index] = tempURL
            }
        }

        group.notify(queue: .main) { [weak self] in
            self?.metalView.loadVideos(urls: orderedURLs.compactMap { $0 })
        }
    }
}

extension SixVideoViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        let picked = Array(urls.prefix(6))
        guard !picked.isEmpty else { return }
        metalView.loadVideos(urls: picked)
    }
}
