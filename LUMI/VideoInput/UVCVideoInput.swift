import Foundation
import AVFoundation
import CoreGraphics
import CoreMedia
import ImageIO

/// 外接 UVC 采集卡输入（HDMI 采集卡）。
///
/// **重要事实（务必阅读）**
/// - 这条路径在 **USB-C 的 iPad（iPadOS 17+）上是原生可用**的：系统会把采集卡枚举为
///   `AVCaptureDevice.DeviceType.external`，`AVCaptureSession` 可以直接取流，延迟最低（约 1-2 帧）。
/// - 在 **iPhone 上不可用**：iOS 不会枚举 UVC 摄像头。此处不会伪造任何画面，
///   而是返回明确的 ``VideoInputFailure/externalDeviceNotSupportedOnIPhone``，
///   UI 会显示原因与替代方案（网络中继）。
///
/// 相机端准备（Nikon Z6 II）：
/// 1. 用 mini-HDMI（Type C）线 + 采集卡，插到 iPad 的 USB-C；
/// 2. 相机菜单：HDMI 输出分辨率=自动、HDMI 输出显示尺寸=100%、HDMI 实时显示屏幕显示=关闭；
/// 3. 待机定时器设为不限，避免相机自休眠切断 HDMI；
/// 4. 建议使用带供电的 USB-C 集线器，保证采集卡供电充足。
final class UVCVideoInput: NSObject, VideoInputSource {

    let kind: VideoInputKind = .uvcExternal
    weak var delegate: VideoInputSourceDelegate?

    private(set) var deviceInfo: VideoInputDeviceInfo?
    private(set) var stats = StreamStats()

    var previewProvider: VideoPreviewProvider { .captureSession(session) }
    var latestFrame: CGImage? { nil }

