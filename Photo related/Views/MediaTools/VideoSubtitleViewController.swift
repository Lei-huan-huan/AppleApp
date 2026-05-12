//
//  VideoSubtitleViewController.swift
//  Photo related
//
//  语音识别生成字幕、叠加预览与导出；可选识别语言；双行字幕 + 系统 Translation 翻译行。
//

import AVFoundation
import AVKit
import CoreText
import PhotosUI
import Speech
import Translation
import UIKit

private struct SpeechSubtitleSegment {
    let text: String
    var translatedText: String?
    let start: TimeInterval
    let duration: TimeInterval

    var end: TimeInterval { start + duration }
}

/// 导出与合成逻辑放在非隔离上下文中，避免在 `Task.detached` 里误占主线程。
private enum SubtitleVideoExport {
    nonisolated static func makeExportURL() -> URL {
        let name = "subtitle_\(Int(Date().timeIntervalSince1970)).mp4"
        return FileManager.default.temporaryDirectory.appendingPathComponent(name)
    }

    nonisolated static func makeVideoComposition(
        asset: AVAsset,
        duration: CMTime,
        subtitles: [SpeechSubtitleSegment],
        dualLine: Bool
    ) async throws -> AVVideoComposition {
        guard try await asset.loadTracks(withMediaType: .video).first != nil else {
            throw NSError(domain: "subtitle", code: -4)
        }

        let composition = AVMutableVideoComposition(propertiesOf: asset)
        composition.frameDuration = CMTime(value: 1, timescale: 30)
        let renderSize = composition.renderSize

        let parentLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: renderSize)
        let videoLayer = CALayer()
        videoLayer.frame = parentLayer.frame
        parentLayer.addSublayer(videoLayer)

        let safeSubtitles = subtitles.filter { $0.start < duration.seconds && $0.end > 0 }
        let fontSize = max(22, renderSize.height * 0.04)
        let bottomPadding = max(16, renderSize.height * 0.045)
        // 与视频像素对齐，避免依赖 UIScreen；导出线程安全
        let contentsScale = max(2.0, min(3.0, renderSize.width / 640.0))

        for segment in safeSubtitles {
            let primary = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !primary.isEmpty else { continue }

            let translation = segment.translatedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let useDual = dualLine && !translation.isEmpty

            // 预览用 UILabel；导出管线里 CATextLayer 必须用 CTFont / 属性串描述字体。
            // 直接赋 UIFont 给 layer.font 在 AVCoreAnimation 离屏渲染时常表现为「只有半透明底、没有字」。
            let displayText: String
            let exportFont: UIFont
            if useDual {
                displayText = "\(primary)\n\(translation)"
                let dualSize = max(18.0, fontSize * 0.94)
                exportFont = UIFont.systemFont(ofSize: dualSize, weight: .semibold)
            } else {
                displayText = "  \(primary)  "
                exportFont = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
            }

            let subtitleFrame = subtitleExportFrame(
                for: displayText,
                renderSize: renderSize,
                font: exportFont,
                bottomPadding: bottomPadding
            )

            let layer = CATextLayer()
            layer.frame = subtitleFrame
            layer.alignmentMode = .center
            layer.backgroundColor = UIColor.black.withAlphaComponent(0.35).cgColor
            layer.cornerRadius = 8
            layer.masksToBounds = true
            layer.isWrapped = true
            layer.contentsScale = contentsScale
            layer.opacity = 0

            let ctFont = Self.ctFontForExport(from: exportFont)
            let attrs: [NSAttributedString.Key: Any] = [
                kCTFontAttributeName as NSAttributedString.Key: ctFont,
                kCTForegroundColorAttributeName as NSAttributedString.Key: UIColor.white.cgColor,
            ]
            layer.string = NSAttributedString(string: displayText, attributes: attrs)

            let appearAt = max(0, min(duration.seconds, segment.start))
            let disappearAt = max(appearAt + 0.05, min(duration.seconds, segment.end))

            let opacityAnimation = CAKeyframeAnimation(keyPath: "opacity")
            opacityAnimation.values = [0, 1, 1, 0]
            opacityAnimation.keyTimes = [0, 0.02, 0.98, 1]
            opacityAnimation.duration = disappearAt - appearAt
            opacityAnimation.beginTime = AVCoreAnimationBeginTimeAtZero + appearAt
            opacityAnimation.isRemovedOnCompletion = false
            opacityAnimation.fillMode = .forwards
            layer.add(opacityAnimation, forKey: "subtitleOpacity")

            parentLayer.addSublayer(layer)
        }

