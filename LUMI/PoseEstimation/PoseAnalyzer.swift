import Foundation
import CoreGraphics

/// 把 ``BodyPose`` 转成结构化、可展示、可断言的 ``PoseReport``。
///
/// 这里是「具体角度和位置必须根据真实检测结果计算」这条要求的落地点：
/// 每一个数字都来自关键点坐标的几何运算，没有任何随机数或占位值。
enum PoseAnalyzer {

    static func analyze(_ pose: BodyPose) -> PoseReport {
        guard !pose.isEmpty, let box = pose.boundingBox else { return .empty }

        var report = PoseReport()
        report.isDetected = true
        report.boundingBox = box
        report.confidence = pose.overallConfidence
        report.validJointCount = pose.validJointCount

        // 肩线：按画面左右排序，不依赖 Vision 的左右命名语义，
        // 保证「画面左侧肩膀更低」这种描述与摄影师看到的画面一致。
        if let a = pose.point(.leftShoulder), let b = pose.point(.rightShoulder) {
            let screenLeft = a.x <= b.x ? a : b
            let screenRight = a.x <= b.x ? b : a
            report.shoulderTiltDegrees = PoseGeometry.tiltDegrees(from: screenLeft, to: screenRight)
        }

        // 髋线
        if let a = pose.point(.leftHip), let b = pose.point(.rightHip) {
            let screenLeft = a.x <= b.x ? a : b
            let screenRight = a.x <= b.x ? b : a
            report.hipTiltDegrees = PoseGeometry.tiltDegrees(from: screenLeft, to: screenRight)
        }

        // 躯干左右倾斜
        if let shoulderCenter = pose.midpoint(.leftShoulder, .rightShoulder),
           let hipCenter = pose.midpoint(.leftHip, .rightHip) {
            report.torsoLeanDegrees = PoseGeometry.torsoLeanDegrees(shoulderCenter: shoulderCenter,
                                                                   hipCenter: hipCenter)
        }

        // 头部转向（估算）与歪斜（实测）
        if let yaw = PoseGeometry.headYawEstimate(from: pose), yaw.confidence >= 0.2 {
            report.headTurnDegrees = yaw.degrees
        }
        report.headTiltDegrees = PoseGeometry.headRollDegrees(from: pose)

        // 肘关节
        if let shoulder = pose.point(.leftShoulder),
           let elbow = pose.point(.leftElbow),
           let wrist = pose.point(.leftWrist) {
            report.leftElbowAngle = PoseGeometry.angleDegrees(vertex: elbow, from: shoulder, to: wrist)
        }
        if let shoulder = pose.point(.rightShoulder),
           let elbow = pose.point(.rightElbow),
           let wrist = pose.point(.rightWrist) {
            report.rightElbowAngle = PoseGeometry.angleDegrees(vertex: elbow, from: shoulder, to: wrist)
        }

        // 手部高度分带
        if let shoulderCenter = pose.midpoint(.leftShoulder, .rightShoulder),
           let hipCenter = pose.midpoint(.leftHip, .rightHip) {
            if let leftWrist = pose.point(.leftWrist) {
                report.leftWristZone = PoseGeometry.wristZone(wrist: leftWrist,
                                                             shoulder: shoulderCenter,
                                                             hip: hipCenter).title
            }
            if let rightWrist = pose.point(.rightWrist) {
                report.rightWristZone = PoseGeometry.wristZone(wrist: rightWrist,
                                                              shoulder: shoulderCenter,
                                                              hip: hipCenter).title
            }
        }

        // 人物在画面中的位置
        report.personCenterOffset = PoseGeometry.horizontalOffset(of: box)
        report.reachingFrameEdge = !pose.truncatedSides().isEmpty

        // 生成指导结论（内部已完成低置信度门控）
        report.coachTips = PoseCoachEngine.tips(for: report, pose: pose)

        return report
    }
}
