import SwiftUI

/// 页面 F 之外的「摄影辅助工具」页（需求第八节的全部工具集中在这里，且每项都可独立开关）。
struct ToolsView: View {

    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var videoInput: VideoInputManager
    @EnvironmentObject private var library: PoseLibrary
    @EnvironmentObject private var favorites: FavoritesStore

    @StateObject private var presetStore = PresetStore()
    @State private var noteDraft: String = ""
    @State private var noteSavedAt: Date?
    @State private var newPresetName = ""
    @State private var showsSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    overlayTools
                    exposureTool
                    notesTool
                    favoritesTool
                    presetsTool
                }
                .padding(LumiTheme.screenPadding)
                .padding(.bottom, 28)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(LumiTheme.background.ignoresSafeArea())
            .navigationTitle("摄影工具")
            .navigationBarTitleDisplayMode(.inline)
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
        .onAppear {
            presetStore.seedDefaultsIfNeeded()
            noteDraft = settings.shootingNotes
        }
    }

    // MARK: - 构图与参考线

    private var overlayTools: some View {
        LumiCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "构图辅助工具",
                                  subtitle: "每项独立开关，实时生效于监看画面",
                                  trailingText: nil)

                toolToggle("三分法网格", isOn: $settings.overlay.showThirds)
                toolToggle("九宫格构图线（细分）", isOn: $settings.overlay.showNineGrid)
                toolToggle("中心参考线（垂直）", isOn: $settings.overlay.showCenterLines)
                toolToggle("水平参考线", isOn: $settings.overlay.showHorizon)
                toolToggle("中心十字标记", isOn: $settings.overlay.showCenterCross)
                toolToggle("安全构图区", isOn: $settings.overlay.showSafeArea)
                toolToggle("人物检测框", isOn: $settings.overlay.showsSubjectBox)

                if settings.overlay.showSafeArea {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("安全区边距")
                                .font(.system(size: 12))
                                .foregroundStyle(LumiTheme.secondaryText)
                            Spacer()
                            Text("\(Int(settings.overlay.safeAreaInset * 100))%")
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(LumiTheme.accent)
                        }
                        Slider(value: $settings.overlay.safeAreaInset, in: 0.02...0.15, step: 0.01)
                            .tint(LumiTheme.accent)
                    }
                }

                Divider().overlay(LumiTheme.stroke)

                SectionHeader(title: "构图比例", subtitle: nil, trailingText: nil)
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
                LimitationBadge(text: "构图比例只绘制取景参考框，不会裁切视频源本身。")

                Divider().overlay(LumiTheme.stroke)
                SecondaryButton(title: "恢复默认参考线", symbol: "arrow.counterclockwise") {
                    settings.resetOverlayAndDisplay()
                }
            }
        }
    }

    private func toolToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(LumiTheme.primaryText)
        }
        .tint(LumiTheme.accent)
    }

    // MARK: - 曝光辅助

    private var exposureTool: some View {
        LumiCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "曝光辅助信息",
                              subtitle: "由画面像素真实计算",
                              trailingText: settings.liveExposureMeterEnabled ? "已开启" : "已关闭")

                toolToggle("启用亮度分布计量", isOn: $settings.liveExposureMeterEnabled)

                if let metrics = videoInput.exposureMetrics {
                    ExposureBar(mean: metrics.meanLuminance,
                                over: metrics.overexposedRatio,
                                under: metrics.underexposedRatio)
                    HStack(spacing: 14) {
                        MetricTile(label: "平均亮度", value: "\(metrics.brightnessPercent)%", caption: metrics.exposureLabel)
                        MetricTile(label: "高光溢出", value: String(format: "%.1f%%", metrics.overexposedPercent),
                                   caption: "亮度 ≥ 250 的像素占比",
                                   accent: metrics.overexposedRatio > 0.06 ? LumiTheme.warning : LumiTheme.primaryText)
                        MetricTile(label: "暗部欠曝", value: String(format: "%.1f%%", metrics.underexposedPercent),
                                   caption: "亮度 ≤ 5 的像素占比",
                                   accent: metrics.underexposedRatio > 0.35 ? LumiTheme.warning : LumiTheme.primaryText)
                    }
                } else {
                    Text(videoInput.state.isRunning
                         ? "等待第一帧以计算亮度分布…"
                         : "未连接视频输入。本项只在有真实像素可用时显示数值。")
                        .font(.system(size: 12))
                        .foregroundStyle(LumiTheme.tertiaryText)
                }

                LimitationBadge(text: "重要：这不是相机测光值。快门/光圈/ISO 属于相机内部状态，不会随 HDMI 画面传出，iOS 也无法从采集设备读取。此处显示的只是从画面像素算出的亮度分布。")
            }
        }
    }

    // MARK: - 拍摄备注

    private var notesTool: some View {
        LumiCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "拍摄备注",
                              subtitle: "自动保存在本机",
                              trailingText: noteSavedAt == nil ? nil : "已保存")

                TextEditor(text: $noteDraft)
                    .font(.system(size: 13))
                    .foregroundStyle(LumiTheme.primaryText)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 110)
                    .padding(8)
                    .background(LumiTheme.surfaceSunken)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

                HStack(spacing: 10) {
                    PrimaryButton(title: "保存备注", symbol: "checkmark") {
                        settings.shootingNotes = noteDraft
                        noteSavedAt = Date()
                    }
                    SecondaryButton(title: "清空", symbol: "trash") {
                        noteDraft = ""
                        settings.shootingNotes = ""
                        noteSavedAt = Date()
                    }
                }

                if let noteSavedAt {
                    Text("最近保存：\(noteSavedAt.formatted(date: .omitted, time: .shortened))（共 \(noteDraft.count) 字）")
                        .font(.system(size: 10))
                        .foregroundStyle(LumiTheme.tertiaryText)
                }
            }
        }
    }

    // MARK: - 姿势收藏

    private var favoritesTool: some View {
        LumiCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "姿势收藏",
                              subtitle: "拍摄现场快速取用",
                              trailingText: "\(favorites.favoritePoseIDs.count) 条")

                let poses = favorites.favoritePoses(in: library)
                if poses.isEmpty {
                    Text("还没有收藏姿势。到「姿势」页点卡片上的 ♡ 即可加入这里。")
                        .font(.system(size: 12))
                        .foregroundStyle(LumiTheme.tertiaryText)
                } else {
                    ForEach(poses) { pose in
                        NavigationLink {
                            PoseDetailView(pose: pose, reasons: [])
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "heart.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(LumiTheme.danger)
                                    .padding(.top, 3)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(pose.name)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(LumiTheme.primaryText)
                                    Text(PoseScriptWriter.shortDigest(pose))
                                        .font(.system(size: 10))
                                        .foregroundStyle(LumiTheme.tertiaryText)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10))
                                    .foregroundStyle(LumiTheme.tertiaryText)
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                        if pose.id != poses.last?.id {
                            Divider().overlay(LumiTheme.stroke)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 拍摄场景预设

    private var presetsTool: some View {
        LumiCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "拍摄场景预设",
                              subtitle: "一键套用参考线、构图比例与备注",
                              trailingText: "\(presetStore.presets.count) 组")

                ForEach(presetStore.presets) { preset in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top, spacing: 8) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(preset.name)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(LumiTheme.primaryText)
                                Text(preset.summary)
                                    .font(.system(size: 10))
                                    .foregroundStyle(LumiTheme.tertiaryText)
                                if !preset.note.isEmpty {
                                    Text(preset.note)
                                        .font(.system(size: 11))
                                        .foregroundStyle(LumiTheme.secondaryText)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Spacer(minLength: 4)
                            Button {
                                presetStore.delete(id: preset.id)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 12))
                                    .foregroundStyle(LumiTheme.tertiaryText)
                                    .padding(4)
                            }
                            .buttonStyle(.plain)
                        }
                        SecondaryButton(title: "套用这组预设", symbol: "wand.and.stars") {
                            settings.overlay = preset.overlay
                            noteDraft = preset.note
                            settings.shootingNotes = preset.note
                            noteSavedAt = Date()
                        }
                    }
                    .padding(10)
                    .background(LumiTheme.surfaceElevated)
                    .clipShape(RoundedRectangle(cornerRadius: LumiTheme.smallCornerRadius, style: .continuous))
                }

                Divider().overlay(LumiTheme.stroke)

                VStack(alignment: .leading, spacing: 8) {
                    Text("把当前设置存为新预设")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(LumiTheme.primaryText)
                    TextField("预设名称，例如「咖啡馆半身」", text: $newPresetName)
                        .font(.system(size: 13))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 9)
                        .background(LumiTheme.surfaceSunken)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    PrimaryButton(title: "保存当前参考线配置",
                                  symbol: "plus",
                                  isEnabled: !newPresetName.trimmingCharacters(in: .whitespaces).isEmpty) {
                        let preset = ShootingPreset(name: newPresetName.trimmingCharacters(in: .whitespaces),
                                                    overlay: settings.overlay,
                                                    note: settings.shootingNotes)
                        presetStore.add(preset)
                        newPresetName = ""
                    }
                }
            }
        }
    }
}

/// 亮度分布条：左暗右亮，标出过曝与欠曝区间
struct ExposureBar: View {
    let mean: Double
    let over: Double
    let under: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    LinearGradient(colors: [.black, .gray, .white],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(height: 10)
                        .clipShape(Capsule())

                    Rectangle()
                        .fill(LumiTheme.accent)
                        .frame(width: 2, height: 18)
                        .offset(x: max(min(width * CGFloat(mean), width - 2), 0))
                        .offset(y: -4)
                }
            }
            .frame(height: 18)

            HStack {
                Text(String(format: "欠曝 %.1f%%", under * 100))
                    .font(.system(size: 9))
                    .foregroundStyle(under > 0.35 ? LumiTheme.warning : LumiTheme.tertiaryText)
                Spacer()
                Text(String(format: "平均 %.0f%%", mean * 100))
                    .font(.system(size: 9))
                    .foregroundStyle(LumiTheme.secondaryText)
                Spacer()
                Text(String(format: "过曝 %.1f%%", over * 100))
                    .font(.system(size: 9))
                    .foregroundStyle(over > 0.06 ? LumiTheme.warning : LumiTheme.tertiaryText)
            }
        }
    }
}