    /// 暴露给预览图层的采集会话
    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "com.lumi.uvc.session")
    private let outputQueue = DispatchQueue(label: "com.lumi.uvc.output", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    private var currentDevice: AVCaptureDevice?
    private var connectionObservation: NSKeyValueObservation?
    private var runtimeErrorObserver: NSObjectProtocol?

    private(set) var isRunning = false

    // MARK: - 启动 / 停止

    func start() throws {
        guard VideoInputCapability.supportsExternalCamera else {
            publish(state: .unsupported(reason: VideoInputCapability.externalCameraUnavailableReason))
            throw VideoInputFailure.externalDeviceNotSupportedOnIPhone
        }

        let devices = Self.discoverExternalCameras()
        guard let device = devices.first else {
            publish(state: .failed(.noExternalDeviceFound))
            throw VideoInputFailure.noExternalDeviceFound
        }
        try configure(device: device)
    }

    func stop() {
        connectionObservation?.invalidate()
        connectionObservation = nil
        if let runtimeErrorObserver {
            NotificationCenter.default.removeObserver(runtimeErrorObserver)
            self.runtimeErrorObserver = nil
        }
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
        isRunning = false
        deviceInfo = nil
        delegate?.videoInput(self, didUpdateDeviceInfo: nil)
        publish(state: .idle)
    }

    /// 重新扫描外接设备（用户在 UI 上点「重新连接」时调用）
    func rescan() throws {
        stop()
        try start()
    }

    // MARK: - 设备发现

    /// 用官方 API 枚举外接 UVC 设备。返回空数组就说明系统确实没给到这个设备
    /// （在 iPhone 上永远为空，这是 Apple 的已知行为，不是本 App 的缺陷）。
    static func discoverExternalCameras() -> [AVCaptureDevice] {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external],
            mediaType: .video,
            position: .unspecified
        )
        return discoverySession.devices
    }

    /// 是否同时存在外接设备（供 UI 显示「已发现设备」徽标）
    static var hasConnectedExternalCamera: Bool {
        guard VideoInputCapability.supportsExternalCamera else { return false }
        return !discoverExternalCameras().isEmpty
    }

    // MARK: - 配置

    private func configure(device: AVCaptureDevice) throws {
        currentDevice = device
        publish(state: .preparing)

        // 监听设备被拔掉（官方推荐做法：KVO 观察 isConnected）
        connectionObservation = device.observe(\.isConnected, options: [.new]) { [weak self] _, change in
            guard let self, let connected = change.newValue, !connected else { return }
            DiagnosticsLog.shared.error(.videoInput, "外接采集设备已断开")
            self.publish(state: .failed(.sessionRuntimeError("外接采集设备已断开（可能被拔出或供电不足）")))
        }

        try sessionQueue.sync {
            session.beginConfiguration()
            // 外接设备用 inputPriority，让设备自己的格式决定行为，避免会话预设强制降级
            session.sessionPreset = .inputPriority

            // 移除旧输入
            for input in session.inputs {
                session.removeInput(input)
            }

            // 选择最接近 1080p / 30fps 的格式（只从设备真实上报的 formats 中选）
            // 说明：这里只设置 activeFormat，不强行改写帧率时长 ——
            // 部分 UVC 采集卡不支持锁定帧率时长，强行设置会抛出 Objective-C 异常（Swift 无法 catch）。
            if let format = CaptureFormatSelector.selectFormat(for: device) {
                do {
                    try device.lockForConfiguration()
                    device.activeFormat = format
                    device.unlockForConfiguration()
                } catch {
                    DiagnosticsLog.shared.error(.videoInput, "设置采集格式失败（将继续使用默认格式）: \(String(describing: error))")
                }
            }

            // 输入
            let input: AVCaptureDeviceInput
            do {
                input = try AVCaptureDeviceInput(device: device)
            } catch {
                session.commitConfiguration()
                let failure = VideoInputFailure.cannotCreateDeviceInput(error.localizedDescription)
                DispatchQueue.main.async { self.publish(state: .failed(failure)) }
                throw failure
            }

            guard session.canAddInput(input) else {
                session.commitConfiguration()
                let failure = VideoInputFailure.cannotAddInputToSession("会话拒绝了该设备的输入（canAddInput = false）")
                DispatchQueue.main.async { self.publish(state: .failed(failure)) }
                throw failure
            }
            session.addInput(input)

            // 输出：只取像素，不做任何编码/落盘，因此延迟最低
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            videoOutput.setSampleBufferDelegate(self, queue: outputQueue)

            if session.canAddOutput(videoOutput) {
                session.addOutput(videoOutput)
            } else if session.outputs.contains(videoOutput) {
                // 已经添加过，跳过
            } else {
                session.commitConfiguration()
                let failure = VideoInputFailure.cannotAddOutputToSession("会话拒绝了视频数据输出")
                DispatchQueue.main.async { self.publish(state: .failed(failure)) }
                throw failure
            }

            // 外接相机可以独立于设备旋转，这里统一用 0°（正装），由 UI 层做显示方向处理
            if let connection = videoOutput.connection(with: .video) {
                if connection.isVideoRotationAngleSupported(0) {
                    connection.videoRotationAngle = 0
                }
            }

            session.commitConfiguration()

            let info = CaptureFormatSelector.deviceInfo(for: device, kind: .uvcExternal)
            DispatchQueue.main.async {
                self.deviceInfo = info
                self.delegate?.videoInput(self, didUpdateDeviceInfo: info)
            }

            // 会话运行时错误（拔线、被系统抢占等）
            runtimeErrorObserver = NotificationCenter.default.addObserver(
                forName: AVCaptureSession.runtimeErrorNotification,
                object: session,
                queue: .main
            ) { [weak self] notification in
                guard let self else { return }
                let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
                let detail = error?.localizedDescription ?? "未知错误"
                // -11800/-11803 等在拔线时很常见，属于可恢复
                self.publish(state: .failed(.sessionRuntimeError(detail)))
            }

            session.startRunning()
            DispatchQueue.main.async {
                self.isRunning = true
                self.publish(state: .running)
            }
            DiagnosticsLog.shared.info(.videoInput, "UVC 采集已启动: \(info.name) \(info.resolutionText) @ \(info.frameRateText)")
        }
    }

    private func publish(state: VideoInputState) {
        delegate?.videoInput(self, didChangeState: state)
    }
}

// MARK: - 视频数据输出

extension UVCVideoInput: AVCaptureVideoDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let timestamp = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        let size = CGSize(width: CVPixelBufferGetWidth(pixelBuffer),
                          height: CVPixelBufferGetHeight(pixelBuffer))

        stats.totalFrames += 1
        stats.lastFrameAt = Date()

        delegate?.videoInput(self,
                             didProducePixelBuffer: pixelBuffer,
                             frameSize: size,
                             orientation: .up,
                             timestamp: timestamp)
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        stats.droppedFrames += 1
    }
}
