import Foundation
import CoreGraphics
@testable import LUMI

/// 测试夹具。
///
/// 设计原则：**所有几何数值都是手算可控的常量**，不用随机数。
/// 这样测试失败时能直接从坐标推出期望值，而不是「跑一次看看是什么」。
enum Fixtures {

    // MARK: - 人体姿态

    /// 一个标准站姿的 19 个关键点（Vision 归一化坐标，**原点在左下角**，y 向上）。
    ///
    /// 手工核对过的几何量（供各测试断言使用）：
    /// - 包围框：x 0.370–0.630，y 0.100–0.896 → 中心 x = 0.500，头顶留白 = 10.4%
    /// - 肩线倾斜 = 0°，髋线倾斜 = 0°，躯干倾斜 = 0°，头部歪斜 = 0°
    /// - 头部偏航 = 0°（鼻尖正好在双耳中点），综合置信度 0.85
    /// - 左肘角 ≈ 132.3°，右肘角 ≈ 139.4°（都落在「弯曲自然」的 100–150° 区间）
    /// - 左右手腕都在髋部高度 → 会触发「双手位置都偏低」这条启发式提示
    static let standardStanding: [BodyJoint: CGPoint] = [
        .nose: CGPoint(x: 0.500, y: 0.880),
        .leftEye: CGPoint(x: 0.483, y: 0.896),
        .rightEye: CGPoint(x: 0.517, y: 0.896),
        .leftEar: CGPoint(x: 0.466, y: 0.884),
        .rightEar: CGPoint(x: 0.534, y: 0.884),
        .neck: CGPoint(x: 0.500, y: 0.820),
        .leftShoulder: CGPoint(x: 0.400, y: 0.800),
        .rightShoulder: CGPoint(x: 0.600, y: 0.800),
        .leftElbow: CGPoint(x: 0.370, y: 0.680),
        .rightElbow: CGPoint(x: 0.630, y: 0.680),
        .leftWrist: CGPoint(x: 0.410, y: 0.620),
        .rightWrist: CGPoint(x: 0.580, y: 0.580),
        .root: CGPoint(x: 0.500, y: 0.620),
        .leftHip: CGPoint(x: 0.440, y: 0.600),
        .rightHip: CGPoint(x: 0.560, y: 0.600),
        .leftKnee: CGPoint(x: 0.440, y: 0.350),
        .rightKnee: CGPoint(x: 0.560, y: 0.350),
        .leftAnkle: CGPoint(x: 0.440, y: 0.100),
        .rightAnkle: CGPoint(x: 0.560, y: 0.100),
    ]

    /// 可链式修改的姿态构造器。
    struct PoseBuilder {
        private var positions: [BodyJoint: CGPoint]
        private var confidenceOverrides: [BodyJoint: Float] = [:]
        private var defaultConfidence: Float = 0.9
        private var overall: Float = 0.85

        init(positions: [BodyJoint: CGPoint] = Fixtures.standardStanding) {
            self.positions = positions
        }

        /// 移动某个关节（返回新实例，避免测试之间互相污染）
        func moving(_ joint: BodyJoint, to point: CGPoint) -> PoseBuilder {
            var copy = self
            copy.positions[joint] = point
            return copy
        }

        /// 移除某个关节（模拟「该关节没检测到」）
        func removing(_ joint: BodyJoint) -> PoseBuilder {
            var copy = self
            copy.positions.removeValue(forKey: joint)
            return copy
        }

        func removing(_ joints: [BodyJoint]) -> PoseBuilder {
            joints.reduce(self) { $0.removing($1) }
        }

        /// 设置某个关节的置信度
        func withConfidence(_ joint: BodyJoint, _ value: Float) -> PoseBuilder {
            var copy = self
            copy.confidenceOverrides[joint] = value
            return copy
        }

        func withDefaultConfidence(_ value: Float) -> PoseBuilder {
            var copy = self
            copy.defaultConfidence = value
            return copy
        }

        func withOverallConfidence(_ value: Float) -> PoseBuilder {
            var copy = self
            copy.overall = value
            return copy
        }

        /// 只保留给定关节，其余全部剔除（用于构造「只有上半身可见」这类场景）
        func keepingOnly(_ joints: [BodyJoint]) -> PoseBuilder {
            var copy = self
            copy.positions = copy.positions.filter { joints.contains($0.key) }
            return copy
        }

        func build(timestamp: Double = 0) -> BodyPose {
            var points: [BodyJoint: BodyJointPoint] = [:]
            for (joint, location) in positions {
                let confidence = confidenceOverrides[joint] ?? defaultConfidence
                points[joint] = BodyJointPoint(joint: joint, location: location, confidence: confidence)
            }
            let validCount = points.values.filter { $0.confidence >= BodyPose.defaultThreshold }.count
            return BodyPose(points: points,
                            overallConfidence: overall,
                            timestamp: timestamp,
                            detectedJointCount: validCount)
        }
    }

