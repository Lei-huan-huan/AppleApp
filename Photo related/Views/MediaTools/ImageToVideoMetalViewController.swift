//
//  ImageToVideoMetalViewController.swift
//  Photo related
//
//  自 IosTest1 同步：PHPicker + 文件拷贝、Metal 幻灯片编码、音轨合成；导出在后台任务执行。
//

import AVFoundation
import AVKit
import Metal
import MetalKit
import Photos
import PhotosUI
import UIKit
import UniformTypeIdentifiers

fileprivate enum DurationBaseMode: Int, Sendable { case images = 0, audio = 1 }
fileprivate enum TransitionEffect: Int, Sendable { case none = 0, crossFade = 1, slideLeft = 2, zoomCross = 3 }

final class ImageToVideoMetalViewController: UIViewController {

    private enum PickerTarget { case images, audioSource }

    private let pickImagesButton = UIButton(type: .system)
    private let pickAudioButton = UIButton(type: .system)
    private let imagesLabel = UILabel()
    private let audioLabel = UILabel()
    private let modeControl = UISegmentedControl(items: ["以图片为准", "以音频为准"])
    private let intervalSlider = UISlider()
    private let intervalLabel = UILabel()
    private let effectControl = UISegmentedControl(items: ["无", "淡入淡出", "左滑", "缩放"])
    private let saveLocationControl = UISegmentedControl(items: ["保存到文稿", "保存到相册"])
    private let outputStemField = UITextField()
    private let toggleSettingsButton = UIButton(type: .system)
    private let optionsHintLabel = UILabel()
    private let settingsContainer = UIStackView()
    private let previewContainer = UIView()
    private let previewPlayButton = UIButton(type: .system)
    private let generateButton = UIButton(type: .system)
    private let statusLabel = UILabel()
    private let activity = UIActivityIndicatorView(style: .medium)

