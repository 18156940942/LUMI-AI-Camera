import XCTest
import CoreGraphics
@testable import LUMI

/// 构图分析的核心约束：
/// 1. **没有人物就没有结论** —— 不能凭画面尺寸编出一份「构图报告」；
/// 2. 每条结论都要标注是「实测」还是「建议」；
/// 3. 阈值边界要能被精确命中。
final class CompositionAnalyzerTests: XCTestCase {

    private let frame = CGSize(width: 1920, height: 1080)

    // MARK: - 无人门控

    func testNoSubjectProducesNoCompositionConclusion() {
        let report = CompositionAnalyzer.analyze(pose: .empty, frameSize: frame)

        XCTAssertFalse(report.isSubjectPresent)
        XCTAssertEqual(report.confidence, 0)
        XCTAssertEqual(report.findings.count, 1, "只应有「未检测到人物」这一条")
        XCTAssertEqual(report.findings.first?.id, "composition-no-subject")
        XCTAssertEqual(report.findings.first?.kind, .objective)
        XCTAssertEqual(report.findings.first?.level, .info)

        // 一旦没检测到人，所有测量量都必须是空的，不能留下上一帧的值
        XCTAssertNil(report.subjectBoundingBox)
        XCTAssertNil(report.headroom)
        XCTAssertNil(report.horizontalCenter)
        XCTAssertNil(report.ruleOfThirdsDeviation)
        XCTAssertNil(report.suggestedShotType)
        XCTAssertNil(report.subjectHeightRatio)
        XCTAssertTrue(report.truncatedJoints.isEmpty)
    }

    func testNoSubjectDetectionSourceIsExplicit() {
        let report = CompositionAnalyzer.analyze(pose: .empty, frameSize: frame)
        XCTAssertTrue(report.detectionSource.contains("未检测到"),
                      "检测来源必须如实说明未检测到，实际: \(report.detectionSource)")
    }

    // MARK: - 正常人物

    func testStandardPoseProducesMeasurements() {
        let report = CompositionAnalyzer.analyze(pose: Fixtures.standardPose(), frameSize: frame)

        XCTAssertTrue(report.isSubjectPresent)
        XCTAssertEqual(report.confidence, 0.85, accuracy: 0.0001)
        XCTAssertEqual(report.frameSize, frame)
        XCTAssertNotNil(report.subjectBoundingBox)
        XCTAssertEqual(Double(report.horizontalCenter ?? 0), 0.50, accuracy: 0.001)
        XCTAssertEqual(Double(report.headroom ?? 0), 0.104, accuracy: 0.001)
        XCTAssertEqual(Double(report.subjectHeightRatio ?? 0), 0.796, accuracy: 0.001)
        XCTAssertFalse(report.findings.isEmpty)
    }

    func testDetectionSourceReportsRealJointCount() {
        let report = CompositionAnalyzer.analyze(pose: Fixtures.standardPose(), frameSize: frame)
        XCTAssertTrue(report.detectionSource.contains("19/19"),
                      "检测来源应包含真实关键点数量，实际: \(report.detectionSource)")
        XCTAssertTrue(report.detectionSource.contains("85"),
                      "检测来源应包含真实综合置信度，实际: \(report.detectionSource)")
    }

    // MARK: - 头顶留白阈值

    func testHeadroomTightBelowTwoPercent() {
        // 头顶推到 0.995 → 留白 0.5%
        let pose = topAdjustedPose(maxY: 0.995)
        let report = CompositionAnalyzer.analyze(pose: pose, frameSize: frame)
        let finding = report.findings.first { $0.id == "composition-headroom" }
        XCTAssertEqual(finding?.level, .warning)
        XCTAssertTrue(finding?.title.contains("贴到画面边缘") ?? false)
    }

    func testHeadroomAttentionBetweenTwoAndFivePercent() {
        let pose = topAdjustedPose(maxY: 0.965) // 留白 3.5%
        let report = CompositionAnalyzer.analyze(pose: pose, frameSize: frame)
        let finding = report.findings.first { $0.id == "composition-headroom" }
        XCTAssertEqual(finding?.level, .attention)
        XCTAssertTrue(finding?.title.contains("偏紧") ?? false)
    }

