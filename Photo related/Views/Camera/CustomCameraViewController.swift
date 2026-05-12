//
//  CustomCameraViewController.swift
//  Photo related
//
//  自定义相机：底部横向「特效分类」；单色为弹窗选择；蜡笔 / 热感 / 大雾 / 水墨画等为点击开关；拍照 / 录像。
//

import AVFoundation
import CoreImage
import CoreLocation
import MetalKit
import Photos
import UIKit
import Vision

// MARK: - 底部横向列表里的「分类」项（后续可继续加分类）

private enum EffectCategoryItem: Int, CaseIterable {
    case monochrome
    case crayon
    case catFace
    case thermal
    case gongbi
    case oilPainting
    case watercolor
    case muralPainting
    case magicCrayon
    case magicSketch
    case cartoon3

    var title: String {
        switch self {
        case .monochrome: return "单色"
        case .crayon: return "蜡笔"
        case .catFace: return "猫脸"
        case .thermal: return "热感"
        case .gongbi: return "工笔画"
        case .oilPainting: return "油画"
        case .watercolor: return "水彩画"
        case .muralPainting: return "壁画"
        case .magicCrayon: return "Crayon"
        case .magicSketch: return "Sketch"
        case .cartoon3: return "卡通3"
        }
    }
}

private final class EffectCategoryCell: UICollectionViewCell {
    static let reuseId = "EffectCategoryCell"
    /// 右侧状态点固定为正圆。若仅在 `layoutSubviews` 里用 `bounds.width/2`，在首帧布局前 `bounds` 可能为 0 → `cornerRadius` 为 0，会画成绿方块（与工笔画等已布局完的圆点不一致）。
    private static let stateIndicatorDiameter: CGFloat = 18

    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    /// 未选中：空心圆环；选中：绿色实心圆（不再用 ✅ 等会显示成方框打勾的符号）。
    private let stateIndicator = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        selectedBackgroundView = nil
        contentView.layer.cornerRadius = 14
        contentView.layer.masksToBounds = true

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        subtitleLabel.font = .systemFont(ofSize: 12, weight: .regular)
        subtitleLabel.numberOfLines = 2

        stateIndicator.translatesAutoresizingMaskIntoConstraints = false
        stateIndicator.layer.masksToBounds = true
        stateIndicator.layer.cornerRadius = Self.stateIndicatorDiameter / 2
        contentView.addSubview(stateIndicator)

        let stack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        stack.axis = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: stateIndicator.leadingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),

            stateIndicator.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            stateIndicator.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            stateIndicator.widthAnchor.constraint(equalToConstant: Self.stateIndicatorDiameter),
            stateIndicator.heightAnchor.constraint(equalToConstant: Self.stateIndicatorDiameter),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let d = min(stateIndicator.bounds.width, stateIndicator.bounds.height)
        stateIndicator.layer.cornerRadius = d > 1 ? d / 2 : Self.stateIndicatorDiameter / 2
    }

    func configure(title: String, subtitle: String, isActive: Bool) {
        titleLabel.text = title
        subtitleLabel.text = subtitle
        titleLabel.textColor = .white
        subtitleLabel.textColor = UIColor.white.withAlphaComponent(0.74)
        contentView.layer.borderWidth = isActive ? 1 : 0.5
        contentView.layer.borderColor = (isActive ? UIColor.systemBlue.withAlphaComponent(0.55) : UIColor.white.withAlphaComponent(0.14)).cgColor
        contentView.backgroundColor = isActive
            ? UIColor.systemBlue.withAlphaComponent(0.38)
            : UIColor.white.withAlphaComponent(0.14)

        stateIndicator.layer.cornerRadius = Self.stateIndicatorDiameter / 2

        if isActive {
            stateIndicator.backgroundColor = UIColor.systemGreen
            stateIndicator.layer.borderWidth = 1
            stateIndicator.layer.borderColor = UIColor.white.withAlphaComponent(0.35).cgColor
        } else {
            stateIndicator.backgroundColor = .clear
            stateIndicator.layer.borderWidth = 2
            stateIndicator.layer.borderColor = UIColor.white.withAlphaComponent(0.48).cgColor
        }
    }
}

private final class CameraPreviewMetalView: MTKView, MTKViewDelegate {
    private let imageLock = NSLock()
    private var latestImage: CIImage?
    private var ciContext: CIContext?
    private var commandQueue: MTLCommandQueue?

    override init(frame: CGRect, device: MTLDevice?) {
        super.init(frame: frame, device: device)
        configureMetal()
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        configureMetal()
    }

    private func configureMetal() {
        if self.device == nil {
            self.device = MTLCreateSystemDefaultDevice()
        }
        framebufferOnly = false
        colorPixelFormat = .bgra8Unorm
        // 使用“按帧驱动”而不是持续刷新，避免预览与采集节奏不同步导致重影/双画面。
        isPaused = true
        enableSetNeedsDisplay = true
        preferredFramesPerSecond = 60
        backgroundColor = .black
        clipsToBounds = true

        guard let device else { return }
        commandQueue = device.makeCommandQueue()
        ciContext = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        delegate = self
    }

    func display(ciImage: CIImage) {
        imageLock.lock()
        latestImage = ciImage
        imageLock.unlock()
        if Thread.isMainThread {
            setNeedsDisplay()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.setNeedsDisplay()
            }
        }
    }

    func draw(in view: MTKView) {
        guard let drawable = currentDrawable,
              let commandQueue,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let ciContext
        else { return }
        if let pass = currentRenderPassDescriptor {
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            let clearEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass)
            clearEncoder?.endEncoding()
        }

        imageLock.lock()
        let image = latestImage
        imageLock.unlock()
        guard let image else {
            commandBuffer.present(drawable)
            commandBuffer.commit()
            return
        }

        let srcRect = image.extent
        guard srcRect.width > 1, srcRect.height > 1,
              srcRect.width.isFinite, srcRect.height.isFinite
        else {
            commandBuffer.present(drawable)
            commandBuffer.commit()
            return
        }

        let drawableW = max(1, CGFloat(drawable.texture.width))
        let drawableH = max(1, CGFloat(drawable.texture.height))

        // 与 AVLayerVideoGravityResizeAspectFill 一致：单一等比缩放 + 居中，避免 sx/sy 不一致导致形变；
        // 不再对裁剪矩形做 .integral，否则容易把裁剪框扩出像素范围，出现单侧黑边。
        let scale = max(drawableW / srcRect.width, drawableH / srcRect.height)
        let scaledW = srcRect.width * scale
        let scaledH = srcRect.height * scale
        let ox = (drawableW - scaledW) * 0.5
        let oy = (drawableH - scaledH) * 0.5
        let transform = CGAffineTransform(translationX: -srcRect.minX, y: -srcRect.minY)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: ox, y: oy)
        let output = image.transformed(by: transform)

        let bounds = CGRect(origin: .zero, size: CGSize(width: drawableW, height: drawableH))
        ciContext.render(output, to: drawable.texture, commandBuffer: commandBuffer, bounds: bounds, colorSpace: CGColorSpaceCreateDeviceRGB())
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
}

// MARK: - 主界面

final class CustomCameraViewController: UIViewController {

    private enum CaptureMode: Int {
        case photo = 0
        case video = 1
    }

