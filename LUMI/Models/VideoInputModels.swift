import Foundation
import CoreGraphics

// MARK: - 视频输入种类

/// 三种**真实**视频输入。没有任何一种是模拟画面。
enum VideoInputKind: String, CaseIterable, Codable, Identifiable, Hashable {
    /// 外接 UVC 采集卡（HDMI 采集卡）。原生最低延迟。
    /// 注意：**仅在 USB-C 的 iPad（iPadOS 17+）上可用**，iPhone 不支持。
    case uvcExternal
    /// 网络中继流（MJPEG / HLS）。iPhone 上唯一可行的实时监看路径。
    case networkRelay
    /// iPhone / iPad 内置摄像头。明确标注为「自测与备用」，不冒充相机监看。
    case builtInCamera

    var id: String { rawValue }

    var title: String {
        switch self {
        case .uvcExternal: return "外接 UVC 采集设备"
        case .networkRelay: return "网络中继流"
        case .builtInCamera: return "内置摄像头"
        }
    }

    var subtitle: String {
        switch self {
        case .uvcExternal: return "HDMI 采集卡直连 · 延迟最低 · 需 USB-C 的 iPad"
        case .networkRelay: return "相机 → 采集卡 → 电脑 → 局域网 → iPhone"
        case .builtInCamera: return "自测/备用，非相机监看"
        }
    }

    var symbolName: String {
        switch self {
        case .uvcExternal: return "cable.connector"
        case .networkRelay: return "wifi"
        case .builtInCamera: return "iphone.gen3.camera"
        }
    }

    /// 该输入是否在 iPhone 上可用（用于 UI 提前给出结论，而不是让用户白试）
    var isAvailableOnIPhone: Bool {
        switch self {
        case .uvcExternal: return false
        case .networkRelay, .builtInCamera: return true
        }
    }

    /// 该输入是否提供相机机身曝光参数（本项目三种输入都不提供，如实说明）
    var providesCameraExposureMetadata: Bool { false }
}

// MARK: - 连接状态

enum VideoInputState: Equatable {
    case idle
    case preparing
    case running
    /// 硬件/系统能力不支持（例如 iPhone 上的 UVC）
    case unsupported(reason: String)
    case failed(VideoInputFailure)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    var shortLabel: String {
        switch self {
        case .idle: return "未连接"
        case .preparing: return "连接中"
        case .running: return "监看中"
        case .unsupported: return "不支持"
        case .failed: return "异常"
        }
    }
}

// MARK: - 失败原因（全部可展示、可定位）

enum VideoInputFailure: Error, Equatable, Identifiable {
    /// iPhone 上使用 UVC 直连
    case externalDeviceNotSupportedOnIPhone
    case noExternalDeviceFound
    case builtInCameraPermissionDenied
    case cannotCreateDeviceInput(String)
    case cannotAddInputToSession(String)
    case cannotAddOutputToSession(String)
    case sessionRuntimeError(String)
    case invalidRelayURL(String)
    case networkUnreachable(String)
    case streamStalled(seconds: Double)
    case streamDecodeFailed(String)
    case configurationFailed(String)

    var id: String { code }

    var code: String {
        switch self {
        case .externalDeviceNotSupportedOnIPhone: return "V-001"
        case .noExternalDeviceFound: return "V-002"
        case .builtInCameraPermissionDenied: return "V-003"
        case .cannotCreateDeviceInput: return "V-010"
        case .cannotAddInputToSession: return "V-011"
        case .cannotAddOutputToSession: return "V-012"
        case .sessionRuntimeError: return "V-013"
        case .invalidRelayURL: return "V-020"
        case .networkUnreachable: return "V-021"
        case .streamStalled: return "V-022"
        case .streamDecodeFailed: return "V-023"
        case .configurationFailed: return "V-030"
        }
    }

    var message: String {
        switch self {
        case .externalDeviceNotSupportedOnIPhone:
            return "本机（iPhone）不支持 UVC 外接摄像头。"
        case .noExternalDeviceFound:
            return "没有检测到外接 UVC 采集设备。"
        case .builtInCameraPermissionDenied:
            return "未获得摄像头权限。"
        case .cannotCreateDeviceInput(let detail):
            return "无法创建视频输入：\(detail)"
        case .cannotAddInputToSession(let detail):
            return "无法把输入加入采集会话：\(detail)"
        case .cannotAddOutputToSession(let detail):
            return "无法建立视频数据输出：\(detail)"
        case .sessionRuntimeError(let detail):
            return "采集会话运行出错：\(detail)"
        case .invalidRelayURL(let raw):
            return "中继地址无效：\(raw)"
        case .networkUnreachable(let detail):
            return "无法连接中继服务：\(detail)"
        case .streamStalled(let seconds):
            return String(format: "视频流已停止约 %.0f 秒（画面不再更新）。", seconds)
        case .streamDecodeFailed(let detail):
            return "视频流解码失败：\(detail)"
        case .configurationFailed(let detail):
            return "配置失败：\(detail)"
        }
    }

