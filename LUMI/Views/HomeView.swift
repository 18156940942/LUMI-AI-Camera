import SwiftUI

/// 页面 A：首页
///
/// 内容顺序经过设计：**先告诉用户当前真实的硬件与连接状态，再给功能入口**。
/// 这样用户不会带着「iPhone 能直连相机」的错误预期点进去。
struct HomeView: View {

    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var videoInput: VideoInputManager
    // 「本机数据」与入口副标题读的是这三个 Store。必须逐个订阅：
    // `AppState` 里的子 Store 是普通 let，不会转发 objectWillChange，
    // 只订阅 `app` 的话，收藏/导入照片后首页数字不会刷新。
    @EnvironmentObject private var poseLibrary: PoseLibrary
    @EnvironmentObject private var favorites: FavoritesStore
    @EnvironmentObject private var photoLibrary: PhotoLibraryStore

    @State private var showsSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    connectionCard
                    capabilityCard
                    entries
                    dataOverview
                }
                .padding(LumiTheme.screenPadding)
                .padding(.bottom, 24)
            }
            .background(LumiTheme.background.ignoresSafeArea())
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showsSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .foregroundStyle(LumiTheme.secondaryText)
                    }
                }
            }
            .sheet(isPresented: $showsSettings) {
                NavigationStack { SettingsView() }
            }
        }
    }

    // MARK: - 标志

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(LumiTheme.accentSoft)
                    .frame(width: 52, height: 52)
                Image(systemName: "camera.aperture")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(LumiTheme.accent)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("LUMI")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .tracking(3)
                    .foregroundStyle(LumiTheme.primaryText)
                Text("AI Camera · 相机监视器与人像摄影助手")
                    .font(.system(size: 11))
                    .foregroundStyle(LumiTheme.tertiaryText)
            }
            Spacer()
        }
        .padding(.top, 4)
    }

    // MARK: - 连接状态（全部为真实状态）

    private var connectionCard: some View {
        LumiCard(highlighted: videoInput.state.isRunning) {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "相机连接状态",
                              subtitle: "状态、分辨率与帧率均来自系统实际上报",
                              trailingText: videoInput.state.shortLabel)

                HStack(spacing: 8) {
                    StatusPill(text: videoInput.state.shortLabel,
                               color: stateColor,
                               symbol: stateSymbol)
                    StatusPill(text: settings.videoInputKind.title,
                               color: LumiTheme.accent,
                               symbol: settings.videoInputKind.symbolName)
                    if VideoInputCapability.supportsExternalCamera && videoInput.externalDeviceCount > 0 {
                        StatusPill(text: "已发现 \(videoInput.externalDeviceCount) 台外接设备",
                                   color: LumiTheme.success,
                                   symbol: "cable.connector")
                    }
                }

                if let info = videoInput.deviceInfo {
                    Divider().overlay(LumiTheme.stroke)
                    InfoRow(label: "输入设备", value: info.name)
                    InfoRow(label: "分辨率", value: info.resolutionText)
                    InfoRow(label: "设备声明帧率", value: info.frameRateText)
                    if videoInput.measuredFPS > 0 {
                        InfoRow(label: "实测到达帧率",
                                value: String(format: "%.1f fps", videoInput.measuredFPS),
                                valueColor: LumiTheme.success)
                    }
                } else if case .idle = videoInput.state {
                    Text("尚未启动视频输入。进入监看页选择输入方式后，这里会显示真实设备信息。")
                        .font(.system(size: 12))
                        .foregroundStyle(LumiTheme.tertiaryText)
                }

                HStack(spacing: 10) {
                    SecondaryButton(title: "进入监看", symbol: "rectangle.on.rectangle") {
                        app.selectedTab = .monitor
                    }
                    SecondaryButton(title: "重新扫描", symbol: "arrow.clockwise") {
                        videoInput.refreshExternalDeviceCount()
                    }
                }
            }
        }
    }

    private var stateColor: Color {
        switch videoInput.state {
        case .running: return LumiTheme.success
        case .preparing: return LumiTheme.warning
        case .idle: return LumiTheme.tertiaryText
        case .unsupported: return LumiTheme.warning
        case .failed: return LumiTheme.danger
        }
    }

    private var stateSymbol: String {
        switch videoInput.state {
        case .running: return "dot.radiowaves.left.and.right"
        case .preparing: return "arrow.triangle.2.circlepath"
        case .idle: return "pause.circle"
        case .unsupported: return "exclamationmark.triangle"
        case .failed: return "xmark.octagon"
        }
    }

    // MARK: - 设备能力说明

    private var capabilityCard: some View {
        Group {
            if VideoInputCapability.supportsExternalCamera {
                LumiCard {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader(title: "外接采集能力", subtitle: "iPadOS 17+ 的官方支持路径")
                        Text("本机（iPad）支持外接 UVC 采集设备。把 HDMI 采集卡插上，选择「外接 UVC 采集设备」即可获得原生最低延迟的监看画面。")
                            .font(.system(size: 12))
                            .foregroundStyle(LumiTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                HardwareRequirementCard(
                    title: "iPhone 无法直连相机：这是系统限制",
                    requirement: "要让 iPhone 显示 Nikon Z6 II 的画面，需要：Z6 II 的 mini-HDMI 输出 → UVC 采集卡 → 一台电脑运行 LUMI 中继脚本 → 局域网 → 本 App。",
                    reason: VideoInputCapability.externalCameraUnavailableReason,
                    alternatives: [
                        "在电脑上运行 tools/lumi_mjpeg_server.py（脚本已随项目提供），然后在监看页选择「网络中继流」并填入电脑 IP。",
                        "借/买一台带 USB-C 的 iPad（iPadOS 17+），把采集卡直接插上，用本 App 的「外接 UVC 采集设备」模式获得原生低延迟。",
                        "临时用「内置摄像头」模式：它显示的是 iPhone 自己的画面，**不是相机监看**，但可以在真实帧上验证姿势与构图分析效果。"
                    ],
                    icon: "cable.connector.slash"
                )
            }
        }
    }

    // MARK: - 功能入口

    private var entries: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "功能", subtitle: "点击进入", trailingText: nil)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                      spacing: 10) {
                entryCard(tab: .monitor, title: "实时监看", subtitle: "真实相机画面 · 网格与参考线", symbol: "rectangle.on.rectangle")
                entryCard(tab: .pose, title: "AI 姿势助手", subtitle: "\(poseLibrary.poses.count) 条离线姿势库", symbol: "figure.walk.motion")
                coachCard
                entryCard(tab: .photos, title: "照片管理", subtitle: "\(photoLibrary.records.count) 张已导入副本", symbol: "photo.stack")
                entryCard(tab: .tools, title: "摄影工具", subtitle: "网格 · 构图比例 · 拍摄备注", symbol: "squareshape.split.2x2")
                settingsCard
            }
        }
    }

    private func entryCard(tab: AppTab, title: String, subtitle: String, symbol: String) -> some View {
        Button {
            app.selectedTab = tab
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(LumiTheme.accent)
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(LumiTheme.primaryText)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(LumiTheme.tertiaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
            .padding(12)
            .background(LumiTheme.surface)
            .overlay(
                RoundedRectangle(cornerRadius: LumiTheme.cornerRadius, style: .continuous)
                    .stroke(LumiTheme.stroke, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: LumiTheme.cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var coachCard: some View {
        Button {
            app.selectedTab = .monitor
            app.pendingCoachOpen = true
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "figure.stand.line.dotted.figure.stand")
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(LumiTheme.accent)
                Text("实时姿势指导")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(LumiTheme.primaryText)
                Text(settings.livePoseEnabled ? "已开启 · 需要视频输入" : "默认关闭 · 需手动开启")
                    .font(.system(size: 11))
                    .foregroundStyle(LumiTheme.tertiaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
            .padding(12)
            .background(LumiTheme.surface)
            .overlay(
                RoundedRectangle(cornerRadius: LumiTheme.cornerRadius, style: .continuous)
                    .stroke(LumiTheme.stroke, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: LumiTheme.cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var settingsCard: some View {
        Button {
            showsSettings = true
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "gearshape")
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(LumiTheme.accent)
                Text("设置")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(LumiTheme.primaryText)
                Text("输入设备 · AI 开关 · 隐私说明")
                    .font(.system(size: 11))
                    .foregroundStyle(LumiTheme.tertiaryText)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
            .padding(12)
            .background(LumiTheme.surface)
            .overlay(
                RoundedRectangle(cornerRadius: LumiTheme.cornerRadius, style: .continuous)
                    .stroke(LumiTheme.stroke, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: LumiTheme.cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 数据概览

    private var dataOverview: some View {
        LumiCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "本机数据", subtitle: "全部存储在设备本地，不上传")
                HStack(spacing: 14) {
                    MetricTile(label: "姿势库", value: "\(poseLibrary.poses.count)", caption: "条离线姿势")
                    MetricTile(label: "已收藏", value: "\(favorites.favoritePoseIDs.count)", caption: "条姿势")
                    MetricTile(label: "照片副本", value: "\(photoLibrary.records.count)", caption: "张（App 内）")
                }
                if let failure = poseLibrary.loadFailure {
                    Text(failure)
                        .font(.system(size: 11))
                        .foregroundStyle(LumiTheme.danger)
                }
            }
        }
    }
}