    private var pickedImageURLs: [URL] = []
    private var audioSourceURL: URL?
    private var activePickerTarget: PickerTarget = .images
    private var isGenerating = false
    private var isSettingsExpanded = false
    private var lastGeneratedVideoURL: URL?
    private var settingsCollapsedConstraint: NSLayoutConstraint?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "图片生成视频"
        view.backgroundColor = .systemBackground
        setupViews()
        outputStemField.text = defaultOutputStem()
        updateGenerateButtonState()
    }

    private func setupViews() {
        pickImagesButton.setTitle("选择图片（1 张或多张）", for: .normal)
        pickImagesButton.menu = UIMenu(children: [
            UIAction(title: "从相册", image: UIImage(systemName: "photo.on.rectangle")) { [weak self] _ in
                self?.presentPhotoPickerForImages()
            },
            UIAction(title: "从文件", image: UIImage(systemName: "folder")) { [weak self] _ in
                self?.presentImageDocumentPicker()
            }
        ])
        pickImagesButton.showsMenuAsPrimaryAction = true
        pickImagesButton.translatesAutoresizingMaskIntoConstraints = false

        pickAudioButton.setTitle("选择音频源（音频或含音轨视频）", for: .normal)
        pickAudioButton.menu = UIMenu(children: [
            UIAction(title: "从相册视频", image: UIImage(systemName: "film")) { [weak self] _ in
                self?.presentPhotoPickerForAudioSource()
            },
            UIAction(title: "从文件", image: UIImage(systemName: "folder")) { [weak self] _ in
                self?.presentAudioSourceDocumentPicker()
            }
        ])
        pickAudioButton.showsMenuAsPrimaryAction = true
        pickAudioButton.translatesAutoresizingMaskIntoConstraints = false

        for label in [imagesLabel, audioLabel] {
            label.font = .preferredFont(forTextStyle: .caption1)
            label.textColor = .secondaryLabel
            label.numberOfLines = 3
            label.translatesAutoresizingMaskIntoConstraints = false
        }
        imagesLabel.text = "未选择图片"
        audioLabel.text = "未选择音频源"

        modeControl.selectedSegmentIndex = 0
        modeControl.translatesAutoresizingMaskIntoConstraints = false

        intervalSlider.minimumValue = 0.5
        intervalSlider.maximumValue = 6.0
        intervalSlider.value = 2.0
        intervalSlider.addAction(UIAction { [weak self] _ in self?.updateIntervalLabel() }, for: .valueChanged)
        intervalSlider.translatesAutoresizingMaskIntoConstraints = false

        intervalLabel.font = .preferredFont(forTextStyle: .subheadline)
        intervalLabel.translatesAutoresizingMaskIntoConstraints = false
        updateIntervalLabel()

        effectControl.selectedSegmentIndex = 1
        effectControl.translatesAutoresizingMaskIntoConstraints = false
        saveLocationControl.selectedSegmentIndex = 0
        saveLocationControl.translatesAutoresizingMaskIntoConstraints = false

        outputStemField.borderStyle = .roundedRect
        outputStemField.placeholder = "输出文件主名（不含 .mov）"
        outputStemField.returnKeyType = .done
        outputStemField.delegate = self
        outputStemField.translatesAutoresizingMaskIntoConstraints = false

        toggleSettingsButton.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
        toggleSettingsButton.contentHorizontalAlignment = .left
        toggleSettingsButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.isSettingsExpanded.toggle()
            let expanded = self.isSettingsExpanded
            self.settingsContainer.isHidden = !expanded
            self.settingsCollapsedConstraint?.isActive = !expanded
            self.updateSettingsToggleTitle()
            UIView.animate(withDuration: 0.2) {
                self.view.layoutIfNeeded()
            }
        }, for: .touchUpInside)
        toggleSettingsButton.translatesAutoresizingMaskIntoConstraints = false

        settingsContainer.axis = .vertical
        settingsContainer.spacing = 8
        settingsContainer.translatesAutoresizingMaskIntoConstraints = false
        settingsContainer.addArrangedSubview(modeControl)
        settingsContainer.addArrangedSubview(intervalSlider)
        settingsContainer.addArrangedSubview(intervalLabel)
        settingsContainer.addArrangedSubview(effectControl)
        settingsContainer.addArrangedSubview(saveLocationControl)
        settingsContainer.addArrangedSubview(outputStemField)
        settingsContainer.isHidden = true
        settingsCollapsedConstraint = settingsContainer.heightAnchor.constraint(equalToConstant: 0)
        settingsCollapsedConstraint?.isActive = true
        updateSettingsToggleTitle()

        previewContainer.backgroundColor = .black
        previewContainer.layer.cornerRadius = 10
        previewContainer.clipsToBounds = true
        previewContainer.translatesAutoresizingMaskIntoConstraints = false

        previewPlayButton.setTitle("点击播放生成视频预览", for: .normal)
        previewPlayButton.setTitleColor(.white, for: .normal)
        previewPlayButton.backgroundColor = UIColor.white.withAlphaComponent(0.15)
        previewPlayButton.titleLabel?.font = .boldSystemFont(ofSize: 16)
        previewPlayButton.addAction(UIAction { [weak self] _ in
            self?.presentGeneratedPreview()
        }, for: .touchUpInside)
        previewPlayButton.translatesAutoresizingMaskIntoConstraints = false

        generateButton.setTitle("开始生成", for: .normal)
        generateButton.titleLabel?.font = .boldSystemFont(ofSize: 17)
        generateButton.addAction(UIAction { [weak self] _ in self?.tapGenerate() }, for: .touchUpInside)
        generateButton.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 0
        statusLabel.text = "先选图片和音频源，再设置规则后生成。"
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        activity.hidesWhenStopped = true
        activity.translatesAutoresizingMaskIntoConstraints = false

        optionsHintLabel.text = "选项已折叠，可展开设置"
        optionsHintLabel.font = .preferredFont(forTextStyle: .caption1)
        optionsHintLabel.textColor = .secondaryLabel
        optionsHintLabel.translatesAutoresizingMaskIntoConstraints = false

        [pickImagesButton, imagesLabel, pickAudioButton, audioLabel, toggleSettingsButton, optionsHintLabel, settingsContainer, generateButton, previewContainer, statusLabel, activity].forEach(view.addSubview)
        previewContainer.addSubview(previewPlayButton)

        NSLayoutConstraint.activate([
            pickImagesButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 14),
            pickImagesButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            imagesLabel.topAnchor.constraint(equalTo: pickImagesButton.bottomAnchor, constant: 6),
            imagesLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            imagesLabel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),

            pickAudioButton.topAnchor.constraint(equalTo: imagesLabel.bottomAnchor, constant: 12),
            pickAudioButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            audioLabel.topAnchor.constraint(equalTo: pickAudioButton.bottomAnchor, constant: 6),
            audioLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            audioLabel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),

            toggleSettingsButton.topAnchor.constraint(equalTo: audioLabel.bottomAnchor, constant: 10),
            toggleSettingsButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            toggleSettingsButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),

            optionsHintLabel.topAnchor.constraint(equalTo: toggleSettingsButton.bottomAnchor, constant: 2),
            optionsHintLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            optionsHintLabel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),

            settingsContainer.topAnchor.constraint(equalTo: optionsHintLabel.bottomAnchor, constant: 6),
            settingsContainer.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            settingsContainer.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),

            generateButton.topAnchor.constraint(equalTo: settingsContainer.bottomAnchor, constant: 12),
            generateButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            previewContainer.topAnchor.constraint(equalTo: generateButton.bottomAnchor, constant: 12),
            previewContainer.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            previewContainer.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            previewContainer.heightAnchor.constraint(equalTo: previewContainer.widthAnchor, multiplier: 9.0 / 16.0),

            previewPlayButton.topAnchor.constraint(equalTo: previewContainer.topAnchor),
            previewPlayButton.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor),
            previewPlayButton.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor),
            previewPlayButton.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor),

            statusLabel.topAnchor.constraint(equalTo: previewContainer.bottomAnchor, constant: 10),
            statusLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            activity.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 10),
            activity.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        ])
    }

    private func makeTitleLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: .headline)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func updateIntervalLabel() {
        intervalLabel.text = String(format: "每张图显示 %.1f 秒", intervalSlider.value)
    }

    private func updateSettingsToggleTitle() {
        let title = isSettingsExpanded ? "收起设置 ▲" : "展开设置 ▼"
        toggleSettingsButton.setTitle(title, for: .normal)
        optionsHintLabel.text = isSettingsExpanded ? "可收起设置，把更多空间留给预览" : "选项已折叠，可展开设置"
    }

    private func updateGenerateButtonState() {
        generateButton.isEnabled = !isGenerating && !pickedImageURLs.isEmpty && audioSourceURL != nil
    }

    private func presentPhotoPickerForImages() {
        activePickerTarget = .images
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 0
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }

    private func presentPhotoPickerForAudioSource() {
        activePickerTarget = .audioSource
        var config = PHPickerConfiguration()
        config.filter = .videos
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }

    private func presentImageDocumentPicker() {
        activePickerTarget = .images
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.image], asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = true
        present(picker, animated: true)
    }

    private func presentAudioSourceDocumentPicker() {
        activePickerTarget = .audioSource
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: mergedAudioSourceUTTypes(), asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }

    private func mergedAudioSourceUTTypes() -> [UTType] {
        let audio: [UTType] = [.audio, .mp3, .mpeg4Audio, .wav, .aiff, .appleProtectedMPEG4Audio]
        let video: [UTType] = [.movie, .mpeg4Movie, .quickTimeMovie]
        var seen = Set<String>()
        var out: [UTType] = []
        for t in audio + video {
            if seen.insert(t.identifier).inserted {
                out.append(t)
            }
        }
        return out
    }

    private func tapGenerate() {
        view.endEditing(true)
        guard !pickedImageURLs.isEmpty, let audioURL = audioSourceURL else { return }
        let outputStem = sanitizedStem(outputStemField.text ?? "")
        let mode = DurationBaseMode(rawValue: modeControl.selectedSegmentIndex) ?? .images
        let effect = TransitionEffect(rawValue: effectControl.selectedSegmentIndex) ?? .crossFade
        let interval = Double(intervalSlider.value)

        isGenerating = true
        updateGenerateButtonState()
        activity.startAnimating()
        statusLabel.text = "正在生成，请稍候…"

        let imageURLs = pickedImageURLs
        Task {
            do {
                let outURL = try await Task.detached(priority: .userInitiated) {
                    try await SlideshowMetalExporter().export(
                        imageURLs: imageURLs,
                        audioSourceURL: audioURL,
                        durationMode: mode,
                        interval: interval,
                        transition: effect,
                        outputStem: outputStem
                    )
                }.value
                await MainActor.run {
                    self.isGenerating = false
                    self.updateGenerateButtonState()
                    self.activity.stopAnimating()
                    self.lastGeneratedVideoURL = outURL
                    self.previewPlayButton.setTitle("点击播放：\(outURL.lastPathComponent)", for: .normal)
                    if self.saveLocationControl.selectedSegmentIndex == 1 {
                        self.saveVideoToPhotoLibrary(fileURL: outURL)
                    } else {
                        self.statusLabel.text = "生成完成：\(outURL.lastPathComponent)"
                        self.presentAlert(title: "生成完成", message: "已保存到文稿：\(outURL.path)")
                    }
                }
            } catch {
                await MainActor.run {
                    self.isGenerating = false
                    self.updateGenerateButtonState()
                    self.activity.stopAnimating()
                    self.statusLabel.text = "生成失败：\(error.localizedDescription)"
                    self.presentAlert(title: "生成失败", message: error.localizedDescription)
                }
            }
        }
    }

    private func sanitizedStem(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { s = defaultOutputStem() }
        let bad = CharacterSet(charactersIn: "/\\:?*\"<>|")
        s = s.components(separatedBy: bad).joined()
        while s.hasPrefix(".") { s = String(s.dropFirst()) }
        if s.isEmpty { s = defaultOutputStem() }
        return s
    }

    private func defaultOutputStem() -> String {
        "图生视频_\(timestampString())"
    }

    private func timestampString() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss_SSS"
        return formatter.string(from: Date())
    }

    private func presentAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }

    private func presentGeneratedPreview() {
        guard let url = lastGeneratedVideoURL else {
            presentAlert(title: "暂无预览", message: "请先生成视频。")
            return
        }
        let pvc = AVPlayerViewController()
        pvc.player = AVPlayer(url: url)
        present(pvc, animated: true) {
            pvc.player?.play()
        }
    }

    private func saveVideoToPhotoLibrary(fileURL: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                guard status == .authorized || status == .limited else {
                    self.statusLabel.text = "相册权限被拒绝，文件已保存在文稿。"
                    self.presentAlert(title: "无相册权限", message: "请在设置中允许本应用添加照片。当前文件仍在文稿：\(fileURL.path)")
                    return
                }
                PHPhotoLibrary.shared().performChanges {
                    _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: fileURL)
                } completionHandler: { [weak self] ok, error in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        if ok {
                            self.statusLabel.text = "生成完成：已保存到相册（文稿也保留了一份）"
                            self.presentAlert(title: "生成完成", message: "已保存到相册。\n文稿备份：\(fileURL.path)")
                        } else {
                            self.statusLabel.text = "保存相册失败，已保留文稿文件。"
                            self.presentAlert(title: "保存相册失败", message: (error?.localizedDescription ?? "未知错误") + "\n\n文稿备份：\(fileURL.path)")
                        }
                    }
                }
            }
        }
    }
}

