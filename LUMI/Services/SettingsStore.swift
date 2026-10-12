import Foundation
import Combine

/// 全局设置。持久化在 UserDefaults，全部本地存储，不上传。
final class SettingsStore: ObservableObject {

    private enum Keys {
        static let videoInputKind = "settings.videoInputKind"
        static let relay = "settings.relay"
        static let gravity = "settings.gravity"
        static let overlay = "settings.overlay"
        static let livePose = "settings.livePoseEnabled"
        static let liveComposition = "settings.liveCompositionEnabled"
        static let analysisFPS = "settings.analysisFPS"
        static let exposureMeter = "settings.exposureMeter"
        static let showConfidence = "settings.showConfidence"
        static let landscapeDefault = "settings.landscapeDefault"
        static let privacyAcknowledged = "settings.privacyAcknowledged"
        static let shootingNotes = "settings.shootingNotes"
        static let keepScreenAwake = "settings.keepScreenAwake"
        static let showFrameStats = "settings.showFrameStats"
        static let monitorZoom = "settings.monitorZoom"
    }

    private let defaults: UserDefaults

    // MARK: - 视频输入

    /// 当前选择的视频输入方式
    @Published var videoInputKind: VideoInputKind {
        didSet { defaults.set(videoInputKind.rawValue, forKey: Keys.videoInputKind) }
    }

    @Published var relay: RelayConfiguration {
        didSet { save(relay, key: Keys.relay) }
    }

    @Published var gravity: VideoGravityMode {
        didSet { defaults.set(gravity.rawValue, forKey: Keys.gravity) }
    }

    @Published var overlay: OverlayConfiguration {
        didSet { save(overlay, key: Keys.overlay) }
    }

    @Published var showsFrameStats: Bool {
        didSet { defaults.set(showsFrameStats, forKey: Keys.showFrameStats) }
    }

    /// 监看画面数字变焦（仅缩放预览图层，不改变相机光学参数）
    @Published var monitorZoom: CGFloat {
        didSet {
            let clamped = min(max(monitorZoom, 1.0), 5.0)
            if abs(clamped - monitorZoom) > 0.001 {
                monitorZoom = clamped
                return
            }
            defaults.set(Double(monitorZoom), forKey: Keys.monitorZoom)
        }
    }

    // MARK: - AI 功能开关（默认关闭以控制耗电）

    /// 实时姿势分析：默认关闭。开启后每帧都会跑 Vision 人体关键点检测，耗电明显上升。
    @Published var livePoseEnabled: Bool {
        didSet { defaults.set(livePoseEnabled, forKey: Keys.livePose) }
    }

    /// 实时构图分析：默认关闭。
    @Published var liveCompositionEnabled: Bool {
        didSet { defaults.set(liveCompositionEnabled, forKey: Keys.liveComposition) }
    }

    /// 分析帧率上限（1...15）。越高越耗电。
    @Published var analysisFPS: Int {
        didSet {
            let clamped = min(max(analysisFPS, 1), 15)
            if clamped != analysisFPS {
                analysisFPS = clamped
                return
            }
            defaults.set(analysisFPS, forKey: Keys.analysisFPS)
        }
    }

    /// 曝光辅助（亮度分布计量）：由画面像素真实计算，与相机测光无关
    @Published var liveExposureMeterEnabled: Bool {
        didSet { defaults.set(liveExposureMeterEnabled, forKey: Keys.exposureMeter) }
    }

    /// 是否显示置信度徽标（低置信度时 UI 会降级显示）
    @Published var showsConfidenceBadges: Bool {
        didSet { defaults.set(showsConfidenceBadges, forKey: Keys.showConfidence) }
    }

    // MARK: - 显示

    @Published var prefersLandscapeMonitor: Bool {
        didSet { defaults.set(prefersLandscapeMonitor, forKey: Keys.landscapeDefault) }
    }

    @Published var keepsScreenAwake: Bool {
        didSet { defaults.set(keepsScreenAwake, forKey: Keys.keepScreenAwake) }
    }

    // MARK: - 隐私

    /// 用户是否已确认隐私说明（首次启动展示）
    @Published var hasAcknowledgedPrivacy: Bool {
        didSet { defaults.set(hasAcknowledgedPrivacy, forKey: Keys.privacyAcknowledged) }
    }

    // MARK: - 拍摄备注

    @Published var shootingNotes: String {
        didSet { defaults.set(shootingNotes, forKey: Keys.shootingNotes) }
    }

    // MARK: - 初始化

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let kindRaw = defaults.string(forKey: Keys.videoInputKind) ?? ""
        self.videoInputKind = VideoInputKind(rawValue: kindRaw) ?? .networkRelay

        if let data = defaults.data(forKey: Keys.relay),
           let decoded = try? JSONDecoder().decode(RelayConfiguration.self, from: data) {
            self.relay = decoded
        } else {
            self.relay = .default
        }

        let gravityRaw = defaults.string(forKey: Keys.gravity) ?? ""
        self.gravity = VideoGravityMode(rawValue: gravityRaw) ?? .aspectFit

        if let data = defaults.data(forKey: Keys.overlay),
           let decoded = try? JSONDecoder().decode(OverlayConfiguration.self, from: data) {
            self.overlay = decoded
        } else {
            self.overlay = .default
        }

        self.livePoseEnabled = defaults.bool(forKey: Keys.livePose)
        self.liveCompositionEnabled = defaults.bool(forKey: Keys.liveComposition)
        let fps = defaults.integer(forKey: Keys.analysisFPS)
        self.analysisFPS = fps == 0 ? 8 : min(max(fps, 1), 15)
        self.liveExposureMeterEnabled = defaults.object(forKey: Keys.exposureMeter) as? Bool ?? true
        self.showsConfidenceBadges = defaults.object(forKey: Keys.showConfidence) as? Bool ?? true
        self.showsFrameStats = defaults.object(forKey: Keys.showFrameStats) as? Bool ?? true
        self.prefersLandscapeMonitor = defaults.bool(forKey: Keys.landscapeDefault)
        self.keepsScreenAwake = defaults.object(forKey: Keys.keepScreenAwake) as? Bool ?? true
        self.hasAcknowledgedPrivacy = defaults.bool(forKey: Keys.privacyAcknowledged)
        self.shootingNotes = defaults.string(forKey: Keys.shootingNotes) ?? ""
        let savedZoom = defaults.double(forKey: Keys.monitorZoom)
        self.monitorZoom = savedZoom >= 1.0 ? CGFloat(min(savedZoom, 5.0)) : 1.0
    }

    private func save<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        }
    }

    /// 供设置页「恢复默认」使用
    func resetOverlayAndDisplay() {
        overlay = .default
        gravity = .aspectFit
        showsFrameStats = true
    }
}
