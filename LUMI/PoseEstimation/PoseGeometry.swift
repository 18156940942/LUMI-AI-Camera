import Foundation
import CoreGraphics

/// 纯几何计算工具。全部是静态纯函数，因此可以被单元测试直接覆盖，
/// 也是「角度与位置必须来自真实检测结果」这条要求的实现基础。
enum PoseGeometry {

    static let degreesPerRadian = 180.0 / Double.pi

    // MARK: - 角度

    /// a→b 连线与水平轴的夹角（度），范围 -180...180。
    /// 使用 Vision 坐标（原点左下、y 向上），因此**正值表示 b 点比 a 点更高（画面中更靠上）**。
    static func lineAngleDegrees(from a: CGPoint, to b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        if abs(dx) < 0.000001 && abs(dy) < 0.000001 { return 0 }
        return atan2(dy, dx) * CGFloat(degreesPerRadian)
    }

    /// 归一化到 -90...90 的「倾斜角」。
    /// 用于肩线、髋线、眼线这类没有方向性的线段：
    /// 正值 = 第二个点更高，负值 = 第二个点更低。
    static func tiltDegrees(from a: CGPoint, to b: CGPoint) -> CGFloat {
        var angle = lineAngleDegrees(from: a, to: b)
        if angle > 90 { angle -= 180 }
        if angle < -90 { angle += 180 }
        return angle
    }

    /// 以 vertex 为顶点的夹角（度），范围 0...180。用于肘关节、膝关节弯曲度。
    static func angleDegrees(vertex: CGPoint, from a: CGPoint, to b: CGPoint) -> CGFloat {
        let v1 = CGPoint(x: a.x - vertex.x, y: a.y - vertex.y)
        let v2 = CGPoint(x: b.x - vertex.x, y: b.y - vertex.y)
        let len1 = hypot(v1.x, v1.y)
        let len2 = hypot(v2.x, v2.y)
        if len1 < 0.000001 || len2 < 0.000001 { return 0 }
        let cosine = (v1.x * v2.x + v1.y * v2.y) / (len1 * len2)
        let clamped = min(max(cosine, -1), 1)
        return acos(clamped) * CGFloat(degreesPerRadian)
    }

    /// 身体躯干的左右倾斜（度）。正 = 肩部相对髋部偏画面右侧。
    static func torsoLeanDegrees(shoulderCenter: CGPoint, hipCenter: CGPoint) -> CGFloat {
        let dx = shoulderCenter.x - hipCenter.x
        let dy = shoulderCenter.y - hipCenter.y
        if abs(dy) < 0.000001 { return 0 }
        return atan2(dx, dy) * CGFloat(degreesPerRadian)
    }

    // MARK: - 位置关系

    static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    /// 从 a 指向 b 的方向描述，用「画面左/右/上/下」表达。
    ///
    /// 约定：所有方向都以**监看画面**为参照（画面左 = 画面左侧），
    /// 因为 App 的使用者是摄影师，摄影师看到的就是画面。
    static func directionText(from a: CGPoint, to b: CGPoint, tolerance: CGFloat = 0.02) -> String {
        let dx = b.x - a.x
        let dy = b.y - a.y
        var parts: [String] = []
        if abs(dx) > tolerance {
            parts.append(dx > 0 ? "画面右侧" : "画面左侧")
        }
        if abs(dy) > tolerance {
            parts.append(dy > 0 ? "上方" : "下方")
        }
        if parts.isEmpty {
            return "与\(label(for: a))大致重合"
        }
        return parts.joined(separator: "偏")
    }

    private static func label(for point: CGPoint) -> String {
        "参考点"
    }

