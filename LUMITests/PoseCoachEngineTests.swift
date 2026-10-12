import XCTest
import CoreGraphics
@testable import LUMI

/// 实时姿势指导引擎。
///
/// 这里要守住三条底线：
/// 1. 置信度/关键点不足时**必须闭嘴**，只说明「识别不稳定」，不给出确定性的角度结论；
/// 2. 每条建议都必须带上触发它的实测数值；
/// 3. 阈值边界（3°/8°、4°、15°、6°）要能被精确命中。
final class PoseCoachEngineTests: XCTestCase {

    private let thresholds = PoseCoachEngine.Thresholds.default

    private func tips(for pose: BodyPose) -> [AnalysisFinding] {
        let report = PoseAnalyzer.analyze(pose)
        return PoseCoachEngine.tips(for: report, pose: pose, thresholds: thresholds)
    }

    private func tip(_ id: String, in findings: [AnalysisFinding]) -> AnalysisFinding? {
        findings.first { $0.id == id }
    }

    // MARK: - 门控

    func testNoPersonProducesSingleExplicitFinding() {
        let findings = PoseCoachEngine.tips(for: .empty, pose: .empty, thresholds: thresholds)
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings.first?.id, "pose-none")
        XCTAssertEqual(findings.first?.level, .info)
        XCTAssertTrue(findings.first?.detail.contains("没有识别到人体") ?? false)
    }

    func testLowConfidenceSuppressesEveryAngleConclusion() {
        let pose = Fixtures.PoseBuilder()
            .withConfidence(.leftKnee, 0.05)
            .withOverallConfidence(0.10)
            .build()
        let findings = tips(for: pose)

        XCTAssertEqual(findings.count, 1, "低置信度下不应该输出任何角度结论")
        let finding = findings.first
        XCTAssertEqual(finding?.id, "pose-low-confidence")
        XCTAssertEqual(finding?.level, .attention)
        XCTAssertTrue(finding?.title.contains("暂不给角度结论") ?? false)
        XCTAssertTrue(finding?.detail.contains("左膝") ?? false,
                      "应列出识别不到的关节，实际: \(finding?.detail ?? "nil")")

        // 确认没有混入任何具体角度结论
        let angleIDs = ["pose-shoulder-tilt", "pose-torso-lean", "pose-head-yaw",
                        "pose-head-roll", "pose-elbow-straight-左臂", "pose-center-offset"]
        for id in angleIDs {
            XCTAssertNil(tip(id, in: findings), "低置信度下不应出现 \(id)")
        }
    }

    func testInsufficientValidJointsSuppressesConclusions() {
        var report = PoseAnalyzer.analyze(Fixtures.standardPose())
        report.validJointCount = 5
        let findings = PoseCoachEngine.tips(for: report,
                                            pose: Fixtures.standardPose(),
                                            thresholds: thresholds)
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings.first?.id, "pose-low-confidence")
    }

    /// 门控用的是严格小于：正好等于阈值时应该放行，保证阈值语义清晰
    func testGateBoundaryIsInclusive() {
        var report = PoseAnalyzer.analyze(Fixtures.standardPose())
        report.confidence = thresholds.minConfidenceForAdvice
        report.validJointCount = thresholds.minValidJointsForAdvice

        let findings = PoseCoachEngine.tips(for: report,
                                            pose: Fixtures.standardPose(),
                                            thresholds: thresholds)
        XCTAssertGreaterThan(findings.count, 1, "正好达到阈值时不应被门控")
        XCTAssertNil(tip("pose-low-confidence", in: findings))
    }

    // MARK: - 肩线

    func testShoulderTiltIsGoodWhenLevel() {
        let findings = tips(for: Fixtures.standardPose())
        let finding = tip("pose-shoulder-tilt", in: findings)
        XCTAssertEqual(finding?.level, .good)
        XCTAssertTrue(finding?.detail.contains("0.0") ?? false)
    }

    func testShoulderTiltAttentionAboveThreeDegrees() {
        // atan2(0.017498, 0.200) = 5°
        let pose = Fixtures.PoseBuilder()
            .moving(.rightShoulder, to: CGPoint(x: 0.600, y: 0.817498))
            .build()
        let finding = tip("pose-shoulder-tilt", in: tips(for: pose))
        XCTAssertEqual(finding?.level, .attention)
        XCTAssertTrue(finding?.detail.contains("5.0") ?? false,
                      "实际: \(finding?.detail ?? "nil")")
    }

    func testShoulderTiltWarningAboveEightDegrees() {
        // atan2(-0.035266, 0.200) = -10°
        let pose = Fixtures.PoseBuilder()
            .moving(.rightShoulder, to: CGPoint(x: 0.600, y: 0.764734))
            .build()
        let finding = tip("pose-shoulder-tilt", in: tips(for: pose))
        XCTAssertEqual(finding?.level, .warning)
        XCTAssertTrue(finding?.detail.contains("10.0") ?? false)
        // 倾斜为负 → 画面右侧肩膀更低
        XCTAssertTrue(finding?.detail.contains("画面右侧肩膀比画面左侧低") ?? false,
                      "实际: \(finding?.detail ?? "nil")")
    }

    // MARK: - 躯干

    func testNoTorsoLeanFindingWhenUpright() {
        let findings = tips(for: Fixtures.standardPose())
        XCTAssertNil(tip("pose-torso-lean", in: findings),
                     "躯干倾斜 0° 在阈值内，不应该产生提示")
    }

    func testTorsoLeanAttentionWhenAboveFourDegrees() {
        let pose = Fixtures.PoseBuilder()
            .moving(.leftShoulder, to: CGPoint(x: 0.450, y: 0.800))
            .moving(.rightShoulder, to: CGPoint(x: 0.650, y: 0.800))
            .build()
        let finding = tip("pose-torso-lean", in: tips(for: pose))
        XCTAssertEqual(finding?.level, .attention)
        XCTAssertTrue(finding?.detail.contains("14.0") ?? false,
                      "实际: \(finding?.detail ?? "nil")")
    }

    // MARK: - 头部

    func testNoHeadYawFindingWhenFacingCamera() {
        let findings = tips(for: Fixtures.standardPose())
        XCTAssertNil(tip("pose-head-yaw", in: findings))
        XCTAssertNil(tip("pose-head-roll", in: findings))
    }

    func testHeadYawIsReportedAsEstimateWhenExceedingFifteenDegrees() {
        let pose = Fixtures.PoseBuilder()
            .moving(.nose, to: CGPoint(x: 0.530, y: 0.880))
            .build()
        let finding = tip("pose-head-yaw", in: tips(for: pose))
        XCTAssertEqual(finding?.level, .info)
        XCTAssertEqual(finding?.kind, .objective)
        XCTAssertTrue(finding?.detail.contains("估算") ?? false,
                      "单目 2D 关键点推不出真正的 3D 偏航，必须标注为估算")
        XCTAssertTrue(finding?.detail.contains("画面右侧") ?? false)
    }

    func testHeadRollIsReportedWhenExceedingSixDegrees() {
        let pose = Fixtures.PoseBuilder()
            .moving(.rightEye, to: CGPoint(x: 0.517, y: 0.916))
            .build()
        let finding = tip("pose-head-roll", in: tips(for: pose))
        XCTAssertEqual(finding?.level, .info)
        XCTAssertTrue(finding?.detail.contains("30.5") ?? false,
                      "实际: \(finding?.detail ?? "nil")")
        XCTAssertTrue(finding?.detail.contains("画面右侧") ?? false)
    }

    // MARK: - 肘关节

    func testElbowTooStraightIsFlagged() {
        // 肩、肘、腕共线 → 肘角 180°
        let pose = Fixtures.PoseBuilder()
            .moving(.leftWrist, to: CGPoint(x: 0.340, y: 0.560))
            .build()
        let finding = tip("pose-elbow-straight-左臂", in: tips(for: pose))
        XCTAssertEqual(finding?.level, .attention)
        XCTAssertEqual(finding?.kind, .heuristic)
        XCTAssertTrue(finding?.detail.contains("180") ?? false,
                      "实际: \(finding?.detail ?? "nil")")
    }

    func testElbowTooClosedIsFlagged() {
        // 手腕拉回肘部附近 → 肘角约 31°
        let pose = Fixtures.PoseBuilder()
            .moving(.leftWrist, to: CGPoint(x: 0.390, y: 0.700))
            .build()
        let finding = tip("pose-elbow-closed-左臂", in: tips(for: pose))
        XCTAssertEqual(finding?.level, .attention)
        XCTAssertTrue(finding?.detail.contains("31") ?? false,
                      "实际: \(finding?.detail ?? "nil")")
    }

    func testNaturalElbowBendIsReportedAsGood() {
        let findings = tips(for: Fixtures.standardPose())
        XCTAssertNotNil(tip("pose-elbow-good-左臂", in: findings))
        XCTAssertNotNil(tip("pose-elbow-good-右臂", in: findings))
    }

    // MARK: - 手部高度

    func testBothWristsLowProducesHeuristicSuggestion() {
        let findings = tips(for: Fixtures.standardPose())
        // 标准夹具两只手腕都在髋部高度
        let finding = tip("pose-wrist-low", in: findings)
        XCTAssertEqual(finding?.kind, .heuristic)
        XCTAssertEqual(finding?.level, .info)
    }

    func testUnevenWristHeightsProducesNoWarning() {
        // 左腕抬到肩线以上，右腕保持在髋部 → 高度有层次
        let pose = Fixtures.PoseBuilder()
            .moving(.leftWrist, to: CGPoint(x: 0.410, y: 0.850))
            .moving(.leftElbow, to: CGPoint(x: 0.360, y: 0.740))
            .build()
        let findings = tips(for: pose)
        XCTAssertNil(tip("pose-wrist-low", in: findings))
    }

    // MARK: - 人物位置

    func testCenterOffsetIsSilentWhenCentered() {
        let findings = tips(for: Fixtures.standardPose())
        XCTAssertNil(tip("pose-center-offset", in: findings))
    }

    func testCenterOffsetInfoWhenSlightlyOff() {
        var builder = Fixtures.PoseBuilder()
        for (joint, point) in Fixtures.standardStanding {
            builder = builder.moving(joint, to: CGPoint(x: point.x + 0.10, y: point.y))
        }
        let finding = tip("pose-center-offset", in: tips(for: builder.build()))
        XCTAssertEqual(finding?.level, .info)
        XCTAssertTrue(finding?.title.contains("略微偏心") ?? false)
    }

    func testCenterOffsetAttentionWhenFarOffCenter() {
        var builder = Fixtures.PoseBuilder()
        for (joint, point) in Fixtures.standardStanding {
            builder = builder.moving(joint, to: CGPoint(x: point.x + 0.25, y: point.y))
        }
        let finding = tip("pose-center-offset", in: tips(for: builder.build()))
        XCTAssertEqual(finding?.level, .attention)
        XCTAssertTrue(finding?.title.contains("明显偏离") ?? false)
        XCTAssertTrue(finding?.detail.contains("25") ?? false)
    }

    // MARK: - 边缘与整体比例

    func testFrameEdgeWarningWhenTruncated() {
        let pose = Fixtures.PoseBuilder()
            .moving(.leftAnkle, to: CGPoint(x: 0.440, y: 0.005))
            .moving(.rightAnkle, to: CGPoint(x: 0.560, y: 0.005))
            .build()
        let finding = tip("pose-frame-edge", in: tips(for: pose))
        XCTAssertEqual(finding?.level, .warning)
        XCTAssertTrue(finding?.detail.contains("画面底部") ?? false)
    }

    func testTorsoScaleIsAlwaysReportedAsHeuristic() {
        let finding = tip("pose-torso-scale", in: tips(for: Fixtures.standardPose()))
        XCTAssertEqual(finding?.kind, .heuristic)
        XCTAssertTrue(finding?.detail.contains("20") ?? false,
                      "肩到髋距离 0.20 应出现在说明里，实际: \(finding?.detail ?? "nil")")
    }

    // MARK: - 输出质量

    func testAllFindingsHaveUniqueKeysAndNonEmptyText() {
        var builder = Fixtures.PoseBuilder()
            .moving(.rightShoulder, to: CGPoint(x: 0.600, y: 0.764734))
            .moving(.nose, to: CGPoint(x: 0.530, y: 0.880))
            .moving(.rightEye, to: CGPoint(x: 0.517, y: 0.916))
        builder = builder.moving(.leftShoulder, to: CGPoint(x: 0.450, y: 0.800))
        builder = builder.moving(.rightShoulder, to: CGPoint(x: 0.650, y: 0.800))
        let findings = tips(for: builder.build())

        XCTAssertFalse(findings.isEmpty)
        var seen = Set<String>()
        for finding in findings {
            XCTAssertFalse(finding.title.isEmpty)
            XCTAssertFalse(finding.detail.isEmpty)
            XCTAssertFalse(finding.kind.badge.isEmpty)
            XCTAssertFalse(finding.level.title.isEmpty)
            XCTAssertGreaterThan(finding.confidence, 0)
            XCTAssertLessThanOrEqual(finding.confidence, 1)
            XCTAssertTrue(seen.insert(finding.id).inserted, "结论 key 重复: \(finding.id)")
        }
    }
}
