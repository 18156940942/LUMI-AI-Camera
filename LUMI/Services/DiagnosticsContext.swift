import AVFoundation
import CoreGraphics
import Foundation
import Photos
import UIKit

// MARK: - 环境快照

/// 一次性采集的运行环境信息。
///
/// 拆成「``Inputs``（外部依赖）+ ``assemble(_:)``（纯函数）」两段，是为了让装配逻辑
/// 可以完整单元测试 —— 项目里所有能用断言守住的逻辑都写了测试，这里不例外。
/// ``measure()`` 只是把真实系统值填进 `Inputs` 的薄封装。
struct DiagnosticsEnvironment: Equatable {

    /// 纯装配输入。默认值让它可以按需只覆盖关心的字段。
    struct Inputs {
        var appVersion: String?
        var buildNumber: String?
        var bundleIdentifier: String?
        var systemName: String = ""
        var systemVersion: String = ""
        var idiom: UIUserInterfaceIdiom = .phone
        var machine: String = ""
        var localeIdentifier: String = ""
        var timeZoneIdentifier: String = ""
        var screenDescription: String = ""
        var freeDiskBytes: Int64?
        var totalDiskBytes: Int64?
        var thermalState: ProcessInfo.ThermalState = .nominal
        var lowPowerMode: Bool = false
        var supportsExternalCamera: Bool = false
        var cpuCoreCount: Int = 0
        var physicalMemoryBytes: UInt64 = 0
        var processUptime: TimeInterval = 0
    }

    var appVersion: String = "未知"
    var buildNumber: String = "未知"
    var bundleIdentifier: String = "未知"
    var systemName: String = "未知"
    var systemVersion: String = "未知"
    var deviceIdiom: String = "未知"
    var deviceMachine: String = "未知"
    var localeIdentifier: String = "未知"
    var timeZoneIdentifier: String = "未知"
    var screenDescription: String = "未知"
    var freeDiskText: String = "未知"
    var totalDiskText: String = "未知"
    var thermalStateText: String = "未知"
    var lowPowerModeText: String = "未知"
    var externalCameraText: String = "未知"
    var cpuCoreCount: Int = 0
    var physicalMemoryText: String = "未知"
    var processUptimeText: String = "未知"

    /// 供 UI 逐行展示、供报告逐行输出的统一数据源（避免两处各写一遍文案）。
    var rows: [(label: String, value: String)] {
        [
            ("App 版本", "\(appVersion)（\(buildNumber)）"),
            ("Bundle ID", bundleIdentifier),
            ("系统", "\(systemName) \(systemVersion)"),
            ("设备", "\(deviceIdiom) · \(deviceMachine)"),
            ("CPU 核心", cpuCoreCount > 0 ? "\(cpuCoreCount) 核" : "未知"),
            ("物理内存", physicalMemoryText),
            ("屏幕", screenDescription),
            ("可用 / 总存储", "\(freeDiskText) / \(totalDiskText)"),
            ("区域 / 时区", "\(localeIdentifier) · \(timeZoneIdentifier)"),
            ("热状态", thermalStateText),
            ("低电量模式", lowPowerModeText),
            ("UVC 外接能力", externalCameraText),
            ("本次运行时长", processUptimeText)
        ]
    }

    // MARK: 装配

    static func assemble(_ inputs: Inputs) -> DiagnosticsEnvironment {
        var env = DiagnosticsEnvironment()
        env.appVersion = nonEmpty(inputs.appVersion, fallback: "未知")
        env.buildNumber = nonEmpty(inputs.buildNumber, fallback: "未知")
        env.bundleIdentifier = nonEmpty(inputs.bundleIdentifier, fallback: "未知")
        env.systemName = nonEmpty(inputs.systemName, fallback: "未知")
        env.systemVersion = nonEmpty(inputs.systemVersion, fallback: "未知")
        env.deviceIdiom = idiomLabel(inputs.idiom)
        env.deviceMachine = nonEmpty(inputs.machine, fallback: "未知")
        env.localeIdentifier = nonEmpty(inputs.localeIdentifier, fallback: "未知")
        env.timeZoneIdentifier = nonEmpty(inputs.timeZoneIdentifier, fallback: "未知")
        env.screenDescription = nonEmpty(inputs.screenDescription, fallback: "未知")
        env.freeDiskText = inputs.freeDiskBytes.map(formatBytes) ?? "未知"
        env.totalDiskText = inputs.totalDiskBytes.map(formatBytes) ?? "未知"
        env.thermalStateText = thermalStateLabel(inputs.thermalState)
        env.lowPowerModeText = inputs.lowPowerMode ? "已开启（系统会限制性能）" : "关闭"
        env.externalCameraText = inputs.supportsExternalCamera ? "支持（iPad）" : "不支持（iPhone）"
        env.cpuCoreCount = max(0, inputs.cpuCoreCount)
        env.physicalMemoryText = inputs.physicalMemoryBytes > 0
            ? formatBytes(Int64(clamping: inputs.physicalMemoryBytes))
            : "未知"
        env.processUptimeText = formatDuration(inputs.processUptime)
        return env
    }