extension ImageToVideoMetalViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }
}

extension ImageToVideoMetalViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard !urls.isEmpty else { return }
        switch activePickerTarget {
        case .images:
            var copied: [URL] = []
            for url in urls {
                if let u = copyPickedFile(from: url, prefix: "img_doc", securityScoped: true) {
                    copied.append(u)
                }
            }
            if !copied.isEmpty {
                pickedImageURLs = copied
                imagesLabel.text = "已选 \(copied.count) 张：\(copied.prefix(3).map(\.lastPathComponent).joined(separator: "、"))"
                if (outputStemField.text ?? "").isEmpty {
                    outputStemField.text = defaultOutputStem()
                }
            }
        case .audioSource:
            guard let first = urls.first,
                  let copied = copyPickedFile(from: first, prefix: "audio_doc", securityScoped: true) else { break }
            audioSourceURL = copied
            audioLabel.text = "音频源：\(copied.lastPathComponent)"
        }
        updateGenerateButtonState()
    }

    private func copyPickedFile(from url: URL, prefix: String, securityScoped: Bool) -> URL? {
        let copyTask: () -> URL? = {
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(prefix)_\(UUID().uuidString)_\(url.lastPathComponent)")
            do {
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.copyItem(at: url, to: dest)
                return dest
            } catch {
                self.presentAlert(title: "复制失败", message: error.localizedDescription)
                return nil
            }
        }
        if securityScoped {
            let ok = url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() } }
            return copyTask()
        }
        return copyTask()
    }
}

