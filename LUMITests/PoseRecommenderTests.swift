import XCTest
@testable import LUMI

/// 离线推荐引擎。
///
/// 这是「姿势推荐不用联网也能用」的实现基础，所以打分逻辑必须是显式、可断言、可复现的：
/// 给定同一组输入，永远得到同一个排序；每条推荐都能说清楚「为什么推荐它」。
final class PoseRecommenderTests: XCTestCase {

    private let recommender = PoseRecommender()
    private let weights = PoseRecommender.Weights.default

    private func query(scenes: Set<PoseScene> = [],
                       styles: Set<PoseStyle> = [],
                       shotType: ShotType? = nil,
                       maxDifficulty: Int = 3) -> PoseRecommender.Query {
        PoseRecommender.Query(scenes: scenes, styles: styles,
                              shotType: shotType, maxDifficulty: maxDifficulty)
    }

    // MARK: - 基本打分

    func testExactMatchOutranksMismatch() {
        let matching = Fixtures.makePoseSuggestion(
            id: "match-01",
            scenes: [.outdoorPortrait],
            styles: [.naturalRelaxed],
            shotType: .halfBody,
            difficulty: 1,
            keywords: []
        )
        let mismatching = Fixtures.makePoseSuggestion(
            id: "miss-01",
            scenes: [.studio],
            styles: [.highFashion],
            shotType: .fullBody,
            difficulty: 1,
            keywords: []
        )

        let results = recommender.recommend(
            from: [mismatching, matching],
            query: query(scenes: [.outdoorPortrait], styles: [.naturalRelaxed], shotType: .halfBody)
        )

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].pose.id, "match-01")
        // 场景 5 + 风格 4 + 景别 3
        XCTAssertEqual(results[0].score, 5 + 4 + 3)
        // 场景 -5 + 风格 -2 + 景别 -3
        XCTAssertEqual(results[1].score, -5 - 2 - 3)
    }

    func testMultipleSceneHitsAccumulate() {
        let pose = Fixtures.makePoseSuggestion(
            id: "multi-01",
            scenes: [.outdoorPortrait, .halfBody],
            styles: [],
            shotType: .seated,          // 不在两个场景的偏好景别里，避免混入加分
            difficulty: 1,
            keywords: []
        )
        let results = recommender.recommend(
            from: [pose],
            query: query(scenes: [.outdoorPortrait, .halfBody])
        )
        XCTAssertEqual(results.first?.score, weights.sceneMatch * 2)
    }

    func testStyleMismatchPenaltyIsHalfOfStyleWeight() {
        let pose = Fixtures.makePoseSuggestion(
            id: "style-miss",
            scenes: [],
            styles: [.naturalRelaxed],
            difficulty: 1,
            keywords: []
        )
        let results = recommender.recommend(from: [pose], query: query(styles: [.retroFilm]))
        XCTAssertEqual(results.first?.score, -(weights.styleMatch / 2))
    }

    func testScenePreferredShotTypeBonusWhenShotTypeNotSpecified() {
        let preferred = Fixtures.makePoseSuggestion(
            id: "pref-01",
            scenes: [.studio],
            styles: [],
            shotType: .closeUp,       // studio 偏好 closeUp / halfBody
            difficulty: 1,
            keywords: []
        )
        let other = Fixtures.makePoseSuggestion(
            id: "other-01",
            scenes: [.studio],
            styles: [],
            shotType: .fullBody,      // 不在偏好里
            difficulty: 1,
            keywords: []
        )
        let results = recommender.recommend(from: [other, preferred], query: query(scenes: [.studio]))

        let preferredScore = results.first { $0.pose.id == "pref-01" }?.score
        let otherScore = results.first { $0.pose.id == "other-01" }?.score
        XCTAssertEqual(preferredScore, weights.sceneMatch + weights.scenePreferredShotType)
        XCTAssertEqual(otherScore, weights.sceneMatch)
        XCTAssertEqual(results[0].pose.id, "pref-01")
    }

    // MARK: - 难度

    func testDifficultyPenaltyForHardPosesBeyondLimit() {
        let hard = Fixtures.makePoseSuggestion(id: "hard", difficulty: 3, keywords: [])
        let results = recommender.recommend(from: [hard], query: query(maxDifficulty: 1))
        // (3 - 1) * 3 = 6
        XCTAssertEqual(results.first?.score, -2 * weights.difficultyPenaltyPerLevel)
    }

    func testNoPenaltyWhenDifficultyWithinLimit() {
        let pose = Fixtures.makePoseSuggestion(id: "easy", difficulty: 3, keywords: [])
        let results = recommender.recommend(from: [pose], query: query(maxDifficulty: 3))
        XCTAssertEqual(results.first?.score, 0)
    }

    func testEasyPoseGetsExplainedInReasons() {
        let pose = Fixtures.makePoseSuggestion(id: "easy-01", difficulty: 1, keywords: [])
        let results = recommender.recommend(from: [pose], query: query(maxDifficulty: 2))
        XCTAssertTrue(results.first?.reasons.contains("不需要专业模特经验即可完成") ?? false,
                      "实际: \(results.first?.reasons ?? [])")
    }

    // MARK: - 排序稳定性

    func testTieIsBrokenByLowerDifficultyFirst() {
        let hard = Fixtures.makePoseSuggestion(id: "aaa-hard", difficulty: 3, keywords: [])
        let easy = Fixtures.makePoseSuggestion(id: "zzz-easy", difficulty: 1, keywords: [])
        let results = recommender.recommend(from: [hard, easy], query: query(maxDifficulty: 3))

        XCTAssertEqual(results.map(\.score), [0, 0], "两者分数应相同")
        XCTAssertEqual(results[0].pose.id, "zzz-easy",
                       "同分时应优先推荐更容易执行的姿势")
    }

    func testTieIsBrokenByIdWhenScoreAndDifficultyMatch() {
        let b = Fixtures.makePoseSuggestion(id: "b-pose", difficulty: 1, keywords: [])
        let a = Fixtures.makePoseSuggestion(id: "a-pose", difficulty: 1, keywords: [])
        let results = recommender.recommend(from: [b, a], query: query())

        XCTAssertEqual(results.map(\.pose.id), ["a-pose", "b-pose"],
                       "完全同分时必须给出确定性的顺序，否则 UI 每次刷新都会跳动")
    }

    func testRecommendationIsDeterministicAcrossRepeatedCalls() {
        let poses = (0..<8).map { index in
            Fixtures.makePoseSuggestion(id: "pose-\(index)",
                                        scenes: index % 2 == 0 ? [.outdoorPortrait] : [.studio],
                                        styles: index % 3 == 0 ? [.naturalRelaxed] : [.highFashion],
                                        difficulty: (index % 3) + 1,
                                        keywords: [])
        }
        let q = query(scenes: [.outdoorPortrait], styles: [.naturalRelaxed], maxDifficulty: 2)
        let first = recommender.recommend(from: poses, query: q).map(\.pose.id)
        let second = recommender.recommend(from: poses.shuffled(), query: q).map(\.pose.id)
        XCTAssertEqual(first, second, "输入顺序变化不应改变排序结果")
    }

    // MARK: - 结果完整性

    func testSceneMismatchNeverEmptiesTheResultSet() {
        let poses = [
            Fixtures.makePoseSuggestion(id: "p1", scenes: [.studio], keywords: []),
            Fixtures.makePoseSuggestion(id: "p2", scenes: [.cafe], keywords: []),
        ]
        let results = recommender.recommend(from: poses, query: query(scenes: [.couple]))
        XCTAssertEqual(results.count, 2,
                       "场景不匹配只应降权，不应把结果清空 —— 否则用户会看到「没有推荐」")
        XCTAssertTrue(results.allSatisfy { $0.score < 0 })
    }

    func testEmptyQueryReturnsAllPoses() {
        let poses = (0..<5).map { Fixtures.makePoseSuggestion(id: "p\($0)", keywords: []) }
        let results = recommender.recommend(from: poses, query: query(), limit: 100)
        XCTAssertEqual(results.count, 5)
        XCTAssertTrue(results.allSatisfy { $0.score == 0 })
    }

    func testLimitIsRespected() {
        let poses = (0..<30).map { Fixtures.makePoseSuggestion(id: "p\($0)", keywords: []) }
        XCTAssertEqual(recommender.recommend(from: poses, query: query(), limit: 5).count, 5)
        XCTAssertEqual(recommender.recommend(from: poses, query: query(), limit: 12).count, 12)
    }

    func testResultNeverExceedsInputSize() {
        let poses = (0..<3).map { Fixtures.makePoseSuggestion(id: "p\($0)", keywords: []) }
        XCTAssertEqual(recommender.recommend(from: poses, query: query(), limit: 50).count, 3)
    }

    func testEmptyInputProducesEmptyResult() {
        XCTAssertTrue(recommender.recommend(from: [], query: query()).isEmpty)
    }

    // MARK: - 推荐理由

    func testReasonsExplainSceneStyleAndShotTypeMatches() {
        let pose = Fixtures.makePoseSuggestion(
            id: "explain",
            scenes: [.outdoorPortrait],
            styles: [.naturalRelaxed],
            shotType: .halfBody,
            difficulty: 1,
            keywords: ["逆光", "回眸"]
        )
        let results = recommender.recommend(
            from: [pose],
            query: query(scenes: [.outdoorPortrait], styles: [.naturalRelaxed], shotType: .halfBody)
        )
        let reasons = results.first?.reasons ?? []
        XCTAssertTrue(reasons.contains { $0.contains("适合「户外人像」") }, "实际: \(reasons)")
        XCTAssertTrue(reasons.contains { $0.contains("风格贴合「自然松弛」") }, "实际: \(reasons)")
        XCTAssertTrue(reasons.contains { $0.contains("景别是半身") }, "实际: \(reasons)")
        XCTAssertTrue(reasons.contains { $0.hasPrefix("关键词：") }, "实际: \(reasons)")
    }

    func testScoreIsSumOfDocumentedWeights() {
        // 这条测试的作用是「把权重表钉住」：一旦有人改了权重而不同步更新文档，这里会失败
        XCTAssertEqual(weights.sceneMatch, 5)
        XCTAssertEqual(weights.styleMatch, 4)
        XCTAssertEqual(weights.shotTypeMatch, 3)
        XCTAssertEqual(weights.scenePreferredShotType, 2)
        XCTAssertEqual(weights.difficultyPenaltyPerLevel, 3)
    }
}