    /// 采集当前真实环境。任何一项取不到就显示「未知」，**不猜、不补零**。
    static func measure() -> DiagnosticsEnvironment {
        let bundle = Bundle.main
        let processInfo = ProcessInfo.processInfo
        let fileManager = FileManager.default
        let attributes = try? fileManager.attributesOfFileSystem(forPath: NSHomeDirectory())

        var inputs = Inputs()
        inputs.appVersion = bundle.infoDictionary?["CFBundleShortVersionString"] as? String
        inputs.buildNumber = bundle.infoDictionary?["CFBundleVersion"] as? String
        inputs.bundleIdentifier = bundle.bundleIdentifier
        inputs.systemName = UIDevice.current.systemName
        inputs.systemVersion = UIDevice.current.systemVersion
        inputs.idiom = UIDevice.current.userInterfaceIdiom
        inputs.machine = machineIdentifier()
        inputs.localeIdentifier = Locale.current.identifier
        inputs.timeZoneIdentifier = TimeZone.current.identifier
        inputs.screenDescription = screenDescription()
        inputs.freeDiskBytes = (attributes?[.systemFreeSize] as? NSNumber)?.int64Value
        inputs.totalDiskBytes = (attributes?[.systemSize] as? NSNumber)?.int64Value
        inputs.thermalState = processInfo.thermalState
        inputs.lowPowerMode = processInfo.isLowPowerModeEnabled
        inputs.supportsExternalCamera = VideoInputCapability.supportsExternalCamera
        inputs.cpuCoreCount = processInfo.processorCount
        inputs.physicalMemoryBytes = processInfo.physicalMemory
        inputs.processUptime = processInfo.systemUptime
        return assemble(inputs)
    }

    // MARK: 纯格式化工具

    /// 空串与 nil 一律归一化为「未知」。系统没给值时**不能编一个看上去合理的值**。
    static func nonEmpty(_ value: String?, fallback: String) -> String {
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return fallback }
        return value
    }

    /// 人类可读字节数，1024 进制（与 iOS「关于本机」一致）。
    /// 负数（取不到时会出现）一律显示「未知」，不显示负值。
    static func formatBytes(_ bytes: Int64) -> String {
        guard bytes >= 0 else { return "未知" }
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        if index == 0 { return "\(bytes) B" }
        // 刻意不用 `String(format: "%.1f %@", …)`：避免依赖 String → CVarArg 的桥接细节，
        // 拼接版本在任何平台上行为一致。
        return String(format: "%.1f", value) + " " + units[index]
    }

    /// 时长。按「秒 / 分 秒 / 小时 分 秒」三档，避免出现 `0 小时 3 分` 这种空档。
    static func formatDuration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "未知" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 { return "\(hours) 小时 \(minutes) 分 \(secs) 秒" }
        if minutes > 0 { return "\(minutes) 分 \(secs) 秒" }
        return "\(secs) 秒"
    }

    /// 热状态。真机长时间做实时姿态分析时，这一项会直接反映系统是否开始降频。
    static func thermalStateLabel(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "正常"
        case .fair: return "偏高"
        case .serious: return "较高（可能已降频）"
        case .critical: return "严重（系统正在强制降频）"
        @unknown default: return "未知"
        }
    }

    static func idiomLabel(_ idiom: UIUserInterfaceIdiom) -> String {
        switch idiom {
        case .phone: return "iPhone"
        case .pad: return "iPad"
        case .mac: return "Mac"
        case .tv: return "Apple TV"
        case .carPlay: return "CarPlay"
        case .vision: return "Apple Vision"
        case .unspecified: return "未指定"
        @unknown default: return "未知"
        }
    }

    // MARK: 私有采集

    private static func machineIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 64) { cString in
                String(cString: cString)
            }
        }
    }

    private static func screenDescription() -> String {
        guard let screen = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first?.screen else {
            return ""
        }
        let size = screen.bounds.size
        return "\(Int(size.width))×\(Int(size.height)) pt @\(String(format: "%.0f", screen.scale))x"
    }
}

// MARK: - 权限快照

/// 权限状态。只报告系统真实返回值，不做任何推测。
///
/// 注意一个诚实的空缺：**iOS 没有提供「本地网络」权限的查询 API**，
/// 所以这一项只能说明「无法查询」，不能写成「已授权」。
struct DiagnosticsPermissions: Equatable {

    var camera: String = "未知"
    var photoLibrary: String = "未知"
    var photoAddOnly: String = "未知"
    var localNetwork: String = "iOS 未提供查询接口"

    var rows: [(label: String, value: String)] {
        [
            ("摄像头（视频输入）", camera),
            ("照片库（读取）", photoLibrary),
            ("照片库（仅新增）", photoAddOnly),
            ("本地网络", localNetwork)
        ]
    }

    static func measure() -> DiagnosticsPermissions {
        var permissions = DiagnosticsPermissions()
        permissions.camera = cameraLabel(AVCaptureDevice.authorizationStatus(for: .video))
        permissions.photoLibrary = photoLabel(PHPhotoLibrary.authorizationStatus(for: .readWrite))
        permissions.photoAddOnly = photoLabel(PHPhotoLibrary.authorizationStatus(for: .addOnly))
        return permissions
    }

    static func cameraLabel(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "已授权"
        case .denied: return "已拒绝（需到「设置 → 隐私与安全性 → 相机」手动开启）"
        case .restricted: return "受限（家长控制或企业策略）"
        case .notDetermined: return "尚未询问（首次使用时会弹窗）"
        @unknown default: return "未知状态"
        }
    }

    static func photoLabel(_ status: PHAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "已授权（完整访问）"
        case .limited: return "有限访问（只能看到你选中的照片）"
        case .denied: return "已拒绝"
        case .restricted: return "受限（家长控制或企业策略）"
        case .notDetermined: return "尚未询问"
        @unknown default: return "未知状态"
        }
    }
}
