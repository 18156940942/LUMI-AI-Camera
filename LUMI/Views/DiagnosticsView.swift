import SwiftUI
import UIKit

/// 设备自检与诊断报告。
///
/// **它存在的唯一理由是环境的限制**：这套代码在没有 Mac 的 Windows 上开发，而
/// `os.Logger` 的内容只有 macOS 的「控制台」App 或 Xcode 才能读。也就是说，
/// 一旦真机上出问题，现场信息本来**取不出来**。这个页面把「看得见、能复制、能导出」
/// 补上，让每一次真机测试都能带回可定位的信息 —— 而不是一句「它不工作」。
///
/// 它不会在没有真实输入时编造任何数值：所有状态直接读自 `VideoInputManager` 与系统 API，
/// 取不到就显示「未取得」。
struct DiagnosticsView: View {

    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var videoInput: VideoInputManager
    // 报告里会写入姿势库/照片副本/收藏的数量。这三个必须各自订阅，
    // 否则打开诊断页时可能写进过期值（例如姿势库其实已加载却报「未加载」）。
    @EnvironmentObject private var poseLibrary: PoseLibrary
    @EnvironmentObject private var photoLibrary: PhotoLibraryStore
    @EnvironmentObject private var favorites: FavoritesStore

    @ObservedObject private var log = DiagnosticsLog.shared
    @Environment(\.dismiss) private var dismiss

