import SwiftUI

/// 根视图：五个页签 + 首次启动的隐私说明。
///
/// 关于页签数量：iOS 在超过 5 个页签时会自动折叠成「更多」，
/// 因此这里固定 5 个页签，「设置」通过首页卡片 / 各页工具栏进入。
struct RootView: View {

    @EnvironmentObject private var app: AppState

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
            get: { !app.settings.hasAcknowledgedPrivacy },
            set: { _ in }
        )) {
            PrivacyView(isFirstRun: true) {
                app.settings.hasAcknowledgedPrivacy = true
            }
        }
    }
}

#Preview {
    RootView().environmentObject(AppState())
}
