import Combine
import Foundation
import os

/// 应用内可读、可导出的诊断日志。
///
/// **为什么需要它。** 项目原来的日志走 ``AppLog``（`os.Logger`）。os_log 的落盘内容
/// 只有在 macOS 上用「控制台」App 或 Xcode 才能查看 —— 而本项目的开发环境是 Windows、
/// 没有 Mac。一旦真机上出问题，使用者**没有任何办法把现场信息取出来**（App 内看不见、
/// 也没法复制发给别人）。所以这里维护一份应用内可见、可一键复制/导出的环形缓冲。
///
/// 数据边界（与 App 内的隐私说明一致）：
/// - 只存在于内存，最多 ``capacity`` 条，**不落盘、不上传**；
/// - 只记录诊断事件（连接状态、错误码、帧率、权限），**不记录任何影像内容或人脸数据**；
/// - 进程退出即清空。
///
/// 线程安全：采集线程、网络线程、分析线程都会写，所以内部用 `NSLock` 保护缓冲；
/// ``entries`` 是给 UI 用的主线程镜像，非主线程写入时会自动跳回主线程更新。
final class DiagnosticsLog: ObservableObject {

    /// 全局共享实例。App 各处直接用它记录。
    static let shared = DiagnosticsLog()

    // MARK: - 级别

    enum Level: String, CaseIterable, Codable, Identifiable, Hashable {
        case debug
        case info
        case warning
        case error

        var id: String { rawValue }

        var label: String {
            switch self {
            case .debug: return "调试"
            case .info: return "信息"
            case .warning: return "警告"
            case .error: return "错误"
            }
        }

        /// 数值权重，用于「只看某级别以上」的筛选与计数比较。
        /// 顺序固定为 debug < info < warning < error。
        var severity: Int {
            switch self {
            case .debug: return 0
            case .info: return 1
            case .warning: return 2
            case .error: return 3
            }
        }

        var symbolName: String {
            switch self {
            case .debug: return "ant"
            case .info: return "info.circle"
            case .warning: return "exclamationmark.triangle"
            case .error: return "xmark.octagon"
            }
        }
    }

    // MARK: - 分类

    /// 与 ``AppLog`` 的 category 一一对应，这样同一条记录会同时进内存与 os_log。
    enum Category: String, CaseIterable, Codable, Identifiable, Hashable {
        case app
        case videoInput
        case network
        case pose
        case composition
        case photo
        case poseLibrary
        case diagnostics

        var id: String { rawValue }

        var label: String {
            switch self {
            case .app: return "应用"
            case .videoInput: return "视频输入"
            case .network: return "网络中继"
            case .pose: return "姿态检测"
            case .composition: return "构图分析"
            case .photo: return "照片"
            case .poseLibrary: return "姿势库"
            case .diagnostics: return "诊断"
            }
        }
    }

    // MARK: - 条目

    struct Entry: Identifiable, Equatable {
        let id: UInt64
        let date: Date
        let level: Level
        let category: Category
        let message: String
    }

    // MARK: - 状态

    /// 给 UI 的主线程镜像。最新的一条在**数组末尾**。
    @Published private(set) var entries: [Entry] = []

    /// 环形缓冲上限。超出后丢弃最旧的条目。
    let capacity: Int

    private let lock = NSLock()
    private var buffer: [Entry] = []
    private var nextID: UInt64 = 1

    init(capacity: Int = 400) {
        self.capacity = max(1, capacity)
    }

    // MARK: - 写入

    func record(_ level: Level, _ category: Category, _ message: String) {
        lock.lock()
        let entry = Entry(id: nextID, date: Date(), level: level, category: category, message: message)
        nextID += 1
        buffer.append(entry)
        if buffer.count > capacity {
            buffer.removeFirst(buffer.count - capacity)
        }
        let snapshot = buffer
        lock.unlock()

        // 同一条记录同时进 os_log（Mac 上可用「控制台」查看）与内存缓冲。
        emitToOSLog(level, category, message)
        publish(snapshot)
    }

    func debug(_ category: Category, _ message: String) { record(.debug, category, message) }
    func info(_ category: Category, _ message: String) { record(.info, category, message) }
    func warning(_ category: Category, _ message: String) { record(.warning, category, message) }
    func error(_ category: Category, _ message: String) { record(.error, category, message) }

    /// 清空缓冲。
    ///
    /// 清空后会**再记一条**「用户清空了日志缓冲」，而不是留一个空列表 ——
    /// 否则诊断报告里无法区分「确实没发生过任何事」与「刚刚被人清掉了」。
    func clear() {
        lock.lock()
        buffer.removeAll(keepingCapacity: true)
        lock.unlock()
        record(.info, .diagnostics, "用户清空了日志缓冲")
    }

    // MARK: - 读取

    /// 线程安全的快照。非主线程（或测试）里应使用它，而不是 ``entries``。
    var snapshot: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    func count(of level: Level) -> Int {
        snapshot.reduce(0) { $0 + ($1.level == level ? 1 : 0) }
    }

    /// 过滤：只保留不低于 `minLevel` 的条目。
    func snapshot(minLevel: Level) -> [Entry] {
        snapshot.filter { $0.level.severity >= minLevel.severity }
    }

    // MARK: - 内部

    private func publish(_ snapshot: [Entry]) {
        if Thread.isMainThread {
            entries = snapshot
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.entries = snapshot
            }
        }
    }

    private func emitToOSLog(_ level: Level, _ category: Category, _ message: String) {
        let logger: Logger
        switch category {
        case .app: logger = AppLog.app
        case .videoInput: logger = AppLog.videoInput
        case .network: logger = AppLog.network
        case .pose: logger = AppLog.pose
        case .composition: logger = AppLog.composition
        case .photo: logger = AppLog.photo
        case .poseLibrary: logger = AppLog.poseLibrary
        case .diagnostics: logger = AppLog.app
        }

        switch level {
        case .debug: logger.debug("\(message, privacy: .public)")
        case .info: logger.info("\(message, privacy: .public)")
        case .warning: logger.warning("\(message, privacy: .public)")
        case .error: logger.error("\(message, privacy: .public)")
        }
    }
}

// MARK: - 时间格式化（纯函数，可单元测试）

extension DiagnosticsLog {

    /// `HH:mm:ss`。时区必须由调用方传入，否则测试不可复现。
    static func timestampString(_ date: Date, timeZone: TimeZone) -> String {
        let parts = components(date, timeZone: timeZone)
        return String(format: "%02d:%02d:%02d",
                      parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    }

    /// `yyyy-MM-dd HH:mm:ss`。
    static func fullTimestampString(_ date: Date, timeZone: TimeZone) -> String {
        let parts = components(date, timeZone: timeZone)
        return String(format: "%04d-%02d-%02d %02d:%02d:%02d",
                      parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
                      parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    }

    private static func components(_ date: Date, timeZone: TimeZone) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    }
}