extension ImageToVideoMetalViewController: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        dismiss(animated: true)
        guard !results.isEmpty else { return }
        switch activePickerTarget {
        case .images:
            Task {
                var copied: [URL] = []
                for item in results {
                    if let u = await copyPhotoItem(item, prefix: "img_ph", typeIdentifier: UTType.image.identifier) {
                        copied.append(u)
                    }
                }
                await MainActor.run {
                    if !copied.isEmpty {
                        self.pickedImageURLs = copied
                        self.imagesLabel.text = "已选 \(copied.count) 张：\(copied.prefix(3).map(\.lastPathComponent).joined(separator: "、"))"
                        if (self.outputStemField.text ?? "").isEmpty {
                            self.outputStemField.text = self.defaultOutputStem()
                        }
                        self.updateGenerateButtonState()
                    }
                }
            }
        case .audioSource:
            guard let first = results.first else { return }
            Task {
                let copied = await copyPhotoItemVideo(first, prefix: "audio_ph")
                await MainActor.run {
                    if let copied {
                        self.audioSourceURL = copied
                        self.audioLabel.text = "音频源（相册视频）：\(copied.lastPathComponent)"
                        self.updateGenerateButtonState()
                    }
                }
            }
        }
    }

    /// 与 IosTest1 一致用 `loadFileRepresentation`；多 UTI 回退，避免部分相册视频只认 mpeg4/quicktime。
    private func copyPhotoItemVideo(_ item: PHPickerResult, prefix: String) async -> URL? {
        let typeIds = [UTType.movie.identifier, UTType.mpeg4Movie.identifier, UTType.quickTimeMovie.identifier]
        for typeId in typeIds {
            if let url = await copyPhotoItem(item, prefix: prefix, typeIdentifier: typeId, alertOnError: false) {
                return url
            }
        }
        await MainActor.run {
            self.presentAlert(title: "读取失败", message: "无法从相册拷贝该视频，请尝试「从文件」选择。")
        }
        return nil
    }

    private func copyPhotoItem(_ item: PHPickerResult, prefix: String, typeIdentifier: String, alertOnError: Bool = true) async -> URL? {
        await withCheckedContinuation { cont in
            item.itemProvider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
                if let error {
                    if alertOnError {
                        DispatchQueue.main.async {
                            self.presentAlert(title: "读取失败", message: error.localizedDescription)
                        }
                    }
                    cont.resume(returning: nil)
                    return
                }
                guard let url else {
                    cont.resume(returning: nil)
                    return
                }
                let dest = FileManager.default.temporaryDirectory
                    .appendingPathComponent("\(prefix)_\(UUID().uuidString)_\(url.lastPathComponent)")
                do {
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.copyItem(at: url, to: dest)
                    cont.resume(returning: dest)
                } catch {
                    if alertOnError {
                        DispatchQueue.main.async {
                            self.presentAlert(title: "复制失败", message: error.localizedDescription)
                        }
                    }
                    cont.resume(returning: nil)
                }
            }
        }
    }
}

