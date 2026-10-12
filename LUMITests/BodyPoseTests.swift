import XCTest
import CoreGraphics
@testable import LUMI

/// `BodyPose` 是「只有真实检测到的关键点才进入数据流」这条规则的载体。
/// 这些测试确保：没有检测到人时数据结构是空的，而不是被填上占位值。
final class BodyPoseTests: XCTestCase {

    func testEmptyPoseHasNoPointsAndNoBoundingBox() {
        let pose = BodyPose.empty
        XCTAssertTrue(pose.isEmpty)
        XCTAssertEqual(pose.validJointCount, 0)
        XCTAssertNil(pose.boundingBox)
        XCTAssertTrue(pose.truncatedSides().isEmpty)
        XCTAssertEqual(pose.overallConfidence, 0)
    }

    func testStandardFixtureHasAllNineteenJoints() {
        let pose = Fixtures.standardPose()
        XCTAssertFalse(pose.isEmpty)
        XCTAssertEqual(pose.points.count, BodyJoint.allCases.count)
        XCTAssertEqual(pose.detectedJointCount, BodyJoint.allCases.count)
        XCTAssertEqual(pose.validJointCount, BodyJoint.allCases.count)
        XCTAssertTrue(pose.unreliableJoints.isEmpty)
    }

    /// 低于阈值的关键点必须被 `point(_:)` 拒绝，避免低质量坐标进入几何计算
    func testPointRespectsConfidenceThreshold() {
        let pose = Fixtures.PoseBuilder()
            .withConfidence(.nose, 0.20)
            .build()
        XCTAssertNil(pose.point(.nose), "置信度 0.20 低于默认阈值 0.25，不应返回坐标")
        XCTAssertNil(pose.point(.nose, threshold: 0.30))
        XCTAssertNotNil(pose.point(.nose, threshold: 0.10), "降低阈值后应能取到该点")
        XCTAssertNotNil(pose.point(.leftShoulder))
    }

    func testValidJointCountExcludesLowConfidenceJoints() {
        let pose = Fixtures.PoseBuilder()
            .withConfidence(.nose, 0.10)
            .withConfidence(.leftWrist, 0.05)
            .build()
        XCTAssertEqual(pose.validJointCount, BodyJoint.allCases.count - 2)
        XCTAssertEqual(Set(pose.unreliableJoints), Set([.nose, .leftWrist]))
    }

    func testBoundingBoxMatchesJointExtremes() {
        let box = Fixtures.standardPose().boundingBox
        let unwrapped = box
        XCTAssertNotNil(unwrapped)
        guard let unwrapped else { return }
        // 标准夹具：最小 x 来自左肘 0.370，最大 x 来自右肘 0.630
        XCTAssertEqual(Double(unwrapped.minX), 0.370, accuracy: 0.0001)
        XCTAssertEqual(Double(unwrapped.maxX), 0.630, accuracy: 0.0001)
        // 最小 y 来自脚踝 0.100，最大 y 来自眼睛 0.896
        XCTAssertEqual(Double(unwrapped.minY), 0.100, accuracy: 0.0001)
        XCTAssertEqual(Double(unwrapped.maxY), 0.896, accuracy: 0.0001)
    }

    func testBoundingBoxIgnoresLowConfidenceJoints() {
        // 把脚踝置信度压低，包围框下沿应该收缩到膝盖
        let pose = Fixtures.PoseBuilder()
            .withConfidence(.leftAnkle, 0.05)
            .withConfidence(.rightAnkle, 0.05)
            .build()
        guard let box = pose.boundingBox else { return XCTFail("应能算出包围框") }
        XCTAssertEqual(Double(box.minY), 0.350, accuracy: 0.0001)
    }

    func testMidpointAveragesBothJoints() {
        let pose = Fixtures.standardPose()
        let midpoint = pose.midpoint(.leftHip, .rightHip)
        XCTAssertNotNil(midpoint)
        guard let midpoint else { return }
        XCTAssertEqual(Double(midpoint.x), 0.500, accuracy: 0.0001)
        XCTAssertEqual(Double(midpoint.y), 0.600, accuracy: 0.0001)
    }

    func testMidpointReturnsNilWhenEitherJointIsUnreliable() {
        let pose = Fixtures.PoseBuilder()
            .withConfidence(.rightHip, 0.10)
            .build()
        XCTAssertNil(pose.midpoint(.leftHip, .rightHip))
    }

    func testTruncatedSidesIsEmptyForWellFramedSubject() {
        XCTAssertTrue(Fixtures.standardPose().truncatedSides().isEmpty,
                      "标准夹具四边都留有余量，不应报截断")
    }

    func testTruncatedSidesDetectsTopTruncation() {
        // 把头顶推到画面最上方
        let pose = Fixtures.PoseBuilder()
            .moving(.nose, to: CGPoint(x: 0.500, y: 0.995))
            .moving(.leftEye, to: CGPoint(x: 0.483, y: 0.998))
            .moving(.rightEye, to: CGPoint(x: 0.517, y: 0.998))
            .build()
        let sides = pose.truncatedSides()
        XCTAssertTrue(sides.contains("画面顶部"), "实际: \(sides)")
    }

    func testTruncatedSidesDetectsBottomTruncation() {
        let pose = Fixtures.PoseBuilder()
            .moving(.leftAnkle, to: CGPoint(x: 0.440, y: 0.005))
            .moving(.rightAnkle, to: CGPoint(x: 0.560, y: 0.005))
            .build()
        let sides = pose.truncatedSides()
        XCTAssertTrue(sides.contains("画面底部"), "实际: \(sides)")
    }

    func testSkeletonEdgesReferenceExistingJoints() {
        // 骨架连线不允许引用不存在的枚举值
        for (a, b) in BodyJoint.skeletonEdges {
            XCTAssertTrue(BodyJoint.allCases.contains(a))
            XCTAssertTrue(BodyJoint.allCases.contains(b))
            XCTAssertNotEqual(a, b, "骨架连线两端不能是同一个关节")
        }
        XCTAssertFalse(BodyJoint.skeletonEdges.isEmpty)
    }

    func testEveryJointHasDisplayNameAndVisionName() {
        for joint in BodyJoint.allCases {
            XCTAssertFalse(joint.displayName.isEmpty, "\(joint) 缺少中文名")
        }
        XCTAssertEqual(Set(BodyJoint.allCases.map(\.displayName)).count,
                       BodyJoint.allCases.count,
                       "关节中文名不应重复")
    }

    func testUpperAndLowerBodyJointGroupsAreDisjointAndNonEmpty() {
        XCTAssertFalse(BodyJoint.upperBodyJoints.isEmpty)
        XCTAssertFalse(BodyJoint.lowerBodyJoints.isEmpty)
        let upper = Set(BodyJoint.upperBodyJoints)
        let lower = Set(BodyJoint.lowerBodyJoints)
        XCTAssertTrue(upper.isDisjoint(with: lower))
    }
}
