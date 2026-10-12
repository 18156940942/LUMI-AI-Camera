import Foundation

/// 本地离线推荐引擎。
///
/// 完全在设备上运行：不联网、不调用任何云端大模型、结果可重复。
/// 打分逻辑是显式且可测试的，因此「为什么推荐这条」可以在 UI 上如实说明。
struct PoseRecommender {

    struct Query: Hashable {
        var scenes: Set<PoseScene> = []
        var styles: Set<PoseStyle> = []
        var shotType: ShotType? = nil
        /// 用户能接受的难度上限（1...3）
        var maxDifficulty: Int = 3
    }

    /// 权重集中在这里，方便单测与后续调参。
    struct Weights {
        var sceneMatch = 5
        var styleMatch = 4
        var shotTypeMatch = 3
        var scenePreferredShotType = 2
        var difficultyPenaltyPerLevel = 3

        static let `default` = Weights()
    }

    let weights: Weights

    init(weights: Weights = .default) {
        self.weights = weights
    }

    func recommend(from poses: [PoseSuggestion], query: Query, limit: Int = 12) -> [PoseRecommendation] {
        let scored: [PoseRecommendation] = poses.compactMap { pose in
            var score = 0
            var reasons: [String] = []

            // 场景匹配：命中越多分越高，但一条姿势一般只标注 1-3 个场景
            let sceneHits = pose.scenes.filter { query.scenes.contains($0) }
            if !query.scenes.isEmpty {
                if sceneHits.isEmpty {
                    // 场景不匹配不是硬性排除，只大幅降权，保证结果永远不为空
                    score -= weights.sceneMatch
                } else {
                    score += weights.sceneMatch * sceneHits.count
                    reasons.append("适合「\(sceneHits.map(\.title).joined(separator: "、"))」")
                }
            }

            let styleHits = pose.styles.filter { query.styles.contains($0) }
            if !query.styles.isEmpty {
                if styleHits.isEmpty {
                    score -= weights.styleMatch / 2
                } else {
                    score += weights.styleMatch * styleHits.count
                    reasons.append("风格贴合「\(styleHits.map(\.title).joined(separator: "、"))」")
                }
            }

            if let wanted = query.shotType {
                if pose.shotType == wanted {
                    score += weights.shotTypeMatch
                    reasons.append("景别是\(wanted.title)")
                } else {
                    score -= weights.shotTypeMatch
                }
            } else if !query.scenes.isEmpty {
                // 未指定景别时，用场景倾向的景别加成
                let preferred = Set(query.scenes.flatMap(\.preferredShotTypes))
                if preferred.contains(pose.shotType) {
                    score += weights.scenePreferredShotType
                }
            }

            if pose.difficulty > query.maxDifficulty {
                score -= (pose.difficulty - query.maxDifficulty) * weights.difficultyPenaltyPerLevel
            } else if pose.difficulty == 1 && query.maxDifficulty >= 1 {
                reasons.append("不需要专业模特经验即可完成")
            }

            // 关键词带给用户一个「为什么是这条」的直观解释
            if !pose.keywords.isEmpty {
                reasons.append("关键词：" + pose.keywords.prefix(3).joined(separator: " / "))
            }

            return PoseRecommendation(pose: pose, score: score, reasons: reasons)
        }

        let sorted = scored.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            // 同分时按难度升序，让新手优先拿到好执行的姿势
            if lhs.pose.difficulty != rhs.pose.difficulty { return lhs.pose.difficulty < rhs.pose.difficulty }
            return lhs.pose.id < rhs.pose.id
        }

        return Array(sorted.prefix(limit))
    }
}