        composition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer,
            in: parentLayer
        )
        return composition
    }

    /// 供导出用：`CTFont` + 属性串；若 PostScript 名在合成线程不可用则回退到系统中文/西文字体。
    nonisolated private static func ctFontForExport(from uiFont: UIFont) -> CTFont {
        let ps = uiFont.fontName as CFString
        if CGFont(ps) != nil {
            return CTFontCreateWithName(ps, uiFont.pointSize, nil)
        }
        let traits = uiFont.fontDescriptor.fontAttributes[.traits] as? [UIFontDescriptor.TraitKey: Any]
        let weightVal = traits?[.weight] as? CGFloat ?? UIFont.Weight.regular.rawValue
        let heavy = weightVal >= UIFont.Weight.semibold.rawValue
            || uiFont.fontDescriptor.symbolicTraits.contains(.traitBold)
        let zh = heavy ? "PingFangSC-Semibold" : "PingFangSC-Regular"
        if CGFont(zh as CFString) != nil {
            return CTFontCreateWithName(zh as CFString, uiFont.pointSize, nil)
        }
        let latin = heavy ? "Helvetica-Bold" : "Helvetica"
        return CTFontCreateWithName(latin as CFString, uiFont.pointSize, nil)
    }

    /// 与 IosTest1 `subtitleFrame` 同源逻辑：底部原点坐标系；放宽行数与高度上限，减少「显示不全」。
    nonisolated private static func subtitleExportFrame(
        for text: String,
        renderSize: CGSize,
        font: UIFont,
        bottomPadding: CGFloat
    ) -> CGRect {
        let maxWidth = renderSize.width * 0.9
        let minWidth = renderSize.width * 0.32
        let horizontalPadding: CGFloat = 24
        let verticalPadding: CGFloat = 10
        let innerW = maxWidth - horizontalPadding * 2

        let measureH: CGFloat = 20_000
        let textBounding = (text as NSString).boundingRect(
            with: CGSize(width: innerW, height: measureH),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil
        )

        let width = min(max(minWidth, ceil(textBounding.width) + horizontalPadding * 2), maxWidth)
        let naturalTextH = ceil(textBounding.height)
        let minHeight = font.lineHeight + verticalPadding * 2
        let maxSubtitleH = min(renderSize.height * 0.48, font.lineHeight * 14 + verticalPadding * 2)
        let height = min(max(minHeight, naturalTextH + verticalPadding * 2), maxSubtitleH)

        let x = (renderSize.width - width) * 0.5
        let y = bottomPadding
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

final class VideoSubtitleViewController: UIViewController {
    private let pickButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        var cfg = UIButton.Configuration.filled()
        cfg.title = "视频"
        cfg.buttonSize = .small
        button.configuration = cfg
        button.accessibilityLabel = "选择视频"
        return button
    }()

    private let languageButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        var cfg = UIButton.Configuration.bordered()
        cfg.title = "语音"
        cfg.buttonSize = .small
        button.configuration = cfg
        button.accessibilityLabel = "识别语言"
        return button
    }()

    private let subtitleModeSegment: UISegmentedControl = {
        let control = UISegmentedControl(items: ["单行", "双行"])
        control.translatesAutoresizingMaskIntoConstraints = false
        control.selectedSegmentIndex = 0
        return control
    }()

    private let translationLanguageButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        var cfg = UIButton.Configuration.bordered()
        cfg.title = "译文"
        cfg.buttonSize = .small
        button.configuration = cfg
        button.accessibilityLabel = "译文字幕语言"
        return button
    }()

    private let recognizeButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        var cfg = UIButton.Configuration.borderedProminent()
        cfg.title = "识别字幕"
        cfg.buttonSize = .small
        button.configuration = cfg
        button.isEnabled = false
        return button
    }()

    private let exportButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        var cfg = UIButton.Configuration.bordered()
        cfg.title = "导出视频"
        cfg.buttonSize = .small
        button.configuration = cfg
        button.isEnabled = false
        return button
    }()

    private let statusLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "请点「视频」选择文件"
        label.numberOfLines = 2
        label.textAlignment = .center
        label.textColor = .secondaryLabel
        label.font = .preferredFont(forTextStyle: .caption1)
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.85
        return label
    }()

    private let playerHostView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .black
        view.layer.cornerRadius = 12
        view.clipsToBounds = true
        return view
    }()

    private let subtitlePrimaryLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textColor = .white
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 26, weight: .semibold)
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return label
    }()

    private let subtitleTranslationLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textColor = UIColor.white.withAlphaComponent(0.92)
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 20, weight: .regular)
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return label
    }()

    private lazy var subtitleStack: UIStackView = {
        let stack = UIStackView(arrangedSubviews: [subtitlePrimaryLabel, subtitleTranslationLabel])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .fill
        stack.distribution = .fill
        stack.spacing = 8
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 12, left: 16, bottom: 14, right: 16)
        stack.backgroundColor = UIColor.black.withAlphaComponent(0.50)
        stack.layer.cornerRadius = 10
        stack.layer.masksToBounds = true
        stack.setContentCompressionResistancePriority(.required, for: .vertical)
        stack.isHidden = true
        return stack
    }()

    private var didInstallSubtitleOverlay = false

    private let placeholderLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "未选择视频"
        label.textColor = .white.withAlphaComponent(0.9)
        label.font = .preferredFont(forTextStyle: .headline)
        return label
    }()

    private let activityIndicator = UIActivityIndicatorView(style: .large)

    private let playerController = AVPlayerViewController()
    private var currentPlayer: AVPlayer?
    private var currentVideoURL: URL?
    private var subtitleSegments: [SpeechSubtitleSegment] = []
    private var timeObserverToken: Any?

    private var selectedLocale: Locale = VideoSubtitleViewController.defaultRecognitionLocale()
    private var selectedTranslationLanguage: Locale.Language = VideoSubtitleViewController.defaultTranslationLanguage()

    private var translationTask: Task<Void, Never>?

    /// 底部紧凑操作区：减少占用高度，把空间留给视频。
    private lazy var compactBottomStack: UIStackView = {
        let pickLangRow = UIStackView(arrangedSubviews: [pickButton, languageButton])
        pickLangRow.axis = .horizontal
        pickLangRow.spacing = 8
        pickLangRow.distribution = .fillEqually

        let modeRow = UIStackView(arrangedSubviews: [subtitleModeSegment, translationLanguageButton])
        modeRow.axis = .horizontal
        modeRow.spacing = 8
        modeRow.alignment = .center
        modeRow.distribution = .fill
        subtitleModeSegment.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let actionsRow = UIStackView(arrangedSubviews: [recognizeButton, exportButton])
        actionsRow.axis = .horizontal
        actionsRow.spacing = 8
        actionsRow.distribution = .fillEqually

        let col = UIStackView(arrangedSubviews: [pickLangRow, modeRow, actionsRow, statusLabel])
        col.axis = .vertical
        col.spacing = 6
        col.translatesAutoresizingMaskIntoConstraints = false
        return col
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "视频字幕"
        view.backgroundColor = .systemBackground
        setupUI()
        refreshLanguageButtonTitle()
        configureLanguageMenu()
        refreshTranslationLanguageButtonTitle()
        configureTranslationLanguageMenu()
        updateTranslationRowVisibility()
        subtitleModeSegment.addTarget(self, action: #selector(subtitleModeChanged), for: .valueChanged)
    }

    deinit {
        translationTask?.cancel()
        removePlayerTimeObserver()
        currentPlayer?.pause()
        currentPlayer = nil
    }

    private static func defaultRecognitionLocale() -> Locale {
        let supported = SFSpeechRecognizer.supportedLocales()
        let ids = Set(supported.map(\.identifier))
        let preferred = ["zh-CN", "zh-Hans-CN", "zh-TW", "en-US", "en-GB", "ja-JP", "ko-KR", "fr-FR", "de-DE", "es-ES", "it-IT", "pt-BR", "ru-RU"]
        for id in preferred where ids.contains(id) {
            return Locale(identifier: id)
        }
        return supported.sorted { $0.identifier < $1.identifier }.first ?? Locale.current
    }

    /// 译文字幕默认：简体中文（汉语）
    private static func defaultTranslationLanguage() -> Locale.Language {
        Locale.Language(identifier: "zh-Hans")
    }

    private static let translationTargetLanguages: [Locale.Language] = [
        Locale.Language(identifier: "zh-Hans"),
        Locale.Language(identifier: "zh-Hant"),
        Locale.Language(identifier: "en"),
        Locale.Language(identifier: "ja"),
        Locale.Language(identifier: "ko"),
        Locale.Language(identifier: "fr"),
        Locale.Language(identifier: "de"),
        Locale.Language(identifier: "es"),
        Locale.Language(identifier: "ru"),
        Locale.Language(identifier: "pt-BR"),
        Locale.Language(identifier: "it"),
        Locale.Language(identifier: "ar"),
        Locale.Language(identifier: "th"),
        Locale.Language(identifier: "vi"),
        Locale.Language(identifier: "id"),
    ]

    private var isDualLineSubtitle: Bool { subtitleModeSegment.selectedSegmentIndex == 1 }

    private func configureLanguageMenu() {
        let locales = Array(SFSpeechRecognizer.supportedLocales()).sorted {
            languageMenuTitle(for: $0).localizedCaseInsensitiveCompare(languageMenuTitle(for: $1)) == .orderedAscending
        }
        languageButton.menu = UIMenu(
            title: "选择识别语言",
            children: locales.map { locale in
                let id = locale.identifier
                return UIAction(
                    title: languageMenuTitle(for: locale),
                    state: id == selectedLocale.identifier ? .on : .off
                ) { [weak self] _ in
                    self?.selectedLocale = locale
                    self?.refreshLanguageButtonTitle()
                    self?.configureLanguageMenu()
                }
            }
        )
        languageButton.showsMenuAsPrimaryAction = true
    }

    private func configureTranslationLanguageMenu() {
        let langs = Self.translationTargetLanguages
        translationLanguageButton.menu = UIMenu(
            title: "译文字幕语言",
            children: langs.map { lang in
                let id = lang.maximalIdentifier
                return UIAction(
                    title: translationMenuTitle(for: lang),
                    state: id == selectedTranslationLanguage.maximalIdentifier ? .on : .off
                ) { [weak self] _ in
                    guard let self else { return }
                    self.selectedTranslationLanguage = lang
                    self.refreshTranslationLanguageButtonTitle()
                    self.configureTranslationLanguageMenu()
                    if self.isDualLineSubtitle, !self.subtitleSegments.isEmpty {
                        self.scheduleTranslation()
                    }
                }
            }
        )
        translationLanguageButton.showsMenuAsPrimaryAction = true
    }

    private func translationMenuTitle(for language: Locale.Language) -> String {
        let id = language.maximalIdentifier
        let name = Locale.current.localizedString(forIdentifier: id) ?? id
        return "\(name) · \(id)"
    }

    private func languageMenuTitle(for locale: Locale) -> String {
        let name = Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
        return "\(name) · \(locale.identifier)"
    }

    private func refreshLanguageButtonTitle() {
        let id = selectedLocale.identifier
        var cfg = languageButton.configuration ?? .bordered()
        cfg.title = id
        cfg.buttonSize = .small
        languageButton.configuration = cfg
    }

    private func refreshTranslationLanguageButtonTitle() {
        let id = selectedTranslationLanguage.maximalIdentifier
        var cfg = translationLanguageButton.configuration ?? .bordered()
        cfg.title = id.count > 14 ? String(id.prefix(14)) + "…" : id
        cfg.buttonSize = .small
        translationLanguageButton.configuration = cfg
    }

    private func updateTranslationRowVisibility() {
        let dual = isDualLineSubtitle
        translationLanguageButton.isHidden = !dual
        if !dual {
            translationLanguageButton.isEnabled = false
        } else if !activityIndicator.isAnimating {
            translationLanguageButton.isEnabled = true
        }
    }

    @objc private func subtitleModeChanged() {
        updateTranslationRowVisibility()
        if isDualLineSubtitle, !subtitleSegments.isEmpty {
            scheduleTranslation()
        } else {
            translationTask?.cancel()
            translationTask = nil
            updateSubtitleForCurrentTime(currentPlayer?.currentTime().seconds ?? 0)
        }
    }

    @objc private func pickButtonTapped() {
        let sheet = UIAlertController(title: "选择视频来源", message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "相册", style: .default) { [weak self] _ in
            self?.presentPhotoPicker()
        })
        sheet.addAction(UIAlertAction(title: "文件", style: .default) { [weak self] _ in
            self?.presentDocumentPicker()
        })
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        if let pop = sheet.popoverPresentationController {
            pop.sourceView = pickButton
            pop.sourceRect = pickButton.bounds
        }
        present(sheet, animated: true)
    }

    @objc private func recognizeButtonTapped() {
        guard currentVideoURL != nil else { return }
        requestSpeechAuthorization { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.showLoadFailed("未获得语音识别权限，请在系统设置中开启。")
                return
            }
            guard let videoURL = self.currentVideoURL else { return }
            self.transcribeAudio(from: videoURL)
        }
    }

    @objc private func exportButtonTapped() {
        guard let sourceURL = currentVideoURL else { return }
        guard !subtitleSegments.isEmpty else { return }
        exportVideoWithSubtitles(
            sourceURL: sourceURL,
            subtitles: subtitleSegments,
            dualLine: isDualLineSubtitle
        )
    }

    private func setupUI() {
        pickButton.addTarget(self, action: #selector(pickButtonTapped), for: .touchUpInside)
        recognizeButton.addTarget(self, action: #selector(recognizeButtonTapped), for: .touchUpInside)
        exportButton.addTarget(self, action: #selector(exportButtonTapped), for: .touchUpInside)

        playerController.showsPlaybackControls = true
        playerController.view.translatesAutoresizingMaskIntoConstraints = false
        playerController.view.backgroundColor = .black

        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        activityIndicator.hidesWhenStopped = true

        addChild(playerController)
        playerHostView.addSubview(playerController.view)
        playerController.didMove(toParent: self)

        view.addSubview(playerHostView)
        view.addSubview(compactBottomStack)
        playerHostView.addSubview(placeholderLabel)
        view.addSubview(activityIndicator)

        NSLayoutConstraint.activate([
            playerHostView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
            playerHostView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            playerHostView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            playerHostView.bottomAnchor.constraint(equalTo: compactBottomStack.topAnchor, constant: -6),

            compactBottomStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            compactBottomStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            compactBottomStack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -4),

            pickButton.heightAnchor.constraint(equalToConstant: 34),
            languageButton.heightAnchor.constraint(equalToConstant: 34),
            subtitleModeSegment.heightAnchor.constraint(equalToConstant: 28),
            translationLanguageButton.heightAnchor.constraint(equalToConstant: 30),
            recognizeButton.heightAnchor.constraint(equalToConstant: 38),
            exportButton.heightAnchor.constraint(equalToConstant: 38),

            playerController.view.topAnchor.constraint(equalTo: playerHostView.topAnchor),
            playerController.view.leadingAnchor.constraint(equalTo: playerHostView.leadingAnchor),
            playerController.view.trailingAnchor.constraint(equalTo: playerHostView.trailingAnchor),
            playerController.view.bottomAnchor.constraint(equalTo: playerHostView.bottomAnchor),

            placeholderLabel.centerXAnchor.constraint(equalTo: playerHostView.centerXAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: playerHostView.centerYAnchor),

            activityIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: playerHostView.centerYAnchor),
        ])
    }

    private func presentPhotoPicker() {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .videos
        config.selectionLimit = 1
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }

    private func presentDocumentPicker() {
        let picker = VideoDocumentPickerSupport.makePicker(asCopy: true, allowsMultipleSelection: false)
        picker.delegate = self
        if let pop = picker.popoverPresentationController {
            pop.sourceView = pickButton
            pop.sourceRect = pickButton.bounds
        }
        present(picker, animated: true)
    }

    private func playVideo(with url: URL) {
        removePlayerTimeObserver()
        translationTask?.cancel()
        translationTask = nil
        subtitleSegments = []
        subtitleStack.isHidden = true
        exportButton.isEnabled = false
        statusLabel.text = "已加载。可选语音后点「识别字幕」"
        recognizeButton.isEnabled = true

        currentVideoURL = url
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        playerController.player = player
        currentPlayer = player
        placeholderLabel.isHidden = true

        setupSubtitleOverlayIfNeeded()
        addTimeObserver(for: player)
        player.play()
    }

    private func setupSubtitleOverlayIfNeeded() {
        guard let overlay = playerController.contentOverlayView else { return }
        guard !didInstallSubtitleOverlay else { return }
        didInstallSubtitleOverlay = true

        overlay.addSubview(subtitleStack)

        let maxH = subtitleStack.heightAnchor.constraint(lessThanOrEqualTo: overlay.heightAnchor, multiplier: 0.42)
        maxH.priority = .required

        NSLayoutConstraint.activate([
            subtitleStack.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            subtitleStack.leadingAnchor.constraint(equalTo: overlay.leadingAnchor, constant: 12),
            subtitleStack.trailingAnchor.constraint(equalTo: overlay.trailingAnchor, constant: -12),
            // 略高于原 -72，给双行留出净空，避免贴底被播放控件压住第二行
            subtitleStack.bottomAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.bottomAnchor, constant: -88),
            maxH,
        ])
    }

    private func addTimeObserver(for player: AVPlayer) {
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            self?.updateSubtitleForCurrentTime(time.seconds)
        }
    }

    private func removePlayerTimeObserver() {
        if let token = timeObserverToken, let player = currentPlayer {
            player.removeTimeObserver(token)
        }
        timeObserverToken = nil
    }

    private func updateSubtitleForCurrentTime(_ seconds: TimeInterval) {
        guard !subtitleSegments.isEmpty, seconds.isFinite else {
            subtitleStack.isHidden = true
            return
        }

        if let segment = subtitleSegments.first(where: { seconds >= $0.start && seconds < $0.end }) {
            subtitlePrimaryLabel.text = segment.text
            if isDualLineSubtitle, let t = segment.translatedText?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                subtitleTranslationLabel.text = t
                subtitleTranslationLabel.isHidden = false
            } else {
                subtitleTranslationLabel.text = nil
                subtitleTranslationLabel.isHidden = true
            }
            subtitleStack.isHidden = false
        } else {
            subtitleStack.isHidden = true
        }
    }

    private func requestSpeechAuthorization(_ completion: @escaping (Bool) -> Void) {
        let status = SFSpeechRecognizer.authorizationStatus()
        switch status {
        case .authorized:
            completion(true)
        case .notDetermined:
            SFSpeechRecognizer.requestAuthorization { newStatus in
                DispatchQueue.main.async { completion(newStatus == .authorized) }
            }
        default:
            completion(false)
        }
    }

    /// 语音识别用的 Locale 与 Translation 框架常用标识不完全一致（如 zh-CN vs zh-Hans），多候选可减少误报「未安装」。
    private func translationSourceLanguageCandidates() -> [Locale.Language] {
        let raw = selectedLocale.identifier.replacingOccurrences(of: "_", with: "-")
        var out: [Locale.Language] = []
        func add(_ id: String) {
            let lang = Locale.Language(identifier: id)
            if !out.contains(where: { $0.maximalIdentifier == lang.maximalIdentifier }) {
                out.append(lang)
            }
        }
        add(raw)
        let lower = raw.lowercased()
        if lower.hasPrefix("zh-hans") || lower == "zh-cn" {
            add("zh-Hans")
            add("zh-Hans-CN")
        } else if lower.hasPrefix("zh-hant") || lower == "zh-tw" || lower == "zh-hk" || lower == "zh-mo" {
            add("zh-Hant")
            add("zh-TW")
        } else if lower.hasPrefix("en") {
            add("en")
            add("en-US")
        } else if lower.hasPrefix("ja") {
            add("ja")
            add("ja-JP")
        } else if lower.hasPrefix("ko") {
            add("ko")
            add("ko-KR")
        }
        return out
    }

    private func transcribeAudio(from url: URL) {
        guard let recognizer = SFSpeechRecognizer(locale: selectedLocale) else {
            showLoadFailed("当前设备不支持所选语言的语音识别。")
            return
        }
        guard recognizer.isAvailable else {
            showLoadFailed("所选语言的语音识别暂不可用，请稍后重试或更换语言。")
            return
        }

        setBusy(true, message: "正在识别语音，请稍候…")
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let error {
                self.setBusy(false, message: "识别失败：\(error.localizedDescription)")
                return
            }
            guard let best = result?.bestTranscription else {
                self.setBusy(false, message: "未识别到有效语音。")
                return
            }
            let segments = best.segments.compactMap { seg -> SpeechSubtitleSegment? in
                let text = seg.substring.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                let start = max(0, TimeInterval(seg.timestamp))
                let duration = max(0.15, TimeInterval(seg.duration))
                return SpeechSubtitleSegment(text: text, translatedText: nil, start: start, duration: duration)
            }
            self.subtitleSegments = segments
            self.exportButton.isEnabled = !segments.isEmpty
            let baseMessage = segments.isEmpty ? "未识别到字幕内容。" : "识别完成：\(segments.count) 条字幕。"
            self.setBusy(false, message: baseMessage)
            if self.isDualLineSubtitle, !segments.isEmpty {
                self.scheduleTranslation()
            }
        }
    }

    private func scheduleTranslation() {
        translationTask?.cancel()
        translationTask = Task { @MainActor [weak self] in
            await self?.performTranslation()
        }
    }

    /// 使用系统 Translation 框架批量翻译（需已安装对应语言包）。
    private func performTranslation() async {
        guard !Task.isCancelled else { return }
        guard isDualLineSubtitle else { return }
        guard !subtitleSegments.isEmpty else { return }

        let target = selectedTranslationLanguage
        let sources = translationSourceLanguageCandidates()
        if shouldSkipTranslationAsSameLanguage(target: target) {
            subtitleSegments = subtitleSegments.map { s in
                SpeechSubtitleSegment(text: s.text, translatedText: s.text, start: s.start, duration: s.duration)
            }
            updateSubtitleForCurrentTime(currentPlayer?.currentTime().seconds ?? 0)
            return
        }

        setBusy(true, message: "正在翻译字幕…")
        let requests = subtitleSegments.map { TranslationSession.Request(sourceText: $0.text) }
        let availability = LanguageAvailability()
        var lastError: Error?

        for source in sources {
            guard !Task.isCancelled else { return }
            let pairStatus = await availability.status(from: source, to: target)
            if pairStatus == .unsupported { continue }

            do {
                let session = try TranslationSession(installedSource: source, target: target)
                if await !session.isReady {
                    try await session.prepareTranslation()
                }
                if await !session.isReady {
                    continue
                }
                let responses = try await session.translations(from: requests)
                guard !Task.isCancelled else { return }

                var next: [SpeechSubtitleSegment] = []
                for (index, seg) in subtitleSegments.enumerated() {
                    let translated: String?
                    if index < responses.count {
                        translated = responses[index].targetText
                    } else {
                        translated = nil
                    }
                    next.append(SpeechSubtitleSegment(
                        text: seg.text,
                        translatedText: translated,
                        start: seg.start,
                        duration: seg.duration
                    ))
                }
                subtitleSegments = next
                updateSubtitleForCurrentTime(currentPlayer?.currentTime().seconds ?? 0)
                setBusy(false, message: "翻译完成，共 \(next.count) 条译文字幕。")
                return
            } catch {
                lastError = error
                continue
            }
        }

        guard !Task.isCancelled else { return }
        let hint = translationFailureHint(from: lastError)
        setBusy(false, message: "翻译未完成。\(hint)")
    }

    private func translationFailureHint(from error: Error?) -> String {
        guard let error else {
            return "可稍后重试，或更换「识别语言 / 译文字幕语言」后再试。"
        }
        if TranslationError.notInstalled ~= error {
            return "若已下载语言包，可尝试更换识别语言或译文字幕语言组合后重试。"
        }
        if TranslationError.unsupportedLanguagePairing ~= error || TranslationError.unsupportedSourceLanguage ~= error {
            return "当前语言对在系统翻译中不可用，请更换译文字幕语言后重试。"
        }
        return "\(error.localizedDescription) 可稍后重试或更换语言组合。"
    }

    /// 识别语与译言实质相同则跳过翻译（避免 zh-CN / zh-Hans 等被当成不同语对）。
    private func shouldSkipTranslationAsSameLanguage(target: Locale.Language) -> Bool {
        let tId = target.maximalIdentifier.lowercased()
        for s in translationSourceLanguageCandidates() {
            if s.maximalIdentifier.lowercased() == tId { return true }
        }
        let speech = selectedLocale.identifier.lowercased().replacingOccurrences(of: "_", with: "-")
        let zhHansFamily = speech.contains("zh-hans") || speech == "zh-cn" || speech.hasPrefix("zh-cn")
        let zhHantFamily = speech.contains("zh-hant") || speech == "zh-tw" || speech == "zh-hk" || speech == "zh-mo"
        if zhHansFamily && (tId.contains("zh-hans") || tId.contains("zh-cn")) { return true }
        if zhHantFamily && (tId.contains("zh-hant") || tId.contains("zh-tw") || tId.contains("zh-hk")) { return true }
        return false
    }

    private func exportVideoWithSubtitles(sourceURL: URL, subtitles: [SpeechSubtitleSegment], dualLine: Bool) {
        setBusy(true, message: "正在导出带字幕视频…")
        let asset = AVURLAsset(url: sourceURL)

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let duration = try await asset.load(.duration)
                guard duration.seconds > 0 else { throw NSError(domain: "subtitle", code: -1) }

                guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
                    throw NSError(domain: "subtitle", code: -2)
                }

                let outputURL = SubtitleVideoExport.makeExportURL()
                try? FileManager.default.removeItem(at: outputURL)
                export.outputURL = outputURL
                export.outputFileType = .mp4
                export.shouldOptimizeForNetworkUse = true
                export.videoComposition = try await SubtitleVideoExport.makeVideoComposition(
                    asset: asset,
                    duration: duration,
                    subtitles: subtitles,
                    dualLine: dualLine
                )

                await withCheckedContinuation { continuation in
                    export.exportAsynchronously {
                        continuation.resume()
                    }
                }

                if export.status == .completed {
                    await MainActor.run {
                        self.setBusy(false, message: "导出成功：\(outputURL.lastPathComponent)")
                        self.presentExportDone(url: outputURL)
                    }
                } else {
                    throw export.error ?? NSError(domain: "subtitle", code: -3)
                }
            } catch {
                await MainActor.run {
                    self.setBusy(false, message: "导出失败：\(error.localizedDescription)")
                }
            }
        }
    }

    private func setBusy(_ busy: Bool, message: String) {
        DispatchQueue.main.async {
            self.statusLabel.text = message
            self.pickButton.isEnabled = !busy
            self.languageButton.isEnabled = !busy
            self.subtitleModeSegment.isEnabled = !busy
            self.translationLanguageButton.isEnabled = !busy && self.isDualLineSubtitle
            self.recognizeButton.isEnabled = !busy && self.currentVideoURL != nil
            self.exportButton.isEnabled = !busy && !self.subtitleSegments.isEmpty
            busy ? self.activityIndicator.startAnimating() : self.activityIndicator.stopAnimating()
        }
    }

    private func presentExportDone(url: URL) {
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let pop = sheet.popoverPresentationController {
            pop.sourceView = exportButton
            pop.sourceRect = exportButton.bounds
        }
        present(sheet, animated: true)
    }
}

