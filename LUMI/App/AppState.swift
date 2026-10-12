import Foundation
import Combine
import SwiftUI

/// 底部主导航页签
enum AppTab: String, CaseIterable, Identifiable, Hashable {
    case home
    case monitor
    case pose
    case photos
    case tools

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "首页"
        case .monitor: return "监看"
        case .pose: return "姿势"
        case .photos: return "照片"
        case .tools: return "工具"
        }
    }

    var symbolName: String {
        switch self {
        case .home: return "rectangle.grid.2x2"
        case .monitor: return "rectangle.on.rectangle"
        case .pose: return "figure.walk.motion"
        case .photos: return "photo.stack"
        case .tools: return "squareshape.split.2x2"
        }
    }
}

/// 全局状态容器。
///
/// 所有 Store 都在这里集中创建，并由 `LUMIApp` 通过 environmentObject 注入，
/// 避免出现多处各自持有一份设置/收藏导致状态不同步。
final class AppState: ObservableObject {

    let settings: SettingsStore
    let favorites: FavoritesStore
    let poseLibrary: PoseLibrary
    let videoInput: VideoInputManager
    let photoLibrary: PhotoLibraryStore

    /// 当前选中的页签（首页卡片可以跳转到指定页签）
    @Published var selectedTab: AppTab = .home

    /// 是否需要从监看页自动跳到实时指导
    @Published var pendingCoachOpen = false

    init(settings: SettingsStore = SettingsStore(),
         favorites: FavoritesStore = FavoritesStore(),
         poseLibrary: PoseLibrary = PoseLibrary(),
         videoInput: VideoInputManager = VideoInputManager(),
         photoLibrary: PhotoLibraryStore = PhotoLibraryStore()) {
        self.settings = settings
        self.favorites = favorites
        self.poseLibrary = poseLibrary
        self.videoInput = videoInput
        self.photoLibrary = photoLibrary
    }

    /// 当前输入能力说明（供首页与设置页展示真实结论）
    var inputAvailabilitySummary: String {
        if VideoInputCapability.supportsExternalCamera {
            let count = videoInput.externalDeviceCount
            return count > 0
                ? "本机（iPad）支持外接 UVC 采集设备，已发现 \(count) 台。"
                : "本机（iPad）支持外接 UVC 采集设备，当前未检测到设备。"
        }
        return "本机为 iPhone：iOS 不枚举 UVC 外接摄像头，请使用「网络中继」模式。"
    }
}
