import SwiftUI

/// 照片详情：客观指标 + 分析结论 + 筛选建议。
struct PhotoDetailView: View {

    @EnvironmentObject private var store: PhotoLibraryStore
    @EnvironmentObject private var library: PoseLibrary
    // 精修结果与配置：详情页要显示「已精修」标记并给出入口
    @EnvironmentObject private var retouch: RetouchStore
    @EnvironmentObject private var settings: SettingsStore

    let recordID: UUID

    @State private var image: UIImage?
    @State private var showsDeletionConfirmation = false
    @State private var showsScenePicker = false
    @State private var showsRetouch = false

    private var record: PhotoRecord? { store.record(withID: recordID) }

    var body: some View {
        ScrollView {
            if let record {
                VStack(alignment: .leading, spacing: 16) {
                    preview(record)
                    if let analysis = record.analysis {
                        verdictCard(analysis)
                        metricsCard(analysis)
                        screeningCard(analysis)
                    } else {
                        LumiCard {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("尚未分析")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(LumiTheme.primaryText)
                                Text("点下方「重新分析」在本机完成清晰度、曝光、闭眼、构图与姿态分析。")
                                    .font(.system(size: 12))
                                    .foregroundStyle(LumiTheme.secondaryText)
                            }
                        }
                    }
                    exifCard(record)
                    poseCard(record)
                    compositionCard(record)
                    actions(record)
                }
                .padding(LumiTheme.screenPadding)
                .padding(.bottom, 28)
            } else {
                EmptyStateCard(symbol: "trash",
                               title: "记录已删除",
                               message: "这张照片的 App 内副本已被删除。",
                               actionTitle: nil,
                               action: nil)
                    .padding(LumiTheme.screenPadding)
            }
        }
        .background(LumiTheme.background.ignoresSafeArea())
        .navigationTitle(record?.displayName ?? "照片")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let record {
                    Button {
                        store.toggleFavorite(recordID: record.id)
                    } label: {
                        Image(systemName: record.isFavorite ? "heart.fill" : "heart")
                            .foregroundStyle(record.isFavorite ? LumiTheme.danger : LumiTheme.secondaryText)
                    }
                }
            }
        }
        .sheet(isPresented: $showsRetouch) {
            RetouchView(recordID: recordID)
        }
        .confirmationDialog("删除 App 内副本？", isPresented: $showsDeletionConfirmation, titleVisibility: .visible) {
            Button("删除 App 内副本", role: .destructive) {
                store.delete(recordID: recordID)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只会删除 LUMI 内的这份副本与分析记录。相册中的原始照片不会被删除，也不会被修改。")
        }
        .task(id: recordID) {
            guard let record else { return }
            let url = store.fileURL(for: record)
            let loaded = await Task.detached(priority: .userInitiated) {
                PhotoLibraryStore.downsampledImage(at: url, maxPixel: 1400)
            }.value
            image = loaded
        }
    }

    // MARK: - 预览

    private func preview(_ record: PhotoRecord) -> some View {
        ZStack {
            Color.black
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView().tint(LumiTheme.accent)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 260)
        .clipShape(RoundedRectangle(cornerRadius: LumiTheme.cornerRadius, style: .continuous))
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 6) {
                if store.analyzingRecordIDs.contains(record.id) {
                    ProgressView().scaleEffect(0.6).tint(.white)
                    Text("分析中…").font(.system(size: 10, weight: .semibold))
                } else {
                    Text(record.sizeText).font(.system(size: 10, weight: .semibold))
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.55))
            .clipShape(Capsule())
            .padding(10)
        }
    }

    // MARK: - 筛选结论

    private func verdictCard(_ analysis: PhotoAnalysisSummary) -> some View {
        let verdict = PhotoAnalyzer.verdict(for: analysis)
        let color: Color
        switch verdict {
        case .keep: color = LumiTheme.success
        case .review: color = LumiTheme.warning
        case .considerDiscard: color = LumiTheme.danger
        }
        return LumiCard(highlighted: true) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(color)
                    Text(verdict.title)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(color)
                    Spacer()
                    Text(String(format: "综合 %.0f 分", analysis.overallScore))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(LumiTheme.secondaryText)
                }
                Text("这是**辅助筛选建议**，由客观指标加权得出，最终取舍请以你的判断为准。")
                    .font(.system(size: 11))
                    .foregroundStyle(LumiTheme.tertiaryText)
            }
        }
    }

    // MARK: - 客观指标

    private func metricsCard(_ analysis: PhotoAnalysisSummary) -> some View {
        LumiCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "客观指标", subtitle: "全部由像素真实计算", trailingText: nil)
                HStack(spacing: 14) {
                    MetricTile(label: "清晰度",
                               value: String(format: "%.2f", analysis.sharpnessScore),
                               caption: analysis.sharpnessLabel,
                               accent: analysis.sharpnessLevel == .good ? LumiTheme.success : LumiTheme.warning)
                    MetricTile(label: "平均亮度",
                               value: "\(Int(analysis.brightness * 100))%",
                               caption: analysis.exposureLabel)
                    MetricTile(label: "明暗反差",
                               value: "\(Int(analysis.contrast * 100))%",
                               caption: "标准差归一化")
                }
                Divider().overlay(LumiTheme.stroke)
                InfoRow(label: "闭眼判定", value: analysis.closedEyeRisk.title,
                        valueColor: analysis.closedEyeRisk == .suspectedClosed ? LumiTheme.warning : LumiTheme.primaryText)
                Text(analysis.closedEyeRisk.caveat)
                    .font(.system(size: 10))
                    .foregroundStyle(LumiTheme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                InfoRow(label: "检测到人脸", value: "\(analysis.faceCount) 张")
                InfoRow(label: "人员数量", value: analysis.personCount > 0 ? "1 人" : "未检测到")
            }
        }
    }

    // MARK: - 建议

    private func screeningCard(_ analysis: PhotoAnalysisSummary) -> some View {
        LumiCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "筛选建议", subtitle: nil, trailingText: "\(analysis.suggestions.count) 条")
                ForEach(Array(analysis.suggestions.enumerated()), id: \.offset) { _, suggestion in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 10))
                            .foregroundStyle(LumiTheme.accent)
                            .padding(.top, 3)
                        Text(suggestion)
                            .font(.system(size: 12))
                            .foregroundStyle(LumiTheme.primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: - EXIF

    private func exifCard(_ record: PhotoRecord) -> some View {
        LumiCard {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "拍摄信息（EXIF）",
                              subtitle: "直接读取文件内元数据，缺失项显示为未提供",
                              trailingText: nil)

                if let exif = record.exif, exif.hasAnyValue {
                    ForEach(Array(exif.keyValuePairs.enumerated()), id: \.offset) { _, pair in
                        InfoRow(label: pair.0, value: pair.1)
                    }
                    if exif.hasExifDictionary == false {
                        Text("该文件没有 EXIF 段，以上信息来自容器元数据。")
                            .font(.system(size: 10))
                            .foregroundStyle(LumiTheme.tertiaryText)
                    }
                } else {
                    Text("该文件未提供可读的 EXIF 信息（可能已被导出工具剥离，或格式为截屏/微信图片）。LUMI 不会为此填充任何推测值。")
                        .font(.system(size: 12))
                        .foregroundStyle(LumiTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider().overlay(LumiTheme.stroke)
                InfoRow(label: "导入时间", value: formatted(record.importedAt))
                InfoRow(label: "文件大小", value: record.sizeText)
                HStack(spacing: 8) {
                    Text("拍摄场景标签")
                        .font(.system(size: 13))
                        .foregroundStyle(LumiTheme.secondaryText)
                    Spacer()
                    Menu {
                        Button("不分类") { store.setScene(nil, for: record.id) }
                        ForEach(PoseScene.allCases) { scene in
                            Button(scene.title) { store.setScene(scene, for: record.id) }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(record.sceneTag?.title ?? "未分类")
                                .font(.system(size: 13, weight: .medium))
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 9))
                        }
                        .foregroundStyle(LumiTheme.accent)
                    }
                }
            }
        }
    }

    private func formatted(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    // MARK: - 姿态结论

    private func poseCard(_ record: PhotoRecord) -> some View {
        LumiCard {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "姿态评估", subtitle: "基于 Vision 人体关键点", trailingText: nil)
                if let findings = record.analysis?.poseFindings, !findings.isEmpty {
                    ForEach(Array(findings.enumerated()), id: \.offset) { _, item in
                        Text("· " + item)
                            .font(.system(size: 12))
                            .foregroundStyle(LumiTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("没有可展示的姿态结论（未检测到人体，或该照片尚未分析）。")
                        .font(.system(size: 12))
                        .foregroundStyle(LumiTheme.tertiaryText)
                }
            }
        }
    }

    // MARK: - 构图结论

    private func compositionCard(_ record: PhotoRecord) -> some View {
        LumiCard {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "构图分析", subtitle: nil, trailingText: nil)
                if let findings = record.analysis?.compositionFindings, !findings.isEmpty {
                    ForEach(Array(findings.enumerated()), id: \.offset) { _, item in
                        Text("· " + item)
                            .font(.system(size: 12))
                            .foregroundStyle(LumiTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("没有可展示的构图结论。")
                        .font(.system(size: 12))
                        .foregroundStyle(LumiTheme.tertiaryText)
                }
            }
        }
    }

    // MARK: - 操作

    private func actions(_ record: PhotoRecord) -> some View {
        VStack(spacing: 10) {
            SecondaryButton(title: retouch.hasUsableResult(for: record.id) ? "查看 / 重新精修" : "精修这张照片",
                            symbol: "wand.and.stars",
                            tint: settings.retouch.isEnabled ? LumiTheme.accent : LumiTheme.secondaryText) {
                showsRetouch = true
            }
            SecondaryButton(title: "重新分析", symbol: "arrow.triangle.2.circlepath") {
                store.analyze(recordID: record.id)
            }
            SecondaryButton(title: record.isFavorite ? "取消收藏" : "收藏", symbol: "heart") {
                store.toggleFavorite(recordID: record.id)
            }
            SecondaryButton(title: "删除 App 内副本", symbol: "trash", tint: LumiTheme.danger) {
                showsDeletionConfirmation = true
            }
            LimitationBadge(text: "LUMI 不会删除或修改相册中的原始照片；此操作只影响 App 内的副本与分析记录。")
        }
    }
}