extension VideoSubtitleViewController: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider else { return }
        provider.loadFileRepresentation(forTypeIdentifier: "public.movie") { [weak self] url, _ in
            guard let self, let sourceURL = url else { return }
            let fileName = sourceURL.lastPathComponent.isEmpty ? "picked_\(UUID().uuidString).mov" : sourceURL.lastPathComponent
            let destURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
            try? FileManager.default.removeItem(at: destURL)
            do {
                try FileManager.default.copyItem(at: sourceURL, to: destURL)
                DispatchQueue.main.async { self.playVideo(with: destURL) }
            } catch {
                DispatchQueue.main.async { self.showLoadFailed(error.localizedDescription) }
            }
        }
    }
}

extension VideoSubtitleViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let sourceURL = urls.first else { return }
        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }

        let fileName = sourceURL.lastPathComponent.isEmpty ? "picked_\(UUID().uuidString).mov" : sourceURL.lastPathComponent
        let destURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        do {
            try? FileManager.default.removeItem(at: destURL)
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
            playVideo(with: destURL)
        } catch {
            showLoadFailed(error.localizedDescription)
        }
    }
}

private extension VideoSubtitleViewController {
    func showLoadFailed(_ message: String) {
        let alert = UIAlertController(title: "处理失败", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }

}
