import XCTest
@testable import LUMI

/// `PoseScriptWriter` 是姿势助手「真的能用」的关键：
/// 输出必须是**具体可执行**的指令（方向、角度、手放哪里、重心在哪条腿），
/// 而不是「放松一点」这类形容词。
///
/// 更重要的是一条一致性约束：文字里的角度**必须由参数生成**。
/// 这样就不可能出现「参数写 30°、文案写 45°」这种自相矛盾。
final class PoseScriptWriterTests: XCTestCase {

    // MARK: - 身体朝向

    func testBodyTextEmbedsRotationDegreesAndDirectionFromParameters() {
        let pose = Fixtures.makePoseSuggestion(
            bodyRotation: PoseRotation(degrees: 30, direction: .left)
        )
        let text = PoseScriptWriter.bodyText(pose)
        XCTAssertTrue(text.contains("向左侧旋转约 30°"),
                      "角度必须来自参数，实际: \(text)")
    }

    func testBodyTextChangesWithParametersToStayConsistent() {
        let fortyFive = Fixtures.makePoseSuggestion(
            bodyRotation: PoseRotation(degrees: 45, direction: .right)
        )
        let text = PoseScriptWriter.bodyText(fortyFive)
        XCTAssertTrue(text.contains("向右侧旋转约 45°"))
        XCTAssertFalse(text.contains("30"), "不应残留旧角度")
    }

    func testBodyTextForFacingPoseDoesNotMentionRotation() {
        let pose = Fixtures.makePoseSuggestion(bodyRotation: .facing)
        let text = PoseScriptWriter.bodyText(pose)
        XCTAssertTrue(text.contains("正对镜头"))
        XCTAssertFalse(text.contains("旋转"))
    }

    // MARK: - 头部

    func testHeadTextCombinesTurnAndChinCue() {
        let pose = Fixtures.makePoseSuggestion(
            headTurn: PoseRotation(degrees: 20, direction: .right),
            chin: .down5
        )
        let text = PoseScriptWriter.headText(pose)
        XCTAssertTrue(text.contains("向右侧旋转约 20°"))
        XCTAssertTrue(text.contains(ChinCue.down5.text),
                      "头部指令必须包含下巴提示，实际: \(text)")
    }

    func testHeadTextForFacingHead() {
        let pose = Fixtures.makePoseSuggestion(headTurn: .facing)
        XCTAssertTrue(PoseScriptWriter.headText(pose).contains("头部正对镜头"))
    }

    // MARK: - 手部

    func testHandsTextNumbersBothHandsWhenTheyDiffer() {
        let pose = Fixtures.makePoseSuggestion(nearestHand: .onHip, otherHand: .relaxedDown)
        let text = PoseScriptWriter.handsText(pose)
        XCTAssertTrue(text.hasPrefix("① "), "两只手不同时应分条列出，实际: \(text)")
        XCTAssertTrue(text.contains("② "))
        XCTAssertTrue(text.contains(HandPlacement.onHip.text))
        XCTAssertTrue(text.contains(HandPlacement.relaxedDown.text))
    }

    func testHandsTextIsSingleWhenOnlyOneHandIsSpecified() {
        let pose = Fixtures.makePoseSuggestion(nearestHand: .onHip, otherHand: nil)
        let text = PoseScriptWriter.handsText(pose)
        XCTAssertFalse(text.contains("①"))
        XCTAssertEqual(text, HandPlacement.onHip.text)
    }

    func testHandsTextIsSingleWhenBothHandsAreTheSame() {
        let pose = Fixtures.makePoseSuggestion(nearestHand: .onHip, otherHand: .onHip)
        let text = PoseScriptWriter.handsText(pose)
        XCTAssertFalse(text.contains("①"), "两只手动作相同时不该重复两遍")
        XCTAssertEqual(text, HandPlacement.onHip.text)
    }

    // MARK: - 构图