    @State private var environment = DiagnosticsEnvironment.measure()
    @State private var permissions = DiagnosticsPermissions.measure()
    @State private var minLevel: DiagnosticsLog.Level = .debug
    @State private var copiedAt: Date?
    @State private var probeResult: RelayProbe.Result?
    @State private var isProbing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                purposeSection
                environmentSection
                permissionSection
                videoStateSection
                librarySection
                relayProbeSection
                logSection
                exportSection
            }
            .padding(LumiTheme.screenPadding)
            .padding(.bottom, 30)
        }
        .background(LumiTheme.background.ignoresSafeArea())
        .navigationTitle("设备自检与诊断")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("完成") { dismiss() }
                    .foregroundStyle(LumiTheme.accent)
            }
        }
        .onAppear { refresh() }
    }

    // MARK: - 说明

    private var purposeSection: some View {
        LumiCard {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "这个页面是干什么的",
                              subtitle: "为什么必须有它",
                              trailingText: nil)
                Text("""
                本项目的开发环境没有 Mac，而系统日志（os.Logger）只能在没有 Mac 时用「控制台」或 Xcode 读取。\
                所以真机上一旦出问题，默认是**看不到任何现场信息**的。
                这里把运行环境、权限、视频输入的真实状态与内存日志集中到一处，你可以直接复制或导出成文本。
                """)
                .font(.system(size: 12))
                .foregroundStyle(LumiTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

                LimitationBadge(text: "日志只存在于内存（上限 \(log.capacity) 条），不落盘、不上传、不记录任何影像内容，App 退出即清空。")
            }
        }
    }

    // MARK: - 运行环境

    private var environmentSection: some View {
        LumiCard {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "运行环境",
                              subtitle: "全部读自系统，取不到即写「未知」",
                              trailingText: nil)
                ForEach(Array(environment.rows.enumerated()), id: \.offset) { _, row in
                    InfoRow(label: row.label, value: row.value)
                }
            }
        }
    }

    // MARK: - 权限

    private var permissionSection: some View {
        LumiCard {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "权限状态",
                              subtitle: "系统实际返回值",
                              trailingText: nil)
                ForEach(Array(permissions.rows.enumerated()), id: \.offset) { _, row in
                    InfoRow(label: row.label, value: row.value)
                }
                LimitationBadge(text: "「本地网络」这一项 iOS 没有提供公开的查询接口，所以只能说明无法查询 —— 不能写成「已授权」。")
            }
        }
    }

    // MARK: - 视频输入实时状态

    private var videoStateSection: some View {
        LumiCard {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "视频输入实时状态",
                              subtitle: "直接读自当前会话，非缓存值",
                              trailingText: videoInput.state.shortLabel)

                ForEach(Array(videoStateRows.enumerated()), id: \.offset) { _, row in
                    InfoRow(label: row.label,
                            value: row.value,
                            valueColor: row.highlight ? LumiTheme.warning : LumiTheme.primaryText)
                }

                if let notice = videoInput.capabilityNotice {
                    Divider().overlay(LumiTheme.stroke)
                    Text(notice)
                        .font(.system(size: 11))
                        .foregroundStyle(LumiTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                SecondaryButton(title: "重新扫描外接设备", symbol: "arrow.clockwise") {
                    videoInput.refreshExternalDeviceCount()
                    DiagnosticsLog.shared.info(.videoInput, "手动触发外接设备重新扫描，结果 \(videoInput.externalDeviceCount) 台")
                }
            }
        }
    }

    /// 实时状态行。`highlight` 用于把「异常值」标黄。
    private struct StateRow {
        var label: String = ""
        var value: String = ""
        var highlight: Bool = false
    }

    private var videoStateRows: [StateRow] {
        var rows: [StateRow] = []
        rows.append(StateRow(label: "选择的输入方式", value: settings.videoInputKind.title))
        rows.append(StateRow(label: "连接状态", value: videoInput.state.shortLabel))
        rows.append(StateRow(
            label: "本机 UVC 外接能力",
            value: VideoInputCapability.supportsExternalCamera ? "支持（iPad）" : "不支持（iPhone）",
            highlight: !VideoInputCapability.supportsExternalCamera))

        if VideoInputCapability.supportsExternalCamera {
            rows.append(StateRow(label: "已发现外接设备", value: "\(videoInput.externalDeviceCount) 台"))
        }

        if let info = videoInput.deviceInfo {
            rows.append(StateRow(label: "设备名称", value: info.name))
            rows.append(StateRow(label: "连接方式", value: info.connectionBadge))
            rows.append(StateRow(label: "分辨率", value: info.resolutionText))
            rows.append(StateRow(label: "设备声明帧率", value: info.frameRateText))
            rows.append(StateRow(label: "像素格式", value: info.pixelFormat ?? "系统未提供"))
        } else {
            rows.append(StateRow(label: "设备信息", value: "未取得（未连接，或系统未上报）"))
        }

        rows.append(StateRow(label: "实测到达帧率",
                             value: String(format: "%.1f fps", videoInput.measuredFPS),
                             highlight: videoInput.state.isRunning && videoInput.measuredFPS < 1))

        let stats = videoInput.stats
        rows.append(StateRow(label: "累计帧 / 丢弃 / 解码失败",
                             value: "\(stats.totalFrames) / \(stats.droppedFrames) / \(stats.decodeFailureCount)",
                             highlight: stats.decodeFailureCount > 0))
        if let age = stats.lastFrameAge {
            rows.append(StateRow(label: "距最近一帧",
                                 value: String(format: "%.1f 秒", age),
                                 highlight: age > 3))
        } else {
            rows.append(StateRow(label: "距最近一帧", value: "尚未收到任何帧"))
        }

        let pipeline = videoInput.pipelineDiagnostics
        rows.append(StateRow(label: "分析帧 / 跳过 / Vision 失败",
                             value: "\(pipeline.analyzedFrames) / \(pipeline.skippedFrames) / \(pipeline.visionFailures)",
                             highlight: pipeline.visionFailures > 0))
        rows.append(StateRow(label: "实测分析帧率",
                             value: String(format: "%.1f fps", pipeline.analysisFPS)))
        rows.append(StateRow(label: "上一帧分析耗时",
                             value: String(format: "%.1f ms", pipeline.lastAnalysisDuration * 1000)))
        rows.append(StateRow(label: "最近一帧检测到人",
                             value: pipeline.personDetectedInLastFrame ? "是" : "否"))
        return rows
    }

    // MARK: - 姿势库与照片库

    private var librarySection: some View {
        LumiCard {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "本地数据", subtitle: nil, trailingText: nil)
                InfoRow(label: "姿势库版本",
                        value: poseLibrary.databaseVersion == 0 ? "未加载" : "v\(poseLibrary.databaseVersion)")
                InfoRow(label: "姿势库条目", value: "\(poseLibrary.poses.count) 条")
                InfoRow(label: "照片副本", value: "\(photoLibrary.records.count) 张")
                InfoRow(label: "姿势收藏", value: "\(favorites.favoritePoseIDs.count) 条")
                InfoRow(label: "日志条数",
                        value: "\(log.entries.count) 条（错误 \(log.count(of: .error)) / 警告 \(log.count(of: .warning))）")
            }
        }
    }

    // MARK: - 中继连通性自检

    private var relayProbeSection: some View {
        LumiCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "中继连通性自检",
                              subtitle: "把「黑屏」拆成可定位的结论",
                              trailingText: isProbing ? "探测中" : nil)

                InfoRow(label: "当前中继地址", value: settings.relay.displayURL)
                InfoRow(label: "播放模式", value: settings.relay.mode.title)

                if let result = probeResult {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: result.isSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(result.isSuccess ? LumiTheme.success : LumiTheme.warning)
                            Text(result.title)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(LumiTheme.primaryText)
                        }
                        Text(result.summaryLine)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(LumiTheme.tertiaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(result.advice)
                            .font(.system(size: 12))
                            .foregroundStyle(LumiTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(LumiTheme.surfaceElevated)
                    .clipShape(RoundedRectangle(cornerRadius: LumiTheme.smallCornerRadius, style: .continuous))
                }

                HStack(spacing: 10) {
                    PrimaryButton(title: isProbing ? "探测中…" : "探测这个地址",
                                  symbol: "antenna.radiowaves.left.and.right",
                                  isEnabled: !isProbing && settings.relay.url != nil) {
                        runProbe()
                    }
                }

                if settings.relay.url == nil {
                    LimitationBadge(text: "当前中继地址无法解析成合法 URL，请先在设置里修正 IP 与端口。")
                }

                Text("探测只发一个 GET 请求，读到第一块画面数据就断开 —— 不会持续占用带宽，也不会在中继端留下长连接。")
                    .font(.system(size: 10))
                    .foregroundStyle(LumiTheme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 日志

    private var logSection: some View {
        LumiCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "内存日志",
                              subtitle: "最新在上，界面最多显示最近 80 条",
                              trailingText: "\(log.entries.count) 条")

                HStack(spacing: 8) {
                    ForEach(DiagnosticsLog.Level.allCases) { level in
                        SelectableChip(title: level.label,
                                       symbol: nil,
                                       isSelected: minLevel == level,
                                       tint: LumiTheme.accent) {
                            minLevel = level
                        }
                    }
                }

                if visibleEntries.isEmpty {
                    Text(minLevel == .debug
                         ? "还没有任何日志。连接一次视频输入后这里会有内容。"
                         : "没有达到「\(minLevel.label)」及以上级别的日志。")
                        .font(.system(size: 12))
                        .foregroundStyle(LumiTheme.tertiaryText)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(visibleEntries) { entry in
                            logRow(entry)
                            if entry.id != visibleEntries.last?.id {
                                Divider().overlay(LumiTheme.stroke)
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(LumiTheme.surfaceSunken)
                    .clipShape(RoundedRectangle(cornerRadius: LumiTheme.smallCornerRadius, style: .continuous))
                }

                SecondaryButton(title: "清空日志", symbol: "trash") {
                    log.clear()
                    copiedAt = nil
                }
            }
        }
    }

    private func logRow(_ entry: DiagnosticsLog.Entry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(DiagnosticsLog.timestampString(entry.date, timeZone: TimeZone.current))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(LumiTheme.tertiaryText)
                .padding(.top, 2)

            Image(systemName: entry.level.symbolName)
                .font(.system(size: 9))
                .foregroundStyle(levelColor(entry.level))
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.category.label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(LumiTheme.secondaryText)
                Text(entry.message)
                    .font(.system(size: 11))
                    .foregroundStyle(LumiTheme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
    }

    private func levelColor(_ level: DiagnosticsLog.Level) -> Color {
        switch level {
        case .debug: return LumiTheme.tertiaryText
        case .info: return LumiTheme.accent
        case .warning: return LumiTheme.warning
        case .error: return LumiTheme.danger
        }
    }

    // MARK: - 导出

    private var exportSection: some View {
        LumiCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "导出诊断报告",
                              subtitle: "纯文本，约 \(estimatedReportKB) KB",
                              trailingText: nil)

                PrimaryButton(title: "复制到剪贴板", symbol: "doc.on.doc") {
                    UIPasteboard.general.string = reportText
                    copiedAt = Date()
                    DiagnosticsLog.shared.info(.diagnostics, "诊断报告已复制（\(reportText.count) 字符）")
                }

                ShareLink(item: reportText, subject: Text("LUMI 诊断报告")) {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 13, weight: .semibold))
                        Text("导出 / 分享")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(LumiTheme.primaryText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(LumiTheme.surfaceElevated)
                    .clipShape(RoundedRectangle(cornerRadius: LumiTheme.smallCornerRadius, style: .continuous))
                }

                if let copiedAt {
                    Text("已复制（\(copiedAt.formatted(date: .omitted, time: .standard))）· 共 \(reportText.count) 字符")
                        .font(.system(size: 10))
                        .foregroundStyle(LumiTheme.success)
                }

                Text("复制后可直接粘贴到聊天窗口；导出可存成 .txt 或用其他 App 打开。报告不含任何影像内容。")
                    .font(.system(size: 10))
                    .foregroundStyle(LumiTheme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var estimatedReportKB: Int {
        max(1, reportText.utf8.count / 1024)
    }

    // MARK: - 报告

    private var reportText: String {
        var sections: [DiagnosticsReport.Section] = []

        sections.append(DiagnosticsReport.Section(
            title: "运行环境",
            lines: DiagnosticsReport.lines(from: environment.rows)))

        sections.append(DiagnosticsReport.Section(
            title: "权限状态",
            lines: DiagnosticsReport.lines(from: permissions.rows)))

        sections.append(DiagnosticsReport.Section(
            title: "视频输入（生成报告时的快照）",
            lines: videoStateRows.map { "\($0.label)：\($0.value)" }))

        sections.append(DiagnosticsReport.Section(
            title: "本地数据",
            lines: [
                "姿势库版本：\(poseLibrary.databaseVersion == 0 ? "未加载" : "v\(poseLibrary.databaseVersion)")",
                "姿势库条目：\(poseLibrary.poses.count) 条",
                "照片副本：\(photoLibrary.records.count) 张",
                "姿势收藏：\(favorites.favoritePoseIDs.count) 条"
            ]))

        var relayLines = [
            "中继地址：\(settings.relay.displayURL)",
            "播放模式：\(settings.relay.mode.title)"
        ]
        if let result = probeResult {
            relayLines.append("探测结果：\(result.title)")
            relayLines.append("探测详情：\(result.summaryLine)")
            relayLines.append("建议：\(result.advice)")
        } else {
            relayLines.append("探测结果：本次未执行（在页面上点「探测这个地址」可补上）")
        }
        sections.append(DiagnosticsReport.Section(title: "中继连通性", lines: relayLines))

        let entries = log.snapshot
        var logLines: [String] = []
        logLines.append("共 \(entries.count) 条（上限 \(log.capacity)）："
                        + "错误 \(log.count(of: .error)) / 警告 \(log.count(of: .warning)) / "
                        + "信息 \(log.count(of: .info)) / 调试 \(log.count(of: .debug))")
        if entries.isEmpty {
            logLines.append("（无日志）")
        } else {
            logLines.append(contentsOf: entries.map {
                DiagnosticsReport.entryLine($0, timeZone: TimeZone.current)
            })
        }
        sections.append(DiagnosticsReport.Section(title: "日志", lines: logLines))

        return DiagnosticsReport.render(
            generatedAt: Date(),
            timeZone: TimeZone.current,
            sections: sections,
            footer: """
            本报告由 LUMI AI Camera 在本机生成，未上传到任何服务器。
            日志仅存在于内存、不落盘，App 退出即清空；报告不含任何影像内容或人脸数据。
            如报告中出现「未知」，表示系统确实没有提供该项，而不是采集失败被隐藏。
            """)
    }

    private var visibleEntries: [DiagnosticsLog.Entry] {
        Array(log.entries
            .filter { $0.level.severity >= minLevel.severity }
            .suffix(80)
            .reversed())
    }

    // MARK: - 动作

    private func refresh() {
        environment = DiagnosticsEnvironment.measure()
        permissions = DiagnosticsPermissions.measure()
        DiagnosticsLog.shared.info(.diagnostics, "已刷新运行环境与权限快照")
    }

    private func runProbe() {
        guard let url = settings.relay.url else {
            DiagnosticsLog.shared.error(.network,
                                        "中继地址无法解析：\(settings.relay.host):\(settings.relay.port)\(settings.relay.path)")
            return
        }

        isProbing = true
        probeResult = nil
        DiagnosticsLog.shared.info(.network, "开始探测中继地址 \(url.absoluteString)")

        // 探测对象靠 URLSession 对 delegate 的强引用存活，直到我们自己 invalidate。
        let activeProbe = RelayProbe()
        activeProbe.probe(url: url, timeout: 6) { result in
            DispatchQueue.main.async {
                self.probeResult = result
                self.isProbing = false
                DiagnosticsLog.shared.record(result.isSuccess ? .info : .warning,
                                             .network,
                                             "探测结果：\(result.summaryLine)")
            }
        }
    }
}
