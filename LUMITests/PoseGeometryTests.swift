import XCTest
import CoreGraphics
@testable import LUMI

/// `PoseGeometry` 是所有角度/位置结论的数学基础。
///
/// 这些测试的作用不是「跑通代码」，而是**锁死方向约定**：
/// 一旦有人把 Vision 坐标系（原点左下、y 向上）和 SwiftUI 绘制坐标系（原点左上、y 向下）
/// 搞混，方向描述就会整体反掉，而 UI 上看起来「有数字」，很难被人肉发现。测试会立刻失败。
final class PoseGeometryTests: XCTestCase {

    // MARK: - 角度计算

    func testLineAngleHorizontalIsZero() {
        let angle = PoseGeometry.lineAngleDegrees(from: CGPoint(x: 0.2, y: 0.5),
                                                 to: CGPoint(x: 0.8, y: 0.5))
        XCTAssertEqual(Double(angle), 0, accuracy: 0.001)
    }

    /// Vision 坐标 y 向上，所以「第二个点更高」应该得到 +90°
    func testLineAngleVerticalIsPositiveNinety() {
        let angle = PoseGeometry.lineAngleDegrees(from: CGPoint(x: 0.5, y: 0.2),
                                                 to: CGPoint(x: 0.5, y: 0.8))
        XCTAssertEqual(Double(angle), 90, accuracy: 0.001)
    }

