import PhotosUI
import SwiftUI

/// 「AI 精修」主页。
///
/// **为什么需要这个页面。** 精修功能原本只挂在两处：照片详情页的操作按钮，
/// 以及设置页的配置项。结果是「功能其实存在，但界面上找不到」—— 用户直接反馈
/// 「在 LUMI 里并没有看到智能 AI 修图和调色功能」。这个页面把它提到首页入口级别。
///
/// 页面的信息结构**刻意先讲边界、再给操作**：
/// 精修必须有一个「执行方」（电脑端中继，或你配置的云端服务），
/// 没有执行方时按钮就该是禁用的，而不是点下去转一圈什么也不发生。
struct RetouchHubView: View {

    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var retouch: RetouchStore
    @EnvironmentObject private var photoLibrary: PhotoLibraryStore

    @Environment(\.dismiss) private var dismiss

    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var catalog: RetouchPresetCatalog?
    @State private var catalogError: String?
    @State private var selectedRecordID: UUID?
    @State private var openedRecordID: UUID?
    @State private var hint: String?

    private var configuration: RetouchConfiguration { settings.retouch }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    introCard
                    photoSection
                    if let catalogError {
                        errorCard(catalogError)
                    } else if catalog == nil {
                        loadingCard
                    } else {
                        quickActionSection
                        presetSection
                    }
                    boundaryCard
                }
                .padding(LumiTheme.screenPadding)
                .padding(.bottom, 28)
            }
            .background(LumiTheme.background.ignoresSafeArea())
            .navigationTitle("AI 精修")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }.foregroundStyle(LumiTheme.accent)
                }
                ToolbarItem(placement: .topBarLeading) {
                    PhotosPicker(selection: $pickerItems,
                                 maxSelectionCount: 1,
                                 matching: .images,
                                 photoLibrary: .shared()) {
                        Image(systemName: "square.and.arrow.down")
                            .foregroundStyle(LumiTheme.accent)
                    }
                }
            }
        }
        .task {
            loadCatalogIfNeeded()
            if selectedRecordID == nil {
                selectedRecordID = photoLibrary.records.first?.id
            }
        }
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await importPicked(items) }
        }
        .sheet(isPresented: Binding(
            get: { openedRecordID != nil },
            set: { if !$0 { openedRecordID = nil } }
        )) {
            if let id = openedRecordID {
                RetouchView(recordID: id)
            }
        }
    }

    // MARK: - 数据

    private func loadCatalogIfNeeded() {
        guard catalog == nil else { return }
        do {
            catalog = try RetouchCatalogLoader.loadFromBundle()
        } catch {
            catalogError = error.localizedDescription
        }
    }

    private func importPicked(_ items: [PhotosPickerItem]) async {
        let wrappers = items.map { item in
            PhotosPickerItemWrapper(suggestedName: nil) {
                try await item.loadTransferable(type: Data.self)
            }
        }
        _ = await photoLibrary.importItems(wrappers)
        // 导入完成后自动选中新进来的那一张 —— 用户来这里就是为了马上处理它。
        if let newest = photoLibrary.records.max(by: { $0.importedAt < $1.importedAt }) {
            selectedRecordID = newest.id
            hint = nil
        }
        pickerItems = []
    }

    private func openRetouch(with presetID: String) {
        guard selectedRecordID != nil else {
            hint = "先在上面选一张照片（或点左上角从相册导入），再选精修方式。"
            return
        }
        // 把选择传给详情页：它读的是 configuration.defaultPresetID
        settings.retouch.defaultPresetID = presetID
        hint = nil
        openedRecordID = selectedRecordID
    }

    // MARK: - 说明

    private var introCard: some View {
        LumiCard(highlighted: configuration.isReady) {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "AI 精修与调色",
                              subtitle: "画质 · 色调 · 人像 · 生成式改动",
                              trailingText: nil)
                Text("14 条预设分四类。「画质增强 / 风格化调色 / 人像美化」是确定性的像素运算，"
                     + "不改变画面内容，也不会把照片传出去；只有「生成式改动」会把照片"
                     + "发给你自己配置的云端服务。")
                    .font(.system(size: 11))
                    .foregroundStyle(LumiTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                Divider().overlay(LumiTheme.stroke)

                InfoRow(label: "执行方", value: "电脑端中继（你自己电脑上的脚本）")
                InfoRow(label: "当前状态", value: configuration.statusText)

                if let hint {
                    Text(hint)
                        .font(.system(size: 11))
                        .foregroundStyle(LumiTheme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
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

    private var loadingCard: some View {
        LumiCard {
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.7).tint(LumiTheme.accent)
                Text("正在读取预设目录…")
                    .font(.system(size: 12))
                    .foregroundStyle(LumiTheme.secondaryText)
            }
        }
    }

    // MARK: - 选照片

    private var photoSection: some View {
        LumiCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "选择照片",
                              subtitle: "App 内的副本，原图不会被修改",
                              trailingText: "\(photoLibrary.records.count) 张")

                if photoLibrary.records.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("还没有导入任何照片。")
                            .font(.system(size: 12))
                            .foregroundStyle(LumiTheme.secondaryText)
                        PhotosPicker(selection: $pickerItems,
                                     maxSelectionCount: 1,
                                     matching: .images,
                                     photoLibrary: .shared()) {
                            Label("从相册导入一张", systemImage: "plus.circle")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(LumiTheme.accent)
                        }
                    }
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(photoLibrary.records.prefix(24)) { record in
                                thumbnail(for: record)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }

    private func thumbnail(for record: PhotoRecord) -> some View {
        let isSelected = selectedRecordID == record.id
        return Button {
            selectedRecordID = record.id
            hint = nil
        } label: {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let image = photoLibrary.image(for: record, maxPixel: 240) {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        LumiTheme.surfaceElevated
                    }
                }
                .frame(width: 68, height: 68)
                .clipShape(RoundedRectangle(cornerRadius: LumiTheme.smallCornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: LumiTheme.smallCornerRadius, style: .continuous)
                        .stroke(isSelected ? LumiTheme.accent : LumiTheme.stroke,
                                lineWidth: isSelected ? 2 : 1)
                )

                if retouch.hasUsableResult(for: record.id) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(LumiTheme.success)
                        .padding(3)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - 一键精修

    private var quickActionSection: some View {
        VStack(spacing: 10) {
            if let reason = blockingReason {
                LumiCard(highlighted: true) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("暂时不能执行")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(LumiTheme.warning)
                        Text(reason)
                            .font(.system(size: 11))
                            .foregroundStyle(LumiTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            PrimaryButton(title: "一键精修这张照片",
                          symbol: "wand.and.stars",
                          isEnabled: blockingReason == nil) {
                openRetouch(with: configuration.defaultPresetID ?? "enhance.auto")
            }
        }
    }

    /// 现在能不能真的执行。与 `RetouchView` 同一套判据，避免两处说法不一致。
    private var blockingReason: String? {
        if photoLibrary.records.isEmpty { return "还没有导入照片。先用上面的「从相册导入」选一张。" }
        if selectedRecordID == nil { return "先在上面选一张照片。" }
        if !configuration.isEnabled {
            return "精修功能未开启。到「设置 → 云端精修」打开总开关，并填入电脑端中继地址。"
        }
        if configuration.normalizedRelayURL == nil {
            return configuration.relayURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "还没填电脑端中继地址。"
                : "中继地址不合法，请检查格式（形如 http://172.20.10.8:8091）。"
        }
        return nil
    }

    // MARK: - 预设

    private var presetSection: some View {
        LumiCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "精修方式",
                              subtitle: "点一条即用当前选中的照片执行",
                              trailingText: nil)

                ForEach(RetouchCategory.allCases) { category in
                    let items = catalog?.presets(in: category) ?? []
                    if !items.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
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
                                        .background(LumiTheme.accentSoft)
                                        .clipShape(Capsule())
                                }
                                Spacer(minLength: 0)
                            }
                            if let summary = catalog?.info(for: category)?.summary {
                                Text(summary)
                                    .font(.system(size: 10))
                                    .foregroundStyle(LumiTheme.tertiaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8),
                                                GridItem(.flexible(), spacing: 8)],
                                      spacing: 8) {
                                ForEach(items) { preset in
                                    presetTile(preset, category: category)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func presetTile(_ preset: RetouchPreset, category: RetouchCategory) -> some View {
        Button {
            openRetouch(with: preset.id)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: category.symbolName)
                    .font(.system(size: 14, weight: .light))
                    .foregroundStyle(category.requiresCloud ? LumiTheme.accent : LumiTheme.secondaryText)
                Text(preset.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LumiTheme.primaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, minHeight: 66, alignment: .topLeading)
            .padding(10)
            .background(LumiTheme.surfaceElevated)
            .overlay(
                RoundedRectangle(cornerRadius: LumiTheme.smallCornerRadius, style: .continuous)
                    .stroke(LumiTheme.stroke, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: LumiTheme.smallCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
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