private struct ImageTransitionUniform {
    var progress: Float
    var effectType: Int32
}

private final class MetalImageTransitionRenderer {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var cache: CVMetalTextureCache?

    init() throws {
        guard let d = MTLCreateSystemDefaultDevice(),
              let q = d.makeCommandQueue(),
              let lib = MetalDefaultLibraryCache.library(for: d) else {
            throw NSError(domain: "Slideshow", code: -100, userInfo: [NSLocalizedDescriptionKey: "Metal 初始化失败"])
        }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = lib.makeFunction(name: "vertex_passthrough")
        desc.fragmentFunction = lib.makeFunction(name: "fragment_image_transition")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let state = try? d.makeRenderPipelineState(descriptor: desc) else {
            throw NSError(domain: "Slideshow", code: -101, userInfo: [NSLocalizedDescriptionKey: "Metal 管线创建失败"])
        }
        device = d
        queue = q
        pipeline = state
        CVMetalTextureCacheCreate(nil, nil, d, nil, &cache)
    }

    func makeTexture(from image: UIImage, targetSize: CGSize) throws -> MTLTexture {
        let normalized = normalizeImageOrientation(image)
        guard normalized.cgImage != nil else {
            throw NSError(domain: "Slideshow", code: -102, userInfo: [NSLocalizedDescriptionKey: "图片读取失败"])
        }
        let rendered = try renderAspectFit(image: normalized, targetSize: targetSize)
        let loader = MTKTextureLoader(device: device)
        return try loader.newTexture(cgImage: rendered, options: [
            MTKTextureLoader.Option.SRGB: false,
            MTKTextureLoader.Option.textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
        ])
    }

