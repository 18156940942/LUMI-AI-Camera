import Foundation
import Combine
import SwiftUI

/// 监看页的视图模型。
///
/// 只负责 UI 交互状态与「把设置正确地传给 VideoInputManager」，
/// 不做任何业务判定 —— 视频是否真的在跑，以 ``VideoInputManager`` 的真实状态为准。
final class MonitorViewModel: ObservableObject {

    /// 数字变焦由 ``SettingsStore/monitorZoom`` 统一持有，这里只做校验工具
    static func clampZoom(_ value: CGFloat) -> CGFloat {
        min(max(value, 1.0), 5.0)
    }

    /// 当前展开的控制面板
    @Published var activePanel: MonitorPanel = .analysis

    /// 中继地址编辑缓冲（点「应用」才生效，避免边输边重连）
    @Published var relayDraft = RelayConfiguration()
    @Published var relayDraftError: String?

    /// 是否忽略当前错误提示（用户点掉之后）
    @Published var dismissedFailure: VideoInputFailure?

    @Published var showsFullscreen = false

    enum MonitorPanel: String, CaseIterable, Identifiable {
        case input
        case overlay
        case analysis
        case info

        var id: String { rawValue }

        var title: String {
            switch self {
            case .input: return "输入"
            case .overlay: return "参考线"
            case .analysis: return "AI 分析"
            case .info: return "信息"
            }
        }

        var symbol: String {
            switch self {
            case .input: return "cable.connector"
            case .overlay: return "grid"
            case .analysis: return "brain"
            case .info: return "info.circle"
            }
        }
    }

    // MARK: - 与设置同步

    func syncRelayDraft(from settings: SettingsStore) {
        relayDraft = settings.relay
        relayDraftError = nil
    }

    /// 校验中继地址（在真正连接之前就拦住明显错误）
    func validateRelayDraft() -> RelayConfiguration? {
        let host = relayDraft.host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else {
            relayDraftError = "请填写电脑的局域网 IP，例如 192.168.1.10"
            return nil
        }
        guard relayDraft.port > 0, relayDraft.port <= 65535 else {
            relayDraftError = "端口需要在 1-65535 之间"
            return nil
        }
        guard relayDraft.url != nil else {
            relayDraftError = "地址格式不正确"
            return nil
        }
        relayDraftError = nil
        return relayDraft
    }

    // MARK: - 启动 / 停止

    func start(settings: SettingsStore, manager: VideoInputManager) {
        manager.start(kind: settings.videoInputKind,
                      relay: settings.relay,
                      analysisFPS: settings.analysisFPS,
                      poseAnalysisEnabled: settings.livePoseEnabled,
                      compositionAnalysisEnabled: settings.liveCompositionEnabled,
                      exposureMeterEnabled: settings.liveExposureMeterEnabled)
        dismissedFailure = nil
    }

    func stop(manager: VideoInputManager) {
        manager.stop()
    }

    /// 设置变化后热更新分析参数（不需要重连视频源）
    func applyAnalysisChanges(settings: SettingsStore, manager: VideoInputManager) {
        manager.updateAnalysisOptions(analysisFPS: settings.analysisFPS,
                                      poseAnalysisEnabled: settings.livePoseEnabled,
                                      compositionAnalysisEnabled: settings.liveCompositionEnabled,
                                      exposureMeterEnabled: settings.liveExposureMeterEnabled)
    }

    /// 是否需要「重新连接」按钮
    var shouldOfferReconnect: Bool {
        true
    }
}