    var recoverySuggestion: String {
        switch self {
        case .externalDeviceNotSupportedOnIPhone:
            return "iPhone 的 USB-C 只是接口形状，iOS 不会枚举 UVC 摄像头。请在 USB-C 的 iPad（iPadOS 17+）上使用此模式，或改用「网络中继」模式：相机 HDMI → 采集卡 → 电脑运行中继脚本 → iPhone 播放。"
        case .noExternalDeviceFound:
            return "请确认：① 采集卡是免驱 UVC 型号；② 用数据线而非充电线；③ 使用带供电的 USB-C 集线器；④ 相机已开机且关闭了 HDMI 显示信息。插好后点「重新扫描」。"
        case .builtInCameraPermissionDenied:
            return "请到「设置 → 隐私与安全性 → 相机」中允许 LUMI 使用摄像头。"
        case .cannotCreateDeviceInput, .cannotAddInputToSession, .cannotAddOutputToSession:
            return "请拔插一次采集卡后点「重新连接」。若仍失败，请在设置页导出诊断信息。"
        case .sessionRuntimeError:
            return "采集会话被系统中断（常见于拔线、来电、切换 App）。点「重新连接」恢复。"
        case .invalidRelayURL:
            return "地址格式应类似 http://192.168.1.10:8090/stream 。请检查 IP、端口与路径。"
        case .networkUnreachable:
            return "请确认手机与电脑在同一个 Wi-Fi；电脑防火墙已放行该端口；中继脚本仍在运行。"
        case .streamStalled:
            return "画面已停止更新。请检查中继脚本日志与 Wi-Fi 信号，然后点「重新连接」。"
        case .streamDecodeFailed:
            return "中继端编码参数可能不受支持。建议用 MJPEG 模式（脚本默认）而不是 HLS。"
        case .configurationFailed:
            return "请重试；若持续失败请提供日志。"
        }
    }
}

// MARK: - 设备信息

/// 输入设备的真实参数。只显示系统实际提供的值，不猜测。
struct VideoInputDeviceInfo: Equatable {
    var kind: VideoInputKind
    var name: String
    var uniqueID: String
    var pixelWidth: Int
    var pixelHeight: Int
    var nominalFrameRate: Double
    var pixelFormat: String?
    /// 是否为系统枚举到的外接设备（UVC 才有意义）
    var isExternal: Bool

    var resolutionText: String {
        guard pixelWidth > 0, pixelHeight > 0 else { return "未知" }
        return "\(pixelWidth)×\(pixelHeight)"
    }

    var frameRateText: String {
        guard nominalFrameRate > 0 else { return "未知" }
        return String(format: "%.2f fps", nominalFrameRate)
    }

    var connectionBadge: String {
        switch kind {
        case .uvcExternal: return "USB-C / UVC"
        case .networkRelay: return "局域网 HTTP"
        case .builtInCamera: return "本机摄像头"
        }
    }
}

// MARK: - 流统计（只统计真实到达的帧）

struct StreamStats: Equatable {
    var receivedFPS: Double = 0
    var totalFrames: Int = 0
    var droppedFrames: Int = 0
    var bytesPerSecond: Double = 0
    var lastFrameAt: Date?
    var decodeFailureCount: Int = 0

    var lastFrameAge: Double? {
        guard let last = lastFrameAt else { return nil }
        return Date().timeIntervalSince(last)
    }
}

// MARK: - 系统中继的播放模式

enum RelayMode: String, CaseIterable, Codable, Identifiable, Hashable {
    /// MJPEG over HTTP：低延迟（局域网约 150-400ms），带宽较高
    case mjpeg
    /// HLS：延迟高（1-3s 起），带宽低，仅在网络受限时使用
    case hls

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mjpeg: return "MJPEG（低延迟，推荐）"
        case .hls: return "HLS（低带宽，延迟高）"
        }
    }

    var latencyHint: String {
        switch self {
        case .mjpeg: return "局域网实测约 150–400 ms"
        case .hls: return "通常 1–3 s 以上"
        }
    }
}

// MARK: - 中继预设

struct RelayConfiguration: Codable, Equatable {
    var host: String = "192.168.1.100"
    var port: Int = 8090
    var path: String = "/stream"
    var mode: RelayMode = .mjpeg

    var url: URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host.trimmingCharacters(in: .whitespaces)
        components.port = port
        components.path = path.hasPrefix("/") ? path : "/" + path
        return components.url
    }

    var displayURL: String {
        url?.absoluteString ?? "http://\(host):\(port)\(path)"
    }

    static let `default` = RelayConfiguration()
}

// MARK: - 画面适配方式

enum VideoGravityMode: String, CaseIterable, Codable, Identifiable, Hashable {
    case aspectFit
    case aspectFill

    var id: String { rawValue }

    var title: String {
        switch self {
        case .aspectFit: return "完整适配（留黑边）"
        case .aspectFill: return "铺满（裁切边缘）"
        }
    }
}

// MARK: - 构图参考线配置

enum CaptureAspect: String, CaseIterable, Codable, Identifiable, Hashable {
    case native
    case square
    case fourThree
    case threeTwo
    case sixteenNine
    case nineSixteen

    var id: String { rawValue }

    var title: String {
        switch self {
        case .native: return "原始"
        case .square: return "1:1"
        case .fourThree: return "4:3"
        case .threeTwo: return "3:2"
        case .sixteenNine: return "16:9"
        case .nineSixteen: return "9:16 竖构图"
        }
    }

    /// 宽 / 高。nil 表示跟随输入原始比例。
    var ratio: CGFloat? {
        switch self {
        case .native: return nil
        case .square: return 1
        case .fourThree: return 4.0 / 3.0
        case .threeTwo: return 3.0 / 2.0
        case .sixteenNine: return 16.0 / 9.0
        case .nineSixteen: return 9.0 / 16.0
        }
    }
}

/// 监看页面的参考线配置（全部可独立开关）
struct OverlayConfiguration: Codable, Equatable {
    var showThirds = true
    var showNineGrid = false
    var showCenterCross = false
    var showCenterLines = false
    var showHorizon = false
    var showSafeArea = false
    /// 安全区比例（相对画面短边）
    var safeAreaInset: Double = 0.05
    var aspect: CaptureAspect = .native
    var showsSubjectBox = false

    static let `default` = OverlayConfiguration()
}
