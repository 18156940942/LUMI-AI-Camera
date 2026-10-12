import XCTest
@testable import LUMI

/// 对应需求里写死的维度：**12 类拍摄场景 + 7 类风格 + 4 种景别**。
/// 这些测试确保枚举集合本身没有少项、没有重复文案，也确保每个维度都有可展示的信息。
final class PoseTypesTests: XCTestCase {

    // MARK: - 场景（需求：12 类）

    func testThereAreExactlyTwelveScenes() {
        XCTAssertEqual(PoseScene.allCases.count, 12)
    }

    func testRequiredScenesAreAllPresent() {
        let expected: [PoseScene] = [.outdoorPortrait, .streetCity, .cafe, .travel, .studio,
                                     .couple, .halfBody, .fullBody, .sitting, .standing,
                                     .sideProfile, .lookingBack]
        XCTAssertEqual(Set(PoseScene.allCases), Set(expected))

        // 逐个核对需求里的中文名
        XCTAssertEqual(PoseScene.outdoorPortrait.title, "户外人像")
        XCTAssertEqual(PoseScene.streetCity.title, "城市街拍")
        XCTAssertEqual(PoseScene.cafe.title, "咖啡馆人像")
        XCTAssertEqual(PoseScene.travel.title, "旅行写真")
        XCTAssertEqual(PoseScene.studio.title, "棚拍人像")
        XCTAssertEqual(PoseScene.couple.title, "情侣写真")
        XCTAssertEqual(PoseScene.halfBody.title, "半身人像")
        XCTAssertEqual(PoseScene.fullBody.title, "全身人像")
        XCTAssertEqual(PoseScene.sitting.title, "坐姿人像")
        XCTAssertEqual(PoseScene.standing.title, "站姿人像")
        XCTAssertEqual(PoseScene.sideProfile.title, "侧身人像")
        XCTAssertEqual(PoseScene.lookingBack.title, "回头人像")
    }

    func testEverySceneHasIntentSymbolAndPreferredShotTypes() {
        for scene in PoseScene.allCases {
            XCTAssertFalse(scene.title.isEmpty)
            XCTAssertFalse(scene.intent.isEmpty, "\(scene.title) 缺少场景说明")
            XCTAssertFalse(scene.symbolName.isEmpty, "\(scene.title) 缺少图标")
            XCTAssertFalse(scene.preferredShotTypes.isEmpty,
                           "\(scene.title) 未声明偏好景别，构图分析会缺少参照")
            XCTAssertEqual(scene.id, scene.rawValue)
        }
    }

    func testSceneTitlesAndIntentsAreUnique() {
        let titles = PoseScene.allCases.map(\.title)
        XCTAssertEqual(Set(titles).count, titles.count, "场景标题重复会让 UI 无法区分")
        let intents = PoseScene.allCases.map(\.intent)
        XCTAssertEqual(Set(intents).count, intents.count, "场景说明重复说明是复制粘贴漏改")
    }

    // MARK: - 风格（需求：7 类）

    func testThereAreExactlySevenStyles() {
        XCTAssertEqual(PoseStyle.allCases.count, 7)
    }

    func testRequiredStylesAreAllPresent() {
        XCTAssertEqual(PoseStyle.naturalRelaxed.title, "自然松弛")
        XCTAssertEqual(PoseStyle.highFashion.title, "高级时尚")
        XCTAssertEqual(PoseStyle.gentleHealing.title, "温柔治愈")
        XCTAssertEqual(PoseStyle.coolCinematic.title, "清冷电影感")
        XCTAssertEqual(PoseStyle.retroFilm.title, "复古胶片")
        XCTAssertEqual(PoseStyle.sunnyVivid.title, "阳光活力")
        XCTAssertEqual(PoseStyle.minimalPremium.title, "极简高级")
    }

    func testEveryStyleHasKeywordsAndSymbol() {
        for style in PoseStyle.allCases {
            XCTAssertFalse(style.keywords.isEmpty, "\(style.title) 缺少关键词")
            XCTAssertFalse(style.symbolName.isEmpty, "\(style.title) 缺少图标")
            XCTAssertEqual(style.id, style.rawValue)
        }
    }

    // MARK: - 景别

    func testShotTypesAndHeightRatios() {
        XCTAssertEqual(ShotType.allCases.count, 4)
        XCTAssertEqual(ShotType.closeUp.title, "特写")
        XCTAssertEqual(ShotType.halfBody.title, "半身")
        XCTAssertEqual(ShotType.fullBody.title, "全身")
        XCTAssertEqual(ShotType.seated.title, "坐姿")

        for shotType in ShotType.allCases {
            let range = shotType.expectedSubjectHeightRatio
            XCTAssertGreaterThan(range.lowerBound, 0)
            XCTAssertLessThanOrEqual(range.upperBound, 1.0)
            XCTAssertLessThanOrEqual(range.lowerBound, range.upperBound)
        }
        // 全身构图里人物占比应明显高于特写之外的其他景别下界
        XCTAssertGreaterThan(ShotType.fullBody.expectedSubjectHeightRatio.lowerBound,
                             ShotType.halfBody.expectedSubjectHeightRatio.lowerBound)
    }

    // MARK: - 相关模型的可编码性

    /// `PoseSuggestion` 是 Codable，收藏与预设都依赖它 —— 编解码必须无损
    func testPoseSuggestionCodableRoundTrip() throws {
        let original = Fixtures.makePoseSuggestion()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PoseSuggestion.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testPoseCompositionTextHelpers() {
        let left = PoseComposition(horizontalAnchor: 0.2, headAnchor: 0.2,
                                   headroomRatio: 0.1, needsLeadRoom: true, note: "")
        XCTAssertTrue(left.horizontalAnchorText.contains("左侧") || left.horizontalAnchorText.contains("左三"))
        XCTAssertTrue(left.headroomText.contains("10%"))

        let centered = PoseComposition(horizontalAnchor: 0.5, headAnchor: 0.2,
                                       headroomRatio: 0.08, needsLeadRoom: false, note: "")
        XCTAssertTrue(centered.horizontalAnchorText.contains("居中"))
        XCTAssertTrue(centered.headroomText.contains("8%"))
    }

    func testPoseStepCategoriesHaveTitlesAndSymbols() {
        XCTAssertEqual(PoseStepCategory.allCases.count, 11)
        for category in PoseStepCategory.allCases {
            XCTAssertFalse(category.title.isEmpty)
            XCTAssertFalse(category.symbolName.isEmpty)
            XCTAssertEqual(category.rawValue, category.rawValue.lowercased())
        }
    }

    func testPoseRecommendationIdentityFollowsPose() {
        let pose = Fixtures.makePoseSuggestion(id: "identity-check")
        let recommendation = PoseRecommendation(pose: pose, score: 7, reasons: ["因为"])
        XCTAssertEqual(recommendation.id, "identity-check")
        XCTAssertEqual(recommendation.score, 7)
        XCTAssertEqual(recommendation.reasons, ["因为"])
    }
}
