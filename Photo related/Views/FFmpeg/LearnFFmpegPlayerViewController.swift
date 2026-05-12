//
//  LearnFFmpegPlayerViewController.swift
//  Photo related
//
//  FFmpeg 播放器页面。
//

import AVFoundation
import MetalKit
import PhotosUI
import UIKit

private enum LearnPlayStatus {
    case idle, preparing, playing, paused, completed, error
}

private enum LFFStrings {
    static let title = "FFmpeg 播放器"
    static let hintURL = "粘贴或输入播放地址"
    static let pickFile = "从相册选择"
    static let play = "播放"
    static let stop = "停止"
    static let dash = "—"

    static func statusText(_ s: LearnPlayStatus, error: String?) -> String {
        switch s {
        case .idle: return "未播放"
        case .preparing: return "准备中"
        case .playing: return "正在播放"
        case .paused: return "已暂停"
        case .completed: return "播放完成"
        case .error: return error ?? "播放失败"
        }
    }
}

private enum LFFColors {
    static let brandPrimary = UIColor(red: 0x6D / 255, green: 0x5D / 255, blue: 0xE7 / 255, alpha: 1)
    static let brandPrimarySoft = UIColor(red: 0x6D / 255, green: 0x5D / 255, blue: 0xE7 / 255, alpha: 0.10)
    static let pageBackground = UIColor.systemGroupedBackground
    static let surface = UIColor.secondarySystemGroupedBackground
    static let border = UIColor.separator.withAlphaComponent(0.4)
    static let playerBackground = UIColor(red: 0x0F / 255, green: 0x0E / 255, blue: 0x1A / 255, alpha: 1)
    static let textPrimary = UIColor.label
    static let textSecondary = UIColor.secondaryLabel
    static let statusIdle = UIColor.systemGray
    static let statusPlaying = UIColor.systemGreen
    static let statusPreparing = UIColor.systemOrange
    static let statusError = UIColor.systemRed
}

private let kLearnFFmpegLastURLKey = "LearnFFmpegLastPlayURL"

final class LearnFFmpegPlayerViewController: UIViewController, FFmpegDemuxerPlayerDelegate, UITextFieldDelegate, PHPickerViewControllerDelegate {
    private var ffmpegPlayer: FFmpegDemuxerPlayer?

    private var status: LearnPlayStatus = .idle {
        didSet { renderStatus() }
    }

    private var errorMessage: String?
    private var videoW = 0
    private var videoH = 0
    private var durationMs: Int64 = 0

    private let urlField = UITextField()
    private let pickFileButton = UIButton(type: .system)
    private let playButton = UIButton(type: .system)
    private let stopButton = UIButton(type: .system)
    private let statusDot = UIView()
    private let statusLabel = UILabel()
    private let metaLabel = UILabel()
    private let playerCard = UIView()
    private let metalView = LearnFFmpegMetalPreviewView(frame: .zero)
    private let playerPlaceholder = UIView()
    private let playerPlaceholderIcon = UIImageView()

    private var observers: [NSObjectProtocol] = []

