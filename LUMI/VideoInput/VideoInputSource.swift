import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import UIKit

/// 预览画面的来源。三种真实输入提供的预览能力不同，UI 据此选择渲染方式。
enum VideoPreviewProvider {
    /// AVCaptureSession（UVC 采集卡 / 内置摄像头）：用 AVCaptureVideoPreviewLayer，零拷贝、延迟最低
    case captureSession(AVCaptureSession)
    /// AVPlayer（HLS 中继）：用 AVPlayerLayer
    case player(AVPlayer)
    /// 帧图序列（MJPEG 中继）：由 SwiftUI 直接渲染解码出的 CGImage
    case imageFrames
}

/// 视频输入源统一接口。
///
/// 三路实现（UVC 直连 / 网络中继 / 内置摄像头）都符合这个协议，
/// 因此上层的监看、姿态分析、构图分析**完全不需要知道自己接的是哪种输入**。
protocol VideoInputSource: AnyObject {
    var kind: VideoInputKind { get }
    var delegate: VideoInputSourceDelegate? { get set }
    var deviceInfo: VideoInputDeviceInfo? { get }
    var stats: StreamStats { get }
    var previewProvider: VideoPreviewProvider { get }
    /// 最近一次解码出的帧（仅网络中继的 imageFrames 模式使用）
    var latestFrame: CGImage? { get }

    /// 启动。失败时抛出明确的 ``VideoInputFailure``。
    func start() throws
    func stop()
}

/// 输入源向管理器汇报的三件事：状态、设备信息、像素帧。
protocol VideoInputSourceDelegate: AnyObject {
    func videoInput(_ source: VideoInputSource, didChangeState state: VideoInputState)
    func videoInput(_ source: VideoInputSource, didUpdateDeviceInfo info: VideoInputDeviceInfo?)
    func videoInput(_ source: VideoInputSource,
                    didProducePixelBuffer pixelBuffer: CVPixelBuffer,
                    frameSize: CGSize,
                    orientation: CGImagePropertyOrientation,
                    timestamp: Double)
    func videoInput(_ source: VideoInputSource,
                    didProduceImage image: CGImage,
                    orientation: CGImagePropertyOrientation,
                    timestamp: Double)
}

extension VideoInputSourceDelegate {
    func videoInput(_ source: VideoInputSource, didProduceImage image: CGImage,
                    orientation: CGImagePropertyOrientation, timestamp: Double) {}
}

/// 设备能力判定。用于在用户真正尝试之前就给出结论，避免白折腾。
enum VideoInputCapability {

    /// 当前设备是否支持 UVC 外接摄像头
    ///
    /// 结论依据（已在文档中留证）：
    /// - Apple 文档与 WWDC 2023《Support external cameras in your iPadOS app》：
    ///   "iPads with USB-C connectors support external cameras"；
    /// - Apple DTS 工程师在开发者论坛明确：iPhone 15 Pro 不会枚举外接摄像头；
    /// - 因此 `AVCaptureDevice.DeviceType.external` 这个符号虽然在 iOS 17+ 存在，
    ///   但在 iPhone 上 DiscoverySession 永远不会返回设备。
    static var supportsExternalCamera: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    /// 面向用户的解释文案
    static var externalCameraUnavailableReason: String {
        if supportsExternalCamera {
            return "本机是 iPad，支持外接 UVC 采集设备。"
        }
        return """
        本机是 iPhone，不支持 UVC 外接摄像头。
        iPhone 上的 USB-C 只是接口形状，iOS 不会把 UVC 采集卡当作摄像头打开 —— \
        这一点由 Apple 官方确认（外接相机支持仅限 USB-C 的 iPad）。
        要在这台 iPhone 上实现真实监看，请使用「网络中继」模式：\
        Nikon Z6 II 的 HDMI 输出 → UVC 采集卡 → 电脑运行 LUMI 中继脚本 → 局域网 → 本 App。
        """
    }

    /// 该输入在当前设备上是否可用
    static func isAvailable(_ kind: VideoInputKind) -> Bool {
        switch kind {
        case .uvcExternal: return supportsExternalCamera
        case .networkRelay, .builtInCamera: return true
        }
    }
}

/// 采集格式选择的共用工具
enum CaptureFormatSelector {

    /// 在设备提供的格式里挑选最接近目标分辨率的格式，并给出原因说明。
    /// 说明：**只从设备真实上报的 formats 里选**，不会假设设备支持某个分辨率。
    static func selectFormat(for device: AVCaptureDevice,
                             preferredLongSide: CGFloat = 1920,
                             preferredMaxFPS: Double = 30) -> AVCaptureDevice.Format? {
        let candidates = device.formats
        guard !candidates.isEmpty else { return nil }

        var best: (format: AVCaptureDevice.Format, score: Double)?

        for format in candidates {
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let longSide = CGFloat(max(dimensions.width, dimensions.height))
            let fps = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30

            // 分辨率差异（越接近越优，权重高）
            let resolutionScore = -abs(longSide - preferredLongSide) / 1000.0
            // 帧率：不超过偏好上限时优先高帧率，超过则惩罚
            let fpsScore = fps <= preferredMaxFPS ? fps / 100.0 : (preferredMaxFPS / fps) - 1.0
            let score = resolutionScore * 2.0 + fpsScore

            if best == nil || score > best!.score {
                best = (format, score)
            }
        }

        return best?.format
    }

    /// 读取当前格式对应的设备信息（分辨率/帧率/像素格式），全部来自系统真实上报值。
    static func deviceInfo(for device: AVCaptureDevice,
                           kind: VideoInputKind) -> VideoInputDeviceInfo {
        let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let fps = device.activeVideoMinFrameDuration.isValid && device.activeVideoMinFrameDuration.seconds > 0
            ? 1.0 / device.activeVideoMinFrameDuration.seconds
            : (device.activeFormat.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0)

        return VideoInputDeviceInfo(kind: kind,
                                    name: device.localizedName,
                                    uniqueID: device.uniqueID,
                                    pixelWidth: Int(dimensions.width),
                                    pixelHeight: Int(dimensions.height),
                                    nominalFrameRate: fps,
                                    pixelFormat: fourCharCodeToString(CMFormatDescriptionGetMediaSubType(device.activeFormat.formatDescription)),
                                    isExternal: device.deviceType == .external)
    }

    static func fourCharCodeToString(_ code: FourCharCode) -> String? {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF)
        ]
        guard let string = String(bytes: bytes, encoding: .ascii) else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}
