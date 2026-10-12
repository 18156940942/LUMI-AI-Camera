import SwiftUI
import UIKit

/// 页面 B：实时监看
///
/// 布局原则（对应需求）：视频画面占主要区域，辅助控制放在画面之外/下方，
/// **不遮挡人物**；全屏时仅保留极简浮层。
struct LiveMonitorView: View {

    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var videoInput: VideoInputManager

    @StateObject private var viewModel = MonitorViewModel()
    @State private var showsCoachSheet = false
    @State private var showsSettingsSheet = false
    @State private var showsDiagnosticsSheet = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    monitorArea
                    primaryActions
                    noticeArea
                    panelPicker
                    panelContent
                }
                .padding(LumiTheme.screenPadding)
                .padding(.bottom, 30)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(LumiTheme.background.ignoresSafeArea())
            .navigationTitle("实时监看")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 14) {
                        Button {
                            viewModel.showsFullscreen = true
                        } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .foregroundStyle(LumiTheme.secondaryText)
                        }
                        .disabled(videoInput.previewProvider == nil)
                        Button {
                            showsDiagnosticsSheet = true
                        } label: {
                            Image(systemName: "stethoscope")
                                .foregroundStyle(LumiTheme.secondaryText)
                        }
                        Button {
                            showsSettingsSheet = true
                        } label: {
                            Image(systemName: "gearshape")
                                .foregroundStyle(LumiTheme.secondaryText)
                        }
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $viewModel.showsFullscreen) {
            fullscreenMonitor
        }
        .sheet(isPresented: $showsCoachSheet) {
            NavigationStack { LivePoseCoachView() }
        }
        .sheet(isPresented: $showsSettingsSheet) {
            NavigationStack { SettingsView() }
        }
        .sheet(isPresented: $showsDiagnosticsSheet) {
            NavigationStack { DiagnosticsView() }
        }
        .onAppear {
            viewModel.syncRelayDraft(from: settings)
            videoInput.refreshExternalDeviceCount()
            applyScreenAwake()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onChange(of: settings.livePoseEnabled) { _, _ in
            viewModel.applyAnalysisChanges(settings: settings, manager: videoInput)
        }
        .onChange(of: settings.liveCompositionEnabled) { _, _ in
            viewModel.applyAnalysisChanges(settings: settings, manager: videoInput)
        }
        .onChange(of: settings.analysisFPS) { _, _ in
            viewModel.applyAnalysisChanges(settings: settings, manager: videoInput)
        }
        .onChange(of: settings.liveExposureMeterEnabled) { _, _ in
            viewModel.applyAnalysisChanges(settings: settings, manager: videoInput)
        }
    }

    // MARK: - 监看区

    private var monitorArea: some View {
        MonitorVideoSurface(showsOverlay: true,
                            showsSkeleton: settings.livePoseEnabled,
                            subjectBox: videoInput.compositionReport.subjectBoundingBox,
                            showsStatusBar: true,
                            showsGuidance: true)
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: LumiTheme.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: LumiTheme.cornerRadius, style: .continuous)
                    .stroke(LumiTheme.strokeStrong, lineWidth: 1)
            )
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                if videoInput.previewProvider != nil { viewModel.showsFullscreen = true }
            }
    }

    // MARK: - 主操作

    private var primaryActions: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                if videoInput.state.isRunning || isPreparing {
                    SecondaryButton(title: "停止", symbol: "stop.fill", tint: LumiTheme.danger) {
                        viewModel.stop(manager: videoInput)
                    }
                } else {
                    PrimaryButton(title: "开始监看", symbol: "play.fill") {
                        viewModel.start(settings: settings, manager: videoInput)
                        applyScreenAwake()
                    }
                }

                SecondaryButton(title: "重新连接", symbol: "arrow.clockwise") {
                    viewModel.start(settings: settings, manager: videoInput)
                    applyScreenAwake()
                }
            }

            HStack(spacing: 10) {
                SecondaryButton(title: "实时姿势指导", symbol: "figure.stand") {
                    if !settings.livePoseEnabled {
                        settings.livePoseEnabled = true
                        viewModel.applyAnalysisChanges(settings: settings, manager: videoInput)
                    }
                    showsCoachSheet = true
                }
                SecondaryButton(title: "全屏监看", symbol: "arrow.up.left.and.arrow.down.right") {
                    viewModel.showsFullscreen = true
                }
                .opacity(videoInput.previewProvider == nil ? 0.4 : 1)
                .disabled(videoInput.previewProvider == nil)
            }

            Text("提示：视频输入不会自动启动，必须由你点「开始监看」——这是本 App 的隐私约定。")
                .font(.system(size: 10))
                .foregroundStyle(LumiTheme.tertiaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var isPreparing: Bool {
        if case .preparing = videoInput.state { return true }
        return false
    }

    // MARK: - 提示区（失败 / 能力限制）

    @ViewBuilder
    private var noticeArea: some View {
        if let notice = videoInput.capabilityNotice,
           viewModel.dismissedFailure == nil || currentFailure != viewModel.dismissedFailure {
            VStack(spacing: 10) {
                HardwareRequirementCard(
                    title: noticeTitle,
                    requirement: notice,
                    reason: VideoInputCapability.supportsExternalCamera
                        ? "本机支持外接 UVC 设备，请检查采集卡是否为免驱 UVC 型号、是否使用了数据线、是否接了供电集线器。"
                        : VideoInputCapability.externalCameraUnavailableReason,
                    alternatives: noticeAlternatives,
                    icon: noticeSymbol,
                    tint: noticeTint
                )
                .overlay(alignment: .topTrailing) {
                    Button {
                        viewModel.dismissedFailure = currentFailure
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(LumiTheme.tertiaryText)
                            .padding(6)
                    }
                    .buttonStyle(.plain)
                }

                // 连接失败时最需要的不是「再试一次」，而是「到底卡在哪一步」。
                // 所以把诊断入口直接放在错误卡片下方，而不是让人去设置里翻。
                SecondaryButton(title: "打开设备自检与诊断", symbol: "stethoscope") {
                    showsDiagnosticsSheet = true
                }
            }
        }
    }

    private var currentFailure: VideoInputFailure? {
        if case .failed(let failure) = videoInput.state { return failure }
        return nil
    }

    private var noticeTitle: String {
        if case .unsupported = videoInput.state { return "当前输入方式在本机不可用" }
        if case .failed = videoInput.state { return "视频输入出现问题" }
        return "连接说明"
    }

    private var noticeSymbol: String {
        if case .unsupported = videoInput.state { return "cable.connector.slash" }
        if case .failed = videoInput.state { return "exclamationmark.triangle" }
        return "info.circle"
    }

    private var noticeTint: Color {
        if case .failed = videoInput.state { return LumiTheme.danger }
        if case .unsupported = videoInput.state { return LumiTheme.warning }
        return LumiTheme.accent
    }

    private var noticeAlternatives: [String] {
        if case .unsupported = videoInput.state {
            return [
                "在电脑上运行 tools/lumi_mjpeg_server.py，把 HDMI 采集卡的画面转成局域网 MJPEG 流，然后在「输入」面板选择「网络中继流」。",
                "换成 USB-C 的 iPad（iPadOS 17+）直连采集卡，获得原生低延迟监看。",
                "急用时切到「内置摄像头」：画面来自 iPhone 自己，可在真实帧上验证 AI 分析。"
            ]
        }
        if case .failed(let failure) = videoInput.state {
            return [failure.recoverySuggestion]
        }
        return []
    }

    // MARK: - 控制面板

    private var panelPicker: some View {
        HStack(spacing: 8) {
            ForEach(MonitorViewModel.MonitorPanel.allCases) { panel in
                SelectableChip(title: panel.title,
                               symbol: panel.symbol,
                               isSelected: viewModel.activePanel == panel,
                               tint: LumiTheme.accent) {
                    viewModel.activePanel = panel
                }
            }
        }
    }

    @ViewBuilder
    private var panelContent: some View {
        switch viewModel.activePanel {
        case .input: inputPanel
        case .overlay: overlayPanel
        case .analysis: analysisPanel
        case .info: infoPanel
        }
    }

    // MARK: 输入面板

    private var inputPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            LumiCard {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: "视频输入方式",
                                  subtitle: "三种都是真实输入，不会显示模拟画面",
                                  trailingText: nil)

                    ForEach(VideoInputKind.allCases) { kind in
                        inputOptionRow(kind)
                    }
                }
            }

            if settings.videoInputKind == .networkRelay {
                relayEditor
            }

            LumiCard {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "中继脚本", subtitle: "随项目提供：tools/lumi_mjpeg_server.py", trailingText: nil)
                    Text("""
                    在电脑上运行：
                    python3 tools/lumi_mjpeg_server.py --list-devices
                    python3 tools/lumi_mjpeg_server.py --device "你的采集卡名称" --width 1280 --height 720 --fps 30

                    脚本会把采集卡画面以 MJPEG 形式发布到 http://电脑IP:8090/stream，
                    本 App 的「网络中继流」模式即从此地址取流。默认 1280×720@30，
                    局域网实测延迟约 150–400 ms。
                    """)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(LumiTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func inputOptionRow(_ kind: VideoInputKind) -> some View {
        let available = VideoInputCapability.isAvailable(kind)
        let selected = settings.videoInputKind == kind
        return Button {
            guard available else { return }
            settings.videoInputKind = kind
            if videoInput.state.isRunning {
                viewModel.start(settings: settings, manager: videoInput)
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: kind.symbolName)
                    .font(.system(size: 15))
                    .foregroundStyle(available ? (selected ? LumiTheme.accent : LumiTheme.secondaryText) : LumiTheme.tertiaryText)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(kind.title)
                            .font(.system(size: 13, weight: selected ? .semibold : .regular))
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
                        if selected {
                            Text("已选择")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(LumiTheme.onAccentText)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(LumiTheme.accent)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    }
                    Text(kind.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(LumiTheme.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(selected ? LumiTheme.accentSoft : LumiTheme.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: LumiTheme.smallCornerRadius, style: .continuous))
            .opacity(available ? 1 : 0.6)
        }
        .buttonStyle(.plain)
    }

    private var relayEditor: some View {
        LumiCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "中继地址", subtitle: "电脑与本机需在同一 Wi-Fi", trailingText: nil)

                HStack(spacing: 8) {
                    labeledField(title: "IP 或主机名", text: $viewModel.relayDraft.host, keyboard: .numbersAndPunctuation)
                    labeledField(title: "端口", text: Binding(
                        get: { String(viewModel.relayDraft.port) },
                        set: { viewModel.relayDraft.port = Int($0.filter(\.isNumber)) ?? 0 }
                    ), keyboard: .numberPad, width: 90)
                }
                labeledField(title: "路径", text: $viewModel.relayDraft.path, keyboard: .URL)

                HStack(spacing: 8) {
                    ForEach(RelayMode.allCases) { mode in
                        SelectableChip(title: mode.title,
                                       symbol: nil,
                                       isSelected: viewModel.relayDraft.mode == mode,
                                       tint: LumiTheme.accent) {
                            viewModel.relayDraft.mode = mode
                        }
                    }
                }

                Text("延迟预期：\(viewModel.relayDraft.mode.latencyHint)")
                    .font(.system(size: 11))
                    .foregroundStyle(LumiTheme.tertiaryText)

                if let error = viewModel.relayDraftError {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(LumiTheme.danger)
                }

                HStack(spacing: 10) {
                    PrimaryButton(title: "应用并连接", symbol: "wifi") {
                        guard let validated = viewModel.validateRelayDraft() else { return }
                        settings.relay = validated
                        settings.videoInputKind = .networkRelay
                        viewModel.start(settings: settings, manager: videoInput)
                        applyScreenAwake()
                    }
                    SecondaryButton(title: "仅保存") {
                        guard let validated = viewModel.validateRelayDraft() else { return }
                        settings.relay = validated
                    }
                }
            }
        }
    }

    private func labeledField(title: String,
                              text: Binding<String>,
                              keyboard: UIKeyboardType,
                              width: CGFloat? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(LumiTheme.tertiaryText)
            TextField("", text: text)
                .keyboardType(keyboard)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(LumiTheme.primaryText)
                .padding(.horizontal, 9)
                .padding(.vertical, 8)
                .frame(width: width)
                .background(LumiTheme.surfaceSunken)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }

    // MARK: 参考线面板

    private var overlayPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            LumiCard {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: "参考线", subtitle: "逐项独立开关", trailingText: nil)
                    toggleRow("三分法构图线", isOn: $settings.overlay.showThirds)
                    toggleRow("九宫格细分线", isOn: $settings.overlay.showNineGrid)
                    toggleRow("中心参考线（垂直）", isOn: $settings.overlay.showCenterLines)
                    toggleRow("水平参考线", isOn: $settings.overlay.showHorizon)
                    toggleRow("中心十字标记", isOn: $settings.overlay.showCenterCross)
                    toggleRow("安全构图区", isOn: $settings.overlay.showSafeArea)
                    toggleRow("显示人物检测框", isOn: $settings.overlay.showsSubjectBox)
                }
            }

            LumiCard {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: "构图比例", subtitle: "仅作为取景参考框，不改变视频源", trailingText: nil)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 8)], spacing: 8) {
                        ForEach(CaptureAspect.allCases) { aspect in
                            SelectableChip(title: aspect.title,
                                           symbol: nil,
                                           isSelected: settings.overlay.aspect == aspect,
                                           tint: LumiTheme.accent) {
                                settings.overlay.aspect = aspect
                            }
                        }
                    }
                }
            }

            LumiCard {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: "画面显示", subtitle: nil, trailingText: nil)
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
                        Text("数字变焦只缩放预览图层，不改变相机光学参数，也不会提升解析力。")
                            .font(.system(size: 10))
                            .foregroundStyle(LumiTheme.tertiaryText)
                    }

                    toggleRow("显示帧与丢弃统计", isOn: $settings.showsFrameStats)
                }
            }
        }
    }

    // MARK: AI 分析面板

    private var analysisPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            LumiCard {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: "AI 功能开关", subtitle: "全部本地计算，默认关闭以控制耗电", trailingText: nil)

                    toggleRow("实时姿势分析", isOn: $settings.livePoseEnabled)
                    Text("开启后对每一分析帧运行 Vision 人体关键点检测（19 个关键点），并给出肩线/躯干/肘部/手位等提示。")
                        .font(.system(size: 10))
                        .foregroundStyle(LumiTheme.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    Divider().overlay(LumiTheme.stroke)

                    toggleRow("实时构图分析", isOn: $settings.liveCompositionEnabled)
                    Text("分析头顶留白、视线空间、边缘截断、三分法与景别。**只以真实帧为输入**；未连接视频时不会有任何结论。")
                        .font(.system(size: 10))
                        .foregroundStyle(LumiTheme.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    Divider().overlay(LumiTheme.stroke)

                    toggleRow("曝光辅助（亮度分布）", isOn: $settings.liveExposureMeterEnabled)
                    Text("由画面像素真实计算亮度均值、过曝与欠曝比例。**这不是相机测光值** —— 相机机身曝光参数不会随 HDMI 画面传出。")
                        .font(.system(size: 10))
                        .foregroundStyle(LumiTheme.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    if let metrics = videoInput.exposureMetrics {
                        Divider().overlay(LumiTheme.stroke)
                        InfoRow(label: "平均亮度", value: "\(metrics.brightnessPercent)%")
                        InfoRow(label: "明暗反差", value: "\(metrics.contrastPercent)%")
                        InfoRow(label: "高光溢出像素", value: String(format: "%.1f%%", metrics.overexposedPercent),
                                valueColor: metrics.overexposedRatio > 0.06 ? LumiTheme.warning : LumiTheme.primaryText)
                        InfoRow(label: "暗部欠曝像素", value: String(format: "%.1f%%", metrics.underexposedPercent),
                                valueColor: metrics.underexposedRatio > 0.35 ? LumiTheme.warning : LumiTheme.primaryText)
                        InfoRow(label: "曝光判断", value: metrics.exposureLabel)
                    } else if settings.liveExposureMeterEnabled && videoInput.state.isRunning {
                        Text("等待第一帧以计算亮度分布…")
                            .font(.system(size: 10))
                            .foregroundStyle(LumiTheme.tertiaryText)
                    }

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
                        Text("帧率越高越耗电。人像姿态指导 6–10 fps 已经足够顺滑。")
                            .font(.system(size: 10))
                            .foregroundStyle(LumiTheme.tertiaryText)
                    }
                }
            }

            if settings.liveCompositionEnabled {
                compositionResultCard
            }

            LumiCard {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "分析运行状态", subtitle: "以下为真实统计", trailingText: nil)
                    InfoRow(label: "已分析帧数", value: "\(videoInput.pipelineDiagnostics.analyzedFrames)")
                    InfoRow(label: "节流跳过帧数", value: "\(videoInput.pipelineDiagnostics.skippedFrames)")
                    InfoRow(label: "未检测到人体的帧", value: "\(videoInput.pipelineDiagnostics.visionFailures)")
                    InfoRow(label: "上帧分析耗时",
                            value: String(format: "%.0f ms", videoInput.pipelineDiagnostics.lastAnalysisDuration * 1000))
                }
            }
        }
    }

    private var compositionResultCard: some View {
        LumiCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "构图分析（最近一帧）",
                              subtitle: videoInput.compositionReport.detectionSource,
                              trailingText: nil)

                if videoInput.compositionReport.findings.isEmpty {
                    Text("等待视频输入与人物进入画面。没有真实帧时本模块不会给出任何结论。")
                        .font(.system(size: 12))
                        .foregroundStyle(LumiTheme.tertiaryText)
                } else {
                    ConfidenceBanner(level: videoInput.compositionReport.reliability)
                    ForEach(videoInput.compositionReport.findings.prefix(6)) { finding in
                        FindingRow(finding: finding, showsConfidence: settings.showsConfidenceBadges)
                        if finding.id != videoInput.compositionReport.findings.prefix(6).last?.id {
                            Divider().overlay(LumiTheme.stroke)
                        }
                    }
                }
            }
        }
    }

    // MARK: 信息面板

    private var infoPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            LumiCard {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "输入设备", subtitle: "数值来自系统实际上报", trailingText: nil)
                    if let info = videoInput.deviceInfo {
                        InfoRow(label: "名称", value: info.name)
                        InfoRow(label: "连接方式", value: info.connectionBadge)
                        InfoRow(label: "分辨率", value: info.resolutionText)
                        InfoRow(label: "设备声明帧率", value: info.frameRateText)
                        InfoRow(label: "像素格式", value: info.pixelFormat ?? "未提供")
                        InfoRow(label: "实测到达帧率",
                                value: videoInput.measuredFPS > 0 ? String(format: "%.1f fps", videoInput.measuredFPS) : "—")
                    } else {
                        Text("尚未连接任何视频输入。")
                            .font(.system(size: 12))
                            .foregroundStyle(LumiTheme.tertiaryText)
                    }
                }
            }

            LumiCard {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "流统计", subtitle: nil, trailingText: nil)
                    InfoRow(label: "接收帧总数", value: "\(videoInput.stats.totalFrames)")
                    InfoRow(label: "丢弃帧", value: "\(videoInput.stats.droppedFrames)")
                    InfoRow(label: "解码失败", value: "\(videoInput.stats.decodeFailureCount)",
                            valueColor: videoInput.stats.decodeFailureCount > 0 ? LumiTheme.warning : LumiTheme.primaryText)
                    InfoRow(label: "实时带宽", value: bandwidthText)
                }
            }

            LumiCard {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "关于曝光辅助信息", subtitle: nil, trailingText: nil)
                    Text("""
                    本 App 的三种视频输入（UVC 采集卡 / 网络中继 / 内置摄像头）都**不会**提供相机机身的曝光参数 —— \
                    快门、光圈、ISO 属于相机内部状态，不会随 HDMI 画面传出，iOS 也无法从采集设备读取。

                    因此 LUMI 不显示机身曝光数值，只显示从画面像素真实计算出的「亮度分布 / 过曝欠曝比例」，\
                    并在照片分析中对已导入的照片读取文件本身携带的 EXIF。
                    """)
                    .font(.system(size: 11))
                    .foregroundStyle(LumiTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            LumiCard {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "本机能力", subtitle: nil, trailingText: nil)
                    Text(app.inputAvailabilitySummary)
                        .font(.system(size: 12))
                        .foregroundStyle(LumiTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    InfoRow(label: "外接 UVC 设备", value: VideoInputCapability.supportsExternalCamera ? "支持" : "不支持",
                            valueColor: VideoInputCapability.supportsExternalCamera ? LumiTheme.success : LumiTheme.warning)
                    InfoRow(label: "已发现外接设备", value: "\(videoInput.externalDeviceCount) 台")
                }
            }
        }
    }

    private var bandwidthText: String {
        let bytes = videoInput.stats.bytesPerSecond
        guard bytes > 1 else { return "—" }
        let mbps = bytes * 8 / 1_000_000
        return String(format: "%.2f Mbps（%.2f MB/s）", mbps, bytes / 1_000_000)
    }

    // MARK: - 通用

    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(LumiTheme.primaryText)
        }
        .tint(LumiTheme.accent)
    }

    private func applyScreenAwake() {
        UIApplication.shared.isIdleTimerDisabled = settings.keepsScreenAwake && videoInput.state.isRunning
    }

    // MARK: - 全屏监看

    private var fullscreenMonitor: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            MonitorVideoSurface(showsOverlay: true,
                                showsSkeleton: settings.livePoseEnabled,
                                subjectBox: videoInput.compositionReport.subjectBoundingBox,
                                showsStatusBar: false,
                                showsGuidance: true)
                .ignoresSafeArea()

            VStack {
                HStack(spacing: 10) {
                    StatusPill(text: videoInput.state.shortLabel,
                               color: videoInput.state.isRunning ? LumiTheme.success : LumiTheme.warning,
                               symbol: "dot.radiowaves.left.and.right")
                    if let info = videoInput.deviceInfo {
                        StatusPill(text: info.resolutionText, color: LumiTheme.accent, symbol: nil)
                    }
                    if videoInput.measuredFPS > 0 {
                        StatusPill(text: String(format: "%.1f fps", videoInput.measuredFPS),
                                   color: LumiTheme.success, symbol: nil)
                    }
                    Spacer()
                    Button {
                        viewModel.showsFullscreen = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(LumiTheme.primaryText)
                            .padding(9)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                Spacer()

                HStack(spacing: 10) {
                    quickToggle(title: "三分法", isOn: $settings.overlay.showThirds)
                    quickToggle(title: "中心线", isOn: $settings.overlay.showCenterLines)
                    quickToggle(title: "安全区", isOn: $settings.overlay.showSafeArea)
                    quickToggle(title: "姿势", isOn: $settings.livePoseEnabled)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
        }
        .statusBarHidden()
        .onAppear {
            if settings.prefersLandscapeMonitor {
                OrientationSupport.setLandscapeLock(true)
            }
        }
        .onDisappear {
            OrientationSupport.setLandscapeLock(false)
        }
    }

    private func quickToggle(title: String, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
            if title == "姿势" {
                viewModel.applyAnalysisChanges(settings: settings, manager: videoInput)
            }
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isOn.wrappedValue ? LumiTheme.onAccentText : LumiTheme.primaryText)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(isOn.wrappedValue ? LumiTheme.accent : Color.black.opacity(0.45))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
