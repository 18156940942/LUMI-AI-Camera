import SwiftUI

/// 页面 C：AI 姿势助手
///
/// 数据来自 App 包内的离线姿势库（``PoseLibrary``），推荐由本地规则引擎完成，
/// **不需要联网**，也不会调用任何云端 AI。
struct PoseAssistantView: View {

    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var library: PoseLibrary
    @EnvironmentObject private var favorites: FavoritesStore

    @StateObject private var viewModel = PoseAssistantViewModel()
    @State private var showsFilters = true

    private var results: [PoseRecommendation] {
        viewModel.results(library: library, favorites: favorites)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    modePicker
                    if showsFilters { filterSection }
                    resultSection
                }
                .padding(LumiTheme.screenPadding)
                .padding(.bottom, 28)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(LumiTheme.background.ignoresSafeArea())
            .navigationTitle("AI 姿势助手")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { showsFilters.toggle() }
                    } label: {
                        Image(systemName: showsFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                            .foregroundStyle(LumiTheme.secondaryText)
                    }
                }
            }
        }
    }

    // MARK: - 模式

    private var modePicker: some View {
        HStack(spacing: 8) {
            ForEach(PoseAssistantViewModel.BrowseMode.allCases) { mode in
                SelectableChip(title: mode.title,
                               symbol: nil,
                               isSelected: viewModel.mode == mode,
                               tint: LumiTheme.accent) {
                    viewModel.mode = mode
                }
            }
        }
    }

    // MARK: - 筛选

    private var filterSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            LumiCard {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: "拍摄场景",
                                  subtitle: "可多选，选得越具体推荐越准",
                                  trailingText: "\(viewModel.selectedScenes.count) 项")

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
                        ForEach(PoseScene.allCases) { scene in
                            SelectableChip(title: scene.title,
                                           symbol: scene.symbolName,
                                           isSelected: viewModel.selectedScenes.contains(scene),
                                           tint: LumiTheme.accent) {
                                viewModel.toggle(scene: scene)
                            }
                        }
                    }

                    Text(sceneHint)
                        .font(.system(size: 11))
                        .foregroundStyle(LumiTheme.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            LumiCard {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: "拍摄风格",
                                  subtitle: "影响动作幅度与眼神处理",
                                  trailingText: "\(viewModel.selectedStyles.count) 项")

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
                        ForEach(PoseStyle.allCases) { style in
                            SelectableChip(title: style.title,
                                           symbol: style.symbolName,
                                           isSelected: viewModel.selectedStyles.contains(style),
                                           tint: LumiTheme.accent) {
                                viewModel.toggle(style: style)
                            }
                        }
                    }
                }
            }

            LumiCard {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: "景别与难度", subtitle: nil, trailingText: nil)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 8)], spacing: 8) {
                        ForEach(ShotType.allCases) { type in
                            SelectableChip(title: type.title,
                                           symbol: nil,
                                           isSelected: viewModel.shotType == type,
                                           tint: LumiTheme.accent) {
                                viewModel.shotType = viewModel.shotType == type ? nil : type
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("难度上限")
                                .font(.system(size: 12))
                                .foregroundStyle(LumiTheme.secondaryText)
                            Spacer()
                            Text(difficultyText)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(LumiTheme.accent)
                        }
                        Slider(value: Binding(
                            get: { Double(viewModel.maxDifficulty) },
                            set: { viewModel.maxDifficulty = Int($0.rounded()) }
                        ), in: 1...3, step: 1)
                        .tint(LumiTheme.accent)
                    }

                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 12))
                            .foregroundStyle(LumiTheme.tertiaryText)
                        TextField("搜索姿势名称、环境、关键词", text: $viewModel.searchText)
                            .font(.system(size: 13))
                            .foregroundStyle(LumiTheme.primaryText)
                            .autocorrectionDisabled()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .background(LumiTheme.surfaceSunken)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

                    if viewModel.hasActiveFilters {
                        SecondaryButton(title: "清除全部筛选", symbol: "xmark.circle") {
                            viewModel.clearFilters()
                        }
                    }
                }
            }
        }
    }

    private var sceneHint: String {
        if viewModel.selectedScenes.isEmpty {
            return "未选择场景时会给出综合推荐。选择具体场景（例如「咖啡馆人像」+「半身人像」）可以得到更贴合的姿势。"
        }
        let intents = viewModel.selectedScenes.prefix(2).map { "\($0.title)：\($0.intent)" }
        return intents.joined(separator: "\n")
    }

    private var difficultyText: String {
        switch viewModel.maxDifficulty {
        case 1: return "仅新手可直接执行"
        case 2: return "中等以下"
        default: return "不限"
        }
    }

    // MARK: - 结果

    private var resultSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "姿势建议",
                          subtitle: viewModel.filterSummary,
                          trailingText: "\(results.count) 条")

            if let failure = library.loadFailure {
                HardwareRequirementCard(
                    title: "姿势库未加载",
                    requirement: failure,
                    reason: "姿势库是随 App 打包的离线 JSON 文件（Resources/pose_library.json）。",
                    alternatives: ["确认构建时把 pose_library.json 加入了 Copy Bundle Resources。"],
                    icon: "doc.questionmark",
                    tint: LumiTheme.danger
                )
            } else if results.isEmpty {
                EmptyStateCard(symbol: "magnifyingglass",
                               title: "没有匹配的姿势",
                               message: "当前筛选条件过窄。可以放宽景别、提高难度上限，或清除筛选重新看推荐结果。",
                               actionTitle: "清除筛选",
                               action: { viewModel.clearFilters() })
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(results) { recommendation in
                        NavigationLink {
                            PoseDetailView(pose: recommendation.pose, reasons: recommendation.reasons)
                        } label: {
                            PoseCardView(pose: recommendation.pose,
                                         reasons: recommendation.reasons,
                                         isFavorite: favorites.isFavorite(recommendation.pose.id)) {
                                favorites.toggleFavorite(recommendation.pose.id)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

/// 姿势卡片
struct PoseCardView: View {

    let pose: PoseSuggestion
    var reasons: [String] = []
    var isFavorite: Bool = false
    var onToggleFavorite: (() -> Void)?

    var body: some View {
        LumiCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(pose.name)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(LumiTheme.primaryText)
                        Text(pose.summary)
                            .font(.system(size: 12))
                            .foregroundStyle(LumiTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 6)
                    Button {
                        onToggleFavorite?()
                    } label: {
                        Image(systemName: isFavorite ? "heart.fill" : "heart")
                            .font(.system(size: 15))
                            .foregroundStyle(isFavorite ? LumiTheme.danger : LumiTheme.tertiaryText)
                            .padding(4)
                    }
                    .buttonStyle(.plain)
                }

                HStack(spacing: 6) {
                    StatusPill(text: pose.shotType.title, color: LumiTheme.accent, symbol: nil)
                    StatusPill(text: "难度 \(pose.difficulty)", color: difficultyColor, symbol: nil)
                    StatusPill(text: PoseScriptWriter.shortDigest(pose), color: LumiTheme.secondaryText, symbol: nil)
                }

                if !reasons.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(reasons.prefix(2).enumerated()), id: \.offset) { _, reason in
                            HStack(alignment: .top, spacing: 5) {
                                Image(systemName: "checkmark.circle")
                                    .font(.system(size: 9))
                                    .foregroundStyle(LumiTheme.accent)
                                    .padding(.top, 2)
                                Text(reason)
                                    .font(.system(size: 11))
                                    .foregroundStyle(LumiTheme.tertiaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }

                HStack(spacing: 5) {
                    Image(systemName: "arrow.right.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(LumiTheme.tertiaryText)
                    Text("查看完整动作分解（身体朝向 / 头部 / 视线 / 手位 / 重心 / 腿 / 机位）")
                        .font(.system(size: 10))
                        .foregroundStyle(LumiTheme.tertiaryText)
                }
            }
        }
    }

    private var difficultyColor: Color {
        switch pose.difficulty {
        case 1: return LumiTheme.success
        case 2: return LumiTheme.warning
        default: return LumiTheme.danger
        }
    }
}