    private let previewView = CameraPreviewMetalView(frame: .zero)
    /// 悬浮在预览上的控制条（特效 / 倍率 / 模式 / 快门），外再包一层毛玻璃底。
    private let panelHudWrapper = UIView()
    private let panelHudBlur = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterialDark))
    private let panelStack = UIStackView()
    private let floatingBackButton = UIButton(type: .system)
    /// 由 SwiftUI 注入，用于无系统导航栏时关闭页面。
    var dismissHandler: (() -> Void)?
    private let shutterRowStack = UIStackView()
    private let modeHostView = UIView()
    private let modeControl = UISegmentedControl(items: ["拍照", "录像"])
    private let switchCameraButton = UIButton(type: .system)
    private let captureButton = UIButton(type: .system)
    private let zoomControlContainer = UIView()
    private let zoomStackView = UIStackView()
    private let recordingIndicator = UIView()
    private let statusLabel = UILabel()
    private let perfHost = UIView()
    private let perfLabel = UILabel()
    private let topBarHost = UIView()
    private let topStatusStack = UIStackView()

    private lazy var categoryCollection: UICollectionView = {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumInteritemSpacing = 10
        layout.minimumLineSpacing = 10
        layout.sectionInset = UIEdgeInsets(top: 2, left: 4, bottom: 2, right: 4)
        let cv = UICollectionView(frame: .zero, collectionViewLayout: layout)
        cv.backgroundColor = .clear
        cv.showsHorizontalScrollIndicator = false
        cv.alwaysBounceHorizontal = true
        cv.delegate = self
        cv.dataSource = self
        cv.register(EffectCategoryCell.self, forCellWithReuseIdentifier: EffectCategoryCell.reuseId)
        return cv
    }()

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.lhh.PhotoRelated.customCamera.session")
    private let videoDataOutputQueue = DispatchQueue(label: "com.lhh.PhotoRelated.customCamera.videoData")
    private let audioDataOutputQueue = DispatchQueue(label: "com.lhh.PhotoRelated.customCamera.audioData")
    private let writerQueue = DispatchQueue(label: "com.lhh.PhotoRelated.customCamera.writer")

    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let audioDataOutput = AVCaptureAudioDataOutput()
    private let photoOutput = AVCapturePhotoOutput()

    private lazy var ciContext = CIContext(options: [.cacheIntermediates: false])
    private lazy var previewEffectPipeline: PreviewEffectPipeline = {
        PreviewEffectPipeline(ciContext: self.ciContext)
    }()

    private let effectLock = NSLock()
    private var lockedEffect: MonochromePreviewEffect = .normal

    private let crayonLock = NSLock()
    private var crayonEffectEnabled = false

    private let catFaceLock = NSLock()
    private var catFaceEffectEnabled = false

    private let thermalLock = NSLock()
    private var thermalEffectEnabled = false

    private let gongbiLock = NSLock()
    private var gongbiEffectEnabled = false

    private let oilPaintingLock = NSLock()
    private var oilPaintingEffectEnabled = false

    private let watercolorLock = NSLock()
    private var watercolorEffectEnabled = false

    private let muralPaintingLock = NSLock()
    private var muralPaintingEffectEnabled = false

    private let magicCrayonLock = NSLock()
    private var magicCrayonEffectEnabled = false
    private let magicSketchLock = NSLock()
    private var magicSketchEffectEnabled = false
    private let cartoon3Lock = NSLock()
    private var cartoon3EffectEnabled = false

    private var isSessionRunning = false
    private var isSetupDone = false
    private var activeSessionPreset: AVCaptureSession.Preset = .hd1280x720
    private var captureSessionHasAudioInput = false
    private var videoInput: AVCaptureDeviceInput?
    private var availableZoomPresets: [CGFloat] = [1.0]
    private var zoomPresetButtons: [UIButton] = []
    private var lastPinchZoomFactor: CGFloat = 1.0
    private var lastAppliedZoomFactor: CGFloat = 1.0
    private var lastZoomApplyMonotonic: CFTimeInterval = 0
    private let cameraPositionLock = NSLock()
    private var currentCameraPosition: AVCaptureDevice.Position = .back

    private var currentMode: CaptureMode = .photo {
        didSet { updateModeUI() }
    }

    /// 仅主线程：控制红点与状态文案
    private var isRecordingMovie = false

    private var recordingURL: URL?
    private var assetWriter: AVAssetWriter?
    private var videoWriterInput: AVAssetWriterInput?
    private var audioWriterInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var writerSessionStarted = false
    private var writerAnchorPTS: CMTime = .invalid
    private var audioFormatDescription: CMFormatDescription?
    private var audioWriterInputAttached = false

    private let recordingWantsFramesLock = NSLock()
    private var recordingWantsFrames = false
    private var recordingStartedMonotonic: CFTimeInterval = 0

    private var lastRenderWallTime: CFTimeInterval = 0
    private var minPreviewInterval: CFTimeInterval = 1.0 / 60.0
    private let previewTimingLock = NSLock()
    private var perfWindowStartTime: CFTimeInterval = 0
    private var perfFrameCount: Int = 0
    private var perfDroppedCount: Int = 0
    private var perfAccumulatedProcessMs: Double = 0
    private var perfLastCameraPTS: CMTime = .invalid
    private var lifecycleObservers: [NSObjectProtocol] = []
    private let locationManager = CLLocationManager()
    private let locationLock = NSLock()
    private var latestLocation: CLLocation?
    private let pendingPhotoLocationLock = NSLock()
    private var pendingPhotoLocations: [Int64: CLLocation] = [:]

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        title = "自定义相机"

        effectLock.lock()
        lockedEffect = .normal
        effectLock.unlock()

        configurePreview()
        configureControls()
        layoutViews()
        updateModeUI()
        updatePreviewPerformanceProfile()
        configureLocationServices()
        registerAppLifecycleNotifications()
        configureSessionOnSetup()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        sessionQueue.async { [weak self] in
            self?.startSessionIfNeeded()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        sessionQueue.async { [weak self] in
            self?.stopSessionIfNeeded()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let r = panelHudWrapper.layer.cornerRadius
        let b = panelHudWrapper.bounds
        if b.width > 2, b.height > 2 {
            panelHudWrapper.layer.shadowPath = UIBezierPath(roundedRect: b, cornerRadius: r).cgPath
        }
        let th = topBarHost.bounds.height
        if th > 4 {
            topBarHost.layer.cornerRadius = th / 2
            if #available(iOS 13.0, *) {
                topBarHost.layer.cornerCurve = .continuous
            }
        }
    }

    deinit {
        let center = NotificationCenter.default
        for observer in lifecycleObservers {
            center.removeObserver(observer)
        }
        lifecycleObservers.removeAll()
    }

    private func configurePreview() {
        previewView.backgroundColor = .black
        previewView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(previewView)

        recordingIndicator.backgroundColor = .systemRed
        recordingIndicator.layer.cornerRadius = 5
        recordingIndicator.isHidden = true
        recordingIndicator.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            recordingIndicator.widthAnchor.constraint(equalToConstant: 10),
            recordingIndicator.heightAnchor.constraint(equalToConstant: 10),
        ])

        statusLabel.textColor = .white
        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.textAlignment = .natural
        statusLabel.numberOfLines = 1
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        perfHost.translatesAutoresizingMaskIntoConstraints = false
        perfHost.backgroundColor = UIColor.black.withAlphaComponent(0.42)
        perfHost.layer.cornerRadius = 12
        perfHost.layer.masksToBounds = true
        perfHost.layer.borderWidth = 0.5
        perfHost.layer.borderColor = UIColor.white.withAlphaComponent(0.12).cgColor
        if #available(iOS 13.0, *) {
            perfHost.layer.cornerCurve = .continuous
        }
        view.addSubview(perfHost)

        perfLabel.textColor = .white
        perfLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        perfLabel.backgroundColor = .clear
        perfLabel.textAlignment = .left
        perfLabel.numberOfLines = 0
        perfLabel.text = " FPS: --\n PROC: -- ms\n DROP: --\n THERM: --\n PRESET: --"
        perfLabel.translatesAutoresizingMaskIntoConstraints = false
        perfLabel.isHidden = false
        perfHost.addSubview(perfLabel)
        NSLayoutConstraint.activate([
            perfLabel.topAnchor.constraint(equalTo: perfHost.topAnchor, constant: 8),
            perfLabel.leadingAnchor.constraint(equalTo: perfHost.leadingAnchor, constant: 10),
            perfLabel.trailingAnchor.constraint(equalTo: perfHost.trailingAnchor, constant: -10),
            perfLabel.bottomAnchor.constraint(equalTo: perfHost.bottomAnchor, constant: -8),
            perfLabel.widthAnchor.constraint(equalToConstant: 168),
        ])
    }

    private func configureLocationServices() {
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        handleLocationAuthorizationStatus()
    }

    private func handleLocationAuthorizationStatus() {
        if #available(iOS 14.0, *) {
            switch locationManager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways:
                locationManager.startUpdatingLocation()
            case .notDetermined:
                locationManager.requestWhenInUseAuthorization()
            default:
                locationManager.stopUpdatingLocation()
                break
            }
        } else {
            let status = CLLocationManager.authorizationStatus()
            switch status {
            case .authorizedAlways, .authorizedWhenInUse:
                locationManager.startUpdatingLocation()
            case .notDetermined:
                locationManager.requestWhenInUseAuthorization()
            default:
                locationManager.stopUpdatingLocation()
                break
            }
        }
    }

    private func setLatestLocation(_ location: CLLocation?) {
        locationLock.lock()
        latestLocation = location
        locationLock.unlock()
    }

    private func currentLocationSnapshot() -> CLLocation? {
        locationLock.lock()
        let value = latestLocation
        locationLock.unlock()
        return value
    }

    private func registerAppLifecycleNotifications() {
        let center = NotificationCenter.default
        let willResign = center.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleAppWillResignActive()
        }
        let didBecome = center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleAppDidBecomeActive()
        }
        let interrupted = center.addObserver(
            forName: .AVCaptureSessionWasInterrupted,
            object: session,
            queue: .main
        ) { [weak self] _ in
            self?.statusLabel.text = "相机被系统中断，等待恢复..."
        }
        let interruptionEnded = center.addObserver(
            forName: .AVCaptureSessionInterruptionEnded,
            object: session,
            queue: .main
        ) { [weak self] _ in
            self?.sessionQueue.async {
                self?.startSessionIfNeeded()
            }
        }
        let runtimeError = center.addObserver(
            forName: .AVCaptureSessionRuntimeError,
            object: session,
            queue: .main
        ) { [weak self] _ in
            self?.sessionQueue.async {
                self?.stopSessionIfNeeded()
                self?.startSessionIfNeeded()
            }
        }
        lifecycleObservers = [willResign, didBecome, interrupted, interruptionEnded, runtimeError]
    }

    private func handleAppWillResignActive() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.getRecordingWantsFrames() {
                self.requestStopFilteredRecording()
            }
            self.stopSessionIfNeeded()
        }
    }

    private func handleAppDidBecomeActive() {
        guard isViewLoaded, view.window != nil else { return }
        sessionQueue.async { [weak self] in
            self?.startSessionIfNeeded()
        }
    }

    private func configureControls() {
        topBarHost.translatesAutoresizingMaskIntoConstraints = false
        topBarHost.backgroundColor = UIColor(white: 0, alpha: 0.48)
        topBarHost.layer.cornerRadius = 22
        topBarHost.layer.masksToBounds = true
        topBarHost.layer.borderWidth = 0.5
        topBarHost.layer.borderColor = UIColor.white.withAlphaComponent(0.12).cgColor
        if #available(iOS 13.0, *) {
            topBarHost.layer.cornerCurve = .continuous
        }
        view.addSubview(topBarHost)

        topStatusStack.axis = .horizontal
        topStatusStack.spacing = 10
        topStatusStack.alignment = .center
        topStatusStack.translatesAutoresizingMaskIntoConstraints = false
        topBarHost.addSubview(topStatusStack)
        topStatusStack.addArrangedSubview(recordingIndicator)
        topStatusStack.addArrangedSubview(statusLabel)
        NSLayoutConstraint.activate([
            topStatusStack.leadingAnchor.constraint(equalTo: topBarHost.leadingAnchor, constant: 12),
            topStatusStack.trailingAnchor.constraint(equalTo: topBarHost.trailingAnchor, constant: -12),
            topStatusStack.topAnchor.constraint(equalTo: topBarHost.topAnchor, constant: 8),
            topStatusStack.bottomAnchor.constraint(equalTo: topBarHost.bottomAnchor, constant: -8),
        ])

        floatingBackButton.translatesAutoresizingMaskIntoConstraints = false
        floatingBackButton.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        floatingBackButton.layer.cornerRadius = 23
        floatingBackButton.layer.masksToBounds = true
        floatingBackButton.layer.borderWidth = 0.5
        floatingBackButton.layer.borderColor = UIColor.white.withAlphaComponent(0.18).cgColor
        floatingBackButton.tintColor = .white
        floatingBackButton.setImage(UIImage(systemName: "chevron.backward"), for: .normal)
        floatingBackButton.accessibilityLabel = "返回"
        floatingBackButton.addTarget(self, action: #selector(floatingBackTapped), for: .touchUpInside)
        view.addSubview(floatingBackButton)

        panelHudWrapper.translatesAutoresizingMaskIntoConstraints = false
        panelHudWrapper.backgroundColor = .clear
        panelHudWrapper.layer.cornerRadius = 28
        panelHudWrapper.layer.masksToBounds = false
        panelHudWrapper.layer.shadowColor = UIColor.black.cgColor
        panelHudWrapper.layer.shadowOpacity = 0.45
        panelHudWrapper.layer.shadowRadius = 18
        panelHudWrapper.layer.shadowOffset = CGSize(width: 0, height: 8)

        panelHudBlur.translatesAutoresizingMaskIntoConstraints = false
        panelHudBlur.layer.cornerRadius = 28
        panelHudBlur.clipsToBounds = true
        panelHudBlur.layer.borderWidth = 0.5
        panelHudBlur.layer.borderColor = UIColor.white.withAlphaComponent(0.1).cgColor
        panelHudWrapper.addSubview(panelHudBlur)
        NSLayoutConstraint.activate([
            panelHudBlur.topAnchor.constraint(equalTo: panelHudWrapper.topAnchor),
            panelHudBlur.leadingAnchor.constraint(equalTo: panelHudWrapper.leadingAnchor),
            panelHudBlur.trailingAnchor.constraint(equalTo: panelHudWrapper.trailingAnchor),
            panelHudBlur.bottomAnchor.constraint(equalTo: panelHudWrapper.bottomAnchor),
        ])

        panelStack.axis = .vertical
        panelStack.spacing = 12
        panelStack.alignment = .fill
        panelStack.isLayoutMarginsRelativeArrangement = true
        panelStack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 6, leading: 4, bottom: 8, trailing: 4)
        panelStack.translatesAutoresizingMaskIntoConstraints = false
        panelStack.backgroundColor = .clear
        panelHudWrapper.addSubview(panelStack)
        NSLayoutConstraint.activate([
            panelStack.topAnchor.constraint(equalTo: panelHudWrapper.topAnchor, constant: 12),
            panelStack.leadingAnchor.constraint(equalTo: panelHudWrapper.leadingAnchor, constant: 12),
            panelStack.trailingAnchor.constraint(equalTo: panelHudWrapper.trailingAnchor, constant: -12),
            panelStack.bottomAnchor.constraint(equalTo: panelHudWrapper.bottomAnchor, constant: -12),
        ])
        view.addSubview(panelHudWrapper)

        categoryCollection.translatesAutoresizingMaskIntoConstraints = false
        categoryCollection.heightAnchor.constraint(equalToConstant: 72).isActive = true
        panelStack.addArrangedSubview(categoryCollection)

        zoomControlContainer.translatesAutoresizingMaskIntoConstraints = false
        zoomControlContainer.backgroundColor = .clear
        zoomControlContainer.layer.cornerRadius = 0
        zoomControlContainer.layer.masksToBounds = false
        zoomControlContainer.layer.borderWidth = 0
        zoomControlContainer.heightAnchor.constraint(equalToConstant: 50).isActive = true
        zoomStackView.axis = .horizontal
        zoomStackView.alignment = .center
        zoomStackView.distribution = .equalSpacing
        zoomStackView.spacing = 18
        zoomStackView.translatesAutoresizingMaskIntoConstraints = false
        zoomControlContainer.addSubview(zoomStackView)
        NSLayoutConstraint.activate([
            zoomStackView.centerXAnchor.constraint(equalTo: zoomControlContainer.centerXAnchor),
            zoomStackView.topAnchor.constraint(equalTo: zoomControlContainer.topAnchor, constant: 3),
            zoomStackView.bottomAnchor.constraint(equalTo: zoomControlContainer.bottomAnchor, constant: -3),
        ])
        panelStack.addArrangedSubview(zoomControlContainer)

        modeHostView.translatesAutoresizingMaskIntoConstraints = false
        modeHostView.heightAnchor.constraint(equalToConstant: 36).isActive = true
        modeControl.selectedSegmentIndex = 0
        modeControl.backgroundColor = UIColor.white.withAlphaComponent(0.14)
        modeControl.selectedSegmentTintColor = .systemBlue
        modeControl.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .normal)
        modeControl.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .selected)
        modeControl.addTarget(self, action: #selector(modeChanged), for: .valueChanged)
        modeControl.translatesAutoresizingMaskIntoConstraints = false
        modeHostView.addSubview(modeControl)
        NSLayoutConstraint.activate([
            modeControl.centerXAnchor.constraint(equalTo: modeHostView.centerXAnchor),
            modeControl.centerYAnchor.constraint(equalTo: modeHostView.centerYAnchor),
            modeControl.widthAnchor.constraint(lessThanOrEqualToConstant: 280),
            modeControl.leadingAnchor.constraint(greaterThanOrEqualTo: modeHostView.leadingAnchor),
            modeControl.trailingAnchor.constraint(lessThanOrEqualTo: modeHostView.trailingAnchor),
        ])
        panelStack.addArrangedSubview(modeHostView)

        shutterRowStack.axis = .horizontal
        shutterRowStack.alignment = .center
        shutterRowStack.distribution = .fill
        shutterRowStack.spacing = 0
        shutterRowStack.translatesAutoresizingMaskIntoConstraints = false

        let shutterDiameter: CGFloat = 80
        let sideControl: CGFloat = 52
        shutterRowStack.heightAnchor.constraint(equalToConstant: max(shutterDiameter, sideControl) + 6).isActive = true

        switchCameraButton.translatesAutoresizingMaskIntoConstraints = false
        switchCameraButton.backgroundColor = UIColor.white.withAlphaComponent(0.18)
        switchCameraButton.layer.cornerRadius = sideControl / 2
        switchCameraButton.tintColor = .white
        switchCameraButton.setImage(UIImage(systemName: "arrow.triangle.2.circlepath.camera"), for: .normal)
        switchCameraButton.addTarget(self, action: #selector(switchCameraTapped), for: .touchUpInside)

        captureButton.translatesAutoresizingMaskIntoConstraints = false
        captureButton.addTarget(self, action: #selector(captureTapped), for: .touchUpInside)

        let spacerL = UIView()
        spacerL.translatesAutoresizingMaskIntoConstraints = false
        let spacerR = UIView()
        spacerR.translatesAutoresizingMaskIntoConstraints = false
        let ghost = UIView()
        ghost.translatesAutoresizingMaskIntoConstraints = false

        shutterRowStack.addArrangedSubview(switchCameraButton)
        shutterRowStack.addArrangedSubview(spacerL)
        shutterRowStack.addArrangedSubview(captureButton)
        shutterRowStack.addArrangedSubview(spacerR)
        shutterRowStack.addArrangedSubview(ghost)

        NSLayoutConstraint.activate([
            switchCameraButton.widthAnchor.constraint(equalToConstant: sideControl),
            switchCameraButton.heightAnchor.constraint(equalToConstant: sideControl),
            ghost.widthAnchor.constraint(equalToConstant: sideControl),
            ghost.heightAnchor.constraint(equalToConstant: sideControl),
            spacerL.widthAnchor.constraint(equalTo: spacerR.widthAnchor),
            captureButton.widthAnchor.constraint(equalToConstant: shutterDiameter),
            captureButton.heightAnchor.constraint(equalToConstant: shutterDiameter),
        ])
        panelStack.addArrangedSubview(shutterRowStack)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePreviewPinch(_:)))
        pinch.cancelsTouchesInView = false
        previewView.isUserInteractionEnabled = true
        previewView.addGestureRecognizer(pinch)

        view.bringSubviewToFront(panelHudWrapper)
        view.bringSubviewToFront(floatingBackButton)
        view.bringSubviewToFront(topBarHost)
        view.bringSubviewToFront(perfHost)
    }

    private func layoutViews() {
        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            previewView.topAnchor.constraint(equalTo: safe.topAnchor),
            previewView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            previewView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            previewView.bottomAnchor.constraint(equalTo: safe.bottomAnchor),

            floatingBackButton.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 12),
            floatingBackButton.topAnchor.constraint(equalTo: safe.topAnchor, constant: 8),
            floatingBackButton.widthAnchor.constraint(equalToConstant: 46),
            floatingBackButton.heightAnchor.constraint(equalToConstant: 46),

            topBarHost.leadingAnchor.constraint(equalTo: floatingBackButton.trailingAnchor, constant: 8),
            topBarHost.centerYAnchor.constraint(equalTo: floatingBackButton.centerYAnchor),
            topBarHost.trailingAnchor.constraint(lessThanOrEqualTo: safe.trailingAnchor, constant: -20),

            panelHudWrapper.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 10),
            panelHudWrapper.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -10),
            panelHudWrapper.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -12),

            perfHost.topAnchor.constraint(equalTo: safe.topAnchor, constant: 8),
            perfHost.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -8),
        ])
    }

    private func updateModeUI() {
        let isVideo = (currentMode == .video)
        modeControl.selectedSegmentIndex = currentMode.rawValue
        let shutterDiameter: CGFloat = 80
        captureButton.layer.cornerRadius = shutterDiameter / 2
        captureButton.layer.borderWidth = 5
        captureButton.layer.borderColor = UIColor.white.cgColor
        captureButton.backgroundColor = isVideo ? .systemRed : .white
        captureButton.tintColor = .clear
        statusLabel.text = isVideo ? "录像：再点一次结束" : "拍照：单次快门"
    }

    @objc private func modeChanged() {
        currentMode = CaptureMode(rawValue: modeControl.selectedSegmentIndex) ?? .photo
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.updateSessionPresetForCurrentModeIfNeeded()
            if self.currentMode == .video {
                self.ensureMicrophoneAndAttachAudioInputIfPossible()
            }
        }
    }

    @objc private func floatingBackTapped() {
        if let dismissHandler {
            dismissHandler()
            return
        }
        if let nav = navigationController, nav.viewControllers.count > 1 {
            nav.popViewController(animated: true)
        } else {
            dismiss(animated: true)
        }
    }

    @objc private func captureTapped() {
        switch currentMode {
        case .photo:
            takePhoto()
        case .video:
            toggleRecording()
        }
    }

    @objc private func switchCameraTapped() {
        sessionQueue.async { [weak self] in
            self?.switchCameraInput()
        }
    }

    @objc private func zoomPresetTapped(_ sender: UIButton) {
        let idx = sender.tag
        guard idx >= 0, idx < availableZoomPresets.count else { return }
        let targetZoom = availableZoomPresets[idx]
        sessionQueue.async { [weak self] in
            self?.setZoomFactor(targetZoom, animated: true)
        }
    }

    @objc private func handlePreviewPinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            lastPinchZoomFactor = 1.0
        case .changed:
            let delta = gesture.scale / max(lastPinchZoomFactor, 0.0001)
            lastPinchZoomFactor = gesture.scale
            sessionQueue.async { [weak self] in
                self?.adjustZoomByScale(delta)
            }
        default:
            lastPinchZoomFactor = 1.0
        }
    }

    // MARK: - 权限与会话

    private func configureSessionOnSetup() {
        sessionQueue.async { [weak self] in
            self?.checkPermissionAndConfigureSession()
        }
    }

    private func checkPermissionAndConfigureSession() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            sessionQueue.suspend()
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                self?.sessionQueue.resume()
                self?.sessionQueue.async {
                    if granted {
                        self?.configureSessionIfNeeded()
                    } else {
                        self?.presentPermissionDenied(message: "需要相机权限才能使用自定义相机。")
                    }
                }
            }
            return
        default:
            presentPermissionDenied(message: "请在系统设置中开启相机权限。")
            return
        }

        configureSessionIfNeeded()
    }

    private func configureSessionIfNeeded() {
        guard !isSetupDone else { return }
        isSetupDone = true

        session.beginConfiguration()

        guard let input = makeVideoInput(preferred: .back),
              session.canAddInput(input)
        else {
            session.commitConfiguration()
            DispatchQueue.main.async { [weak self] in
                self?.statusLabel.text = "无法打开相机设备"
            }
            return
        }
        session.addInput(input)
        videoInput = input
        setCurrentCameraPosition(input.device.position)
        configureZoomPresetsForCurrentCamera()
        activeSessionPreset = bestSessionPreset(for: currentMode)
        if session.canSetSessionPreset(activeSessionPreset) {
            session.sessionPreset = activeSessionPreset
        }

        videoDataOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
        videoDataOutput.alwaysDiscardsLateVideoFrames = true
        videoDataOutput.setSampleBufferDelegate(self, queue: videoDataOutputQueue)

        guard session.canAddOutput(videoDataOutput) else {
            session.commitConfiguration()
            return
        }
        session.addOutput(videoDataOutput)

        if let conn = videoDataOutput.connection(with: .video) {
            if conn.isVideoOrientationSupported {
                conn.videoOrientation = .portrait
            }
            if conn.isVideoMirroringSupported {
                conn.isVideoMirrored = (input.device.position == .front)
            }
        }

        guard session.canAddOutput(photoOutput) else {
            session.commitConfiguration()
            return
        }
        session.addOutput(photoOutput)
        photoOutput.isHighResolutionCaptureEnabled = true

        audioDataOutput.setSampleBufferDelegate(self, queue: audioDataOutputQueue)
        if session.canAddOutput(audioDataOutput) {
            session.addOutput(audioDataOutput)
        }

        session.commitConfiguration()

        ensureMicrophoneAndAttachAudioInputIfPossible()

        DispatchQueue.main.async { [weak self] in
            self?.statusLabel.text = "预览已就绪"
            self?.reloadEffectCategoryUI()
        }
    }

    private func makeVideoInput(preferred position: AVCaptureDevice.Position) -> AVCaptureDeviceInput? {
        let positions: [AVCaptureDevice.Position] = [position, .back, .front]
        for p in positions {
            let deviceTypes: [AVCaptureDevice.DeviceType]
            if p == .back {
                deviceTypes = [
                    .builtInTripleCamera,
                    .builtInDualWideCamera,
                    .builtInDualCamera,
                    .builtInWideAngleCamera,
                ]
            } else {
                deviceTypes = [
                    .builtInTrueDepthCamera,
                    .builtInWideAngleCamera,
                ]
            }
            let discovery = AVCaptureDevice.DiscoverySession(
                deviceTypes: deviceTypes,
                mediaType: .video,
                position: p
            )
            if let device = discovery.devices.first,
               let input = try? AVCaptureDeviceInput(device: device) {
                return input
            }
        }
        return nil
    }

    private func setCurrentCameraPosition(_ position: AVCaptureDevice.Position) {
        cameraPositionLock.lock()
        currentCameraPosition = position
        cameraPositionLock.unlock()
    }

    private func getCurrentCameraPosition() -> AVCaptureDevice.Position {
        cameraPositionLock.lock()
        let p = currentCameraPosition
        cameraPositionLock.unlock()
        return p
    }

    private func switchCameraInput() {
        guard isSetupDone else { return }
        if getRecordingWantsFrames() {
            DispatchQueue.main.async { [weak self] in
                self?.statusLabel.text = "录像中不支持切换前后摄"
            }
            return
        }

        guard let oldInput = videoInput else { return }
        let newPos: AVCaptureDevice.Position = (oldInput.device.position == .back) ? .front : .back
        guard let newInput = makeVideoInput(preferred: newPos) else {
            DispatchQueue.main.async { [weak self] in
                self?.statusLabel.text = "当前设备不支持该摄像头"
            }
            return
        }

        session.beginConfiguration()
        session.removeInput(oldInput)
        if session.canAddInput(newInput) {
            session.addInput(newInput)
            videoInput = newInput
            setCurrentCameraPosition(newInput.device.position)
            } else if session.canAddInput(oldInput) {
            session.addInput(oldInput)
            videoInput = oldInput
            setCurrentCameraPosition(oldInput.device.position)
            }

        if let conn = videoDataOutput.connection(with: .video) {
            if conn.isVideoOrientationSupported { conn.videoOrientation = .portrait }
            if conn.isVideoMirroringSupported { conn.isVideoMirrored = (videoInput?.device.position == .front) }
        }
        if let conn = photoOutput.connection(with: .video) {
            if conn.isVideoOrientationSupported { conn.videoOrientation = .portrait }
            if conn.isVideoMirroringSupported { conn.isVideoMirrored = (videoInput?.device.position == .front) }
        }
        session.commitConfiguration()

        updateSessionPresetForCurrentModeIfNeeded()
        configureZoomPresetsForCurrentCamera()
        updateZoomButtonSelectionForCurrentZoom()
    }

    private func bestSessionPreset(for mode: CaptureMode) -> AVCaptureSession.Preset {
        let candidates: [AVCaptureSession.Preset]
        switch mode {
        case .photo:
            // 拍照优先高像素，尽量接近系统相机默认大图。
            candidates = [.photo, .high, .hd1920x1080, .hd1280x720]
        case .video:
            // 录像固定优先 1080，设备不支持时自动降级。
            candidates = [.hd1920x1080, .high, .hd1280x720]
        }
        for preset in candidates where session.canSetSessionPreset(preset) {
            return preset
        }
        return .high
    }

    private func updateSessionPresetForCurrentModeIfNeeded() {
        guard isSetupDone else { return }
        let target = bestSessionPreset(for: currentMode)
        guard target != activeSessionPreset else { return }
        guard session.canSetSessionPreset(target) else { return }
        // 切换 photo / video 的 sessionPreset 时，系统常把 videoZoomFactor 重置为 1，
        // 但 lastAppliedZoomFactor 仍为旧值，会导致 setZoomFactor 误判「已应用」而直接 return，
        // 出现「按钮仍显示 5x、预览实际 1x」。
        let zoomToRestore = videoInput?.device.videoZoomFactor ?? lastAppliedZoomFactor
        session.beginConfiguration()
        session.sessionPreset = target
        session.commitConfiguration()
        activeSessionPreset = target
        if let device = videoInput?.device {
            lastAppliedZoomFactor = device.videoZoomFactor
            setZoomFactor(zoomToRestore, animated: false)
        }
        configureZoomPresetsForCurrentCamera()
    }

    private func configureZoomPresetsForCurrentCamera() {
        guard let device = videoInput?.device else { return }
        let presets = computeZoomPresets(for: device)
        DispatchQueue.main.async { [weak self] in
            self?.rebuildZoomPresetButtons(presets: presets)
        }
    }

    private func computeZoomPresets(for device: AVCaptureDevice) -> [CGFloat] {
        var values = Set<CGFloat>()
        let minZoom = device.minAvailableVideoZoomFactor
        let maxZoom = device.maxAvailableVideoZoomFactor
        let epsilon: CGFloat = 0.02

        func isReachable(_ zoom: CGFloat) -> Bool {
            return zoom >= (minZoom - epsilon) && zoom <= (maxZoom + epsilon)
        }

        func normalized(_ zoom: CGFloat) -> CGFloat {
            // 设备上常见的镜头倍率做吸附，避免出现 4.9x 这类体验不一致的文案。
            let commonStops: [CGFloat] = [0.5, 1.0, 2.0, 2.5, 3.0, 5.0, 10.0]
            if let nearest = commonStops.min(by: { abs($0 - zoom) < abs($1 - zoom) }),
               abs(nearest - zoom) <= 0.22 {
                return nearest
            }
            return (zoom * 10).rounded() / 10.0
        }

        if isReachable(1.0) {
            values.insert(1.0)
        }
        let constituent = device.constituentDevices
        if constituent.contains(where: { $0.deviceType == .builtInUltraWideCamera }) && isReachable(0.5) {
            values.insert(0.5)
        }

        let switchOver = device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
        if !switchOver.isEmpty, constituent.count > 1 {
            for raw in switchOver {
                // 这里只保留「镜头切换点」附近倍率；过大的值通常是数码变焦区间，不放到系统相机风格按钮里。
                let factor = normalized(raw)
                if factor >= 0.5, factor <= 6.0, isReachable(factor) {
                    values.insert(factor)
                }
            }
        } else if constituent.contains(where: { $0.deviceType == .builtInTelephotoCamera }), isReachable(2.0) {
            values.insert(2.0)
        }

        // 有长焦镜头时，优先补一个 5x（若可达）；避免部分机型只回传 4.9 导致看不到 5x。
        if constituent.contains(where: { $0.deviceType == .builtInTelephotoCamera }), isReachable(5.0) {
            values.insert(5.0)
        }

        let sorted = values.sorted()
        if sorted.isEmpty {
            return [max(minZoom, min(1.0, maxZoom))]
        }
        return sorted
    }

    private func rebuildZoomPresetButtons(presets: [CGFloat]) {
        availableZoomPresets = presets.isEmpty ? [1.0] : presets
        zoomPresetButtons.forEach { btn in
            zoomStackView.removeArrangedSubview(btn)
            btn.removeFromSuperview()
        }
        zoomPresetButtons.removeAll()

        for (idx, zoom) in availableZoomPresets.enumerated() {
            let btn = UIButton(type: .system)
            btn.tag = idx
            btn.setTitle(formatZoomFactorLabel(zoom), for: .normal)
            btn.setTitleColor(.white, for: .normal)
            btn.titleLabel?.font = .systemFont(ofSize: 13, weight: .bold)
            btn.titleLabel?.adjustsFontSizeToFitWidth = true
            btn.titleLabel?.minimumScaleFactor = 0.75
            btn.backgroundColor = UIColor.black.withAlphaComponent(0.48)
            let ring: CGFloat = 44
            btn.layer.cornerRadius = ring / 2
            btn.layer.masksToBounds = true
            btn.layer.borderWidth = 0.5
            btn.layer.borderColor = UIColor.white.withAlphaComponent(0.22).cgColor
            if #available(iOS 13.0, *) {
                btn.layer.cornerCurve = .continuous
            }
            btn.contentEdgeInsets = .zero
            btn.addTarget(self, action: #selector(zoomPresetTapped(_:)), for: .touchUpInside)
            zoomStackView.addArrangedSubview(btn)
            NSLayoutConstraint.activate([
                btn.widthAnchor.constraint(equalToConstant: ring),
                btn.heightAnchor.constraint(equalToConstant: ring),
            ])
            zoomPresetButtons.append(btn)
        }
        updateZoomButtonSelectionForCurrentZoom()
    }

    private func formatZoomFactorLabel(_ zoom: CGFloat) -> String {
        if abs(zoom.rounded() - zoom) < 0.05 {
            return "\(Int(zoom.rounded()))x"
        }
        return String(format: "%.1fx", zoom)
    }

    private func setZoomFactor(_ requested: CGFloat, animated: Bool) {
        guard let device = videoInput?.device else { return }
        let clamped = clampedZoom(requested, for: device)
        if abs(clamped - lastAppliedZoomFactor) < 0.003 {
            return
        }
        do {
            try device.lockForConfiguration()
            if animated {
                if device.isRampingVideoZoom {
                    device.cancelVideoZoomRamp()
                }
                let rate = zoomRampRate(from: device.videoZoomFactor, to: clamped)
                device.ramp(toVideoZoomFactor: clamped, withRate: rate)
            } else {
                device.videoZoomFactor = clamped
            }
            device.unlockForConfiguration()
            lastAppliedZoomFactor = clamped
            DispatchQueue.main.async { [weak self] in
                self?.updateZoomButtonSelection(currentZoom: clamped)
            }
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.statusLabel.text = "变焦失败：\(error.localizedDescription)"
            }
        }
    }

    private func adjustZoomByScale(_ scaleDelta: CGFloat) {
        guard let device = videoInput?.device else { return }
        let now = CACurrentMediaTime()
        if now - lastZoomApplyMonotonic < (1.0 / 90.0) {
            return
        }
        lastZoomApplyMonotonic = now

        let current = max(0.1, device.videoZoomFactor)
        let target = current * scaleDelta
        let clamped = clampedZoom(target, for: device)
        // 抑制手势中的微小噪声，避免高频 lock/unlock 造成细微卡顿。
        if abs(clamped - current) < 0.006 {
            return
        }
        setZoomFactor(clamped, animated: false)
    }

    private func clampedZoom(_ requested: CGFloat, for device: AVCaptureDevice) -> CGFloat {
        let minZoom = device.minAvailableVideoZoomFactor
        // 使用当前设备真实可用上限；不依赖新 SDK 属性，确保低版本工程也可编译。
        let softMax = device.maxAvailableVideoZoomFactor
        return max(minZoom, min(requested, softMax))
    }

    private func zoomRampRate(from start: CGFloat, to end: CGFloat) -> Float {
        let delta = abs(end - start)
        switch delta {
        case 0..<0.25: return 20
        case 0.25..<0.8: return 28
        case 0.8..<1.8: return 36
        default: return 46
        }
    }

    private func updateZoomButtonSelectionForCurrentZoom() {
        guard let current = videoInput?.device.videoZoomFactor else { return }
        DispatchQueue.main.async { [weak self] in
            self?.updateZoomButtonSelection(currentZoom: current)
        }
    }

    private func updateZoomButtonSelection(currentZoom: CGFloat) {
        guard !zoomPresetButtons.isEmpty, !availableZoomPresets.isEmpty else { return }
        var nearestIndex = 0
        var nearestDistance = CGFloat.greatestFiniteMagnitude
        for (idx, value) in availableZoomPresets.enumerated() {
            let dist = abs(value - currentZoom)
            if dist < nearestDistance {
                nearestDistance = dist
                nearestIndex = idx
            }
        }
        for (idx, btn) in zoomPresetButtons.enumerated() {
            let selected = (idx == nearestIndex)
            btn.backgroundColor = selected ? .white : UIColor.black.withAlphaComponent(0.48)
            btn.setTitleColor(selected ? .black : .white, for: .normal)
            btn.layer.borderWidth = selected ? 0 : 0.5
            btn.layer.borderColor = selected ? UIColor.clear.cgColor : UIColor.white.withAlphaComponent(0.25).cgColor
        }
    }

    private func ensureMicrophoneAndAttachAudioInputIfPossible() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            addAudioInputToSessionIfNeeded()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                guard granted else { return }
                self?.sessionQueue.async {
                    self?.addAudioInputToSessionIfNeeded()
                }
            }
        default:
            break
        }
    }

    private func addAudioInputToSessionIfNeeded() {
        guard isSetupDone else { return }
        if session.inputs.contains(where: { ($0 as? AVCaptureDeviceInput)?.device.hasMediaType(.audio) == true }) {
            captureSessionHasAudioInput = true
            return
        }
        guard let device = AVCaptureDevice.default(for: .audio),
              let input = try? AVCaptureDeviceInput(device: device)
        else { return }

        session.beginConfiguration()
        if session.canAddInput(input) {
            session.addInput(input)
            captureSessionHasAudioInput = true
        }
        session.commitConfiguration()
    }

    private func startSessionIfNeeded() {
        sessionQueue.async { [weak self] in
            guard let self, self.isSetupDone, !self.isSessionRunning else { return }
            self.session.startRunning()
            self.isSessionRunning = true
        }
    }

    private func stopSessionIfNeeded() {
        sessionQueue.async { [weak self] in
            guard let self, self.isSessionRunning else { return }
            if self.isRecordingMovie {
                self.requestStopFilteredRecording()
            }
            self.session.stopRunning()
            self.isSessionRunning = false
        }
    }

    private func presentPermissionDenied(message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.statusLabel.text = message
        }
    }

    // MARK: - 拍照

    private func takePhoto() {
        sessionQueue.async { [weak self] in
            guard let self, self.isSessionRunning else { return }
            if let conn = self.photoOutput.connection(with: .video) {
                if conn.isVideoOrientationSupported {
                    conn.videoOrientation = .portrait
                }
                if conn.isVideoMirroringSupported {
                    conn.isVideoMirrored = (self.videoInput?.device.position == .front)
                }
            }
            let settings: AVCapturePhotoSettings
            if self.photoOutput.availablePhotoCodecTypes.contains(.hevc) {
                settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
            } else {
                settings = AVCapturePhotoSettings()
            }
            if self.photoOutput.isHighResolutionCaptureEnabled {
                settings.isHighResolutionPhotoEnabled = true
            }
            settings.photoQualityPrioritization = self.bestAllowedPhotoQualityPrioritization()
            if let location = self.currentLocationSnapshot() {
                self.pendingPhotoLocationLock.lock()
                self.pendingPhotoLocations[settings.uniqueID] = location
                self.pendingPhotoLocationLock.unlock()
            }
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    // MARK: - 录像（AVAssetWriter 写入与预览一致的单色滤镜 + 麦克风）

    private func toggleRecording() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let active = self.getRecordingWantsFrames()
            if active {
                self.requestStopFilteredRecording()
            } else {
                self.startFilteredRecording()
            }
        }
    }

    private func startFilteredRecording() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("custom-camera-\(Int(Date().timeIntervalSince1970)).mp4")

        writerQueue.async { [weak self] in
            guard let self else { return }
            guard !self.getRecordingWantsFrames() else { return }

            self.resetWriterState()
            self.recordingURL = url
            self.writerSessionStarted = false
            self.audioFormatDescription = nil
            self.audioWriterInputAttached = false
            self.writerAnchorPTS = .invalid
            self.recordingStartedMonotonic = CACurrentMediaTime()

            self.setRecordingWantsFrames(true)
        }

        DispatchQueue.main.async { [weak self] in
            self?.isRecordingMovie = true
            self?.recordingIndicator.isHidden = false
            self?.statusLabel.text = "正在录像（含当前特效）…"
        }
    }

    private func requestStopFilteredRecording() {
        writerQueue.async { [weak self] in
            self?.finalizeFilteredRecordingToDisk()
        }
    }

    private func resetWriterState() {
        assetWriter = nil
        videoWriterInput = nil
        audioWriterInput = nil
        pixelBufferAdaptor = nil
        writerSessionStarted = false
        writerAnchorPTS = .invalid
        audioFormatDescription = nil
        audioWriterInputAttached = false
    }

    private func getRecordingWantsFrames() -> Bool {
        recordingWantsFramesLock.lock()
        let v = recordingWantsFrames
        recordingWantsFramesLock.unlock()
        return v
    }

    private func setRecordingWantsFrames(_ value: Bool) {
        recordingWantsFramesLock.lock()
        recordingWantsFrames = value
        recordingWantsFramesLock.unlock()
    }

    /// 在 writerQueue 上调用
    private func finalizeFilteredRecordingToDisk() {
        setRecordingWantsFrames(false)

        guard let writer = assetWriter else {
            if let url = recordingURL {
                try? FileManager.default.removeItem(at: url)
            }
            recordingURL = nil
            DispatchQueue.main.async { [weak self] in
                self?.isRecordingMovie = false
                self?.recordingIndicator.isHidden = true
            }
            return
        }

        if !writerSessionStarted {
            writer.cancelWriting()
            resetWriterState()
            if let url = recordingURL {
                try? FileManager.default.removeItem(at: url)
            }
            recordingURL = nil
            DispatchQueue.main.async { [weak self] in
                self?.isRecordingMovie = false
                self?.recordingIndicator.isHidden = true
                self?.statusLabel.text = "录像过短，未写入文件"
            }
            return
        }

        videoWriterInput?.markAsFinished()
        audioWriterInput?.markAsFinished()

        let outputURL = recordingURL
        writer.finishWriting { [weak self] in
            guard let self else { return }
            self.writerQueue.async {
                self.resetWriterState()
            }
            DispatchQueue.main.async { [weak self] in
                self?.isRecordingMovie = false
                self?.recordingIndicator.isHidden = true
            }
            if writer.status == .failed {
                let err = writer.error?.localizedDescription ?? "写入失败"
                DispatchQueue.main.async { [weak self] in
                    self?.statusLabel.text = err
                }
                if let outputURL {
                    try? FileManager.default.removeItem(at: outputURL)
                }
                return
            }
            guard let outputURL else { return }
            self.saveVideoToLibrary(at: outputURL, location: self.currentLocationSnapshot())
        }
    }

    /// 在 writerQueue 上调用：根据首帧尺寸创建 Writer；若有麦克风则等格式描述后再 `startWriting`
    private func ensureWriterVideoTrackIfNeeded(outputWidth: Int, outputHeight: Int, firstVideoPTS: CMTime) {
        guard outputWidth > 0, outputHeight > 0 else { return }
        if assetWriter != nil { return }
        guard let url = recordingURL else { return }

        do {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: outputWidth,
                AVVideoHeightKey: outputHeight,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: outputWidth * outputHeight * 4,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264BaselineAutoLevel,
                ],
            ]
            let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            vIn.expectsMediaDataInRealTime = true

            let pxAttrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: outputWidth,
                kCVPixelBufferHeightKey as String: outputHeight,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            ]
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vIn, sourcePixelBufferAttributes: pxAttrs)

            guard writer.canAdd(vIn) else { return }
            writer.add(vIn)

            assetWriter = writer
            videoWriterInput = vIn
            pixelBufferAdaptor = adaptor
            writerAnchorPTS = firstVideoPTS
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.statusLabel.text = error.localizedDescription
            }
        }
    }

    private func tryAttachAudioInputIfPossible() {
        guard let writer = assetWriter, writer.status == .unknown else { return }
        guard captureSessionHasAudioInput, !audioWriterInputAttached, let fmt = audioFormatDescription else { return }

        let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: fmt)
        aIn.expectsMediaDataInRealTime = true
        guard writer.canAdd(aIn) else { return }
        writer.add(aIn)
        audioWriterInput = aIn
        audioWriterInputAttached = true
    }

    private func tryStartWriterSessionIfReady() {
        guard let writer = assetWriter, writer.status == .unknown else { return }
        guard writerAnchorPTS.isValid else { return }
        if captureSessionHasAudioInput, !audioWriterInputAttached {
            let waited = CACurrentMediaTime() - recordingStartedMonotonic
            if waited < 0.15 { return }
        }

        writer.startWriting()
        guard writer.status != .failed else {
            DispatchQueue.main.async { [weak self] in
                self?.statusLabel.text = writer.error?.localizedDescription ?? "录像启动失败"
            }
            return
        }
        writer.startSession(atSourceTime: writerAnchorPTS)
        writerSessionStarted = true
    }

    /// 在 writerQueue 上调用
    private func appendFilteredVideo(filtered: CIImage, presentationTime: CMTime) {
        guard getRecordingWantsFrames() else { return }

        let integral = filtered.extent.integral
        let w = max(1, Int(integral.width))
        let h = max(1, Int(integral.height))

        let translated = filtered.transformed(by: CGAffineTransform(translationX: -integral.origin.x, y: -integral.origin.y))
        let renderRect = CGRect(origin: .zero, size: CGSize(width: CGFloat(w), height: CGFloat(h)))

        ensureWriterVideoTrackIfNeeded(outputWidth: w, outputHeight: h, firstVideoPTS: presentationTime)
        tryAttachAudioInputIfPossible()
        tryStartWriterSessionIfReady()

        guard writerSessionStarted,
              let writer = assetWriter,
              writer.status == .writing,
              let vIn = videoWriterInput,
              vIn.isReadyForMoreMediaData,
              let adaptor = pixelBufferAdaptor,
              let pool = adaptor.pixelBufferPool
        else { return }

        var dst: CVPixelBuffer?
        if CVPixelBufferPoolCreatePixelBuffer(nil, pool, &dst) != kCVReturnSuccess || dst == nil { return }

        ciContext.render(translated, to: dst!, bounds: renderRect, colorSpace: CGColorSpaceCreateDeviceRGB())

        if !adaptor.append(dst!, withPresentationTime: presentationTime) {
            // 单帧失败时继续，避免整段失败无提示
        }
    }

    /// 在 writerQueue 上调用
    private func processRecordingAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard getRecordingWantsFrames() else { return }
        if audioFormatDescription == nil {
            audioFormatDescription = CMSampleBufferGetFormatDescription(sampleBuffer)
        }
        tryAttachAudioInputIfPossible()
        tryStartWriterSessionIfReady()
        guard writerSessionStarted,
              let aIn = audioWriterInput,
              aIn.isReadyForMoreMediaData
        else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard writerAnchorPTS.isValid, CMTimeCompare(pts, writerAnchorPTS) >= 0 else { return }
        _ = aIn.append(sampleBuffer)
    }

    // MARK: - 滤镜

    private func reloadEffectCategoryUI() {
        if Thread.isMainThread {
            categoryCollection.reloadData()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.categoryCollection.reloadData()
            }
        }
    }

    private func currentEffect() -> MonochromePreviewEffect {
        effectLock.lock()
        let e = lockedEffect
        effectLock.unlock()
        return e
    }

    private func setEffect(_ e: MonochromePreviewEffect) {
        effectLock.lock()
        lockedEffect = e
        effectLock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.reloadEffectCategoryUI()
        }
        updatePreviewPerformanceProfile()
    }

    private func isCrayonEnabled() -> Bool {
        crayonLock.lock()
        let v = crayonEffectEnabled
        crayonLock.unlock()
        return v
    }

    private func toggleCrayonEnabled() {
        crayonLock.lock()
        crayonEffectEnabled.toggle()
        crayonLock.unlock()
        reloadEffectCategoryUI()
        updatePreviewPerformanceProfile()
    }

    private func isCatFaceEnabled() -> Bool {
        catFaceLock.lock()
        let v = catFaceEffectEnabled
        catFaceLock.unlock()
        return v
    }

    private func toggleCatFaceEnabled() {
        catFaceLock.lock()
        catFaceEffectEnabled.toggle()
        catFaceLock.unlock()
        reloadEffectCategoryUI()
        updatePreviewPerformanceProfile()
    }

    private func isThermalEnabled() -> Bool {
        thermalLock.lock()
        let v = thermalEffectEnabled
        thermalLock.unlock()
        return v
    }

    private func toggleThermalEnabled() {
        thermalLock.lock()
        thermalEffectEnabled.toggle()
        thermalLock.unlock()
        reloadEffectCategoryUI()
        updatePreviewPerformanceProfile()
    }

    private func isGongbiEnabled() -> Bool {
        gongbiLock.lock()
        let v = gongbiEffectEnabled
        gongbiLock.unlock()
        return v
    }

    private func toggleGongbiEnabled() {
        gongbiLock.lock()
        gongbiEffectEnabled.toggle()
        let nowOn = gongbiEffectEnabled
        gongbiLock.unlock()
        if nowOn {
            oilPaintingLock.lock(); oilPaintingEffectEnabled = false; oilPaintingLock.unlock()
            watercolorLock.lock(); watercolorEffectEnabled = false; watercolorLock.unlock()
            muralPaintingLock.lock(); muralPaintingEffectEnabled = false; muralPaintingLock.unlock()
        }
        reloadEffectCategoryUI()
        updatePreviewPerformanceProfile()
    }

    private func isOilPaintingEnabled() -> Bool {
        oilPaintingLock.lock()
        let v = oilPaintingEffectEnabled
        oilPaintingLock.unlock()
        return v
    }

    private func toggleOilPaintingEnabled() {
        oilPaintingLock.lock()
        oilPaintingEffectEnabled.toggle()
        let nowOn = oilPaintingEffectEnabled
        oilPaintingLock.unlock()
        if nowOn {
            gongbiLock.lock(); gongbiEffectEnabled = false; gongbiLock.unlock()
            watercolorLock.lock(); watercolorEffectEnabled = false; watercolorLock.unlock()
            muralPaintingLock.lock(); muralPaintingEffectEnabled = false; muralPaintingLock.unlock()
        }
        reloadEffectCategoryUI()
        updatePreviewPerformanceProfile()
    }

    private func isWatercolorEnabled() -> Bool {
        watercolorLock.lock()
        let v = watercolorEffectEnabled
        watercolorLock.unlock()
        return v
    }

    private func toggleWatercolorEnabled() {
        watercolorLock.lock()
        watercolorEffectEnabled.toggle()
        let nowOn = watercolorEffectEnabled
        watercolorLock.unlock()
        if nowOn {
            gongbiLock.lock(); gongbiEffectEnabled = false; gongbiLock.unlock()
            oilPaintingLock.lock(); oilPaintingEffectEnabled = false; oilPaintingLock.unlock()
            muralPaintingLock.lock(); muralPaintingEffectEnabled = false; muralPaintingLock.unlock()
        }
        reloadEffectCategoryUI()
        updatePreviewPerformanceProfile()
    }

    private func isMuralPaintingEnabled() -> Bool {
        muralPaintingLock.lock()
        let v = muralPaintingEffectEnabled
        muralPaintingLock.unlock()
        return v
    }

    private func toggleMuralPaintingEnabled() {
        muralPaintingLock.lock()
        muralPaintingEffectEnabled.toggle()
        let nowOn = muralPaintingEffectEnabled
        muralPaintingLock.unlock()
        if nowOn {
            gongbiLock.lock(); gongbiEffectEnabled = false; gongbiLock.unlock()
            oilPaintingLock.lock(); oilPaintingEffectEnabled = false; oilPaintingLock.unlock()
            watercolorLock.lock(); watercolorEffectEnabled = false; watercolorLock.unlock()
        }
        reloadEffectCategoryUI()
        updatePreviewPerformanceProfile()
    }

    private func isMagicCrayonEnabled() -> Bool {
        magicCrayonLock.lock()
        let v = magicCrayonEffectEnabled
        magicCrayonLock.unlock()
        return v
    }

    private func toggleMagicCrayonEnabled() {
        magicCrayonLock.lock()
        magicCrayonEffectEnabled.toggle()
        magicCrayonLock.unlock()
        reloadEffectCategoryUI()
        updatePreviewPerformanceProfile()
    }

    private func isMagicSketchEnabled() -> Bool {
        magicSketchLock.lock()
        let v = magicSketchEffectEnabled
        magicSketchLock.unlock()
        return v
    }

    private func toggleMagicSketchEnabled() {
        magicSketchLock.lock()
        magicSketchEffectEnabled.toggle()
        magicSketchLock.unlock()
        reloadEffectCategoryUI()
        updatePreviewPerformanceProfile()
    }

    private func isCartoon3Enabled() -> Bool {
        cartoon3Lock.lock()
        let v = cartoon3EffectEnabled
        cartoon3Lock.unlock()
        return v
    }

    private func toggleCartoon3Enabled() {
        cartoon3Lock.lock()
        cartoon3EffectEnabled.toggle()
        cartoon3Lock.unlock()
        reloadEffectCategoryUI()
        updatePreviewPerformanceProfile()
    }

    private func updatePreviewPerformanceProfile() {
        let heavyEnabled = isMagicSketchEnabled() || isCartoon3Enabled() || isCatFaceEnabled()
        let fps = heavyEnabled ? 30 : 60
        let interval = heavyEnabled ? (1.0 / 30.0) : (1.0 / 60.0)
        previewTimingLock.lock()
        minPreviewInterval = interval
        previewTimingLock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.previewView.preferredFramesPerSecond = fps
        }
    }

    private func recordPerformanceSample(processMs: Double, pts: CMTime, rendered: Bool) {
        let now = CACurrentMediaTime()
        if perfWindowStartTime == 0 {
            perfWindowStartTime = now
        }
        perfFrameCount += 1
        perfAccumulatedProcessMs += processMs
        if !rendered {
            perfDroppedCount += 1
        }
        if perfLastCameraPTS.isValid, pts.isValid {
            let delta = CMTimeGetSeconds(pts) - CMTimeGetSeconds(perfLastCameraPTS)
            if delta > 0.08 {
                perfDroppedCount += Int(max(0, (delta / 0.033) - 1.0))
            }
        }
        perfLastCameraPTS = pts

        let elapsed = now - perfWindowStartTime
        if elapsed < 1.0 { return }
        let fps = Double(perfFrameCount) / max(0.001, elapsed)
        let avgProcess = perfAccumulatedProcessMs / Double(max(1, perfFrameCount))
        let dropped = perfDroppedCount
        let thermal = thermalStateText()
        let preset = shortPresetName(activeSessionPreset)
        previewTimingLock.lock()
        let targetFPS = Int((1.0 / max(0.001, minPreviewInterval)).rounded())
        previewTimingLock.unlock()
        let modeText = (currentMode == .photo) ? "PHOTO" : "VIDEO"
        let overlay = String(format: " FPS: %.1f/%d\n PROC: %.1f ms\n DROP: %d\n THERM: %@\n PRESET: %@ %@",
                             fps, targetFPS, avgProcess, dropped, thermal, modeText, preset)
        DispatchQueue.main.async { [weak self] in
            self?.perfLabel.text = overlay
        }

        perfWindowStartTime = now
        perfFrameCount = 0
        perfDroppedCount = 0
        perfAccumulatedProcessMs = 0
    }

    private func thermalStateText() -> String {
        if #available(iOS 11.0, *) {
            switch ProcessInfo.processInfo.thermalState {
            case .nominal: return "NOMINAL"
            case .fair: return "FAIR"
            case .serious: return "SERIOUS"
            case .critical: return "CRITICAL"
            @unknown default: return "UNKNOWN"
            }
        }
        return "N/A"
    }

    private func shortPresetName(_ preset: AVCaptureSession.Preset) -> String {
        switch preset {
        case .hd4K3840x2160: return "4K"
        case .hd1920x1080: return "1080P"
        case .hd1280x720: return "720P"
        case .photo: return "PHOTO"
        case .high: return "HIGH"
        default: return preset.rawValue
        }
    }

    private func applyPreviewFilterChain(to input: CIImage) -> CIImage {
        previewEffectPipeline.apply(to: input, configuration: previewEffectConfigurationFromLocks())
    }

    private func previewEffectConfigurationFromLocks() -> PreviewEffectConfiguration {
        var c = PreviewEffectConfiguration()
        c.monochrome = currentEffect()
        c.crayon = isCrayonEnabled()
        c.catFace = isCatFaceEnabled()
        c.thermal = isThermalEnabled()
        c.gongbi = isGongbiEnabled()
        c.oilPainting = isOilPaintingEnabled()
        c.watercolor = isWatercolorEnabled()
        c.muralPainting = isMuralPaintingEnabled()
        c.magicCrayon = isMagicCrayonEnabled()
        c.magicSketch = isMagicSketchEnabled()
        c.magicSketchStrength = 0.5
        c.cartoon3 = isCartoon3Enabled()
        return c
    }

    private func orientedCIImage(from pixelBuffer: CVPixelBuffer, connection: AVCaptureConnection) -> CIImage {
        var image = CIImage(cvPixelBuffer: pixelBuffer)
        let orientation = cgImageOrientation(from: connection, devicePosition: getCurrentCameraPosition())
        image = image.oriented(orientation)
        return image
    }

    private func cgImageOrientation(from connection: AVCaptureConnection, devicePosition: AVCaptureDevice.Position) -> CGImagePropertyOrientation {
        let videoOrientation: AVCaptureVideoOrientation = connection.isVideoOrientationSupported ? connection.videoOrientation : .portrait
        let mirrored = connection.isVideoMirrored || (devicePosition == .front)

        switch videoOrientation {
        case .portrait:
            // 当前采集链路在 portrait 下已是正向像素，这里不再额外做 90° 旋转
            return mirrored ? .upMirrored : .up
        case .portraitUpsideDown:
            return mirrored ? .downMirrored : .down
        case .landscapeRight:
            // Home indicator / Dynamic Island 在右侧
            return mirrored ? .rightMirrored : .left
        case .landscapeLeft:
            // Home indicator / Dynamic Island 在左侧
            return mirrored ? .leftMirrored : .right
        @unknown default:
            return mirrored ? .upMirrored : .up
        }
    }

    private func presentMonochromePicker(from cell: UICollectionViewCell?) {
        let sheet = UIAlertController(
            title: "单色效果",
            message: "选「正常」可去掉单色滤镜。点「取消」不改变当前画面。",
            preferredStyle: .actionSheet
        )
        for effect in MonochromePreviewEffect.allCases {
            sheet.addAction(UIAlertAction(title: effect.displayName, style: .default) { [weak self] _ in
                self?.setEffect(effect)
            })
        }
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        if let pop = sheet.popoverPresentationController {
            pop.sourceView = cell ?? view
            pop.sourceRect = cell?.bounds ?? CGRect(x: view.bounds.midX, y: view.bounds.maxY - 80, width: 1, height: 1)
        }
        present(sheet, animated: true)
    }

    private func savePhotoToLibrary(_ data: Data, location: CLLocation?) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { [weak self] in
                    self?.statusLabel.text = "无相册写入权限，无法保存"
                }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                if let location {
                    request.location = location
                }
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = self.makeLibraryFilename(kind: "PHOTO", fileExtension: "jpg")
                request.addResource(with: .photo, data: data, options: options)
            } completionHandler: { ok, error in
                DispatchQueue.main.async { [weak self] in
                    if ok {
                        self?.statusLabel.text = "已保存到相册"
                    } else {
                        self?.statusLabel.text = error?.localizedDescription ?? "保存失败"
                    }
                }
            }
        }
    }

    private func bestAllowedPhotoQualityPrioritization() -> AVCapturePhotoOutput.QualityPrioritization {
        let maxPriority = photoOutput.maxPhotoQualityPrioritization
        if maxPriority == .quality {
            return .quality
        }
        if maxPriority == .balanced {
            return .balanced
        }
        return .speed
    }

    private func scalePhotoForScreenHeightKeepingAspect(_ image: CIImage) -> CIImage {
        let extent = image.extent.integral
        guard extent.width > 1, extent.height > 1 else { return image }
        let screenScale = UIScreen.main.scale
        let targetHeight = max(1, (UIScreen.main.bounds.height * screenScale).rounded())
        let ratio = targetHeight / extent.height
        let targetWidth = max(1, (extent.width * ratio).rounded())
        let translated = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        return translated.transformed(by: CGAffineTransform(scaleX: targetWidth / extent.width, y: targetHeight / extent.height))
    }

    private func saveVideoToLibrary(at url: URL, location: CLLocation?) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { [weak self] in
                    self?.statusLabel.text = "无相册写入权限，无法保存视频"
                }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                if let location {
                    request.location = location
                }
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = self.makeLibraryFilename(kind: "VIDEO", fileExtension: "mp4")
                request.addResource(with: .video, fileURL: url, options: options)
            } completionHandler: { ok, error in
                DispatchQueue.main.async { [weak self] in
                    if ok {
                        self?.statusLabel.text = "视频已保存到相册"
                    } else {
                        self?.statusLabel.text = error?.localizedDescription ?? "视频保存失败"
                    }
                }
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private func makeLibraryFilename(kind _: String, fileExtension: String) -> String {
        let effectPrefix = activeEffectFilenamePrefix()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss_SSS"
        let ts = formatter.string(from: Date())
        return "\(effectPrefix)\(ts).\(fileExtension)"
    }

    private func activeEffectFilenamePrefix() -> String {
        var effects: [String] = []
        let mono = currentEffect()
        if mono != .normal {
            effects.append(mono.displayName)
        }
        if isCrayonEnabled() { effects.append("蜡笔") }
        if isCatFaceEnabled() { effects.append("猫脸") }
        if isThermalEnabled() { effects.append("热感") }
        if isGongbiEnabled() { effects.append("工笔画") }
        if isOilPaintingEnabled() { effects.append("油画") }
        if isWatercolorEnabled() { effects.append("水彩画") }
        if isMuralPaintingEnabled() { effects.append("壁画") }
        if isMagicCrayonEnabled() { effects.append("Crayon") }
        if isMagicSketchEnabled() { effects.append("Sketch") }
        if isCartoon3Enabled() { effects.append("卡通3") }
        if effects.isEmpty {
            return "正常_"
        }
        return effects.joined() + "_"
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CustomCameraViewController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === videoDataOutput {
            autoreleasepool {
                let frameStart = CACurrentMediaTime()
                guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

                let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                let base = orientedCIImage(from: pixelBuffer, connection: connection)
                let filtered = applyPreviewFilterChain(to: base).cropped(to: base.extent)

                if getRecordingWantsFrames() {
                    writerQueue.async { [weak self] in
                        self?.appendFilteredVideo(filtered: filtered, presentationTime: pts)
                    }
                }

                let now = CACurrentMediaTime()
                previewTimingLock.lock()
                let interval = minPreviewInterval
                previewTimingLock.unlock()
                let shouldRender = (now - lastRenderWallTime >= interval)
                if shouldRender {
                    lastRenderWallTime = now
                    // 直接在采集队列提交最新 CI 帧，避免每帧切到主线程带来的抖动。
                    previewView.display(ciImage: filtered)
                }
                let processMs = (CACurrentMediaTime() - frameStart) * 1000.0
                recordPerformanceSample(processMs: processMs, pts: pts, rendered: shouldRender)
            }
            return
        }

        if output === audioDataOutput {
            guard getRecordingWantsFrames() else { return }
            writerQueue.async { [weak self] in
                self?.processRecordingAudioSampleBuffer(sampleBuffer)
            }
        }
    }
}

// MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

extension CustomCameraViewController: AVCaptureAudioDataOutputSampleBufferDelegate {}

// MARK: - AVCapturePhotoCaptureDelegate

extension CustomCameraViewController: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            DispatchQueue.main.async { [weak self] in
                self?.statusLabel.text = error.localizedDescription
            }
            return
        }
        guard let data = photo.fileDataRepresentation() else {
            DispatchQueue.main.async { [weak self] in
                self?.statusLabel.text = "无法读取照片数据"
            }
            return
        }

        guard let ci = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
            DispatchQueue.main.async { [weak self] in
                self?.statusLabel.text = "无法解码照片"
            }
            return
        }

        let filtered = applyPreviewFilterChain(to: ci).cropped(to: ci.extent)
        let output = scalePhotoForScreenHeightKeepingAspect(filtered)
        let extent = output.extent.integral
        guard let cg = ciContext.createCGImage(output, from: extent),
              let jpeg = UIImage(cgImage: cg, scale: 1, orientation: .up).jpegData(compressionQuality: 0.92)
        else {
            DispatchQueue.main.async { [weak self] in
                self?.statusLabel.text = "处理照片失败"
            }
            return
        }

        let photoId = photo.resolvedSettings.uniqueID
        pendingPhotoLocationLock.lock()
        let location = pendingPhotoLocations.removeValue(forKey: photoId)
        pendingPhotoLocationLock.unlock()
        savePhotoToLibrary(jpeg, location: location)
    }
}