    /// 把归一化坐标（原点左下）转换成 SwiftUI 绘制坐标（原点左上）
    static func flipped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: 1 - point.y)
    }

    static func flipped(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: 1 - rect.maxY, width: rect.width, height: rect.height)
    }

    // MARK: - 手腕所在高度分带

    /// 手腕高度的粗略分带。用于「手放在哪里」的客观描述。
    enum WristZone: String, Hashable {
        case aboveShoulder
        case chest
        case waist
        case hip
        case belowHip
        case unknown

        var title: String {
            switch self {
            case .aboveShoulder: return "高于肩线"
            case .chest: return "在胸部高度"
            case .waist: return "在腰线附近"
            case .hip: return "在髋部高度"
            case .belowHip: return "低于髋部"
            case .unknown: return "不可判定"
            }
        }
    }

    /// 根据肩、髋的归一化 y 坐标判断手腕处于哪一带。
    /// 注意：这是**粗分带**，不做精确骨骼长度建模，因此 UI 上用「附近/大致」这类措辞。
    static func wristZone(wrist: CGPoint, shoulder: CGPoint, hip: CGPoint) -> WristZone {
        let shoulderY = shoulder.y
        let hipY = hip.y
        let y = wrist.y

        if y >= shoulderY + 0.02 { return .aboveShoulder }
        if y >= shoulderY - 0.06 { return .chest }
        let waistLine = (shoulderY + hipY) / 2.0
        if y >= waistLine - 0.03 { return .waist }
        if y >= hipY - 0.04 { return .hip }
        return .belowHip
    }

    // MARK: - 头部姿态估算

    /// 头部水平转动（偏航）的**估算值**。
    ///
    /// 方法：鼻尖相对双耳（或双眼）中点的水平偏移量，按两耳间距的一半归一化后映射为角度。
    /// 局限：这是单目 2D 关键点的粗略估计，不是 3D 姿态解算，
    /// 因此返回结果中带 confidence，且 UI 必须标注「估算」。
    struct HeadYawEstimate {
        var degrees: CGFloat
        var confidence: Float
        /// 阳性表示鼻尖偏向画面右侧 → 头部转向画面右侧
        var towardScreenRight: Bool

        var text: String {
            let side = towardScreenRight ? "画面右侧" : "画面左侧"
            return String(format: "头部向%@转动约 %.0f°（估算）", side, abs(degrees))
        }
    }

    static func headYawEstimate(from pose: BodyPose) -> HeadYawEstimate? {
        guard let nose = pose.point(.nose) else { return nil }

        let leftEar = pose.point(.leftEar)
        let rightEar = pose.point(.rightEar)
        let leftEye = pose.point(.leftEye)
        let rightEye = pose.point(.rightEye)

        var centerX: CGFloat?
        var halfWidth: CGFloat?
        var baseConfidence: Float = 0

        if let le = leftEar, let re = rightEar, abs(le.x - re.x) > 0.02 {
            centerX = (le.x + re.x) / 2
            halfWidth = abs(le.x - re.x) / 2
            baseConfidence = min(pose.confidence(.leftEar), pose.confidence(.rightEar))
        } else if let le = leftEye, let re = rightEye, abs(le.x - re.x) > 0.01 {
            // 耳朵不可见时退化为双眼：双眼间距大很多，映射系数相应放大
            centerX = (le.x + re.x) / 2
            halfWidth = abs(le.x - re.x) / 2
            baseConfidence = min(pose.confidence(.leftEye), pose.confidence(.rightEye)) * 0.7
        }

        guard let center = centerX, let half = halfWidth, half > 0.0001 else { return nil }

        let offset = (nose.x - center) / half          // -1...1 量级
        let clamped = min(max(offset, -1.2), 1.2)
        let degrees = clamped * 55                     // 经验映射：偏移满量程约 55°
        let confidence = baseConfidence * min(pose.confidence(.nose) / 0.5, 1.0)

        return HeadYawEstimate(degrees: degrees,
                               confidence: confidence,
                               towardScreenRight: offset > 0)
    }

    /// 头部左右歪斜（滚转）。正 = 画面右侧的眼睛更高。
    static func headRollDegrees(from pose: BodyPose) -> CGFloat? {
        guard let a = pose.point(.leftEye), let b = pose.point(.rightEye) else { return nil }
        // 不依赖 Vision 的左右命名语义，直接按画面左右排序，保证方向描述与实际画面一致
        let screenLeft = a.x <= b.x ? a : b
        let screenRight = a.x <= b.x ? b : a
        return tiltDegrees(from: screenLeft, to: screenRight)
    }

    // MARK: - 构图相关几何

    /// 人物中心相对画面中心的水平偏移（正 = 偏画面右侧）
    static func horizontalOffset(of box: CGRect) -> CGFloat {
        box.midX - 0.5
    }

    /// 距离最近的三分线的归一化偏离量（0 = 正好落在三分线上）
    static func deviationFromNearestThird(_ x: CGFloat) -> CGFloat {
        let thirds: [CGFloat] = [1.0 / 3.0, 2.0 / 3.0]
        return thirds.map { abs(x - $0) }.min() ?? 0
    }

    /// 头顶留白比例：头顶（包围框上沿）到画面顶部的距离占画面高度比例
    static func headroom(of box: CGRect) -> CGFloat {
        return 1 - box.maxY
    }

    /// 视线方向一侧的留白比例。`towardRight == true` 时看画面右侧的空白，
    /// 否则看左侧。返回 0...1。
    static func leadRoom(of box: CGRect, towardScreenRight: Bool) -> CGFloat {
        towardScreenRight ? (1 - box.maxX) : box.minX
    }

    /// 人物高度占画面比例
    static func subjectHeightRatio(of box: CGRect) -> CGFloat {
        box.height
    }
}