    private func renderAspectFit(image: UIImage, targetSize: CGSize) throws -> CGImage {
        let width = Int(targetSize.width)
        let height = Int(targetSize.height)
        guard width > 0, height > 0 else {
            throw NSError(domain: "Slideshow", code: -103, userInfo: [NSLocalizedDescriptionKey: "无效输出尺寸"])
        }
        UIGraphicsBeginImageContextWithOptions(CGSize(width: width, height: height), true, 1.0)
        UIColor.black.setFill()
        UIRectFill(CGRect(x: 0, y: 0, width: width, height: height))
        let imageSize = image.size
        let imageRatio = imageSize.width / max(imageSize.height, 1)
        let targetRatio = CGFloat(width) / CGFloat(height)
        var drawRect = CGRect(x: 0, y: 0, width: width, height: height)
        if imageRatio > targetRatio {
            let h = CGFloat(width) / imageRatio
            drawRect = CGRect(x: 0, y: (CGFloat(height) - h) * 0.5, width: CGFloat(width), height: h)
        } else {
            let w = CGFloat(height) * imageRatio
            drawRect = CGRect(x: (CGFloat(width) - w) * 0.5, y: 0, width: w, height: CGFloat(height))
        }
        image.draw(in: drawRect)
        let out = UIGraphicsGetImageFromCurrentImageContext()?.cgImage
        UIGraphicsEndImageContext()
        guard let out else {
            throw NSError(domain: "Slideshow", code: -104, userInfo: [NSLocalizedDescriptionKey: "图片格式化失败"])
        }
        return out
    }

    private func normalizeImageOrientation(_ image: UIImage) -> UIImage {
        if image.imageOrientation == .up {
            return image
        }
        UIGraphicsBeginImageContextWithOptions(image.size, false, image.scale)
        image.draw(in: CGRect(origin: .zero, size: image.size))
        let normalized = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return normalized ?? image
    }

    func renderPixelBuffer(from fromTex: MTLTexture, to toTex: MTLTexture, progress: Float, effect: Int, pixelBuffer: CVPixelBuffer) throws {
        guard let cache else { throw NSError(domain: "Slideshow", code: -105, userInfo: [NSLocalizedDescriptionKey: "纹理缓存不可用"]) }
        var ref: CVMetalTexture?
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let result = CVMetalTextureCacheCreateTextureFromImage(nil, cache, pixelBuffer, nil, .bgra8Unorm, width, height, 0, &ref)
        guard result == kCVReturnSuccess, let ref, let target = CVMetalTextureGetTexture(ref) else {
            throw NSError(domain: "Slideshow", code: -106, userInfo: [NSLocalizedDescriptionKey: "目标纹理创建失败"])
        }
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].storeAction = .store
        rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        guard let cb = queue.makeCommandBuffer(), let enc = cb.makeRenderCommandEncoder(descriptor: rp) else {
            throw NSError(domain: "Slideshow", code: -107, userInfo: [NSLocalizedDescriptionKey: "Metal 编码失败"])
        }
        var scale = SIMD2<Float>(1, 1)
        var uniforms = ImageTransitionUniform(progress: progress, effectType: Int32(effect))
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBytes(&scale, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
        enc.setFragmentTexture(fromTex, index: 0)
        enc.setFragmentTexture(toTex, index: 1)
        enc.setFragmentBytes(&uniforms, length: MemoryLayout<ImageTransitionUniform>.stride, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
    }
}

private final class SlideshowMetalExporter {
    private let defaultFPS: Int32 = 30
    private let slideLeftFPS: Int32 = 60
    /// 防止以音频为准时帧数过大导致内存/时间过长（与 SwiftUI 版策略一致，可按需调高）。
    private static let maxRenderDurationSeconds: Double = 600