    func testCompositionTextReflectsHorizontalAnchor() {
        let left = Fixtures.makePoseSuggestion(
            composition: PoseComposition(horizontalAnchor: 0.3, headAnchor: 0.25,
                                         headroomRatio: 0.08, needsLeadRoom: false, note: "")
        )
        XCTAssertTrue(PoseScriptWriter.compositionText(left).contains("左三分之一线"))

        let right = Fixtures.makePoseSuggestion(
            composition: PoseComposition(horizontalAnchor: 0.7, headAnchor: 0.25,
                                         headroomRatio: 0.08, needsLeadRoom: false, note: "")
        )
        XCTAssertTrue(PoseScriptWriter.compositionText(right).contains("右三分之一线"))

        let centered = Fixtures.makePoseSuggestion(
            composition: PoseComposition(horizontalAnchor: 0.5, headAnchor: 0.25,
                                         headroomRatio: 0.08, needsLeadRoom: false, note: "")
        )
        XCTAssertTrue(PoseScriptWriter.compositionText(centered).contains("居中"))
    }

    func testCompositionTextIncludesHeadroomPercentage() {
        let pose = Fixtures.makePoseSuggestion(
            composition: PoseComposition(horizontalAnchor: 0.5, headAnchor: 0.25,
                                         headroomRatio: 0.12, needsLeadRoom: false, note: "")
        )
        XCTAssertTrue(PoseScriptWriter.compositionText(pose).contains("12%"))
    }

    func testCompositionTextMentionsLeadRoomOnlyWhenNeeded() {
        let needing = Fixtures.makePoseSuggestion(
            composition: PoseComposition(horizontalAnchor: 0.5, headAnchor: 0.25,
                                         headroomRatio: 0.1, needsLeadRoom: true, note: "")
        )
        XCTAssertTrue(PoseScriptWriter.compositionText(needing).contains("视线方向留出"))

        let notNeeding = Fixtures.makePoseSuggestion(
            composition: PoseComposition(horizontalAnchor: 0.5, headAnchor: 0.25,
                                         headroomRatio: 0.1, needsLeadRoom: false, note: "")
        )
        XCTAssertFalse(PoseScriptWriter.compositionText(notNeeding).contains("视线方向留出"))
    }

    func testCompositionTextAppendsNoteWhenPresent() {
        let pose = Fixtures.makePoseSuggestion(
            composition: PoseComposition(horizontalAnchor: 0.5, headAnchor: 0.25,
                                         headroomRatio: 0.1, needsLeadRoom: false,
                                         note: "背景不要压住头顶")
        )
        XCTAssertTrue(PoseScriptWriter.compositionText(pose).contains("背景不要压住头顶"))
    }

    // MARK: - 完整分步

    func testStepsCoverAllMajorCategories() {
        let pose = Fixtures.makePoseSuggestion()
        let steps = PoseScriptWriter.steps(for: pose)
        let categories = Set(steps.map(\.category))

        let expected: Set<PoseStepCategory> = [.body, .head, .eyes, .shoulders, .hands,
                                               .weight, .legs, .environment, .camera,
                                               .composition, .tips]
        XCTAssertEqual(categories, expected)
    }

    func testStepsSkipEnvironmentAndTipsWhenEmpty() {
        let pose = Fixtures.makePoseSuggestion(environment: "   ", photographerTips: "\n")
        let steps = PoseScriptWriter.steps(for: pose)
        let categories = Set(steps.map(\.category))
        XCTAssertFalse(categories.contains(.environment))
        XCTAssertFalse(categories.contains(.tips))
        XCTAssertEqual(steps.count, 9, "11 项里去掉「环境互动」和「执行提示」应剩 9 项")
    }