    func testLineAngleReturnsZeroForIdenticalPoints() {
        let angle = PoseGeometry.lineAngleDegrees(from: CGPoint(x: 0.5, y: 0.5),
                                                 to: CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(Double(angle), 0, accuracy: 0.001)
    }

    /// 倾斜角必须归一化到 -90...90：肩线没有方向性，135° 和 -45° 是同一条线
    func testTiltIsNormalizedIntoMinus90To90() {
        let descending = PoseGeometry.tiltDegrees(from: CGPoint(x: 0.8, y: 0.2),
                                                 to: CGPoint(x: 0.2, y: 0.8))
        let ascending = PoseGeometry.tiltDegrees(from: CGPoint(x: 0.2, y: 0.2),
                                                to: CGPoint(x: 0.8, y: 0.8))
        XCTAssertEqual(Double(descending), -45, accuracy: 0.001)
        XCTAssertEqual(Double(ascending), 45, accuracy: 0.001)
        XCTAssertLessThanOrEqual(abs(Double(descending)), 90)
        XCTAssertLessThanOrEqual(abs(Double(ascending)), 90)
    }

    func testAngleDegreesRightAngleIsNinety() {
        let angle = PoseGeometry.angleDegrees(vertex: CGPoint(x: 0.5, y: 0.5),
                                             from: CGPoint(x: 0.5, y: 1.0),
                                             to: CGPoint(x: 1.0, y: 0.5))
        XCTAssertEqual(Double(angle), 90, accuracy: 0.01)
    }

    func testAngleDegreesStraightLimbIsOneEighty() {
        let angle = PoseGeometry.angleDegrees(vertex: CGPoint(x: 0.5, y: 0.5),
                                             from: CGPoint(x: 0.0, y: 0.5),
                                             to: CGPoint(x: 1.0, y: 0.5))
        XCTAssertEqual(Double(angle), 180, accuracy: 0.01)
    }

    /// 退化输入不能抛异常、不能返回 NaN —— 真实检测里经常出现重复点
    func testAngleDegreesHandlesDegenerateInput() {
        let angle = PoseGeometry.angleDegrees(vertex: CGPoint(x: 0.5, y: 0.5),
                                             from: CGPoint(x: 0.5, y: 0.5),
                                             to: CGPoint(x: 1.0, y: 0.5))
        XCTAssertEqual(Double(angle), 0, accuracy: 0.001)
        XCTAssertFalse(angle.isNaN)
    }

    // MARK: - 躯干倾斜

    func testTorsoLeanIsZeroWhenShouldersAboveHips() {
        let lean = PoseGeometry.torsoLeanDegrees(shoulderCenter: CGPoint(x: 0.5, y: 0.7),
                                                hipCenter: CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(Double(lean), 0, accuracy: 0.001)
    }

    /// 肩部相对髋部偏向画面右侧 → 正角度
    func testTorsoLeanIsPositiveWhenShouldersShiftToScreenRight() {
        let lean = PoseGeometry.torsoLeanDegrees(shoulderCenter: CGPoint(x: 0.6, y: 0.6),
                                                hipCenter: CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(Double(lean), 45, accuracy: 0.001)
    }

    func testTorsoLeanIsNegativeWhenShouldersShiftToScreenLeft() {
        let lean = PoseGeometry.torsoLeanDegrees(shoulderCenter: CGPoint(x: 0.4, y: 0.6),
                                                hipCenter: CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(Double(lean), -45, accuracy: 0.001)
    }

    // MARK: - 方向文案

    func testDirectionTextUsesScreenReference() {
        XCTAssertEqual(PoseGeometry.directionText(from: CGPoint(x: 0.2, y: 0.5),
                                                 to: CGPoint(x: 0.8, y: 0.5)),
                       "画面右侧")
        XCTAssertEqual(PoseGeometry.directionText(from: CGPoint(x: 0.8, y: 0.5),
                                                 to: CGPoint(x: 0.2, y: 0.5)),
                       "画面左侧")
        XCTAssertEqual(PoseGeometry.directionText(from: CGPoint(x: 0.5, y: 0.2),
                                                 to: CGPoint(x: 0.5, y: 0.9)),
                       "上方")
        XCTAssertEqual(PoseGeometry.directionText(from: CGPoint(x: 0.5, y: 0.9),
                                                 to: CGPoint(x: 0.5, y: 0.2)),
                       "下方")
    }

    func testDirectionTextCombinesBothAxesInStableOrder() {
        let text = PoseGeometry.directionText(from: CGPoint(x: 0.8, y: 0.9),
                                             to: CGPoint(x: 0.2, y: 0.1))
        XCTAssertEqual(text, "画面左侧偏下方")
    }

    func testDirectionTextFallsBackWhenPointsCoincide() {
        let text = PoseGeometry.directionText(from: CGPoint(x: 0.5, y: 0.5),
                                             to: CGPoint(x: 0.51, y: 0.51))
        XCTAssertEqual(text, "与参考点大致重合")
    }

    // MARK: - 坐标翻转

    /// 归一化坐标（原点左下）→ SwiftUI 绘制坐标（原点左上）
    func testFlippedPointInvertsY() {
        let flipped = PoseGeometry.flipped(CGPoint(x: 0.3, y: 0.25))
        XCTAssertEqual(Double(flipped.x), 0.3, accuracy: 0.0001)
        XCTAssertEqual(Double(flipped.y), 0.75, accuracy: 0.0001)
    }

    func testFlippedRectInvertsYUsingMaxY() {
        let flipped = PoseGeometry.flipped(CGRect(x: 0.2, y: 0.1, width: 0.4, height: 0.5))
        XCTAssertEqual(Double(flipped.minX), 0.2, accuracy: 0.0001)
        XCTAssertEqual(Double(flipped.minY), 0.4, accuracy: 0.0001)
        XCTAssertEqual(Double(flipped.width), 0.4, accuracy: 0.0001)
        XCTAssertEqual(Double(flipped.height), 0.5, accuracy: 0.0001)
    }

    // MARK: - 手腕高度分带

    func testWristZoneBands() {
        let shoulder = CGPoint(x: 0.5, y: 0.80)
        let hip = CGPoint(x: 0.5, y: 0.60)

        XCTAssertEqual(PoseGeometry.wristZone(wrist: CGPoint(x: 0.5, y: 0.95),
                                             shoulder: shoulder, hip: hip), .aboveShoulder)
        XCTAssertEqual(PoseGeometry.wristZone(wrist: CGPoint(x: 0.5, y: 0.78),
                                             shoulder: shoulder, hip: hip), .chest)
        XCTAssertEqual(PoseGeometry.wristZone(wrist: CGPoint(x: 0.5, y: 0.69),
                                             shoulder: shoulder, hip: hip), .waist)
        XCTAssertEqual(PoseGeometry.wristZone(wrist: CGPoint(x: 0.5, y: 0.58),
                                             shoulder: shoulder, hip: hip), .hip)
        XCTAssertEqual(PoseGeometry.wristZone(wrist: CGPoint(x: 0.5, y: 0.40),
                                             shoulder: shoulder, hip: hip), .belowHip)
    }

    func testWristZoneTitlesAreNonEmpty() {
        for zone in [PoseGeometry.WristZone.aboveShoulder, .chest, .waist, .hip, .belowHip, .unknown] {
            XCTAssertFalse(zone.title.isEmpty)
        }
    }

    // MARK: - 头部姿态估算

    func testHeadYawIsZeroWhenNoseIsCenteredBetweenEars() throws {
        let estimate = try XCTUnwrap(PoseGeometry.headYawEstimate(from: Fixtures.standardPose()))
        XCTAssertEqual(Double(estimate.degrees), 0, accuracy: 0.001)
        XCTAssertFalse(estimate.towardScreenRight)
        XCTAssertEqual(Double(estimate.confidence), 0.9, accuracy: 0.01)
    }

    /// 鼻尖偏向画面右侧 → 头部转向画面右侧，且角度为正
    func testHeadYawIsPositiveWhenNoseShiftsToScreenRight() {
        let pose = Fixtures.PoseBuilder()
            .moving(.nose, to: CGPoint(x: 0.55, y: 0.880))
            .build()
        let estimate = PoseGeometry.headYawEstimate(from: pose)
        XCTAssertNotNil(estimate)
        XCTAssertEqual(estimate?.towardScreenRight, true)
        // 偏移量 0.05 / 半耳距 0.034 ≈ 1.47，被钳制到 1.2 → 1.2 × 55° = 66°
        XCTAssertEqual(Double(estimate?.degrees ?? 0), 66, accuracy: 0.5)
    }

    func testHeadYawFallsBackToEyesWhenEarsMissing() {
        let pose = Fixtures.PoseBuilder()
            .removing([.leftEar, .rightEar])
            .moving(.nose, to: CGPoint(x: 0.530, y: 0.880))
            .build()
        let estimate = PoseGeometry.headYawEstimate(from: pose)
        XCTAssertNotNil(estimate, "耳朵不可见时应退化为双眼估算，而不是直接返回 nil")
        // 双眼间距 0.034，半距 0.017；偏移 0.03 / 0.017 ≈ 1.76 → 钳制 1.2 → 66°
        XCTAssertEqual(Double(estimate?.degrees ?? 0), 66, accuracy: 0.5)
    }

    func testHeadYawReturnsNilWithoutNose() {
        let pose = Fixtures.PoseBuilder().removing(.nose).build()
        XCTAssertNil(PoseGeometry.headYawEstimate(from: pose),
                     "没有鼻尖就完全没有偏航依据，必须返回 nil 而不是给一个猜测值")
    }

    func testHeadRollIsZeroForLevelEyes() {
        let roll = PoseGeometry.headRollDegrees(from: Fixtures.standardPose())
        XCTAssertNotNil(roll)
        XCTAssertEqual(Double(roll ?? 99), 0, accuracy: 0.001)
    }

    /// 画面右侧的眼睛更高 → 正角度
    func testHeadRollIsPositiveWhenScreenRightEyeIsHigher() {
        let pose = Fixtures.PoseBuilder()
            .moving(.rightEye, to: CGPoint(x: 0.517, y: 0.916))
            .build()
        let roll = PoseGeometry.headRollDegrees(from: pose)
        XCTAssertNotNil(roll)
        // dx = 0.034, dy = 0.020 → atan2(0.020, 0.034) ≈ 30.47°
        XCTAssertEqual(Double(roll ?? 0), 30.47, accuracy: 0.5)
    }

    func testHeadRollReturnsNilWithoutEyes() {
        let pose = Fixtures.PoseBuilder().removing([.leftEye, .rightEye]).build()
        XCTAssertNil(PoseGeometry.headRollDegrees(from: pose))
    }

    // MARK: - 构图几何

    func testHeadroomIsDistanceFromBoxTopToFrameTop() {
        let box = CGRect(x: 0.2, y: 0.1, width: 0.6, height: 0.8)
        XCTAssertEqual(Double(PoseGeometry.headroom(of: box)), 0.1, accuracy: 0.0001)
    }

    func testLeadRoomFollowsGazeDirection() {
        let box = CGRect(x: 0.2, y: 0.1, width: 0.6, height: 0.8)
        XCTAssertEqual(Double(PoseGeometry.leadRoom(of: box, towardScreenRight: true)), 0.2, accuracy: 0.0001)
        XCTAssertEqual(Double(PoseGeometry.leadRoom(of: box, towardScreenRight: false)), 0.2, accuracy: 0.0001)

        let offCenter = CGRect(x: 0.05, y: 0.1, width: 0.5, height: 0.8)
        XCTAssertEqual(Double(PoseGeometry.leadRoom(of: offCenter, towardScreenRight: true)), 0.45, accuracy: 0.0001)
        XCTAssertEqual(Double(PoseGeometry.leadRoom(of: offCenter, towardScreenRight: false)), 0.05, accuracy: 0.0001)
    }

    func testDeviationFromNearestThird() {
        XCTAssertEqual(Double(PoseGeometry.deviationFromNearestThird(1.0 / 3.0)), 0, accuracy: 0.0001)
        XCTAssertEqual(Double(PoseGeometry.deviationFromNearestThird(2.0 / 3.0)), 0, accuracy: 0.0001)
        XCTAssertEqual(Double(PoseGeometry.deviationFromNearestThird(0.5)), 1.0 / 6.0, accuracy: 0.0001)
    }

    func testHorizontalOffsetAndSubjectHeightRatio() {
        let centered = CGRect(x: 0.2, y: 0, width: 0.6, height: 0.75)
        XCTAssertEqual(Double(PoseGeometry.horizontalOffset(of: centered)), 0, accuracy: 0.0001)
        XCTAssertEqual(Double(PoseGeometry.subjectHeightRatio(of: centered)), 0.75, accuracy: 0.0001)

        let rightShifted = CGRect(x: 0.4, y: 0, width: 0.4, height: 0.5)
        XCTAssertEqual(Double(PoseGeometry.horizontalOffset(of: rightShifted)), 0.1, accuracy: 0.0001)
    }
}
