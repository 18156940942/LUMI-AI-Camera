import SwiftUI
import PhotosUI

/// 页面 E：照片管理
///
/// 明确的数据边界（页面顶部固定展示）：
/// - 只能导入**已经在系统相册里**的照片（即已经传输到 iPhone 的照片）；
/// - 无法读取相机存储卡，也不会声称能读取尚未传输的照片；
/// - 所有分析在设备本地完成，不上传。
struct PhotoLibraryView: View {

    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var store: PhotoLibraryStore

    @StateObject private var viewModel = PhotoLibraryViewModel()
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showsTransferGuide = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    boundaryNotice
                    actionRow
                    if store.records.isEmpty {
                        emptyState
                    } else {
                        groupingPicker
                        groupList
                    }
                }
                .padding(LumiTheme.screenPadding)
                .padding(.bottom, 28)
            }
            .background(LumiTheme.background.ignoresSafeArea())
            .navigationTitle("照片管理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    PhotosPicker(selection: $pickerItems,
                                 maxSelectionCount: 30,
                                 matching: .images,
                                 photoLibrary: .shared()) {
                        Image(systemName: "plus.circle")
                            .foregroundStyle(LumiTheme.accent)
                    }
                }
            }
        }
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            Task {
                let wrappers = items.map { item in
                    PhotosPickerItemWrapper(suggestedName: nil) {
                        try await item.loadTransferable(type: Data.self)
                    }
                }
                _ = await store.importItems(wrappers)
                pickerItems = []
            }
        }
        .confirmationDialog(deletionTitle,
                            isPresented: Binding(
                                get: { viewModel.pendingDeletion != nil || !viewModel.pendingBatchDeletion.isEmpty },
                                set: { if !$0 { viewModel.pendingDeletion = nil; viewModel.pendingBatchDeletion = [] } }
                            ),
                            titleVisibility: .visible) {
            Button("删除 App 内副本", role: .destructive) {
                if let record = viewModel.pendingDeletion {
                    store.delete(recordID: record.id)
                } else {
                    store.delete(recordIDs: viewModel.pendingBatchDeletion.map(\.id))
                }
                viewModel.pendingDeletion = nil
                viewModel.pendingBatchDeletion = []
            }
            Button("取消", role: .cancel) {
                viewModel.pendingDeletion = nil
                viewModel.pendingBatchDeletion = []
            }
        } message: {
            Text(deletionMessageText)
        }
        .confirmationDialog("清空 App 内全部照片记录？",
                            isPresented: $viewModel.showsDeleteAllConfirmation,
                            titleVisibility: .visible) {
            Button("清空 (\(store.records.count) 张)", role: .destructive) {
                store.deleteAll()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除 LUMI 内所有照片副本与分析记录，共 \(store.records.count) 张。相册中的原始照片不受影响。")
        }
    }

    // MARK: - 数据边界说明

    private var boundaryNotice: some View {
        LumiCard {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "关于导入：请先看清楚能做什么", subtitle: nil, trailingText: nil)
                Text("""
                · LUMI 通过系统照片选择器读取**你主动挑选的**照片，并在 App 内保存一份副本；
                · 所有清晰度、闭眼、构图、姿态分析都在**本机**完成，不会上传任何照片；
                · LUMI 无法读取相机存储卡，也无法读取尚未传输到 iPhone 的照片；
                · 若照片还在相机里，需要先通过相机 Wi-Fi（SnapBridge）、读卡器或 USB 传输到系统相册；
                · LUMI 永远不会删除或修改相册中的原始照片，删除操作只作用在 App 内的副本上。
                """)
                .font(.system(size: 11))
                .foregroundStyle(LumiTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

                SecondaryButton(title: "查看传输条件说明", symbol: "questionmark.circle") {
                    showsTransferGuide.toggle()
                }

                if showsTransferGuide {
                    Text("""
                    Nikon Z6 II 把照片传到 iPhone 的常见方式：
                    1) SnapBridge（相机 Wi-Fi/蓝牙）：只能传 JPEG，且需先在相机里开启无线连接并完成配对；RAW 通常无法传。
                    2) 读卡器：把 CFexpress/SD 卡插到 USB-C 读卡器，用「文件」App 复制进相册。速度最快，推荐用于批量。
                    3) 相机 USB-C 直连：Z6 II 可以被 iOS 识别为相机的存储设备（PTP），由系统「导入」功能复制照片。

                    传进相册后，回到本页点右上角「+」选择要分析的照片即可。
                    """)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(LumiTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .background(LumiTheme.surfaceSunken)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
            }
        }
    }

    // MARK: - 操作

    private var actionRow: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                PhotosPicker(selection: $pickerItems,
                             maxSelectionCount: 30,
                             matching: .images,
                             photoLibrary: .shared()) {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 13, weight: .semibold))
                        Text("导入照片")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundStyle(LumiTheme.onAccentText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(LumiTheme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: LumiTheme.smallCornerRadius, style: .continuous))
                }
                .buttonStyle(.plain)

                SecondaryButton(title: "全部重新分析", symbol: "arrow.triangle.2.circlepath") {
                    store.analyzeAll()
                }
                .disabled(store.records.isEmpty)
            }

            if store.isImporting {
                HStack(spacing: 8) {
                    ProgressView().tint(LumiTheme.accent)
                    Text("正在导入并分析…")
                        .font(.system(size: 12))
                        .foregroundStyle(LumiTheme.secondaryText)
                }
            }

            if let message = store.lastImportMessage {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(LumiTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let error = store.lastError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(LumiTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !store.records.isEmpty {
                SecondaryButton(title: "清空 App 内全部记录", symbol: "trash", tint: LumiTheme.danger) {
                    viewModel.showsDeleteAllConfirmation = true
                }
            }
        }
    }

    private var emptyState: some View {
        EmptyStateCard(symbol: "photo.stack",
                       title: "还没有导入照片",
                       message: "点上方「导入照片」，从系统相册选择要分析的照片。LUMI 会保存一份副本并在本地完成清晰度、曝光、闭眼、构图与姿态分析。",
                       actionTitle: nil,
                       action: nil)
    }

    private var groupingPicker: some View {
        HStack(spacing: 8) {
            ForEach(PhotoLibraryViewModel.Grouping.allCases) { mode in
                SelectableChip(title: mode.title,
                               symbol: nil,
                               isSelected: viewModel.grouping == mode,
                               tint: LumiTheme.accent) {
                    viewModel.grouping = mode
                }
            }
        }
    }

    private var groupList: some View {
        ForEach(viewModel.groups(from: store)) { group in
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: group.title, subtitle: nil, trailingText: "\(group.records.count) 张")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 8) {
                    ForEach(group.records) { record in
                        NavigationLink {
                            PhotoDetailView(recordID: record.id)
                        } label: {
                            PhotoCellView(record: record, store: store)
                            }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(record.isFavorite ? "取消收藏" : "收藏") {
                                store.toggleFavorite(recordID: record.id)
                            }
                            Button("重新分析") {
                                store.analyze(recordID: record.id)
                            }
                            Button("删除 App 内副本", role: .destructive) {
                                viewModel.pendingDeletion = record
                            }
                        }
                    }
                }
            }
            .padding(.top, 6)
        }
    }

    // MARK: - 删除确认

    private var deletionTitle: String {
        if viewModel.pendingDeletion != nil { return "删除这张照片的 App 内副本？" }
        if !viewModel.pendingBatchDeletion.isEmpty { return "删除这 \(viewModel.pendingBatchDeletion.count) 张照片的 App 内副本？" }
        return ""
    }

    private var deletionMessageText: String {
        if let record = viewModel.pendingDeletion {
            return viewModel.deletionMessage(for: [record])
        }
        return viewModel.deletionMessage(for: viewModel.pendingBatchDeletion)
    }
}

