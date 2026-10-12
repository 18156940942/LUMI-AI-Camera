import SwiftUI

/// 页面 D：实时姿势指导
///
/// 显示内容与「真实检测」的对应关系（每一处都在 UI 上标清楚）：
/// - 骨架与关键点：当帧 Vision 人体姿态检测结果，低置信度关节会更暗更小；
/// - 角度数值：由关键点坐标计算的实测值；
/// - 头部转向：单目 2D 关键点估算值，标注「估算」；
/// - 提示文案：由实测值触发，低置信度时只输出「识别不稳定」而不给角度结论。
struct LivePoseCoachView: View {

    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var videoInput: VideoInputManager

    @Environment(\.dismiss) private var dismiss
    @State private var showsOverlayBox = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                videoArea
                if !videoInput.state.isRunning { notRunningHint }
                statusRow
                if videoInput.poseReport.isDetected {
                    confidenceRow
                    metricsGrid
                }
                tipsSection
                if settings.liveCompositionEnabled { compositionSection }
                controls
                conventionNote
            }
            .padding(LumiTheme.screenPadding)
            .padding(.bottom, 24)
        }
        .background(LumiTheme.background.ignoresSafeArea())
        .navigationTitle("实时姿势指导")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("完成") { dismiss() }
                    .foregroundStyle(LumiTheme.accent)
            }
        }
        .onAppear {
            if !settings.livePoseEnabled {
                settings.livePoseEnabled = true
            }
            videoInput.updateAnalysisOptions(analysisFPS: settings.analysisFPS,
                                            poseAnalysisEnabled: settings.livePoseEnabled,
                                            compositionAnalysisEnabled: settings.liveCompositionEnabled,
                                            exposureMeterEnabled: settings.liveExposureMeterEnabled)
        }
    }

    // MARK: - 画面

    private var videoArea: some View {
        MonitorVideoSurface(showsOverlay: true,
                            showsSkeleton: true,
                            subjectBox: showsOverlayBox ? videoInput.poseReport.boundingBox : nil,
                            showsStatusBar: false,
                            showsGuidance: true)
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: LumiTheme.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: LumiTheme.cornerRadius, style: .continuous)
                    .stroke(LumiTheme.strokeStrong, lineWidth: 1)
            )
    }

    private var notRunningHint: some View {
        LumiCard(highlighted: true) {
            VStack(alignment: .leading, spacing: 8) {
                Text("还没有视频输入")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(LumiTheme.primaryText)
                Text("实时姿势指导需要真实视频帧。请回到「监看」页选择输入方式并点「开始监看」——例如用网络中继把 Nikon Z6 II 的画面接过来。")
                    .font(.system(size: 12))
                    .foregroundStyle(LumiTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                PrimaryButton(title: "开始（沿用监看页的设置）", symbol: "play.fill") {
                    videoInput.start(kind: settings.videoInputKind,
                                     relay: settings.relay,
                                     analysisFPS: settings.analysisFPS,
                                     poseAnalysisEnabled: settings.livePoseEnabled,
                                     compositionAnalysisEnabled: settings.liveCompositionEnabled,
                                     exposureMeterEnabled: settings.liveExposureMeterEnabled)
                }
            }
        }
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            StatusPill(text: videoInput.state.shortLabel,
                       color: videoInput.state.isRunning ? LumiTheme.success : LumiTheme.warning,
                       symbol: "dot.radiowaves.left.and.right")
            if videoInput.measuredFPS > 0 {
                StatusPill(text: String(format: "画面 %.1f fps", videoInput.measuredFPS),
                           color: LumiTheme.accent, symbol: nil)
            }
            StatusPill(text: "分析 \(settings.analysisFPS) fps",
                       color: LumiTheme.warning, symbol: "brain")
            Spacer()
        }
    }

    private var confidenceRow: some View {
        ConfidenceBanner(level: videoInput.poseReport.reliability,
                         validJointCount: videoInput.poseReport.validJointCount)
    }

    // MARK: - 实测数值

    private var metricsGrid: some View {
        LumiCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "实测数值",
                              subtitle: "由关键点坐标计算，非估计值（标注除外）",
                              trailingText: nil)

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                          spacing: 12) {
                    metric("肩线倾斜", degrees(videoInput.poseReport.shoulderTiltDegrees), "画面右高为正")
                    metric("躯干倾斜", degrees(videoInput.poseReport.torsoLeanDegrees), "肩相对髋的偏移")
                    metric("头部转向", degrees(videoInput.poseReport.headTurnDegrees), "2D 关键点估算")
                    metric("头部歪斜", degrees(videoInput.poseReport.headTiltDegrees), "画面对比")
                    metric("左肘角度", degrees(videoInput.poseReport.leftElbowAngle), "越接近 180° 越直")
                    metric("右肘角度", degrees(videoInput.poseReport.rightElbowAngle), "越接近 180° 越直")
                    metric("左腕高度", videoInput.poseReport.leftWristZone ?? "—", "相对肩/髋分带")
                    metric("右腕高度", videoInput.poseReport.rightWristZone ?? "—", "相对肩/髋分带")
                }

                if let offset = videoInput.poseReport.personCenterOffset {
                    InfoRow(label: "人物中心相对画面中线",
                            value: String(format: "%@ %.1f%%",
                                          offset >= 0 ? "偏右" : "偏左",
                                          abs(offset) * 100))
                }
                InfoRow(label: "是否触及画面边缘",
                        value: videoInput.poseReport.reachingFrameEdge ? "是（存在裁切风险）" : "否",
                        valueColor: videoInput.poseReport.reachingFrameEdge ? LumiTheme.warning : LumiTheme.success)
            }
        }
    }

    private func metric(_ label: String, _ value: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(LumiTheme.monitorLabel)
                .foregroundStyle(LumiTheme.tertiaryText)
            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .monospaced))
                .foregroundStyle(LumiTheme.primaryText)
            Text(caption)
                .font(.system(size: 9))
                .foregroundStyle(LumiTheme.tertiaryText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func degrees(_ value: CGFloat?) -> String {
        guard let value else { return "—" }
        return String(format: "%.1f°", value)
    }

    // MARK: - 指导建议

    private var tipsSection: some View {
        LumiCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "实时指导",
                              subtitle: "每条都由实测值触发",
                              trailingText: "\(videoInput.poseReport.coachTips.count) 条")

                if videoInput.poseReport.coachTips.isEmpty {
                    Text(videoInput.state.isRunning
                         ? "等待检测到人物。请让被摄者进入画面。"
                         : "连接视频输入后开始分析。")
                        .font(.system(size: 12))
                        .foregroundStyle(LumiTheme.tertiaryText)
                } else {
                    ForEach(videoInput.poseReport.coachTips) { tip in
                        FindingRow(finding: tip, showsConfidence: settings.showsConfidenceBadges)
                        if tip.id != videoInput.poseReport.coachTips.last?.id {
                            Divider().overlay(LumiTheme.stroke)
                        }
                    }
                }
            }
        }
    }

    private var compositionSection: some View {
        LumiCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "构图分析", subtitle: videoInput.compositionReport.detectionSource, trailingText: nil)
                if videoInput.compositionReport.findings.isEmpty {
                    Text("暂无结论。")
                        .font(.system(size: 12))
                        .foregroundStyle(LumiTheme.tertiaryText)
                } else {
                    ForEach(videoInput.compositionReport.findings.prefix(5)) { finding in
                        FindingRow(finding: finding, showsConfidence: settings.showsConfidenceBadges)
                    }
                }
            }
        }
    }

    // MARK: - 控制

    private var controls: some View {
        LumiCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "分析控制", subtitle: nil, trailingText: nil)
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

                Toggle(isOn: $showsOverlayBox) {
                    Text("显示人物检测框")
                        .font(.system(size: 13))
                        .foregroundStyle(LumiTheme.primaryText)
                }
                .tint(LumiTheme.accent)

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
        }
        .onChange(of: settings.livePoseEnabled) { _, _ in
            videoInput.updateAnalysisOptions(analysisFPS: settings.analysisFPS,
                                            poseAnalysisEnabled: settings.livePoseEnabled,
                                            compositionAnalysisEnabled: settings.liveCompositionEnabled,
                                            exposureMeterEnabled: settings.liveExposureMeterEnabled)
        }
        .onChange(of: settings.liveCompositionEnabled) { _, _ in
            videoInput.updateAnalysisOptions(analysisFPS: settings.analysisFPS,
                                            poseAnalysisEnabled: settings.livePoseEnabled,
                                            compositionAnalysisEnabled: settings.liveCompositionEnabled,
                                            exposureMeterEnabled: settings.liveExposureMeterEnabled)
        }
        .onChange(of: settings.analysisFPS) { _, _ in
            videoInput.updateAnalysisOptions(analysisFPS: settings.analysisFPS,
                                            poseAnalysisEnabled: settings.livePoseEnabled,
                                            compositionAnalysisEnabled: settings.liveCompositionEnabled,
                                            exposureMeterEnabled: settings.liveExposureMeterEnabled)
        }
    }

    private var conventionNote: some View {
        LumiCard {
            VStack(alignment: .leading, spacing: 6) {
                Text("方向约定")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(LumiTheme.primaryText)
                Text("""
                所有左右描述都以**监看画面**为准（「画面左」＝画面左侧），因为使用者是摄影师，\
                摄影师看到的就是画面。这样「画面左侧肩膀低了 6°」这类提示可以直接照着画面调整，不会左右颠倒。

                已知限制：头部转动角度来自单目 2D 关键点估算，正对与背对时都可能偏大；\
                身体严重遮挡或逆光时关键点会失效，此时 App 只提示「识别不稳定」，不会给出角度结论。
                """)
                .font(.system(size: 11))
                .foregroundStyle(LumiTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