    func testHeadroomGoodInNormalRange() {
        let report = CompositionAnalyzer.analyze(pose: Fixtures.standardPose(), frameSize: frame)
        let finding = report.findings.first { $0.id == "composition-headroom" }
        XCTAssertEqual(finding?.level, .good)
    }

    func testHeadroomExcessiveAboveThirtyFivePercent() {
        // 所有关节整体下压，头顶降到 0.60 → 留白 40%
        let pose = Fixtures.PoseBuilder().withDefaultConfidence(0.9).build()
        var lowered = pose
        var moved: [BodyJoint: BodyJointPoint] = [:]
        for (joint, point) in pose.points {
            moved[joint] = BodyJointPoint(joint: joint,
                                          location: CGPoint(x: point.location.x,
                                                            y: point.location.y * 0.70),
                                          confidence: point.confidence)
        }
        lowered.points = moved

        let report = CompositionAnalyzer.analyze(pose: lowered, frameSize: frame)
        let finding = report.findings.first { $0.id == "composition-headroom" }
        XCTAssertEqual(finding?.level, .attention)
        XCTAssertTrue(finding?.title.contains("过多") ?? false)
    }

    // MARK: - 视线留白

    func testLeadRoomIsSkippedWhenSubjectFacesCamera() {
        let report = CompositionAnalyzer.analyze(pose: Fixtures.standardPose(), frameSize: frame)
        let finding = report.findings.first { $0.id == "composition-lead-room" }
        XCTAssertEqual(finding?.kind, .heuristic,
                       "正对镜头时不该套用视线留白规则，应作为规则说明给出")
        XCTAssertTrue(finding?.title.contains("不适用") ?? false)
    }

    func testLeadRoomAttentionWhenGazeSideIsCramped() {
        // 人物整体右移到画面最右侧，同时把头再往右转一点：
        // 视线朝画面右侧，而右侧只剩 5% 宽度 → 应判定「缺少空间」
        var builder = Fixtures.PoseBuilder()
        for (joint, point) in Fixtures.standardStanding {
            builder = builder.moving(joint, to: CGPoint(x: point.x + 0.32, y: point.y))
        }
        builder = builder.moving(.nose, to: CGPoint(x: 0.500 + 0.32 + 0.03, y: 0.880))
        let pose = builder.build()

        let report = CompositionAnalyzer.analyze(pose: pose, frameSize: frame)
        // 先确认前提成立：头部确实朝画面右侧、右侧留白确实很窄
        let yaw = PoseGeometry.headYawEstimate(from: pose)
        XCTAssertEqual(yaw?.towardScreenRight, true, "夹具前提：视线应朝画面右侧")
        XCTAssertEqual(Double(PoseGeometry.leadRoom(of: report.subjectBoundingBox ?? .zero,
                                                    towardScreenRight: true)),
                       0.05, accuracy: 0.001)

        let finding = report.findings.first { $0.id == "composition-lead-room" }
        XCTAssertEqual(finding?.level, .attention)
        XCTAssertTrue(finding?.title.contains("缺少空间") ?? false)
    }

    // MARK: - 三分法

    func testThirdsReportedAsInfoWhenSubjectIsCentered() {
        let report = CompositionAnalyzer.analyze(pose: Fixtures.standardPose(), frameSize: frame)
        let finding = report.findings.first { $0.id == "composition-thirds" }
        XCTAssertNotNil(finding)
        // 标准夹具中心在 0.50，距最近三分线 0.1667 → 不在三分线上，但这是提示而非问题
        XCTAssertEqual(finding?.level, .info)
        XCTAssertTrue(finding?.title.contains("未落在三分线") ?? false)
    }

