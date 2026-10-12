import Foundation
import AVFoundation
import Combine
import CoreGraphics
import ImageIO

/// 视频输入总控。
///
/// 唯一负责三件事：
/// 1. 按用户选择创建/销毁对应的 ``VideoInputSource``；
/// 2. 把源的像素帧转发给 ``FrameAnalysisPipeline``（渲染与分析解耦）；
/// 3. 把状态、设备信息、实测帧率发布给 UI。
///
/// **不会**在没有真实输入的情况下伪造任何状态：`state` 与 `deviceInfo` 永远反映真实情况。
final class VideoInputManager: NSObject, ObservableObject {

    // MARK: - 对 UI 发布的状态

    @Published private(set) var state: VideoInputState = .idle
    @Published private(set) var deviceInfo: VideoInputDeviceInfo?
    @Published private(set) var stats = StreamStats()
    @Published private(set) var previewProvider: VideoPreviewProvider?
    @Published private(set) var lastFrameImage: CGImage?
    /// 实测到达帧率（由真实帧时间戳计算，非设备声明值）
    @Published private(set) var measuredFPS: Double = 0
    @Published private(set) var pipelineDiagnostics = FrameAnalysisPipeline.Diagnostics()
    /// 当前是否发现外接 UVC 设备（用于在首页显示「已发现设备」）
    @Published private(set) var externalDeviceCount: Int = 0
    /// 能力提示：例如在 iPhone 上选择 UVC 直连时的解释
    @Published private(set) var capabilityNotice: String?

    // MARK: - 分析结果（由管线回调更新）

    @Published private(set) var bodyPose: BodyPose = .empty
    @Published private(set) var poseReport: PoseReport = .empty
    @Published private(set) var compositionReport: CompositionReport = .empty
    /// 最近一次分析的时间，用于 UI 显示「距今多久」
    @Published private(set) var lastAnalysisDate: Date?
    /// 曝光辅助：由画面像素真实计算的亮度分布（**不是相机测光值**）
    @Published private(set) var exposureMetrics: ImageQualityMetrics?

    // MARK: - 内部

    let pipeline = FrameAnalysisPipeline()
    private var source: VideoInputSource?
    private(set) var currentKind: VideoInputKind?

    /// 帧率统计（滚动窗口，只统计真实到达的帧）
    private let fpsLock = NSLock()
    private var frameTimestamps: [Double] = []

    override init() {
        super.init()
        pipeline.onPoseResult = { [weak self] pose, report in
            guard let self else { return }
            self.bodyPose = pose
            self.poseReport = report
            self.lastAnalysisDate = Date()
        }
        pipeline.onCompositionResult = { [weak self] report in
            guard let self else { return }
            self.compositionReport = report
            self.lastAnalysisDate = Date()
        }
        pipeline.onDiagnostics = { [weak self] diagnostics in
            self?.pipelineDiagnostics = diagnostics
        }
        pipeline.onExposureMetrics = { [weak self] metrics in
            self?.exposureMetrics = metrics
        }
        refreshExternalDeviceCount()
    }

    // MARK: - 生命周期