    func export(
        imageURLs: [URL],
        audioSourceURL: URL,
        durationMode: DurationBaseMode,
        interval: Double,
        transition: TransitionEffect,
        outputStem: String
    ) async throws -> URL {
        guard !imageURLs.isEmpty else {
            throw NSError(domain: "Slideshow", code: -1, userInfo: [NSLocalizedDescriptionKey: "至少需要 1 张图片"])
        }
        let images = imageURLs.compactMap { UIImage(contentsOfFile: $0.path) }
        guard !images.isEmpty else {
            throw NSError(domain: "Slideshow", code: -2, userInfo: [NSLocalizedDescriptionKey: "图片读取失败"])
        }

        let audioAsset = AVURLAsset(url: audioSourceURL)
        let audioTracks = try await audioAsset.loadTracks(withMediaType: .audio)
        guard let audioTrack = audioTracks.first else {
            throw NSError(domain: "Slideshow", code: -3, userInfo: [NSLocalizedDescriptionKey: "音频源内没有可用音轨"])
        }
        let audioDuration = try await audioAsset.load(.duration)
        guard audioDuration.isValid, !audioDuration.isIndefinite, CMTimeCompare(audioDuration, .zero) > 0 else {
            throw NSError(domain: "Slideshow", code: -4, userInfo: [NSLocalizedDescriptionKey: "音频时长无效"])
        }

        let outputSize = normalizedOutputSize(from: images.first)
        let imageDuration = Double(images.count) * interval
        let renderDurationSeconds = (durationMode == .images) ? imageDuration : audioDuration.seconds
        let renderDuration = CMTime(seconds: renderDurationSeconds, preferredTimescale: 600)
        if renderDurationSeconds <= 0 {
            throw NSError(domain: "Slideshow", code: -5, userInfo: [NSLocalizedDescriptionKey: "时长计算失败"])
        }
        if renderDurationSeconds > Self.maxRenderDurationSeconds {
            let cap = Int(Self.maxRenderDurationSeconds / 60)
            throw NSError(
                domain: "Slideshow",
                code: -20,
                userInfo: [NSLocalizedDescriptionKey: "目标时长超过 \(cap) 分钟上限，请换较短音频或增加图片张数后改用「以图片为准」。"]
            )
        }

        let tempSilentURL = FileManager.default.temporaryDirectory.appendingPathComponent("metal_slideshow_silent_\(UUID().uuidString).mov")
        let renderer = try MetalImageTransitionRenderer()
        let textures = try images.map { try renderer.makeTexture(from: $0, targetSize: outputSize) }
        try renderSilentVideo(textures: textures, renderer: renderer, outputSize: outputSize, duration: renderDurationSeconds, interval: interval, mode: durationMode, transition: transition, to: tempSilentURL)

        let outURL = try documentsDirectory().appendingPathComponent("\(outputStem).mov")
        if FileManager.default.fileExists(atPath: outURL.path) {
            throw NSError(domain: "Slideshow", code: -6, userInfo: [NSLocalizedDescriptionKey: "已存在同名文件：\(outURL.lastPathComponent)"])
        }

        let silentAsset = AVURLAsset(url: tempSilentURL)
        try await mergeAudio(with: silentAsset, audioAsset: audioAsset, audioTrack: audioTrack, mode: durationMode, outputURL: outURL)
        try? FileManager.default.removeItem(at: tempSilentURL)
        return outURL
    }

    private func renderSilentVideo(
        textures: [MTLTexture],
        renderer: MetalImageTransitionRenderer,
        outputSize: CGSize,
        duration: Double,
        interval: Double,
        mode: DurationBaseMode,
        transition: TransitionEffect,
        to outputURL: URL
    ) throws {
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let fps: Int32 = (transition == .slideLeft) ? slideLeftFPS : defaultFPS
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(outputSize.width),
            AVVideoHeightKey: Int(outputSize.height),
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: Int(outputSize.width),
            kCVPixelBufferHeightKey as String: Int(outputSize.height),
        ])
        guard writer.canAdd(input) else {
            throw NSError(domain: "Slideshow", code: -7, userInfo: [NSLocalizedDescriptionKey: "无法添加视频写入输入"])
        }
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let totalFrames = max(1, Int(ceil(duration * Double(fps))))
        let transitionDuration = (transition == .none) ? 0.0 : min(max(interval * 0.35, 0.15), min(interval * 0.8, 0.8))
        let transitionStart = max(0.0, interval - transitionDuration)
        let lastIndex = textures.count - 1
        let frameDuration = CMTime(value: 1, timescale: fps)
        var frameTime = CMTime.zero