    func testThirdsRecognizedWhenSubjectCenterSitsOnThirdLine() {
        // 整体左移 1/6，使包围框中心正好落在 1/3 处
        let shift = 1.0 / 3.0 - 0.50
        var builder = Fixtures.PoseBuilder()
        for (joint, point) in Fixtures.standardStanding {
            builder = builder.moving(joint, to: CGPoint(x: point.x + shift, y: point.y))
        }
        let pose = builder.build()
        let report = CompositionAnalyzer.analyze(pose: pose, frameSize: frame)

        XCTAssertEqual(Double(report.horizontalCenter ?? 0), 1.0 / 3.0, accuracy: 0.001)
        XCTAssertEqual(Double(report.ruleOfThirdsDeviation ?? 9), 0, accuracy: 0.001)

        let finding = report.findings.first { $0.id == "composition-thirds" }
        XCTAssertEqual(finding?.level, .good)
        XCTAssertTrue(finding?.title.contains("落在三分线上") ?? false)
    }

    func testThirdsDeviationMatchesMeasurement() {
        let report = CompositionAnalyzer.analyze(pose: Fixtures.standardPose(), frameSize: frame)
        XCTAssertEqual(Double(report.ruleOfThirdsDeviation ?? 0), 1.0 / 6.0, accuracy: 0.0001)
    }

    // MARK: - 截断

    func testTruncationProducesWarning() {
        let pose = Fixtures.PoseBuilder()
            .moving(.leftAnkle, to: CGPoint(x: 0.440, y: 0.005))
            .moving(.rightAnkle, to: CGPoint(x: 0.560, y: 0.005))
            .build()
        let report = CompositionAnalyzer.analyze(pose: pose, frameSize: frame)
        let finding = report.findings.first { $0.id == "composition-truncation" }
        XCTAssertEqual(finding?.level, .warning)
        XCTAssertFalse(report.truncatedJoints.isEmpty)
    }

    func testTruncationMentionsJointOnEdgeWhenCutAtJoint() {
        // 脚踝正好压在画面下边缘（0.000）→ 应提示「切在关节上」
        let pose = Fixtures.PoseBuilder()
            .moving(.leftAnkle, to: CGPoint(x: 0.440, y: 0.000))
            .moving(.rightAnkle, to: CGPoint(x: 0.560, y: 0.000))
            .build()
        let report = CompositionAnalyzer.analyze(pose: pose, frameSize: frame)
        let finding = report.findings.first { $0.id == "composition-truncation" }
        XCTAssertTrue(finding?.detail.contains("压在边缘") ?? false,
                      "实际: \(finding?.detail ?? "nil")")
    }

    // MARK: - 景别推断

    func testShotTypeIsFullBodyWhenLegsAreVisible() {
        let report = CompositionAnalyzer.analyze(pose: Fixtures.standardPose(), frameSize: frame)
        XCTAssertEqual(report.suggestedShotType, .fullBody)
        XCTAssertFalse(report.shotTypeReasons.isEmpty, "景别判断必须给出可核对的依据")
        XCTAssertTrue(report.shotTypeReasons.contains { $0.contains("包围框高度") })
    }

    func testShotTypeIsSeatedWhenKneeAngleIsSharp() {
        // 把脚踝拉到膝盖高度 → 膝角接近 90°，判定为坐姿
        let pose = Fixtures.PoseBuilder()
            .moving(.leftAnkle, to: CGPoint(x: 0.560, y: 0.350))
            .moving(.rightAnkle, to: CGPoint(x: 0.720, y: 0.350))
            .build()
        let report = CompositionAnalyzer.analyze(pose: pose, frameSize: frame)
        XCTAssertEqual(report.suggestedShotType, .seated)
    }

    func testShotTypeIsHalfBodyWhenLegsAreNotVisible() {
        let pose = Fixtures.PoseBuilder()
            .removing([.leftKnee, .rightKnee, .leftAnkle, .rightAnkle])
            .build()
        let report = CompositionAnalyzer.analyze(pose: pose, frameSize: frame)
        XCTAssertEqual(report.suggestedShotType, .halfBody)
        XCTAssertTrue(report.shotTypeReasons.contains { $0.contains("腿部未完整入镜") })
    }