    /// 启动指定输入
    func start(kind: VideoInputKind,
               relay: RelayConfiguration,
               analysisFPS: Int,
               poseAnalysisEnabled: Bool,
               compositionAnalysisEnabled: Bool,
               exposureMeterEnabled: Bool = true) {
        stop()

        pipeline.update(options: FrameAnalysisPipeline.Options(
            poseEnabled: poseAnalysisEnabled,
            compositionEnabled: compositionAnalysisEnabled,
            exposureMeterEnabled: exposureMeterEnabled,
            maxFPS: max(1, min(analysisFPS, 15))
        ))
        pipeline.reset()

        currentKind = kind
        capabilityNotice = nil

        // 在 iPhone 上选择 UVC 时，提前给出准确解释（而不是等失败）
        if kind == .uvcExternal && !VideoInputCapability.supportsExternalCamera {
            let failure = VideoInputFailure.externalDeviceNotSupportedOnIPhone
            capabilityNotice = failure.message + " " + failure.recoverySuggestion
            state = .unsupported(reason: VideoInputCapability.externalCameraUnavailableReason)
            previewProvider = nil
            deviceInfo = nil
            return
        }

        let newSource: VideoInputSource
        switch kind {
        case .uvcExternal:
            newSource = UVCVideoInput()
        case .networkRelay:
            let network = NetworkVideoInput(configuration: relay)
            network.maxDecodeFPS = 20
            newSource = network
        case .builtInCamera:
            newSource = BuiltInCameraInput()
        }

        newSource.delegate = self
        source = newSource
        // 预览通道在建源时就可以给出（captureSession / player 都已存在）
        previewProvider = newSource.previewProvider

        do {
            try newSource.start()
        } catch let failure as VideoInputFailure {
            state = .failed(failure)
            capabilityNotice = failure.message + " " + failure.recoverySuggestion
            AppLog.videoInput.error("启动视频输入失败 [\(failure.code, privacy: .public)]: \(failure.message, privacy: .public)")
        } catch {
            let failure = VideoInputFailure.configurationFailed(error.localizedDescription)
            state = .failed(failure)
            capabilityNotice = failure.message
            AppLog.videoInput.error("启动视频输入失败: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stop() {
        source?.stop()
        source = nil
        currentKind = nil
        previewProvider = nil
        lastFrameImage = nil
        deviceInfo = nil
        state = .idle
        measuredFPS = 0
        stats = StreamStats()
        resetFrameMeter()
    }

    /// 重新连接（拔插采集卡、改中继地址、网络抖动后使用）
    func reconnect(kind: VideoInputKind,
                   relay: RelayConfiguration,
                   analysisFPS: Int,
                   poseAnalysisEnabled: Bool,
                   compositionAnalysisEnabled: Bool,
                   exposureMeterEnabled: Bool = true) {
        start(kind: kind,
              relay: relay,
              analysisFPS: analysisFPS,
              poseAnalysisEnabled: poseAnalysisEnabled,
              compositionAnalysisEnabled: compositionAnalysisEnabled,
              exposureMeterEnabled: exposureMeterEnabled)
    }

    /// 分析开关变化时热更新（不需要重连视频源）
    func updateAnalysisOptions(analysisFPS: Int,
                               poseAnalysisEnabled: Bool,
                               compositionAnalysisEnabled: Bool,
                               exposureMeterEnabled: Bool = true) {
        pipeline.update(options: FrameAnalysisPipeline.Options(
            poseEnabled: poseAnalysisEnabled,
            compositionEnabled: compositionAnalysisEnabled,
            exposureMeterEnabled: exposureMeterEnabled,
            maxFPS: max(1, min(analysisFPS, 15))
        ))
        if !poseAnalysisEnabled {
            bodyPose = .empty
            poseReport = .empty
        }
        if !compositionAnalysisEnabled {
            compositionReport = .empty
        }
        if !exposureMeterEnabled {
            exposureMetrics = nil
        }
    }

    /// 扫描外接 UVC 设备（在 iPad 上有效；iPhone 上恒为 0）
    func refreshExternalDeviceCount() {
        guard VideoInputCapability.supportsExternalCamera else {
            externalDeviceCount = 0
            return
        }
        externalDeviceCount = UVCVideoInput.discoverExternalCameras().count
    }

    // MARK: - 帧率统计

    private func recordFrame(timestamp: Double) {
        fpsLock.lock()
        frameTimestamps.append(timestamp)
        if frameTimestamps.count > 40 {
            frameTimestamps.removeFirst(frameTimestamps.count - 40)
        }
        let snapshot = frameTimestamps
        fpsLock.unlock()

        guard snapshot.count >= 2, let first = snapshot.first, let last = snapshot.last, last > first else {
            measuredFPS = 0
            return
        }
        measuredFPS = Double(snapshot.count - 1) / (last - first)
    }

    private func resetFrameMeter() {
        fpsLock.lock()
        frameTimestamps.removeAll()
        fpsLock.unlock()
    }
}

// MARK: - VideoInputSourceDelegate

extension VideoInputManager: VideoInputSourceDelegate {

    func videoInput(_ source: VideoInputSource, didChangeState state: VideoInputState) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.source === source else { return }
            self.state = state
            if case .failed(let failure) = state {
                self.capabilityNotice = failure.message + "\n" + failure.recoverySuggestion
            }
        }
    }

    func videoInput(_ source: VideoInputSource, didUpdateDeviceInfo info: VideoInputDeviceInfo?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.source === source else { return }
            self.deviceInfo = info
        }
    }

    func videoInput(_ source: VideoInputSource,
                    didProducePixelBuffer pixelBuffer: CVPixelBuffer,
                    frameSize: CGSize,
                    orientation: CGImagePropertyOrientation,
                    timestamp: Double) {
        // 在采集线程上直接喂给分析管线（内部有节流与自己的队列），不阻塞视频输出
        pipeline.submit(pixelBuffer: pixelBuffer,
                        frameSize: frameSize,
                        orientation: orientation,
                        timestamp: timestamp)

        DispatchQueue.main.async { [weak self] in
            guard let self, self.source === source else { return }
            self.recordFrame(timestamp: timestamp > 0 ? timestamp : Date().timeIntervalSince1970)
            self.stats = source.stats
        }
    }

    func videoInput(_ source: VideoInputSource,
                    didProduceImage image: CGImage,
                    orientation: CGImagePropertyOrientation,
                    timestamp: Double) {
        let size = CGSize(width: image.width, height: image.height)
        pipeline.submit(cgImage: image, frameSize: size, orientation: orientation, timestamp: timestamp)

        DispatchQueue.main.async { [weak self] in
            guard let self, self.source === source else { return }
            self.lastFrameImage = image
            self.recordFrame(timestamp: timestamp > 0 ? timestamp : Date().timeIntervalSince1970)
            self.stats = source.stats
        }
    }
}
