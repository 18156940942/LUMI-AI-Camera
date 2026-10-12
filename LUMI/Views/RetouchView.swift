import SwiftUI

/// 照片精修页。
///
/// 设计上有一条关键约束：**不能假装能用**。
/// 没开总开关、没填中继地址、地址不合法、中继连不上 —— 这些情况各自有明确文案，
/// 并且执行按钮会被禁用，而不是点下去转一圈然后什么也没发生。
struct RetouchView: View {

    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var retouch: RetouchStore
    @EnvironmentObject private var photoLibrary: PhotoLibraryStore

    @Environment(\.dismiss) private var dismiss

    let recordID: UUID

    @State private var catalog: RetouchPresetCatalog?
    @State private var catalogError: String?
    @State private var selectedPresetID: String = ""
    @State private var prompt: String = ""
    @State private var showsResult = true
    @State private var showsDeleteResult = false

    private var record: PhotoRecord? { photoLibrary.record(withID: recordID) }
    private var configuration: RetouchConfiguration { settings.retouch }
    private var state: RetouchJobState { retouch.state(for: recordID) }

    private var selectedPreset: RetouchPreset? {
        catalog?.preset(withID: selectedPresetID)
    }

    /// 现在能不能真的执行。四个条件逐条检查，任一条不满足都不让点。
    private var blockingReason: String? {
        guard let preset = selectedPreset else { return "请先选一条预设。" }
        if !configuration.isEnabled {
            return "精修功能未开启。到「设置 → 云端精修」打开总开关并填入电脑端中继地址。"
        }
        if configuration.normalizedRelayURL == nil {
            return configuration.relayURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "还没填电脑端中继地址。"
                : "中继地址不合法，请检查格式（形如 http://172.20.10.8:8091）。"
        }
        if preset.requiresPrompt && prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "这条预设需要填写文字指令。"
        }
        return nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    statusCard
                    if let catalogError {
                        errorCard(catalogError)
                    } else if catalog == nil {
                        LumiCard {
                            HStack(spacing: 8) {
                                ProgressView().scaleEffect(0.7).tint(LumiTheme.accent)
                                Text("正在读取预设目录…")
                                    .font(.system(size: 12))
                                    .foregroundStyle(LumiTheme.secondaryText)
                            }
                        }
                    } else {
                        presetSection
                        if selectedPreset?.requiresPrompt == true {
                            promptSection
                        }
                        intensitySection
                        actionSection
                    }
                    if retouch.hasUsableResult(for: recordID) {
                        resultSection
                    }
                    boundaryCard
                }
                .padding(LumiTheme.screenPadding)
                .padding(.bottom, 28)
            }
            .background(LumiTheme.background.ignoresSafeArea())
            .navigationTitle("照片精修")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }.foregroundStyle(LumiTheme.accent)
                }
            }
            .task(id: recordID) {
                if catalog == nil {
                    do {
                        catalog = try RetouchCatalogLoader.loadFromBundle()
                        selectedPresetID = configuration.defaultPresetID
                            ?? catalog?.presets.first?.id
                            ?? ""
                    } catch {
                        catalogError = error.localizedDescription
                    }
                }
                prompt = configuration.generativePrompt
            }
            .confirmationDialog("删除精修副本？", isPresented: $showsDeleteResult, titleVisibility: .visible) {
                Button("删除精修副本", role: .destructive) {
                    retouch.clearResult(for: recordID)
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("只删除这张照片的精修结果，原图与照片本身都不受影响。")
            }
        }
    }

    // MARK: - 状态

    private var statusCard: some View {
        LumiCard(highlighted: configuration.isReady) {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "中继状态",
                              subtitle: "照片会发到你自己电脑上的中继脚本处理",
                              trailingText: nil)
                InfoRow(label: "总开关", value: configuration.isEnabled ? "已开启" : "未开启")
                InfoRow(label: "中继地址",
                        value: configuration.relayURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "未填写"
                            : (configuration.normalizedRelayURL?.absoluteString ?? "不合法"))
                InfoRow(label: "当前状态", value: configuration.statusText)
            }
        }
    }

    private func errorCard(_ message: String) -> some View {
        LumiCard(highlighted: true) {
            VStack(alignment: .leading, spacing: 6) {
                Text("预设目录加载失败")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(LumiTheme.primaryText)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(LumiTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 预设

    private var presetSection: some View {
        LumiCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "选择精修方式",
                              subtitle: "前三类是确定性算法，只有生成式改动会改变画面内容",
                              trailingText: nil)

                ForEach(RetouchCategory.allCases) { category in
                    let items = catalog?.presets(in: category) ?? []
                    if !items.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Image(systemName: category.symbolName)
                                    .font(.system(size: 12))
                                    .foregroundStyle(category.requiresCloud ? LumiTheme.accent : LumiTheme.secondaryText)
                                Text(catalog?.info(for: category)?.title ?? category.fallbackTitle)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(LumiTheme.primaryText)
                                if category.requiresCloud {
                                    Text("需云端")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(LumiTheme.accent)
                                        .padding(.horizontal, 5).padding(.vertical, 2)
                                        .background(LumiTheme.accent.opacity(0.15))
                                        .clipShape(Capsule())
                                }
                            }
                            if let summary = catalog?.info(for: category)?.summary {
                                Text(summary)
                                    .font(.system(size: 10))
                                    .foregroundStyle(LumiTheme.tertiaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            ForEach(items) { preset in
                                presetRow(preset)
                            }
                        }
                    }
                }
            }
        }
    }

    private func presetRow(_ preset: RetouchPreset) -> some View {
        Button {
            selectedPresetID = preset.id
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: selectedPresetID == preset.id ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(selectedPresetID == preset.id ? LumiTheme.accent : LumiTheme.tertiaryText)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(LumiTheme.primaryText)
                    Text(preset.detail)
                        .font(.system(size: 10))
                        .foregroundStyle(LumiTheme.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 文字指令

    private var promptSection: some View {
        LumiCard {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "文字指令",
                              subtitle: "描述你想要的改动，会原样发给云端模型",
                              trailingText: nil)
                TextEditor(text: $prompt)
                    .font(.system(size: 12))
                    .foregroundStyle(LumiTheme.primaryText)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 76)
                    .padding(8)
                    .background(LumiTheme.surfaceElevated)
                    .clipShape(RoundedRectangle(cornerRadius: LumiTheme.smallCornerRadius, style: .continuous))
                Text("示例：把画面左侧的路人去掉 / 把天空换成黄昏的云")
                    .font(.system(size: 10))
                    .foregroundStyle(LumiTheme.tertiaryText)
            }
        }
    }

    // MARK: - 强度

    private var intensitySection: some View {
        LumiCard {
            VStack(alignment: .leading, spacing: 6) {
                SectionHeader(title: "强度", subtitle: nil, trailingText: "\(retouch.intensity)")
                Slider(value: Binding(
                    get: { Double(retouch.intensity) },
                    set: { retouch.intensity = Int($0.rounded()) }
                ), in: 0...100, step: 5)
                .tint(LumiTheme.accent)
                Text("生成式改动不使用这个值，它由上面的文字指令决定。")
                    .font(.system(size: 10))
                    .foregroundStyle(LumiTheme.tertiaryText)
            }
        }
    }

    // MARK: - 执行

    private var actionSection: some View {
        VStack(spacing: 10) {
            if let blockingReason {
                LumiCard(highlighted: true) {
                    Text(blockingReason)
                        .font(.system(size: 11))
                        .foregroundStyle(LumiTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if case .failed(_, let message) = state {
                LumiCard(highlighted: true) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("上一次失败")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(LumiTheme.danger)
                        Text(message)
                            .font(.system(size: 11))
                            .foregroundStyle(LumiTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            PrimaryButton(title: state.isRunning ? "处理中…" : "开始精修",
                          symbol: "wand.and.stars",
                          isEnabled: blockingReason == nil && !state.isRunning) {
                runRetouch()
            }
            if let message = retouch.lastMessage, !state.isRunning {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(LumiTheme.tertiaryText)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private func runRetouch() {
        guard let preset = selectedPreset,
              let url = configuration.normalizedRelayURL,
              let record else { return }

        let sourceURL = photoLibrary.fileURL(for: record)
        Task {
            guard let data = try? Data(contentsOf: sourceURL) else {
                retouch.reportLocalProblem("读不到这张照片的本地副本，无法精修。")
                return
            }
            await retouch.retouch(photoID: recordID,
                                  sourceData: data,
                                  preset: preset,
                                  relayBase: url,
                                  prompt: preset.requiresPrompt ? prompt : nil)
            // 记住用户填过的文字指令，下次不用重打
            if preset.requiresPrompt, settings.retouch.generativePrompt != prompt {
                settings.retouch.generativePrompt = prompt
            }
        }
    }

    // MARK: - 结果

    private var resultSection: some View {
        LumiCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "结果",
                              subtitle: "原图始终保留，这里只是并排看差异",
                              trailingText: nil)
                HStack(spacing: 8) {
                    comparisonPane(title: "原图", url: record.map { photoLibrary.fileURL(for: $0) })
                    comparisonPane(title: "精修后", url: retouch.resultURL(for: recordID))
                }
                if let info = retouch.record(for: recordID) {
                    InfoRow(label: "预设", value: catalog?.preset(withID: info.presetID)?.title ?? info.presetID)
                    InfoRow(label: "执行方", value: info.provider)
                    InfoRow(label: "完成时间", value: info.finishedAt.formatted(date: .abbreviated, time: .shortened))
                    InfoRow(label: "文件大小", value: ByteCountFormatter.string(fromByteCount: Int64(info.byteSize), countStyle: .file))
                }
                SecondaryButton(title: "删除精修副本", symbol: "trash", tint: LumiTheme.danger) {
                    showsDeleteResult = true
                }
            }
        }
    }

    private func comparisonPane(title: String, url: URL?) -> some View {
        VStack(spacing: 4) {
            ZStack {
                Color.black
                if let url, let image = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: image).resizable().scaledToFit()
                } else {
                    Text("—").foregroundStyle(LumiTheme.tertiaryText)
                }
            }
            .frame(height: 120)
            .clipShape(RoundedRectangle(cornerRadius: LumiTheme.smallCornerRadius, style: .continuous))
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(LumiTheme.tertiaryText)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 边界

    private var boundaryCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            LimitationBadge(text: "精修结果只存在 App 沙盒里，不会写回相册；你的原始照片永远不被修改。")
            LimitationBadge(text: "画质增强、调色与人像美化都在你自己电脑上算，照片不会离开本机；只有「生成式改动」会把照片发给你配置的云端服务商。")
            LimitationBadge(text: "本地算法是确定性运算，同样的输入永远得到同样的输出；云端生成式结果不确定，可能改动超出你的预期。")
        }
    }
}
