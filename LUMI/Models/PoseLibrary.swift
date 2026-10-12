import Foundation
import Combine

/// 姿势库：从 App 包内读取离线 JSON 数据库。
///
/// 关键点：**姿势推荐不依赖网络**。打开页面即出结果，户外无信号也能用。
/// JSON 文件是唯一的数据源，方便你自己继续往里加姿势而不需要改代码。
final class PoseLibrary: ObservableObject {

    /// 解析出的全部姿势
    @Published private(set) var poses: [PoseSuggestion] = []
    /// 读取失败时的原因；UI 会如实展示，而不是静默显示空列表
    @Published private(set) var loadFailure: String?
    @Published private(set) var databaseVersion: Int = 0

    private let recommender = PoseRecommender()

    // MARK: - JSON 容器

    private struct Database: Decodable {
        let version: Int
        let poses: [PoseSuggestion]
    }

    // MARK: - 初始化

    /// 从 App 包中读取（默认路径）
    init(bundle: Bundle = .main, fileName: String = "pose_library") {
        load(bundle: bundle, fileName: fileName)
    }

    /// 测试与预览用：直接注入内存数据
    init(poses: [PoseSuggestion]) {
        self.poses = poses
        self.databaseVersion = 0
    }

    private func load(bundle: Bundle, fileName: String) {
        guard let url = bundle.url(forResource: fileName, withExtension: "json") else {
            loadFailure = "未在 App 包中找到 \(fileName).json，姿势库为空。"
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let db = try JSONDecoder().decode(Database.self, from: data)
            poses = db.poses
            databaseVersion = db.version
            loadFailure = nil
            AppLog.poseLibrary.info("姿势库加载完成，共 \(db.poses.count) 条，版本 \(db.version)")
        } catch {
            poses = []
            loadFailure = "姿势库解析失败：\(error.localizedDescription)"
            AppLog.poseLibrary.error("姿势库解析失败: \(String(describing: error))")
        }
    }

    // MARK: - 查询

    func pose(withID id: String) -> PoseSuggestion? {
        poses.first { $0.id == id }
    }

    func poses(in scene: PoseScene) -> [PoseSuggestion] {
        poses.filter { $0.scenes.contains(scene) }
    }

    func poses(with style: PoseStyle) -> [PoseSuggestion] {
        poses.filter { $0.styles.contains(style) }
    }

    /// 全部出现过的场景（按枚举声明顺序，保证 UI 顺序稳定）
    var availableScenes: [PoseScene] {
        PoseScene.allCases.filter { scene in poses.contains { $0.scenes.contains(scene) } }
    }

    var availableStyles: [PoseStyle] {
        PoseStyle.allCases.filter { style in poses.contains { $0.styles.contains(style) } }
    }

    // MARK: - 推荐

    func recommend(scenes: Set<PoseScene>,
                   styles: Set<PoseStyle>,
                   shotType: ShotType?,
                   maxDifficulty: Int = 3,
                   limit: Int = 12) -> [PoseRecommendation] {
        let query = PoseRecommender.Query(scenes: scenes,
                                          styles: styles,
                                          shotType: shotType,
                                          maxDifficulty: maxDifficulty)
        return recommender.recommend(from: poses, query: query, limit: limit)
    }

    /// 关键词检索（名称、摘要、环境、关键词、摄影提示都可命中）
    func search(_ text: String) -> [PoseSuggestion] {
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return poses }
        return poses.filter { pose in
            if pose.name.lowercased().contains(key) { return true }
            if pose.summary.lowercased().contains(key) { return true }
            if pose.environment.lowercased().contains(key) { return true }
            if pose.photographerTips.lowercased().contains(key) { return true }
            if pose.keywords.contains(where: { $0.lowercased().contains(key) }) { return true }
            if pose.scenes.contains(where: { $0.title.contains(key) }) { return true }
            if pose.styles.contains(where: { $0.title.contains(key) }) { return true }
            return false
        }
    }
}