    func testShotTypeIsCloseUpWhenOnlyUpperBodyIsReliable() {
        let pose = Fixtures.PoseBuilder()
            .keepingOnly(BodyJoint.upperBodyJoints)
            .build()
        let report = CompositionAnalyzer.analyze(pose: pose, frameSize: frame)
        XCTAssertEqual(report.suggestedShotType, .closeUp)
    }

    // MARK: - 背景干扰

    func testBackgroundNotEvaluatedWhenNoClutterValueProvided() {
        let report = CompositionAnalyzer.analyze(pose: Fixtures.standardPose(),
                                                frameSize: frame,
                                                backgroundClutter: nil)
        let finding = report.findings.first { $0.id == "composition-background" }
        XCTAssertEqual(finding?.level, .info)
        XCTAssertTrue(finding?.detail.contains("不逐帧计算") ?? false,
                      "没算就要如实说明没算，不能留空也不能编一个值")
        XCTAssertNil(report.backgroundClutterScore)
    }

    func testBackgroundAttentionWhenClutterIsHigh() {
        let report = CompositionAnalyzer.analyze(pose: Fixtures.standardPose(),
                                                frameSize: frame,
                                                backgroundClutter: 0.55)
        let finding = report.findings.first { $0.id == "composition-background" }
        XCTAssertEqual(finding?.level, .attention)
        XCTAssertTrue(finding?.detail.contains("0.55") ?? false)
    }

    func testBackgroundGoodWhenClutterIsLow() {
        let report = CompositionAnalyzer.analyze(pose: Fixtures.standardPose(),
                                                frameSize: frame,
                                                backgroundClutter: 0.10)
        let finding = report.findings.first { $0.id == "composition-background" }
        XCTAssertEqual(finding?.level, .good)
    }

    // MARK: - 结论性质标注

    func testEveryFindingCarriesKindLevelAndDetail() {
        let report = CompositionAnalyzer.analyze(pose: Fixtures.standardPose(),
                                                frameSize: frame,
                                                backgroundClutter: 0.2)
        XCTAssertFalse(report.findings.isEmpty)
        var seenKeys = Set<String>()
        for finding in report.findings {
            XCTAssertFalse(finding.title.isEmpty, "\(finding.id) 缺少标题")
            XCTAssertFalse(finding.detail.isEmpty, "\(finding.id) 缺少说明")
            XCTAssertTrue([FindingKind.objective, .heuristic].contains(finding.kind))
            XCTAssertFalse(finding.kind.badge.isEmpty)
            XCTAssertGreaterThan(finding.confidence, 0)
            XCTAssertLessThanOrEqual(finding.confidence, 1)
            XCTAssertTrue(seenKeys.insert(finding.id).inserted,
                          "结论 key 重复: \(finding.id)")
        }
    }

    func testObjectiveAndHeuristicFindingsAreSeparable() {
        let report = CompositionAnalyzer.analyze(pose: Fixtures.standardPose(),
                                                frameSize: frame,
                                                backgroundClutter: 0.2)
        XCTAssertFalse(report.objectiveFindings.isEmpty)
        XCTAssertTrue(report.objectiveFindings.allSatisfy { $0.kind == .objective })
        XCTAssertTrue(report.heuristicFindings.allSatisfy { $0.kind == .heuristic })
        XCTAssertEqual(report.objectiveFindings.count + report.heuristicFindings.count,
                       report.findings.count)
    }

    // MARK: - 辅助

    /// 生成一个「头顶到指定高度」的姿态：整体平移，保持其他几何关系不变
    private func topAdjustedPose(maxY: CGFloat) -> BodyPose {
        let standardMaxY: CGFloat = 0.896
        let delta = maxY - standardMaxY
        var builder = Fixtures.PoseBuilder()
        for (joint, point) in Fixtures.standardStanding {
            builder = builder.moving(joint, to: CGPoint(x: point.x, y: point.y + delta))
        }
        return builder.build()
    }
}
