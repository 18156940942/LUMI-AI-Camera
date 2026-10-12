import SwiftUI
import UIKit

/// 页面 F：设置
struct SettingsView: View {

    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var videoInput: VideoInputManager

    @Environment(\.dismiss) private var dismiss
    @State private var showsPrivacyDetail = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                inputStatusSection
                connectionGuideSection
                aiSettingsSection
                gridSettingsSection
                displaySettingsSection
                privacySection
                versionSection
                resetSection
            }
            .padding(LumiTheme.screenPadding)
            .padding(.bottom, 30)
        }
        .background(LumiTheme.background.ignoresSafeArea())
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("完成") { dismiss() }
                    .foregroundStyle(LumiTheme.accent)
            }
        }
        .sheet(isPresented: $showsPrivacyDetail) {
            NavigationStack { PrivacyView(isFirstRun: false, onAcknowledge: nil) }
        }
    }

    // MARK: - 视频输入设备状态

    private var inputStatusSection: some View {
        LumiCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "视频输入设备状态",
                              subtitle: "全部为系统实际上报值",
                              trailingText: videoInput.state.shortLabel)

                InfoRow(label: "当前输入方式", value: settings.videoInputKind.title)
                InfoRow(label: "连接状态", value: videoInput.state.shortLabel)
                InfoRow(label: "本机外接 UVC 能力",
                        value: VideoInputCapability.supportsExternalCamera ? "支持（iPad）" : "不支持（iPhone）",
                        valueColor: VideoInputCapability.supportsExternalCamera ? LumiTheme.success : LumiTheme.warning)

                if VideoInputCapability.supportsExternalCamera {
                    InfoRow(label: "已发现外接设备", value: "\(videoInput.externalDeviceCount) 台")
                }

                if let info = videoInput.deviceInfo {
                    Divider().overlay(LumiTheme.stroke)
                    InfoRow(label: "设备名称", value: info.name)
                    InfoRow(label: "连接方式", value: info.connectionBadge)
                    InfoRow(label: "分辨率", value: info.resolutionText)
                    InfoRow(label: "设备声明帧率", value: info.frameRateText)
                    InfoRow(label: "像素格式", value: info.pixelFormat ?? "未提供")
                }

                if let notice = videoInput.capabilityNotice {
                    Divider().overlay(LumiTheme.stroke)
                    Text(notice)
                        .font(.system(size: 11))
                        .foregroundStyle(LumiTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 10) {
                    SecondaryButton(title: "重新扫描设备", symbol: "arrow.clockwise") {
                        videoInput.refreshExternalDeviceCount()
                    }
                    SecondaryButton(title: "重新连接", symbol: "bolt") {
                        videoInput.reconnect(kind: settings.videoInputKind,
                                             relay: settings.relay,
                                             analysisFPS: settings.analysisFPS,
                                             poseAnalysisEnabled: settings.livePoseEnabled,
                                             compositionAnalysisEnabled: settings.liveCompositionEnabled,
                                             exposureMeterEnabled: settings.liveExposureMeterEnabled)
                    }
                }
            }
        }
    }

    // MARK: - 连接说明

    private var connectionGuideSection: some View {
        LumiCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "连接说明", subtitle: "三种输入方式的实际接线路径", trailingText: nil)

                guideBlock(
                    title: "① 外接 UVC 采集设备（延迟最低）",
                    available: VideoInputCapability.supportsExternalCamera,
                    lines: [
                        "硬件：Nikon Z6 II 的 mini-HDMI（Type C）输出 → 免驱 UVC HDMI 采集卡 → USB-C 接入 iPad。",
                        "相机设置：HDMI 输出分辨率=自动、HDMI 输出显示尺寸=100%、HDMI 实时显示屏幕显示=关闭、待机定时器=不限。",
                        "建议使用带供电的 USB-C 集线器，否则部分采集卡会黑屏或掉线。",
                        "限制：**iPhone 无法使用此方式**（iOS 不枚举 UVC 外接摄像头），仅 USB-C 的 iPad（iPadOS 17+）可用。",
                        "另外：1920×1080 120p/100p 与慢动作短片不输出 HDMI；Movie 模式连接 Camera Control Pro 2 时也不输出。"
                    ]
                )

                guideBlock(
                    title: "② 网络中继流（iPhone 上的可行方案）",
                    available: true,
                    lines: [
                        "硬件：Z6 II HDMI → UVC 采集卡 → 电脑 USB。",
                        "软件：在电脑运行 python3 tools/lumi_mjpeg_server.py --device \"采集卡名称\" --width 1280 --height 720 --fps 30。",
                        "连接：手机与电脑连同一个 Wi-Fi，在监看页填入电脑 IP:8090，模式选 MJPEG。",
                        "延迟：局域网实测约 150–400 ms，适合判断构图与姿态，不适合精确确认焦点。"
                    ]
                )

                guideBlock(
                    title: "③ 内置摄像头（自测 / 备用）",
                    available: true,
                    lines: [
                        "画面来自 iPhone 自己的摄像头，**不是相机监看**，App 内已显著标注。",
                        "用途：在没有采集卡时，用真实视频帧验证姿势检测与构图分析是否正常工作。",
                        "权限：首次使用会弹出摄像头授权请求，未授权时不会启动。"
                    ]
                )
            }
        }
    }

    private func guideBlock(title: String, available: Bool, lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(LumiTheme.primaryText)
                if !available {
                    Text("本机不可用")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(LumiTheme.warning)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(LumiTheme.warning.opacity(0.14))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .top, spacing: 5) {
                    Text("·")
                        .font(.system(size: 11))
                        .foregroundStyle(LumiTheme.tertiaryText)
                    Text(line)
                        .font(.system(size: 11))
                        .foregroundStyle(LumiTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LumiTheme.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: LumiTheme.smallCornerRadius, style: .continuous))
        .opacity(available ? 1 : 0.75)
    }

    // MARK: - AI 功能设置

    private var aiSettingsSection: some View {
        LumiCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "AI 功能设置", subtitle: "全部本地计算，无云端依赖", trailingText: nil)

                Toggle(isOn: $settings.livePoseEnabled) {
                    Text("实时姿势分析")
                        .font(.system(size: 13))
                        .foregroundStyle(LumiTheme.primaryText)
                }
                .tint(LumiTheme.accent)

                Toggle(isOn: $settings.liveCompositionEnabled) {
                    Text("实时构图分析")
                        .font(.system(size: 13))
                        .foregroundStyle(LumiTheme.primaryText)
                }
                .tint(LumiTheme.accent)

                Toggle(isOn: $settings.liveExposureMeterEnabled) {
                    Text("曝光辅助（亮度分布）")
                        .font(.system(size: 13))
                        .foregroundStyle(LumiTheme.primaryText)
                }
                .tint(LumiTheme.accent)

                Toggle(isOn: $settings.showsConfidenceBadges) {
                    Text("显示置信度提示")
                        .font(.system(size: 13))
                        .foregroundStyle(LumiTheme.primaryText)
                }
                .tint(LumiTheme.accent)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("分析帧率上限")
                            .font(.system(size: 12))
                            .foregroundStyle(LumiTheme.secondaryText)
                        Spacer()
                        Text("\(settings.analysisFPS) fps")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(LumiTheme.accent)
                    }
                    Slider(value: Binding(
                        get: { Double(settings.analysisFPS) },
                        set: { settings.analysisFPS = Int($0.rounded()) }
                    ), in: 1...15, step: 1)
                    .tint(LumiTheme.accent)
                }

                Divider().overlay(LumiTheme.stroke)

                Text("""
                · 使用 Apple Vision 框架在本机完成人体关键点与人脸特征点检测；
                · 姿势推荐来自随 App 打包的离线姿势库，不需要联网；
                · **本 App 不包含任何云端 AI 调用，也没有任何 API 密钥**，因此不存在「把密钥放进客户端」的风险；
                · 如果你将来要接入云端 AI，请把密钥放在你自己的服务端，客户端只调用你的接口 —— 这是本项目刻意预留的边界。
                """)
                .font(.system(size: 11))
                .foregroundStyle(LumiTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 网格线设置

    private var gridSettingsSection: some View {
        LumiCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "网格线设置", subtitle: nil, trailingText: nil)
                Toggle(isOn: $settings.overlay.showThirds) { settingLabel("三分法构图线") }.tint(LumiTheme.accent)
                Toggle(isOn: $settings.overlay.showNineGrid) { settingLabel("九宫格细分线") }.tint(LumiTheme.accent)
                Toggle(isOn: $settings.overlay.showCenterLines) { settingLabel("中心参考线（垂直）") }.tint(LumiTheme.accent)
                Toggle(isOn: $settings.overlay.showHorizon) { settingLabel("水平参考线") }.tint(LumiTheme.accent)
                Toggle(isOn: $settings.overlay.showCenterCross) { settingLabel("中心十字标记") }.tint(LumiTheme.accent)
                Toggle(isOn: $settings.overlay.showSafeArea) { settingLabel("安全构图区") }.tint(LumiTheme.accent)
                Toggle(isOn: $settings.overlay.showsSubjectBox) { settingLabel("人物检测框") }.tint(LumiTheme.accent)
            }
        }
    }

    // MARK: - 视频显示设置

    private var displaySettingsSection: some View {
        LumiCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "视频显示设置", subtitle: nil, trailingText: nil)

                HStack(spacing: 8) {
                    ForEach(VideoGravityMode.allCases) { mode in
                        SelectableChip(title: mode.title,
                                       symbol: nil,
                                       isSelected: settings.gravity == mode,
                                       tint: LumiTheme.accent) {
                            settings.gravity = mode
                        }
                    }
                }

                HStack(spacing: 8) {
                    ForEach(CaptureAspect.allCases) { aspect in
                        if [CaptureAspect.native, .threeTwo, .sixteenNine, .nineSixteen].contains(aspect) {
                            SelectableChip(title: aspect.title,
                                           symbol: nil,
                                           isSelected: settings.overlay.aspect == aspect,
                                           tint: LumiTheme.accent) {
                                settings.overlay.aspect = aspect
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("数字变焦")
                            .font(.system(size: 12))
                            .foregroundStyle(LumiTheme.secondaryText)
                        Spacer()
                        Text(String(format: "%.1f×", settings.monitorZoom))
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(LumiTheme.accent)
                    }
                    Slider(value: $settings.monitorZoom, in: 1.0...5.0, step: 0.1)
                        .tint(LumiTheme.accent)
                }

                Toggle(isOn: $settings.prefersLandscapeMonitor) { settingLabel("全屏监看时自动转横屏") }.tint(LumiTheme.accent)
                Toggle(isOn: $settings.keepsScreenAwake) { settingLabel("监看时屏幕常亮") }.tint(LumiTheme.accent)
                Toggle(isOn: $settings.showsFrameStats) { settingLabel("显示帧与丢弃统计") }.tint(LumiTheme.accent)

                Text("横屏：开启后，进入全屏监看时会主动请求旋转到横屏；退出全屏后恢复。这是唯一会改变屏幕方向的地方。")
                    .font(.system(size: 10))
                    .foregroundStyle(LumiTheme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func settingLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(LumiTheme.primaryText)
    }

    // MARK: - 隐私

    private var privacySection: some View {
        LumiCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "隐私说明", subtitle: "本 App 不联网上传任何影像数据", trailingText: nil)

                InfoRow(label: "摄像头", value: "仅在内置摄像头模式使用，需你手动开启")
                InfoRow(label: "照片", value: "仅读取你主动挑选的照片")
                InfoRow(label: "人体姿态数据", value: "仅在本机内存中处理，不落盘、不上传")
                InfoRow(label: "局域网", value: "仅用于连接你自建的中继流")

                SecondaryButton(title: "查看完整隐私与安全说明", symbol: "lock.shield") {
                    showsPrivacyDetail = true
                }

                if !settings.hasAcknowledgedPrivacy {
                    SecondaryButton(title: "重新显示首次启动提示", symbol: "hand.raised") {
                        settings.hasAcknowledgedPrivacy = false
                    }
                }
            }
        }
    }

    // MARK: - 版本信息

    private var versionSection: some View {
        LumiCard {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "版本信息", subtitle: nil, trailingText: nil)
                InfoRow(label: "App 版本", value: appVersionText)
                InfoRow(label: "构建号", value: buildNumberText)
                InfoRow(label: "姿势库版本", value: app.poseLibrary.databaseVersion == 0 ? "未加载" : "v\(app.poseLibrary.databaseVersion)")
                InfoRow(label: "姿势库条目", value: "\(app.poseLibrary.poses.count) 条")
                InfoRow(label: "照片副本", value: "\(app.photoLibrary.records.count) 张")
                InfoRow(label: "系统版本", value: UIDevice.current.systemName + " " + UIDevice.current.systemVersion)
                InfoRow(label: "设备型号", value: deviceModelText)
                InfoRow(label: "界面语言", value: "简体中文")
            }
        }
    }

    private var appVersionText: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "未知"
    }

    private var buildNumberText: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "未知"
    }

    private var deviceModelText: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafePointer(to: &systemInfo.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 64) { cString in
                String(cString: cString)
            }
        }
        let idiom = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        return "\(idiom) · \(machine)"
    }

    // MARK: - 恢复默认

    private var resetSection: some View {
        VStack(spacing: 10) {
            SecondaryButton(title: "恢复参考线与显示默认值", symbol: "arrow.counterclockwise") {
                settings.resetOverlayAndDisplay()
            }
            LimitationBadge(text: "当前版本不做任何数据上传，因此没有「清除云端数据」这类选项。")
        }
    }
}
