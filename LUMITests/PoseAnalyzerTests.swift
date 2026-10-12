import XCTest
import CoreGraphics
@testable import LUMI

/// `PoseAnalyzer` 把关键点转成可展示的角度数字。
/// 关键验证点：**每个数字都能由坐标反推出来**，不存在随机值或占位值。
final class PoseAnalyzerTests: XCTestCase {

    // MARK: - 未检测到人

    func testEmptyPoseProducesEmptyReport() {
        let report = PoseAnalyzer.analyze(.empty)
        XCTAssertFalse(report.isDetected)
        XCTAssertEqual(report.confidence, 0)
        XCTAssertEqual(report.validJointCount, 0)
        XCTAssertNil(report.shoulderTiltDegrees)
        XCTAssertNil(report.torsoLeanDegrees)
        XCTAssertNil(report.personCenterOffset)
        XCTAssertNil(report.boundingBox)
        XCTAssertFalse(report.reachingFrameEdge)
        XCTAssertTrue(report.coachTips.isEmpty,
                      "没有检测到人时不应该产生任何姿态结论")
    }

    // MARK: - 标准站姿

    func testStandardPoseProducesMeasuredValues() {
        let report = PoseAnalyzer.analyze(Fixtures.standardPose())

        XCTAssertTrue(report.isDetected)
        XCTAssertEqual(report.confidence, 0.85, accuracy: 0.0001)
        XCTAssertEqual(report.validJointCount, BodyJoint.allCases.count)

        XCTAssertEqual(Double(report.shoulderTiltDegrees ?? 99), 0, accuracy: 0.001)
        XCTAssertEqual(Double(report.hipTiltDegrees ?? 99), 0, accuracy: 0.001)
        XCTAssertEqual(Double(report.torsoLeanDegrees ?? 99), 0, accuracy: 0.001)
        XCTAssertEqual(Double(report.headTurnDegrees ?? 99), 0, accuracy: 0.01)
        XCTAssertEqual(Double(report.headTiltDegrees ?? 99), 0, accuracy: 0.001)
        XCTAssertEqual(Double(report.personCenterOffset ?? 99), 0, accuracy: 0.001)

        // 肘关节角度必须落在「弯曲自然」区间
        XCTAssertEqual(Double(report.leftElbowAngle ?? 0), 132.3, accuracy: 1.0)
        XCTAssertEqual(Double(report.rightElbowAngle ?? 0), 139.4, accuracy: 1.0)

        XCTAssertEqual(report.leftWristZone, PoseGeometry.WristZone.hip.title)
        XCTAssertEqual(report.rightWristZone, PoseGeometry.WristZone.hip.title)

        XCTAssertFalse(report.reachingFrameEdge)
        XCTAssertNotNil(report.boundingBox)
    }

    /// 肩线倾斜必须与坐标严格对应：
    /// 右肩下移使倾斜角为 -10°（因为「画面右侧肩膀更低」）
    func testShoulderTiltMatchesCoordinates() {
        // atan2(-0.035266, 0.200) = -10°
        let pose = Fixtures.PoseBuilder()
            .moving(.rightShoulder, to: CGPoint(x: 0.600, y: 0.764734))
            .build()
        let report = PoseAnalyzer.analyze(pose)
        XCTAssertEqual(Double(report.shoulderTiltDegrees ?? 99), -10, accuracy: 0.1)
    }

    /// 髋线倾斜同样要跟随坐标
    func testHipTiltMatchesCoordinates() {
        let pose = Fixtures.PoseBuilder()
            .moving(.rightHip, to: CGPoint(x: 0.560, y: 0.635266))
            .build()
        let report = PoseAnalyzer.analyze(pose)
        // atan2(0.035266, 0.120) ≈ 16.38°
        XCTAssertEqual(Double(report.hipTiltDegrees ?? 0), 16.38, accuracy: 0.2)
    }

    func testTorsoLeanMatchesCoordinates() {
        // 肩中心相对髋中心右移 0.05、上移 0.20 → atan2(0.05, 0.2) ≈ 14.04°
        let pose = Fixtures.PoseBuilder()
            .moving(.leftShoulder, to: CGPoint(x: 0.450, y: 0.800))
            .moving(.rightShoulder, to: CGPoint(x: 0.650, y: 0.800))
            .build()
        let report = PoseAnalyzer.analyze(pose)
        XCTAssertEqual(Double(report.torsoLeanDegrees ?? 0), 14.04, accuracy: 0.2)
    }

