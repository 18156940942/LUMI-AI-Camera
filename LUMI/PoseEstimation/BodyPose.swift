import Foundation
import Vision
import CoreGraphics

/// 与 Vision `VNHumanBodyPoseObservation` 的 19 个关键点一一对应的强类型枚举。
///
/// 用枚举而不是字符串，好处是：编译器能在关键点缺失时提醒你，且骨架连线可以静态声明。
enum BodyJoint: String, CaseIterable, Hashable {
    case nose
    case leftEye
    case rightEye
    case leftEar
    case rightEar
    case neck
    case leftShoulder
    case rightShoulder
    case leftElbow
    case rightElbow
    case leftWrist
    case rightWrist
    case root
    case leftHip
    case rightHip
    case leftKnee
    case rightKnee
    case leftAnkle
    case rightAnkle

    var visionName: VNHumanBodyPoseObservation.JointName {
        switch self {
        case .nose: return .nose
        case .leftEye: return .leftEye
        case .rightEye: return .rightEye
        case .leftEar: return .leftEar
        case .rightEar: return .rightEar
        case .neck: return .neck
        case .leftShoulder: return .leftShoulder
        case .rightShoulder: return .rightShoulder
        case .leftElbow: return .leftElbow
        case .rightElbow: return .rightElbow
        case .leftWrist: return .leftWrist
        case .rightWrist: return .rightWrist
        case .root: return .root
        case .leftHip: return .leftHip
        case .rightHip: return .rightHip
        case .leftKnee: return .leftKnee
        case .rightKnee: return .rightKnee
        case .leftAnkle: return .leftAnkle
        case .rightAnkle: return .rightAnkle
        }
    }

    var displayName: String {
        switch self {
        case .nose: return "鼻"
        case .leftEye: return "左眼"
        case .rightEye: return "右眼"
        case .leftEar: return "左耳"
        case .rightEar: return "右耳"
        case .neck: return "颈"
        case .leftShoulder: return "左肩"
        case .rightShoulder: return "右肩"
        case .leftElbow: return "左肘"
        case .rightElbow: return "右肘"
        case .leftWrist: return "左腕"
        case .rightWrist: return "右腕"
        case .root: return "躯干根"
        case .leftHip: return "左髋"
        case .rightHip: return "右髋"
        case .leftKnee: return "左膝"
        case .rightKnee: return "右膝"
        case .leftAnkle: return "左踝"
        case .rightAnkle: return "右踝"
        }
    }

    /// 用于「上半身是否完整」等判断的关键点集合
    static let upperBodyJoints: [BodyJoint] = [
        .nose, .neck, .leftShoulder, .rightShoulder, .leftElbow, .rightElbow, .leftWrist, .rightWrist
    ]

    static let lowerBodyJoints: [BodyJoint] = [
        .root, .leftHip, .rightHip, .leftKnee, .rightKnee, .leftAnkle, .rightAnkle
    ]

    /// 骨架连线定义（左右对称，共 16 条）
    static let skeletonEdges: [(BodyJoint, BodyJoint)] = [
        (.nose, .neck),
        (.nose, .leftEye), (.nose, .rightEye),
        (.leftEye, .leftEar), (.rightEye, .rightEar),
        (.neck, .leftShoulder), (.neck, .rightShoulder),
        (.leftShoulder, .leftElbow), (.leftElbow, .leftWrist),
        (.rightShoulder, .rightElbow), (.rightElbow, .rightWrist),
        (.neck, .root),
        (.root, .leftHip), (.root, .rightHip),
        (.leftHip, .leftKnee), (.leftKnee, .leftAnkle),
        (.rightHip, .rightKnee), (.rightKnee, .rightAnkle),
        (.leftShoulder, .leftHip), (.rightShoulder, .rightHip)
    ]
}

/// 单个关键点的检测结果
struct BodyJointPoint: Hashable {
    var joint: BodyJoint
    /// 归一化坐标，**原点在左下角**（Vision 约定），x/y 范围 0...1
    var location: CGPoint
    var confidence: Float
}

/// 一帧人体姿态检测结果。
///
/// 只有真实检测到的关键点才会进入 `points`。没有检测到人时，`points` 为空、
/// 调用方必须显式处理「未检测到」的情况，不允许编造数据。
struct BodyPose: Equatable {
    var points: [BodyJoint: BodyJointPoint]
    /// 用于门控「低置信度不给出确定性结论」的综合置信度（0...1）
    var overallConfidence: Float
    /// 帧时间戳（秒）
    var timestamp: Double
    /// 关键点数量（Vision 固定 19 个，这里是实际返回并达到阈值的数量）
    var detectedJointCount: Int

    static let empty = BodyPose(points: [:], overallConfidence: 0, timestamp: 0, detectedJointCount: 0)

    /// 默认的关键点可用阈值。低于该值的点视为不可用。
    static let defaultThreshold: Float = 0.25

    func point(_ joint: BodyJoint, threshold: Float = BodyPose.defaultThreshold) -> CGPoint? {
        guard let p = points[joint], p.confidence >= threshold else { return nil }
        return p.location
    }

    func confidence(_ joint: BodyJoint) -> Float {
        points[joint]?.confidence ?? 0
    }

    var isEmpty: Bool { points.isEmpty }

    /// 达到阈值的有效关键点数量
    var validJointCount: Int {
        points.values.filter { $0.confidence >= BodyPose.defaultThreshold }.count
    }

    /// 未达到阈值的关节名（用于向用户解释「为什么没有结论」）
    var unreliableJoints: [BodyJoint] {
        BodyJoint.allCases.filter { confidence($0) < BodyPose.defaultThreshold }
    }

    func midpoint(_ a: BodyJoint, _ b: BodyJoint, threshold: Float = BodyPose.defaultThreshold) -> CGPoint? {
        guard let pa = point(a, threshold: threshold), let pb = point(b, threshold: threshold) else { return nil }
        return CGPoint(x: (pa.x + pb.x) / 2.0, y: (pa.y + pb.y) / 2.0)
    }

    /// 由高置信度关键点构成的包围框（Vision 归一化坐标）
    var boundingBox: CGRect? {
        let usable = points.values.filter { $0.confidence >= BodyPose.defaultThreshold }
        guard !usable.isEmpty else { return nil }
        var minX = CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude
        for p in usable {
            minX = min(minX, p.location.x)
            minY = min(minY, p.location.y)
            maxX = max(maxX, p.location.x)
            maxY = max(maxY, p.location.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// 人体包围框是否被画面边缘截断（含容差，避免抖动误报）
    func truncatedSides(tolerance: CGFloat = 0.02) -> [String] {
        guard let box = boundingBox else { return [] }
        var sides: [String] = []
        if box.minX <= tolerance { sides.append("画面左侧") }
        if box.maxX >= 1 - tolerance { sides.append("画面右侧") }
        if box.maxY >= 1 - tolerance { sides.append("画面顶部") }
        if box.minY <= tolerance { sides.append("画面底部") }
        return sides
    }
}
