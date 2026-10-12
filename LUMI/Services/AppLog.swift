import Foundation
import os

/// 统一日志出口。用 os.Logger，既能在 Xcode 控制台看，也能在 iPhone 上用「控制台」App 抓，
/// 便于排查真实的连接问题（而不是打印一堆无用信息）。
enum AppLog {
    private static let subsystem = "com.lumi.aicamera"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let videoInput = Logger(subsystem: subsystem, category: "video-input")
    static let network = Logger(subsystem: subsystem, category: "network-relay")
    static let pose = Logger(subsystem: subsystem, category: "pose-estimation")
    static let composition = Logger(subsystem: subsystem, category: "composition")
    static let photo = Logger(subsystem: subsystem, category: "photo-library")
    static let poseLibrary = Logger(subsystem: subsystem, category: "pose-library")
}