extension CustomCameraViewController: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        handleLocationAuthorizationStatus()
    }

    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        handleLocationAuthorizationStatus()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        setLatestLocation(last)
    }
}

// MARK: - UICollectionView

extension CustomCameraViewController: UICollectionViewDataSource, UICollectionViewDelegate, UICollectionViewDelegateFlowLayout {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        EffectCategoryItem.allCases.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: EffectCategoryCell.reuseId, for: indexPath) as! EffectCategoryCell
        let item = EffectCategoryItem(rawValue: indexPath.item)!
        let subtitle: String
        let active: Bool
        switch item {
        case .monochrome:
            let current = currentEffect()
            subtitle = current == .normal ? "原色预览，点选切换单色" : "当前：\(current.displayName)"
            active = current != .normal
        case .crayon:
            subtitle = isCrayonEnabled() ? "蜡笔效果已开启" : "轻点开启蜡笔"
            active = isCrayonEnabled()
        case .catFace:
            subtitle = isCatFaceEnabled() ? "已开启，再点「猫脸」可关闭" : "轻点开启猫脸（需拍到人脸）"
            active = isCatFaceEnabled()
        case .thermal:
            subtitle = isThermalEnabled() ? "热感映射已开启" : "轻点开启热感"
            active = isThermalEnabled()
        case .gongbi:
            subtitle = isGongbiEnabled() ? "工笔画风已开启" : "轻点开启工笔"
            active = isGongbiEnabled()
        case .oilPainting:
            subtitle = isOilPaintingEnabled() ? "油画质感已开启" : "轻点开启油画"
            active = isOilPaintingEnabled()
        case .watercolor:
            subtitle = isWatercolorEnabled() ? "水彩晕染已开启" : "轻点开启水彩"
            active = isWatercolorEnabled()
        case .muralPainting:
            subtitle = isMuralPaintingEnabled() ? "壁画风格已开启" : "轻点开启壁画"
            active = isMuralPaintingEnabled()
        case .magicCrayon:
            subtitle = isMagicCrayonEnabled() ? "Crayon 已开启" : "轻点开启 Crayon"
            active = isMagicCrayonEnabled()
        case .magicSketch:
            subtitle = isMagicSketchEnabled() ? "Sketch 已开启" : "轻点开启 Sketch"
            active = isMagicSketchEnabled()
        case .cartoon3:
            subtitle = isCartoon3Enabled() ? "卡通3 已开启" : "轻点开启卡通3"
            active = isCartoon3Enabled()
        }
        cell.configure(title: item.title, subtitle: subtitle, isActive: active)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        CGSize(width: 168, height: 60)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        let item = EffectCategoryItem(rawValue: indexPath.item)!
        switch item {
        case .monochrome:
            let cell = collectionView.cellForItem(at: indexPath)
            presentMonochromePicker(from: cell)
        case .crayon:
            toggleCrayonEnabled()
        case .catFace:
            toggleCatFaceEnabled()
        case .thermal:
            toggleThermalEnabled()
        case .gongbi:
            toggleGongbiEnabled()
        case .oilPainting:
            toggleOilPaintingEnabled()
        case .watercolor:
            toggleWatercolorEnabled()
        case .muralPainting:
            toggleMuralPaintingEnabled()
        case .magicCrayon:
            toggleMagicCrayonEnabled()
        case .magicSketch:
            toggleMagicSketchEnabled()
        case .cartoon3:
            toggleCartoon3Enabled()
        }
    }
}