    /// 标准站姿，全部关节置信度 0.9，综合置信度 0.85
    static func standardPose() -> BodyPose {
        PoseBuilder().build()
    }

    /// 空姿态（没有检测到人）
    static var emptyPose: BodyPose { .empty }

    // MARK: - 姿势条目

    /// 构造一条用于测试的姿势。默认值刻意做得「中性且完整」，
    /// 各测试只覆盖自己关心的一两个字段，避免测试之间隐性耦合。
    static func makePoseSuggestion(
        id: String = "test-01",
        name: String = "测试姿势",
        summary: String = "用于单元测试的姿势条目",
        scenes: [PoseScene] = [.outdoorPortrait],
        styles: [PoseStyle] = [.naturalRelaxed],
        shotType: ShotType = .halfBody,
        bodyRotation: PoseRotation = PoseRotation(degrees: 30, direction: .left),
        headTurn: PoseRotation = PoseRotation(degrees: 20, direction: .right),
        chin: ChinCue = .neutral,
        gaze: PoseGaze = PoseGaze(anchor: .camera, detail: "看向镜头中心"),
        shoulders: ShoulderCue = .relaxedEven,
        nearestHand: HandPlacement = .onHip,
        otherHand: HandPlacement? = .relaxedDown,
        weight: WeightCue = .backLeg,
        legs: LegCue = .oneFootForward,
        environment: String = "借助场地中的台阶或栏杆",
        cameraAngle: CameraAngle = .eyeLevel,
        composition: PoseComposition = PoseComposition(horizontalAnchor: 0.35,
                                                       headAnchor: 0.25,
                                                       headroomRatio: 0.1,
                                                       needsLeadRoom: true,
                                                       note: "注意背景不要压住头顶"),
        photographerTips: String = "先拍一张试光，再让模特进入状态",
        difficulty: Int = 1,
        keywords: [String] = ["测试", "站位"]
    ) -> PoseSuggestion {
        PoseSuggestion(id: id,
                       name: name,
                       summary: summary,
                       scenes: scenes,
                       styles: styles,
                       shotType: shotType,
                       bodyRotation: bodyRotation,
                       headTurn: headTurn,
                       chin: chin,
                       gaze: gaze,
                       shoulders: shoulders,
                       nearestHand: nearestHand,
                       otherHand: otherHand,
                       weight: weight,
                       legs: legs,
                       environment: environment,
                       cameraAngle: cameraAngle,
                       composition: composition,
                       photographerTips: photographerTips,
                       difficulty: difficulty,
                       keywords: keywords)
    }

    // MARK: - 图像

    /// 用 CGContext 生成一张纯色灰度图（数据由 CGContext 自己分配，生命周期安全）
    static func solidGrayImage(value: CGFloat, size: Int = 64) -> CGImage {
        let context = CGContext(data: nil,
                                width: size,
                                height: size,
                                bitsPerComponent: 8,
                                bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceGray(),
                                bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.setFillColor(gray: value, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return context.makeImage()!
    }

    /// 黑白棋盘格：相邻像素差异极大 → 边缘密度与拉普拉斯方差都应该很高
    static func checkerboardImage(blockSize: Int = 8, size: Int = 64) -> CGImage {
        let context = CGContext(data: nil,
                                width: size,
                                height: size,
                                bitsPerComponent: 8,
                                bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceGray(),
                                bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        context.setFillColor(gray: 1, alpha: 1)
        var blockY = 0
        while blockY < size {
            var blockX = 0
            while blockX < size {
                if ((blockX / blockSize) + (blockY / blockSize)) % 2 == 1 {
                    context.fill(CGRect(x: blockX, y: blockY, width: blockSize, height: blockSize))
                }
                blockX += blockSize
            }
            blockY += blockSize
        }
        return context.makeImage()!
    }

    /// 手写灰度缓冲：完全可控，用来断言 mean / stddev / 边缘密度
    static func grayBuffer(_ rows: [[UInt8]]) -> ImageQualityCalculator.GrayBuffer {
        let height = rows.count
        let width = rows.first?.count ?? 0
        var data: [UInt8] = []
        data.reserveCapacity(width * height)
        for row in rows {
            precondition(row.count == width, "灰度缓冲每一行长度必须一致")
            data.append(contentsOf: row)
        }
        return ImageQualityCalculator.GrayBuffer(data: data, width: width, height: height)
    }
}