    /// 左/右描述必须按「画面左右」排序，不能直接采用 Vision 的 left/right 命名
    /// （两者在正面人像里是相反的）
    func testShoulderTiltUsesScreenOrderNotVisionNaming() {
        // 让 Vision 的 leftShoulder 跑到画面右侧、rightShoulder 跑到画面左侧
        let pose = Fixtures.PoseBuilder()
            .moving(.leftShoulder, to: CGPoint(x: 0.700, y: 0.800))
            .moving(.rightShoulder, to: CGPoint(x: 0.300, y: 0.800))
            .build()
        let report = PoseAnalyzer.analyze(pose)
        // 画面左侧（x=0.300）与画面右侧（x=0.700）等高 → 倾斜仍为 0
        XCTAssertEqual(Double(report.shoulderTiltDegrees ?? 99), 0, accuracy: 0.001)
    }

    func testPersonCenterOffsetFollowsBoundingBox() {
        // 整体右移 0.1：所有关节 +0.1（保持包围框宽度不变）
        var shifted = Fixtures.PoseBuilder()
        for (joint, point) in Fixtures.standardStanding {
            shifted = shifted.moving(joint, to: CGPoint(x: point.x + 0.10, y: point.y))
        }
        let report = PoseAnalyzer.analyze(shifted.build())
        XCTAssertEqual(Double(report.personCenterOffset ?? 0), 0.10, accuracy: 0.001)
    }

    func testReachingFrameEdgeIsTrueWhenSubjectIsTruncated() {
        let pose = Fixtures.PoseBuilder()
            .moving(.leftAnkle, to: CGPoint(x: 0.440, y: 0.005))
            .moving(.rightAnkle, to: CGPoint(x: 0.560, y: 0.005))
            .build()
        let report = PoseAnalyzer.analyze(pose)
        XCTAssertTrue(report.reachingFrameEdge)
    }

    func testWristZoneTextIsPopulatedForBothHands() {
        let report = PoseAnalyzer.analyze(Fixtures.standardPose())
        XCTAssertNotNil(report.leftWristZone)
        XCTAssertNotNil(report.rightWristZone)
        XCTAssertFalse(report.leftWristZone?.isEmpty ?? true)
        XCTAssertFalse(report.rightWristZone?.isEmpty ?? true)
    }

    func testCoachTipsAreGeneratedForReliablePose() {
        let report = PoseAnalyzer.analyze(Fixtures.standardPose())
        XCTAssertFalse(report.coachTips.isEmpty,
                       "置信度 0.85、19 个有效关键点，应该能给出结论")
        for tip in report.coachTips {
            XCTAssertFalse(tip.title.isEmpty)
            XCTAssertFalse(tip.detail.isEmpty)
            XCTAssertGreaterThan(tip.confidence, 0)
            XCTAssertLessThanOrEqual(tip.confidence, 1)
        }
    }

    /// 每一条角度结论里都必须出现实测数值，方便摄影师自己复核
    func testAngleFindingsEmbedMeasuredNumbers() {
        let pose = Fixtures.PoseBuilder()
            .moving(.rightShoulder, to: CGPoint(x: 0.600, y: 0.764734))
            .build()
        let report = PoseAnalyzer.analyze(pose)
        let shoulderTip = report.coachTips.first { $0.id == "pose-shoulder-tilt" }
        let tip = shoulderTip
        XCTAssertNotNil(tip)
        XCTAssertTrue(tip?.detail.contains("10.0") ?? false,
                      "肩线结论里应包含实测角度，实际: \(tip?.detail ?? "nil")")
    }

    func testReliabilityFollowsConfidence() {
        let high = PoseAnalyzer.analyze(Fixtures.standardPose())
        XCTAssertEqual(high.reliability, .high)

        let medium = PoseAnalyzer.analyze(
            Fixtures.PoseBuilder().withOverallConfidence(0.50).build()
        )
        XCTAssertEqual(medium.reliability, .medium)

        let low = PoseAnalyzer.analyze(
            Fixtures.PoseBuilder().withOverallConfidence(0.10).build()
        )
        XCTAssertEqual(low.reliability, .low)
    }

    func testThreeQuarterViewHeadTurnIsReflectedInReport() {
        // 鼻尖偏到画面右侧 → headTurnDegrees 应为正，且报告里带值
        let pose = Fixtures.PoseBuilder()
            .moving(.nose, to: CGPoint(x: 0.530, y: 0.880))
            .build()
        let report = PoseAnalyzer.analyze(pose)
        XCTAssertNotNil(report.headTurnDegrees)
        XCTAssertGreaterThan(report.headTurnDegrees ?? 0, 15,
                             "偏移约 0.03（半耳距 0.034）已经是很明显的转头，应超过 15°")
    }
}
