import Foundation
import Combine
import SwiftUI

/// 姿势助手页面的视图模型。
///
/// 所有筛选与推荐都在本地完成（``PoseLibrary`` + ``PoseRecommender``），
/// 因此户外无网络时同样可用。
final class PoseAssistantViewModel: ObservableObject {

    enum BrowseMode: String, CaseIterable, Identifiable {
        case recommended
        case favorites
        case all

        var id: String { rawValue }

        var title: String {
            switch self {
            case .recommended: return "智能推荐"
            case .favorites: return "我的收藏"
            case .all: return "全部姿势"
            }
        }
    }

    @Published var selectedScenes: Set<PoseScene> = []
    @Published var selectedStyles: Set<PoseStyle> = []
    @Published var shotType: ShotType?
    @Published var maxDifficulty: Int = 3
    @Published var searchText: String = ""
    @Published var mode: BrowseMode = .recommended

    // MARK: - 筛选

    func toggle(scene: PoseScene) {
        if selectedScenes.contains(scene) {
            selectedScenes.remove(scene)
        } else {
            selectedScenes.insert(scene)
        }
    }

    func toggle(style: PoseStyle) {
        if selectedStyles.contains(style) {
            selectedStyles.remove(style)
        } else {
            selectedStyles.insert(style)
        }
    }

    func clearFilters() {
        selectedScenes.removeAll()
        selectedStyles.removeAll()
        shotType = nil
        maxDifficulty = 3
        searchText = ""
    }

    var hasActiveFilters: Bool {
        !selectedScenes.isEmpty || !selectedStyles.isEmpty || shotType != nil || maxDifficulty < 3 || !searchText.isEmpty
    }

    var filterSummary: String {
        var parts: [String] = []
        if !selectedScenes.isEmpty {
            parts.append(selectedScenes.map(\.title).sorted().joined(separator: "、"))
        }
        if !selectedStyles.isEmpty {
            parts.append(selectedStyles.map(\.title).sorted().joined(separator: "、"))
        }
        if let shotType {
            parts.append(shotType.title)
        }
        if maxDifficulty < 3 {
            parts.append("难度 ≤ \(maxDifficulty)")
        }
        if !searchText.isEmpty {
            parts.append("搜索「\(searchText)」")
        }
        return parts.isEmpty ? "未设置筛选条件，按综合匹配度排序" : parts.joined(separator: " · ")
    }

    // MARK: - 结果

    func results(library: PoseLibrary, favorites: FavoritesStore) -> [PoseRecommendation] {
        let base: [PoseRecommendation]

        switch mode {
        case .favorites:
            let favoritePoses = favorites.favoritePoses(in: library)
            base = favoritePoses.map { PoseRecommendation(pose: $0, score: 100, reasons: ["你收藏过这条姿势"]) }
        case .all:
            base = library.poses.map { PoseRecommendation(pose: $0, score: 0, reasons: []) }
        case .recommended:
            base = library.recommend(scenes: selectedScenes,
                                     styles: selectedStyles,
                                     shotType: shotType,
                                     maxDifficulty: maxDifficulty,
                                     limit: 40)
        }

        var filtered = base

        if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            let matchedIDs = Set(library.search(searchText).map(\.id))
            filtered = filtered.filter { matchedIDs.contains($0.pose.id) }
        }

        if maxDifficulty < 3 {
            filtered = filtered.filter { $0.pose.difficulty <= maxDifficulty }
        }

        // 「智能推荐」模式下应用了场景/风格筛选；其他模式也保持一致的可预期行为
        if mode != .recommended {
            if !selectedScenes.isEmpty {
                filtered = filtered.filter { !$0.pose.scenes.isEmpty && !Set($0.pose.scenes).isDisjoint(with: selectedScenes) }
            }
            if !selectedStyles.isEmpty {
                filtered = filtered.filter { !Set($0.pose.styles).isDisjoint(with: selectedStyles) }
            }
            if let shotType {
                filtered = filtered.filter { $0.pose.shotType == shotType }
            }
        }

        return filtered
    }
}
