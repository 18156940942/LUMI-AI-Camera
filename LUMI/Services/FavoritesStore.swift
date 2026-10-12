import Foundation
import Combine

/// 姿势收藏与最近浏览。本地 UserDefaults 存储，离线可用。
final class FavoritesStore: ObservableObject {

    private enum Keys {
        static let favorites = "favorites.poseIDs"
        static let recent = "favorites.recentPoseIDs"
    }

    private let defaults: UserDefaults
    private let maxRecent = 20

    @Published private(set) var favoritePoseIDs: [String] = []
    @Published private(set) var recentPoseIDs: [String] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.favoritePoseIDs = defaults.stringArray(forKey: Keys.favorites) ?? []
        self.recentPoseIDs = defaults.stringArray(forKey: Keys.recent) ?? []
    }

    // MARK: - 收藏

    func isFavorite(_ poseID: String) -> Bool {
        favoritePoseIDs.contains(poseID)
    }

    /// 返回切换后的状态
    @discardableResult
    func toggleFavorite(_ poseID: String) -> Bool {
        if let index = favoritePoseIDs.firstIndex(of: poseID) {
            favoritePoseIDs.remove(at: index)
            defaults.set(favoritePoseIDs, forKey: Keys.favorites)
            return false
        } else {
            favoritePoseIDs.append(poseID)
            defaults.set(favoritePoseIDs, forKey: Keys.favorites)
            return true
        }
    }

    func removeAllFavorites() {
        favoritePoseIDs = []
        defaults.set(favoritePoseIDs, forKey: Keys.favorites)
    }

    /// 按收藏顺序返回姿势对象（找不到的被跳过，例如姿势库被删过条目）
    func favoritePoses(in library: PoseLibrary) -> [PoseSuggestion] {
        favoritePoseIDs.compactMap { library.pose(withID: $0) }
    }

    // MARK: - 最近浏览

    func markVisited(_ poseID: String) {
        var ids = recentPoseIDs.filter { $0 != poseID }
        ids.insert(poseID, at: 0)
        if ids.count > maxRecent { ids = Array(ids.prefix(maxRecent)) }
        recentPoseIDs = ids
        defaults.set(ids, forKey: Keys.recent)
    }
}