        for frame in 0..<totalFrames {
            while !input.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.002)
            }
            guard let pixelBufferPool = adaptor.pixelBufferPool else {
                throw NSError(domain: "Slideshow", code: -16, userInfo: [NSLocalizedDescriptionKey: "像素缓冲池不可用"])
            }
            var maybeBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pixelBufferPool, &maybeBuffer)
            guard let pixelBuffer = maybeBuffer else {
                throw NSError(domain: "Slideshow", code: -17, userInfo: [NSLocalizedDescriptionKey: "像素缓冲创建失败"])
            }

            let t = Double(frame) / Double(fps)
            let slot = Int(floor(t / interval))
            let local = t - (Double(slot) * interval)

            let currentIndex: Int
            if mode == .images {
                currentIndex = min(slot, lastIndex)
            } else {
                currentIndex = slot % textures.count
            }
            let nextIndex: Int = {
                if mode == .images {
                    return min(currentIndex + 1, lastIndex)
                }
                return (currentIndex + 1) % textures.count
            }()

            let progress: Float
            if transitionDuration > 0, local >= transitionStart, nextIndex != currentIndex {
                progress = Float((local - transitionStart) / transitionDuration)
            } else {
                progress = 0
            }

            try renderer.renderPixelBuffer(
                from: textures[currentIndex],
                to: textures[nextIndex],
                progress: min(max(progress, 0), 1),
                effect: transition.rawValue,
                pixelBuffer: pixelBuffer
            )
            _ = adaptor.append(pixelBuffer, withPresentationTime: frameTime)
            frameTime = CMTimeAdd(frameTime, frameDuration)
        }

        input.markAsFinished()
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        semaphore.wait()
        if writer.status != .completed {
            throw writer.error ?? NSError(domain: "Slideshow", code: -8, userInfo: [NSLocalizedDescriptionKey: "视频写入失败"])
        }
    }

    private func mergeAudio(
        with silentVideoAsset: AVURLAsset,
        audioAsset: AVURLAsset,
        audioTrack: AVAssetTrack,
        mode: DurationBaseMode,
        outputURL: URL
    ) async throws {
        let videoDuration = try await silentVideoAsset.load(.duration)
        let audioDuration = try await audioAsset.load(.duration)
        let videoTracks = try await silentVideoAsset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else {
            throw NSError(domain: "Slideshow", code: -9, userInfo: [NSLocalizedDescriptionKey: "临时视频无视频轨"])
        }

        let composition = AVMutableComposition()
        guard let compVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let compAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw NSError(domain: "Slideshow", code: -10, userInfo: [NSLocalizedDescriptionKey: "合成轨创建失败"])
        }

        let vRange = CMTimeRange(start: .zero, duration: videoDuration)
        try compVideo.insertTimeRange(vRange, of: videoTrack, at: .zero)
        compVideo.preferredTransform = try await videoTrack.load(.preferredTransform)

        if mode == .images {
            var insertAt = CMTime.zero
            while CMTimeCompare(insertAt, videoDuration) < 0 {
                let remain = CMTimeSubtract(videoDuration, insertAt)
                let chunk = CMTimeMinimum(remain, audioDuration)
                try compAudio.insertTimeRange(CMTimeRange(start: .zero, duration: chunk), of: audioTrack, at: insertAt)
                insertAt = CMTimeAdd(insertAt, chunk)
            }
        } else {
            let chunk = CMTimeMinimum(videoDuration, audioDuration)
            try compAudio.insertTimeRange(CMTimeRange(start: .zero, duration: chunk), of: audioTrack, at: .zero)
        }

        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw NSError(domain: "Slideshow", code: -11, userInfo: [NSLocalizedDescriptionKey: "无法创建导出会话"])
        }
        exporter.outputURL = outputURL
        exporter.outputFileType = .mov
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            exporter.exportAsynchronously {
                switch exporter.status {
                case .completed: cont.resume()
                case .failed: cont.resume(throwing: exporter.error ?? NSError(domain: "Slideshow", code: -12, userInfo: [NSLocalizedDescriptionKey: "导出失败"]))
                case .cancelled: cont.resume(throwing: NSError(domain: "Slideshow", code: -13, userInfo: [NSLocalizedDescriptionKey: "导出取消"]))
                default: cont.resume(throwing: NSError(domain: "Slideshow", code: -14, userInfo: [NSLocalizedDescriptionKey: "导出状态异常"]))
                }
            }
        }
    }

    private func normalizedOutputSize(from first: UIImage?) -> CGSize {
        guard let first else { return CGSize(width: 1280, height: 720) }
        let base = first.size
        let maxEdge: CGFloat = 1280
        var w = base.width
        var h = base.height
        if w <= 0 || h <= 0 { return CGSize(width: 1280, height: 720) }
        let ratio = min(1.0, maxEdge / max(w, h))
        w *= ratio
        h *= ratio
        let evenW = max(2, Int(w) / 2 * 2)
        let evenH = max(2, Int(h) / 2 * 2)
        return CGSize(width: evenW, height: evenH)
    }

    private func documentsDirectory() throws -> URL {
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw NSError(domain: "Slideshow", code: -15, userInfo: [NSLocalizedDescriptionKey: "无法获取文稿目录"])
        }
        return dir
    }
}