// MARK: - 缩略图单元

struct PhotoCellView: View {

    let record: PhotoRecord
    let store: PhotoLibraryStore

    @State private var image: UIImage?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    ZStack {
                        LumiTheme.surfaceElevated
                        Image(systemName: "photo")
                            .foregroundStyle(LumiTheme.tertiaryText)
                    }
                }
            }
            .frame(height: 116)
            .frame(maxWidth: .infinity)
            .clipped()

            VStack(alignment: .trailing, spacing: 4) {
                if record.isFavorite {
                    badge(symbol: "heart.fill", color: LumiTheme.danger)
                }
                if let analysis = record.analysis {
                    badge(symbol: verdictSymbol(analysis), color: verdictColor(analysis))
                }
                if store.analyzingRecordIDs.contains(record.id) {
                    ProgressView()
                        .scaleEffect(0.6)
                        .padding(4)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                }
            }
            .padding(5)

            VStack {
                Spacer()
                HStack(spacing: 4) {
                    if let iso = record.exif?.isoText {
                        Text(iso).font(.system(size: 8, weight: .semibold))
                    }
                    if let aperture = record.exif?.apertureText {
                        Text(aperture).font(.system(size: 8, weight: .semibold))
                    }
                    Spacer()
                    if let scene = record.sceneTag {
                        Text(scene.title).font(.system(size: 8, weight: .semibold))
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(Color.black.opacity(0.55))
            }
        }
        .frame(height: 116)
        .clipShape(RoundedRectangle(cornerRadius: LumiTheme.smallCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: LumiTheme.smallCornerRadius, style: .continuous)
                .stroke(LumiTheme.stroke, lineWidth: 1)
        )
        .task(id: record.id) {
            if image != nil { return }
            let url = store.fileURL(for: record)
            let loaded = await Task.detached(priority: .utility) {
                PhotoLibraryStore.downsampledImage(at: url, maxPixel: 320)
            }.value
            image = loaded
        }
    }

    private func badge(symbol: String, color: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .padding(4)
            .background(color.opacity(0.85))
            .clipShape(Circle())
    }

    private func verdictSymbol(_ analysis: PhotoAnalysisSummary) -> String {
        switch PhotoAnalyzer.verdict(for: analysis) {
        case .keep: return "checkmark"
        case .review: return "questionmark"
        case .considerDiscard: return "exclamationmark"
        }
    }

    private func verdictColor(_ analysis: PhotoAnalysisSummary) -> Color {
        switch PhotoAnalyzer.verdict(for: analysis) {
        case .keep: return LumiTheme.success
        case .review: return LumiTheme.warning
        case .considerDiscard: return LumiTheme.danger
        }
    }
}
