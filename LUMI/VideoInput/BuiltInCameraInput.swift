import Foundation
import AVFoundation
import CoreGraphics
import CoreMedia
import ImageIO
import UIKit

/// iPhone / iPad 内置摄像头输入。
///
/// **定位说明（UI 上会显著标注）**
/// 这不是 Z6 II 的监看画面，而是「自测与备用」通道：
/// - 用它可以在一台只有 iPhone 的场合，**在真实视频帧上**验证姿势检测与构图分析是否工作；
/// - 日常也可以当作手持姿势指导工具使用。
///
/// 之所以保留这一路，是为了让 AI 功能在任何情况下都能被真实检验，
/// 而不是只能看一个「等待连接」的空界面。App 中不会用预设画面冒充它。
final class BuiltInCameraInput: NSObject, VideoInputSource {

    let kind: VideoInputKind = .builtInCamera
    weak var delegate: VideoInputSourceDelegate?

    private(set) var deviceInfo: VideoInputDeviceInfo?
    private(set) var stats = StreamStats()
    var latestFrame: CGImage? { nil }

    var previewProvider: VideoPreviewProvider { .captureSession(session) }

    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "com.lumi.builtin.session")
    private let outputQueue = DispatchQueue(label: "com.lumi.builtin.output", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    private var runtimeErrorObserver: NSObjectProtocol?
    private(set) var isRunning = false

    /// 使用的镜头位置：默认后置（拍摄中被摄者在前方，与相机的使用场景一致）
    var preferredPosition: AVCaptureDevice.Position = .back

    func start() throws {
        publish(state: .preparing)

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            try configureAndRun()
        case .notDetermined:
            // 同步等待权限结果，避免出现「已返回但会话尚未配置」的中间态
            let semaphore = DispatchSemaphore(value: 0)
            var granted = false
            AVCaptureDevice.requestAccess(for: .video) { result in
                granted = result
                semaphore.signal()
            }
            semaphore.wait()
            guard granted else {
                publish(state: .failed(.builtInCameraPermissionDenied))
                throw VideoInputFailure.builtInCameraPermissionDenied
            }
            try configureAndRun()
        default:
            publish(state: .failed(.builtInCameraPermissionDenied))
            throw VideoInputFailure.builtInCameraPermissionDenied
        }
    }

    func stop() {
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

    private func configureAndRun() throws {
        var device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: preferredPosition)
        if device == nil {
            device = AVCaptureDevice.default(for: .video)
        }
        guard let camera = device else {
            let failure = VideoInputFailure.configurationFailed("本机没有可用的摄像头设备")
            publish(state: .failed(failure))
            throw failure
        }

        try sessionQueue.sync {
            session.beginConfiguration()
            session.sessionPreset = .high

            for input in session.inputs {
                session.removeInput(input)
            }

            let input: AVCaptureDeviceInput
            do {
                input = try AVCaptureDeviceInput(device: camera)
            } catch {
                session.commitConfiguration()
                let failure = VideoInputFailure.cannotCreateDeviceInput(error.localizedDescription)
                DispatchQueue.main.async { self.publish(state: .failed(failure)) }
                throw failure
            }

            guard session.canAddInput(input) else {
                session.commitConfiguration()
                let failure = VideoInputFailure.cannotAddInputToSession("会话拒绝了内置摄像头的输入")
                DispatchQueue.main.async { self.publish(state: .failed(failure)) }
                throw failure
            }
            session.addInput(input)

            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            videoOutput.setSampleBufferDelegate(self, queue: outputQueue)

            if !session.outputs.contains(videoOutput) {
                guard session.canAddOutput(videoOutput) else {
                    session.commitConfiguration()
                    let failure = VideoInputFailure.cannotAddOutputToSession("会话拒绝了视频数据输出")
                    DispatchQueue.main.async { self.publish(state: .failed(failure)) }
                    throw failure
                }
                session.addOutput(videoOutput)
            }

            // 内置摄像头需要跟随设备方向旋转，否则横屏时画面会侧倒
            if let connection = videoOutput.connection(with: .video) {
                let angle = Self.rotationAngle(for: UIDevice.current.orientation)
                if connection.isVideoRotationAngleSupported(angle) {
                    connection.videoRotationAngle = angle
                }
            }

            session.commitConfiguration()

            let info = CaptureFormatSelector.deviceInfo(for: camera, kind: .builtInCamera)
            DispatchQueue.main.async {
                self.deviceInfo = info
                self.delegate?.videoInput(self, didUpdateDeviceInfo: info)
            }

            runtimeErrorObserver = NotificationCenter.default.addObserver(
                forName: AVCaptureSession.runtimeErrorNotification,
                object: session,
                queue: .main
            ) { [weak self] notification in
                guard let self else { return }
                let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
                self.publish(state: .failed(.sessionRuntimeError(error?.localizedDescription ?? "未知错误")))
            }

            session.startRunning()
            DispatchQueue.main.async {
                self.isRunning = true
                self.publish(state: .running)
            }
        }
    }

    /// 更新视频旋转角度（横竖屏切换时调用）
    func updateRotation(for orientation: UIDeviceOrientation) {
        let angle = Self.rotationAngle(for: orientation)
        sessionQueue.async { [weak self] in
            guard let self, let connection = self.videoOutput.connection(with: .video) else { return }
            if connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
        }
    }

    static func rotationAngle(for orientation: UIDeviceOrientation) -> CGFloat {
        switch orientation {
        case .portrait: return 90
        case .portraitUpsideDown: return 270
        case .landscapeLeft: return 180
        case .landscapeRight: return 0
        default: return 90
        }
    }

    private func publish(state: VideoInputState) {
        delegate?.videoInput(self, didChangeState: state)
    }
}

extension BuiltInCameraInput: AVCaptureVideoDataOutputSampleBufferDelegate {

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
