import SwiftUI

/// 根视图：首次启动的隐私说明门槛 + 五个页签。
///
/// 关于页签数量：iOS 在超过 5 个页签时会自动折叠成「更多」，
/// 因此这里固定 5 个页签，「设置」通过首页卡片 / 各页工具栏进入。
///
/// ## 关于首次启动门槛的写法（**改动前请先读完**）
///
/// 最初用的是 `.fullScreenCover(isPresented:)` 包一层全屏页，条件读
/// `app.settings.hasAcknowledgedPrivacy`。真机首跑时点击「我已了解，进入 LUMI」
/// **没有任何反应**，两个原因叠加：
///
/// 1. **观察链断裂**：`AppState` 把各 Store 作为普通 `let` 持有，子 Store 变化时
///    `AppState` 不会转发 `objectWillChange`。所以只订阅 `AppState` 的视图，
///    在子 Store 变化后不会被重算 —— 值改成了 `true`，但 `body` 不重算、
///    Binding 的 `get` 不重读，全屏页一直盖着。
///    （这一类问题现在由 `scripts/check_observation.py` 静态守住。）
/// 2. **模态展示状态可能和真相脱节**：即使订阅对了，
///    「由 Binding 驱动的模态页」本身也比「普通条件分支」更容易出现状态不一致，
///    尤其在 `interactiveDismissDisabled` 参与时。
///
/// 所以这里改成**直接条件渲染**。理由：
///
/// - 这道门槛一旦失效，**整个 App 就完全不可用**（首跑实测就是如此），
///   属于最高严重级别的失败模式，值得用结构上更稳的写法，而不是依赖展示机制配合；
/// - 语义上也更准确 —— 用户确认之前，主界面**本来就不该存在**。
struct RootView: View {

    @EnvironmentObject private var app: AppState

    /// 必须直接订阅 `SettingsStore`：条件分支依赖它，而 `AppState` 不会转发
    /// 子 Store 的变化。只订阅 `AppState` 就会重现上面第 1 条。
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        Group {
            if settings.hasAcknowledgedPrivacy {
                mainTabs
            } else {
                PrivacyView(isFirstRun: true) {
                    settings.hasAcknowledgedPrivacy = true
                }
            }
        }
    }

    private var mainTabs: some View {
        TabView(selection: $app.selectedTab) {
            HomeView()
                .tabItem { Label(AppTab.home.title, systemImage: AppTab.home.symbolName) }
                .tag(AppTab.home)

            LiveMonitorView()
                .tabItem { Label(AppTab.monitor.title, systemImage: AppTab.monitor.symbolName) }
                .tag(AppTab.monitor)

            PoseAssistantView()
                .tabItem { Label(AppTab.pose.title, systemImage: AppTab.pose.symbolName) }
                .tag(AppTab.pose)

            PhotoLibraryView()
                .tabItem { Label(AppTab.photos.title, systemImage: AppTab.photos.symbolName) }
                .tag(AppTab.photos)

            ToolsView()
                .tabItem { Label(AppTab.tools.title, systemImage: AppTab.tools.symbolName) }
                .tag(AppTab.tools)
        }
        .tint(LumiTheme.accent)
    }
}

/// 预览宿主：`RootView` 同时需要 `AppState` 与它内部的 `SettingsStore` 两个环境对象。
/// 单独写成一个 View 是为了避免在 `@ViewBuilder` 闭包里写 `let` + `return`。
private struct RootViewPreviewHost: View {

    @StateObject private var state = AppState()

    var body: some View {
        RootView()
            .environmentObject(state)
            .environmentObject(state.settings)
    }
}

#Preview {
    RootViewPreviewHost()
}