    func testStepIdentifiersAreUniqueAndStable() {
        let pose = Fixtures.makePoseSuggestion(id: "abc-01")
        let steps = PoseScriptWriter.steps(for: pose)
        let ids = steps.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "步骤 id 不能重复")
        XCTAssertTrue(ids.allSatisfy { $0.hasPrefix("abc-01-") },
                      "步骤 id 必须以姿势 id 为前缀，便于收藏与定位")
    }

    func testEveryStepHasNonEmptyTextAndTitle() {
        let pose = Fixtures.makePoseSuggestion()
        for step in PoseScriptWriter.steps(for: pose) {
            XCTAssertFalse(step.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           "\(step.category) 步骤文案为空")
            XCTAssertFalse(step.category.title.isEmpty)
            XCTAssertFalse(step.category.symbolName.isEmpty)
        }
    }

    func testEveryStepCategoryIsCoveredByAllCases() {
        // PoseStepCategory.allCases 必须与 steps(for:) 实际会产出的类别集合一致，
        // 否则 UI 上的图例会和实际内容对不上
        let produced = Set(PoseScriptWriter.steps(for: Fixtures.makePoseSuggestion()).map(\.category))
        XCTAssertTrue(produced.isSubset(of: Set(PoseStepCategory.allCases)))
    }

    // MARK: - 卡片摘要

    func testShortDigestContainsShotTypeAndGaze() {
        let pose = Fixtures.makePoseSuggestion(shotType: .fullBody,
                                               bodyRotation: PoseRotation(degrees: 40, direction: .left),
                                               gaze: PoseGaze(anchor: .offCamera, detail: "看向左侧树梢"))
        let digest = PoseScriptWriter.shortDigest(pose)
        XCTAssertTrue(digest.contains(ShotType.fullBody.title))
        XCTAssertTrue(digest.contains("向左侧旋转约 40°"))
        XCTAssertTrue(digest.contains(GazeAnchor.offCamera.title))
    }

    func testShortDigestOmitsRotationForFacingPose() {
        let pose = Fixtures.makePoseSuggestion(bodyRotation: .facing)
        XCTAssertFalse(PoseScriptWriter.shortDigest(pose).contains("旋转"))
    }

    // MARK: - 全部枚举的文案完整性

    func testAllPoseEnumsHaveExecutableText() {
        for cue in ChinCue.allCases {
            XCTAssertFalse(cue.text.isEmpty, "\(cue) 缺少文案")
            XCTAssertTrue(cue.text.contains("°") || cue.text.contains("歪"),
                          "\(cue) 的文案应包含具体角度或方向，实际: \(cue.text)")
        }
        for cue in ShoulderCue.allCases {
            XCTAssertFalse(cue.text.isEmpty)
        }
        for placement in HandPlacement.allCases {
            XCTAssertFalse(placement.text.isEmpty)
            XCTAssertGreaterThan(placement.text.count, 8,
                                 "\(placement) 的手部指令过于笼统: \(placement.text)")
        }
        for cue in WeightCue.allCases {
            XCTAssertFalse(cue.text.isEmpty)
        }
        for cue in LegCue.allCases {
            XCTAssertFalse(cue.text.isEmpty)
        }
        for angle in CameraAngle.allCases {
            XCTAssertFalse(angle.text.isEmpty)
        }
        for anchor in GazeAnchor.allCases {
            XCTAssertFalse(anchor.title.isEmpty)
        }
        for direction in RotationDirection.allCases {
            XCTAssertFalse(direction.title.isEmpty)
        }
    }

    func testPoseRotationDescriptiveText() {
        XCTAssertEqual(PoseRotation(degrees: 30, direction: .left).descriptiveText,
                       "向左侧旋转约 30°")
        XCTAssertEqual(PoseRotation(degrees: 15, direction: .right).descriptiveText,
                       "向右侧旋转约 15°")
        XCTAssertEqual(PoseRotation.facing.descriptiveText, "保持正对镜头")
        XCTAssertTrue(PoseRotation(degrees: 0, direction: .left).isFacing,
                      "角度为 0 时应等价于正对，避免出现「向左侧旋转约 0°」这种文案")
    }

    /// 大角度必须换成「背对」这种可立即执行的说法：
    /// 「旋转 165°」需要在脑子里换算，而「背对镜头」不用
    func testLargeRotationUsesBackToCameraWording() {
        let large = PoseRotation(degrees: 165, direction: .left)
        XCTAssertTrue(large.descriptiveText.contains("背对镜头"),
                      "实际: \(large.descriptiveText)")
        XCTAssertFalse(large.descriptiveText.contains("旋转约 165°"))

        // 135° 及以下仍用角度描述，避免语义跳变太早
        let medium = PoseRotation(degrees: 135, direction: .right)
        XCTAssertTrue(medium.descriptiveText.contains("旋转约 135°"),
                      "实际: \(medium.descriptiveText)")
    }
}
