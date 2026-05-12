//
//  FourVideoViewController.swift
//  Photo related
//

import UIKit
import PhotosUI
import MetalKit

final class FourVideoViewController: UIViewController {
    private let metalView = FourVideoMetalView(frame: .zero)
    private var observers: [NSObjectProtocol] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "4 路 Metal 播放"

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
                forName: .fourVideoSelectFromPhotos,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.selectVideosFromPhotoLibrary()
            }
        )
        observers.append(
            NotificationCenter.default.addObserver(
                forName: .fourVideoSelectFromFiles,
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
        config.selectionLimit = 4

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

extension FourVideoViewController: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        dismiss(animated: true)
        guard !results.isEmpty else { return }

        let selected = Array(results.prefix(4))
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

extension FourVideoViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        let picked = Array(urls.prefix(4))
        guard !picked.isEmpty else { return }
        metalView.loadVideos(urls: picked)
    }
}
