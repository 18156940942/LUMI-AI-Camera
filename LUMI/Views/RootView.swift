import SwiftUI

/// 根视图：五个页签 + 首次启动的隐私说明。
///
/// 关于页签数量：iOS 在超过 5 个页签时会自动折叠成「更多」，
/// 因此这里固定 5 个页签，「设置」通过首页卡片 / 各页工具栏进入。
struct RootView: View {

    @EnvironmentObject private var app: AppState

    /// 必须直接订阅 `SettingsStore`，不能只订阅 `AppState`。
    ///
    /// 原因（这是一个真实踩过的坑）：`AppState.settings` 是普通 `let`，
    /// 子 Store 变化时 `AppState` **不会**转发 `objectWillChange`。
    /// 如果这里写成 `app.settings.hasAcknowledgedPrivacy`，那么点击「我已了解」后
    /// 值确实被改成了 `true`，但这个视图从不重算、Binding 的 get 从不重读，
    /// 全屏页就会一直盖着 —— 表现就是「点了没反应」。
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
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
        .fullScreenCover(isPresented: Binding(
            get: { !settings.hasAcknowledgedPrivacy },
            // 只允许通过页面内的确认按钮关闭，所以这里刻意不处理写入。
            set: { _ in }
        )) {
            PrivacyView(isFirstRun: true) {
                settings.hasAcknowledgedPrivacy = true
            }
        }
    }
}

#Preview {
    RootView().environmentObject(AppState())
}