    private let controlHeight: CGFloat = 48

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = LFFColors.pageBackground
        configureNavigationBar()
        setupControls()
        setupHierarchy()
        bindAppLifecycle()
        renderStatus()
    }

    private func setupControls() {
        urlField.borderStyle = .none
        urlField.placeholder = LFFStrings.hintURL
        urlField.text = UserDefaults.standard.string(forKey: kLearnFFmpegLastURLKey) ?? ""
        urlField.autocapitalizationType = .none
        urlField.autocorrectionType = .no
        urlField.keyboardType = .URL
        urlField.returnKeyType = .done
        urlField.font = .systemFont(ofSize: 15)
        urlField.delegate = self
        urlField.translatesAutoresizingMaskIntoConstraints = false
        urlField.backgroundColor = LFFColors.surface
        urlField.textColor = LFFColors.textPrimary
        urlField.tintColor = LFFColors.brandPrimary
        urlField.layer.cornerRadius = 12
        urlField.layer.borderWidth = 0
        urlField.clipsToBounds = true
        let linkIconHost = UIView(frame: CGRect(x: 0, y: 0, width: 36, height: controlHeight))
        let linkIcon = UIImageView(image: UIImage(systemName: "link"))
        linkIcon.tintColor = LFFColors.textSecondary
        linkIcon.frame = CGRect(x: 12, y: (controlHeight - 18) / 2, width: 18, height: 18)
        linkIcon.contentMode = .scaleAspectFit
        linkIconHost.addSubview(linkIcon)
        urlField.leftView = linkIconHost
        urlField.leftViewMode = .always
        urlField.rightView = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: controlHeight))
        urlField.rightViewMode = .always

        var pickCfg = UIButton.Configuration.tinted()
        pickCfg.title = LFFStrings.pickFile
        pickCfg.image = UIImage(systemName: "photo.on.rectangle")
        pickCfg.imagePadding = 6
        pickCfg.baseForegroundColor = LFFColors.brandPrimary
        pickCfg.baseBackgroundColor = LFFColors.brandPrimary
        pickCfg.cornerStyle = .medium
        pickCfg.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 14)
        pickCfg.attributedTitle = AttributedString(LFFStrings.pickFile, attributes: AttributeContainer([
            .font: UIFont.systemFont(ofSize: 14, weight: .semibold)
        ]))
        pickFileButton.configuration = pickCfg
        pickFileButton.addTarget(self, action: #selector(tapPickFile), for: .touchUpInside)

        var playCfg = UIButton.Configuration.filled()
        playCfg.title = LFFStrings.play
        playCfg.image = UIImage(systemName: "play.fill")
        playCfg.imagePadding = 6
        playCfg.baseBackgroundColor = LFFColors.brandPrimary
        playCfg.baseForegroundColor = .white
        playCfg.cornerStyle = .medium
        playCfg.attributedTitle = AttributedString(LFFStrings.play, attributes: AttributeContainer([
            .font: UIFont.systemFont(ofSize: 16, weight: .semibold)
        ]))
        playButton.configuration = playCfg
        playButton.addTarget(self, action: #selector(tapPlay), for: .touchUpInside)

        var stopCfg = UIButton.Configuration.gray()
        stopCfg.title = LFFStrings.stop
        stopCfg.image = UIImage(systemName: "stop.fill")
        stopCfg.imagePadding = 6
        stopCfg.baseForegroundColor = LFFColors.textPrimary
        stopCfg.cornerStyle = .medium
        stopCfg.attributedTitle = AttributedString(LFFStrings.stop, attributes: AttributeContainer([
            .font: UIFont.systemFont(ofSize: 16, weight: .semibold)
        ]))
        stopButton.configuration = stopCfg
        stopButton.addTarget(self, action: #selector(tapStop), for: .touchUpInside)

        statusDot.layer.cornerRadius = 4
        statusDot.clipsToBounds = true
        statusLabel.font = .systemFont(ofSize: 14, weight: .medium)
        statusLabel.textColor = LFFColors.textPrimary
        statusLabel.numberOfLines = 0
        statusLabel.lineBreakMode = .byWordWrapping

        metaLabel.font = .systemFont(ofSize: 13, weight: .regular)
        metaLabel.textColor = LFFColors.textSecondary
        metaLabel.textAlignment = .right
        metaLabel.numberOfLines = 1
        metaLabel.text = ""

        playerCard.backgroundColor = LFFColors.playerBackground
        playerCard.clipsToBounds = true
        playerCard.layer.cornerRadius = 18

        metalView.translatesAutoresizingMaskIntoConstraints = false
        metalView.isOpaque = true
        metalView.backgroundColor = LFFColors.playerBackground

        playerPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        playerPlaceholder.backgroundColor = LFFColors.playerBackground
        playerPlaceholderIcon.translatesAutoresizingMaskIntoConstraints = false
        playerPlaceholderIcon.image = UIImage(systemName: "play.rectangle")
        playerPlaceholderIcon.tintColor = UIColor.white.withAlphaComponent(0.35)
        playerPlaceholderIcon.contentMode = .scaleAspectFit
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver(_:))
        ffmpegPlayer?.close()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        configureNavigationBar()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isMovingFromParent || isBeingDismissed {
            view.endEditing(true)
        }
    }

    private func configureNavigationBar() {
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.titleView = nil
        navigationItem.leftBarButtonItem = nil
        navigationItem.leftBarButtonItems = nil
        navigationItem.leftItemsSupplementBackButton = true
        // 标题改由外层 SwiftUI 的 toolbar 提供，避免在 SwiftUI NavigationStack 里被覆盖。

        let appearance = UINavigationBarAppearance()
        appearance.configureWithDefaultBackground()
        appearance.shadowColor = .clear
        navigationItem.standardAppearance = appearance
        navigationItem.scrollEdgeAppearance = appearance
        navigationItem.compactAppearance = appearance
        navigationItem.compactScrollEdgeAppearance = appearance

        navigationController?.navigationBar.tintColor = LFFColors.brandPrimary
    }

    private func setupHierarchy() {
        playerCard.translatesAutoresizingMaskIntoConstraints = false
        playerCard.addSubview(metalView)
        playerCard.addSubview(playerPlaceholder)
        playerPlaceholder.addSubview(playerPlaceholderIcon)
        NSLayoutConstraint.activate([
            metalView.topAnchor.constraint(equalTo: playerCard.topAnchor),
            metalView.leadingAnchor.constraint(equalTo: playerCard.leadingAnchor),
            metalView.trailingAnchor.constraint(equalTo: playerCard.trailingAnchor),
            metalView.bottomAnchor.constraint(equalTo: playerCard.bottomAnchor),
            playerPlaceholder.topAnchor.constraint(equalTo: playerCard.topAnchor),
            playerPlaceholder.leadingAnchor.constraint(equalTo: playerCard.leadingAnchor),
            playerPlaceholder.trailingAnchor.constraint(equalTo: playerCard.trailingAnchor),
            playerPlaceholder.bottomAnchor.constraint(equalTo: playerCard.bottomAnchor),
            playerPlaceholderIcon.centerXAnchor.constraint(equalTo: playerPlaceholder.centerXAnchor),
            playerPlaceholderIcon.centerYAnchor.constraint(equalTo: playerPlaceholder.centerYAnchor),
            playerPlaceholderIcon.widthAnchor.constraint(equalToConstant: 64),
            playerPlaceholderIcon.heightAnchor.constraint(equalToConstant: 64)
        ])

        let statusRow = UIStackView(arrangedSubviews: [statusDot, statusLabel, metaLabel])
        statusRow.axis = .horizontal
        statusRow.spacing = 8
        statusRow.alignment = .top
        statusRow.translatesAutoresizingMaskIntoConstraints = false

        let urlRow = UIStackView(arrangedSubviews: [urlField, pickFileButton])
        urlRow.axis = .horizontal
        urlRow.spacing = 10
        urlRow.alignment = .fill
        urlRow.distribution = .fill
        urlRow.translatesAutoresizingMaskIntoConstraints = false

        let actionRow = UIStackView(arrangedSubviews: [playButton, stopButton])
        actionRow.axis = .horizontal
        actionRow.spacing = 10
        actionRow.alignment = .fill
        actionRow.distribution = .fill
        actionRow.translatesAutoresizingMaskIntoConstraints = false

        let mainStack = UIStackView(arrangedSubviews: [playerCard, statusRow, urlRow, actionRow])
        mainStack.axis = .vertical
        mainStack.spacing = 14
        mainStack.alignment = .fill
        mainStack.distribution = .fill
        mainStack.setCustomSpacing(10, after: playerCard)
        mainStack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(mainStack)
        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            mainStack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            mainStack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            mainStack.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -16)
        ])

        statusDot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        statusDot.heightAnchor.constraint(equalToConstant: 8).isActive = true

        urlField.heightAnchor.constraint(equalToConstant: controlHeight).isActive = true
        pickFileButton.heightAnchor.constraint(equalToConstant: controlHeight).isActive = true
        playButton.heightAnchor.constraint(equalToConstant: 52).isActive = true
        stopButton.heightAnchor.constraint(equalToConstant: 52).isActive = true
        stopButton.widthAnchor.constraint(equalToConstant: 96).isActive = true

        urlField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        urlField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pickFileButton.setContentHuggingPriority(.required, for: .horizontal)
        pickFileButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        playButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stopButton.setContentHuggingPriority(.required, for: .horizontal)
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        metaLabel.setContentHuggingPriority(.required, for: .horizontal)

        playerCard.setContentHuggingPriority(.defaultLow, for: .vertical)
        playerCard.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        [statusRow, urlRow, actionRow].forEach {
            $0.setContentCompressionResistancePriority(.required, for: .vertical)
            $0.setContentHuggingPriority(.required, for: .vertical)
        }
    }

    private func bindAppLifecycle() {
        observers.append(
            NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.handleLeaveForeground()
            }
        )
        observers.append(
            NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.handleEnterForeground()
            }
        )
    }

    private func handleLeaveForeground() {
        guard status == .playing || status == .preparing else { return }
        ffmpegPlayer?.pauseDecoding()
        status = .paused
    }

    private func handleEnterForeground() {
        guard status == .paused else { return }
        ffmpegPlayer?.resumeDecoding()
        status = .playing
    }

    private func renderStatus() {
        statusLabel.text = LFFStrings.statusText(status, error: errorMessage)
        let dot: UIColor
        switch status {
        case .idle, .completed: dot = LFFColors.statusIdle
        case .preparing, .paused: dot = LFFColors.statusPreparing
        case .playing: dot = LFFColors.statusPlaying
        case .error: dot = LFFColors.statusError
        }
        statusDot.backgroundColor = dot
        playButton.isEnabled = status != .preparing

        var parts: [String] = []
        if videoW > 0, videoH > 0 {
            parts.append("\(videoW)×\(videoH)")
        }
        if durationMs > 0 {
            parts.append(Self.formatDuration(ms: durationMs))
        }
        metaLabel.text = parts.joined(separator: " · ")
    }

    @objc private func tapPickFile() {
        var config = PHPickerConfiguration()
        config.filter = .videos
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }

    @objc private func tapPlay() {
        view.endEditing(true)
        let raw = urlField.text ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            errorMessage = "请输入或选择一个播放地址"
            status = .error
            return
        }
        view.layoutIfNeeded()
        guard metalView.bounds.width > 1, metalView.bounds.height > 1 else {
            errorMessage = "视频显示区域尚未就绪，请稍候再试"
            status = .error
            return
        }
        guard let url = Self.makeURL(from: trimmed) else {
            errorMessage = "地址格式无效"
            status = .error
            return
        }

        UserDefaults.standard.set(trimmed, forKey: kLearnFFmpegLastURLKey)

        activatePlaybackAudioSession()

        teardownCurrentPlayer()

        errorMessage = nil
        videoW = 0
        videoH = 0
        durationMs = 0
        status = .preparing

        let player = FFmpegDemuxerPlayer()
        player.delegate = self
        do {
            try player.ffOpenMedia(url)
        } catch {
            errorMessage = "播放失败：\(error.localizedDescription)"
            status = .error
            return
        }

        ffmpegPlayer = player
        metalView.ffmpegPlayer = player
        playerPlaceholder.isHidden = true

        let sz = player.videoSize
        videoW = Int(sz.width)
        videoH = Int(sz.height)
        durationMs = player.durationMs

        player.start()
        status = .playing
    }

    @objc private func tapStop() {
        teardownCurrentPlayer()
        errorMessage = nil
        videoW = 0
        videoH = 0
        durationMs = 0
        status = .idle
    }

    private func teardownCurrentPlayer() {
        metalView.ffmpegPlayer = nil
        if let player = ffmpegPlayer {
            player.delegate = nil
            player.stop()
            player.close()
        }
        ffmpegPlayer = nil
        metalView.flushTextureCache()
        playerPlaceholder.isHidden = false
    }

    private func activatePlaybackAudioSession() {
        // 默认会话是 .soloAmbient，会被静音开关静音；切到 .playback 才能正常出声。
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback, options: [])
            try session.setActive(true, options: [])
        } catch {
            // 失败也不阻断播放，仅打印一下原因。
            print("[FFmpegPlayer] AudioSession activate failed: \(error)")
        }
    }

    static func makeURL(from trimmed: String) -> URL? {
        let lower = trimmed.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://")
            || lower.hasPrefix("rtmp://") || lower.hasPrefix("rtmps://")
            || lower.hasPrefix("rtmpt://") || lower.hasPrefix("rtmpts://")
            || lower.hasPrefix("tcp://") || lower.hasPrefix("udp://")
            || lower.hasPrefix("mmsh://") || lower.hasPrefix("mmst://") {
            return URL(string: trimmed)
        }
        if lower.hasPrefix("file:") {
            return URL(string: trimmed)
        }
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed)
        }
        return URL(string: trimmed)
    }

    static func formatDuration(ms: Int64) -> String {
        if ms <= 0 { return LFFStrings.dash }
        let totalSec = ms / 1000
        let h = totalSec / 3600
        let m = (totalSec % 3600) / 60
        let s = totalSec % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    // MARK: - PHPickerViewControllerDelegate

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        dismiss(animated: true)
        guard let item = results.first else { return }

        // 不动当前播放：仅把所选视频复制到沙盒，把路径填到地址栏。
        // 切换/释放旧播放器要等用户主动点「播放」时才发生。
        item.itemProvider.loadFileRepresentation(forTypeIdentifier: "public.movie") { [weak self] url, error in
            guard let self else { return }
            if let error {
                DispatchQueue.main.async {
                    self.errorMessage = "无法读取相册视频：\(error.localizedDescription)"
                    if self.status != .playing && self.status != .paused {
                        self.status = .error
                    }
                }
                return
            }
            guard let url else {
                DispatchQueue.main.async {
                    self.errorMessage = "未能取得视频文件"
                    if self.status != .playing && self.status != .paused {
                        self.status = .error
                    }
                }
                return
            }
            let ext = url.pathExtension
            let baseName = url.deletingPathExtension().lastPathComponent
            let uniqueName = "\(baseName)-\(UUID().uuidString)" + (ext.isEmpty ? "" : ".\(ext)")
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent(uniqueName)
            do {
                try FileManager.default.copyItem(at: url, to: temp)
                DispatchQueue.main.async {
                    self.urlField.text = temp.path
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = "无法复制相册视频：\(error.localizedDescription)"
                    if self.status != .playing && self.status != .paused {
                        self.status = .error
                    }
                }
            }
        }
    }

    // MARK: - FFmpegDemuxerPlayerDelegate

    func ffmpegPlayerDidCompletePlayback(_ player: FFmpegDemuxerPlayer) {
        guard player === ffmpegPlayer else { return }
        player.stop()
        status = .completed
    }

    func ffmpegPlayer(_ player: FFmpegDemuxerPlayer, didFailWithCode code: Int, message: String) {
        guard player === ffmpegPlayer else { return }
        errorMessage = "播放失败 (\(code)): \(message)"
        status = .error
        teardownCurrentPlayer()
    }
}
