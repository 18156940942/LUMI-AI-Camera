import Foundation
import CoreGraphics

/// 构图分析引擎。
///
/// 输入必须是**真实视频帧上检测到的**人体姿态；没有帧、没有人物时不会给出任何构图结论。
/// 输出严格区分两类结论：
/// - ``FindingKind/objective``：可测事实（例如「头顶留白 1.2%」「人物中心偏离右三分线 6%」）
/// - ``FindingKind/heuristic``：基于摄影经验的建议（例如「建议加大留白」）
///
/// 这样摄影师可以自己判断哪一条该采纳，而不是被一堆「AI 认为」糊住。
enum CompositionAnalyzer {

    struct Thresholds {
        /// 头顶留白低于该值判定为贴边
        var headroomTight: CGFloat = 0.02
        var headroomAcceptable: CGFloat = 0.05
        var headroomExcessive: CGFloat = 0.35
        /// 视线方向留白低于该值判定为空间不足
        var leadRoomTight: CGFloat = 0.06
        /// 人物中心与三分线偏离低于该值判定为「落在三分线上」
        var thirdsTolerance: CGFloat = 0.045
        /// 背景干扰评分超过该值提示
        var backgroundClutterNotice: CGFloat = 0.42

        static let `default` = Thresholds()
    }

    static func analyze(pose: BodyPose,
                        frameSize: CGSize,
                        backgroundClutter: CGFloat? = nil,
                        thresholds: Thresholds = .default) -> CompositionReport {

        guard !pose.isEmpty, let box = pose.boundingBox else {
            return CompositionReport(
                frameSize: frameSize,
                isSubjectPresent: false,
                findings: [
                    AnalysisFinding(key: "composition-no-subject",
                                    kind: .objective,
                                    level: .info,
                                    title: "未检测到人物，无法做构图判断",
                                    detail: "构图分析以真实人物关键点为输入。当前帧没有识别到人体，因此不给出任何构图结论。请让被摄者进入画面后重试。",
                                    confidence: 1.0)
                ],
                confidence: 0,
                detectionSource: "Vision 人体关键点：未检测到人体")
        }

        var report = CompositionReport()
        report.frameSize = frameSize
        report.isSubjectPresent = true
        report.subjectBoundingBox = box
        report.confidence = pose.overallConfidence
        report.truncatedJoints = pose.truncatedSides()
        report.subjectHeightRatio = PoseGeometry.subjectHeightRatio(of: box)
        report.horizontalCenter = box.midX
        report.headroom = PoseGeometry.headroom(of: box)
        report.ruleOfThirdsDeviation = PoseGeometry.deviationFromNearestThird(box.midX)
        report.backgroundClutterScore = backgroundClutter
        report.detectionSource = "Vision 人体关键点（有效关键点 \(pose.validJointCount)/19，综合置信度 \(Int(pose.overallConfidence * 100))%）"

        let (shotType, reasons) = inferShotType(pose: pose, box: box)
        report.suggestedShotType = shotType
        report.shotTypeReasons = reasons

        var findings: [AnalysisFinding] = []
        let confidence = pose.overallConfidence

        // MARK: 1. 头顶留白
        if let headroom = report.headroom {
            let percent = headroom * 100
            if headroom < thresholds.headroomTight {
                findings.append(AnalysisFinding(
                    key: "composition-headroom",
                    kind: .objective,
                    level: .warning,
                    title: "头顶几乎贴到画面边缘",
                    detail: String(format: "实测：头顶留白仅 %.1f%% 画面高度。这个距离在打印或平台裁切时很容易把头发切掉。建议下移机位或后退半步，把留白做到 5%% 以上。", percent),
                    confidence: confidence))
            } else if headroom < thresholds.headroomAcceptable {
                findings.append(AnalysisFinding(
                    key: "composition-headroom",
                    kind: .objective,
                    level: .attention,
                    title: "头顶留白偏紧",
                    detail: String(format: "实测：头顶留白 %.1f%%。可用于紧凑的半身构图，但若后期要做 4:5 / 1:1 裁切会显得局促，建议留到 5%%-10%%。", percent),
                    confidence: confidence))
            } else if headroom > thresholds.headroomExcessive {
                findings.append(AnalysisFinding(
                    key: "composition-headroom",
                    kind: .objective,
                    level: .attention,
                    title: "头顶留白过多",
                    detail: String(format: "实测：头顶留白 %.1f%%。人物会显得「沉」在画面下方，并且浪费了画面上部。建议靠近或抬高机位，把留白压到 8%%-20%%。", percent),
                    confidence: confidence))
            } else {
                findings.append(AnalysisFinding(
                    key: "composition-headroom",
                    kind: .objective,
                    level: .good,
                    title: "头顶留白合理",
                    detail: String(format: "实测：头顶留白 %.1f%%，在常用的 5%%-25%% 区间内。", percent),
                    confidence: confidence))
            }
        }

        // MARK: 2. 视线方向空间
        let gazeTowardRight: Bool? = PoseGeometry.headYawEstimate(from: pose).map { $0.towardScreenRight }
        let isFacingCamera = abs(report.horizontalCenter.map { _ in 0 } ?? 0) >= 0 && isHeadFacingCamera(pose: pose)
        if !isFacingCamera {
            if let towardRight = gazeTowardRight {
                let lead = PoseGeometry.leadRoom(of: box, towardScreenRight: towardRight)
                let sideText = towardRight ? "画面右侧" : "画面左侧"
                if lead < thresholds.leadRoomTight {
                    findings.append(AnalysisFinding(
                        key: "composition-lead-room",
                        kind: .objective,
                        level: .attention,
                        title: "视线方向缺少空间",
                        detail: String(format: "实测：人物看向%@，而那一侧只剩 %.1f%% 画面宽度。视觉上会像「撞到画框」，建议把人物向反方向平移，让视线侧留出 15%% 以上空间。", sideText, lead * 100),
                        confidence: confidence))
                } else {
                    findings.append(AnalysisFinding(
                        key: "composition-lead-room",
                        kind: .objective,
                        level: .good,
                        title: "视线方向留白充足",
                        detail: String(format: "实测：视线方向（%@）留白 %.1f%% 画面宽度。", sideText, lead * 100),
                        confidence: confidence))
                }
            }
        } else {
            findings.append(AnalysisFinding(
                key: "composition-lead-room",
                kind: .heuristic,
                level: .info,
                title: "人物正对镜头，视线留白规则不适用",
                detail: "实测：头部基本正对镜头，因此不按「视线方向留白」判断。此时应优先保证左右留白对称或刻意打破对称。",
                confidence: confidence))
        }

        // MARK: 3. 边缘截断
        if !report.truncatedJoints.isEmpty {
            let jointOnEdge = jointsTouchingEdge(pose: pose)
            var detail = "实测：" + report.truncatedJoints.joined(separator: "、") + "已贴到画面边缘。"
            if !jointOnEdge.isEmpty {
                detail += "其中 " + jointOnEdge.joined(separator: "、") + " 正好压在边缘上 —— 裁切落在关节处是最容易出错的一种，建议改成切在小臂或大腿中段。"
            } else {
                detail += "建议后退或调整机位；若这是刻意的紧裁切，请确认没有切在关节上。"
            }
            findings.append(AnalysisFinding(
                key: "composition-truncation",
                kind: .objective,
                level: .warning,
                title: "人物被画面边缘截断",
                detail: detail,
                confidence: confidence))
        }

        // MARK: 4. 三分法
        if let deviation = report.ruleOfThirdsDeviation, let center = report.horizontalCenter {
            let percent = deviation * 100
            if deviation <= thresholds.thirdsTolerance {
                findings.append(AnalysisFinding(
                    key: "composition-thirds",
                    kind: .objective,
                    level: .good,
                    title: "人物中心落在三分线上",
                    detail: String(format: "实测：人物中心位于画面 %.0f%% 处，与最近的三分线（33%% 或 67%%）仅差 %.1f%%。", center * 100, percent),
                    confidence: confidence))
            } else {
                findings.append(AnalysisFinding(
                    key: "composition-thirds",
                    kind: .objective,
                    level: .info,
                    title: "人物中心未落在三分线",
                    detail: String(format: "实测：人物中心位于画面 %.0f%% 处，距最近三分线 %.1f%%。居中构图本身没问题（尤其在正面对称的人像里），但如果想要更松弛的平衡，可横向移动约 %.1f%% 画面宽度贴近三分线。", center * 100, percent, percent),
                    confidence: confidence))
            }
        }

        // MARK: 5. 景别判断
        if let shotType = report.suggestedShotType {
            findings.append(AnalysisFinding(
                key: "composition-shot-type",
                kind: .objective,
                level: .info,
                title: "当前取景对应「\(shotType.title)」",
                detail: "判断依据：" + reasons.joined(separator: "；"),
                confidence: confidence))
        }

        // MARK: 6. 背景干扰（只在真的算过像素时才给结论）
        if let clutter = report.backgroundClutterScore {
            if clutter >= thresholds.backgroundClutterNotice {
                findings.append(AnalysisFinding(
                    key: "composition-background",
                    kind: .objective,
                    level: .attention,
                    title: "人物轮廓外的高频细节较多",
                    detail: String(format: "实测：人物区域外的边缘密度为 %.2f，说明背景里有较多线条/杂物，容易与人物轮廓抢注意力。可考虑开大光圈（更浅景深）或换一个更干净的背景角度。", clutter),
                    confidence: confidence))
            } else {
                findings.append(AnalysisFinding(
                    key: "composition-background",
                    kind: .objective,
                    level: .good,
                    title: "背景相对干净",
                    detail: String(format: "实测：人物区域外的边缘密度为 %.2f，背景干扰较低。", clutter),
                    confidence: confidence))
            }
        } else {
            findings.append(AnalysisFinding(
                key: "composition-background",
                kind: .objective,
                level: .info,
                title: "背景干扰未评估",
                detail: "实时画面模式不逐帧计算背景细节密度（会显著增加耗电），因此本项不给出结论。导入照片后会在照片分析中给出该数值。",
                confidence: 1.0))
        }

        report.findings = findings
        return report
    }

    // MARK: - 内部判定

    /// 头部是否基本正对镜头（用于决定「视线留白」规则是否适用）
    private static func isHeadFacingCamera(pose: BodyPose) -> Bool {
        guard let yaw = PoseGeometry.headYawEstimate(from: pose) else { return true }
        return abs(yaw.degrees) < 12
    }

    /// 是否有明显弯曲的腿（用于区分坐姿）
    private static func looksSeated(pose: BodyPose) -> Bool {
        guard let leftKnee = pose.point(.leftKnee),
              let leftHip = pose.point(.leftHip),
              let leftAnkle = pose.point(.leftAnkle) else { return false }
        let kneeAngle = PoseGeometry.angleDegrees(vertex: leftKnee, from: leftHip, to: leftAnkle)
        return kneeAngle < 130
    }

    /// 推断当前取景对应的景别，并给出可核对的理由。
    static func inferShotType(pose: BodyPose, box: CGRect) -> (ShotType, [String]) {
        var reasons: [String] = []

        let kneeVisible = pose.confidence(.leftKnee) >= 0.25 && pose.confidence(.rightKnee) >= 0.25
        let ankleVisible = pose.confidence(.leftAnkle) >= 0.25 && pose.confidence(.rightAnkle) >= 0.25
        let hipVisible = pose.confidence(.leftHip) >= 0.25 && pose.confidence(.rightHip) >= 0.25

        reasons.append(String(format: "人体包围框高度占画面 %.0f%%", box.height * 100))

        if ankleVisible && kneeVisible {
            reasons.append("膝与踝关键点均可见，说明腿部完整在画面内")
            if looksSeated(pose: pose) {
                reasons.append("膝关节角度小于 130°，判断为坐姿")
                return (.seated, reasons)
            }
            return (.fullBody, reasons)
        }

        if hipVisible {
            reasons.append("髋部关键点可见，腿部未完整入镜")
            if box.height > 0.8 {
                reasons.append("人物已接近充满画面，更接近紧凑的半身")
            }
            return (.halfBody, reasons)
        }

        reasons.append("仅上半身关键点可靠，判定为特写/近半身")
        return (.closeUp, reasons)
    }

    /// 找出正好压在画面边缘上的关节
    private static func jointsTouchingEdge(pose: BodyPose, tolerance: CGFloat = 0.015) -> [String] {
        var result: [String] = []
        for joint in BodyJoint.allCases {
            guard let point = pose.point(joint) else { continue }
            let onEdge = point.x <= tolerance || point.x >= 1 - tolerance
                || point.y <= tolerance || point.y >= 1 - tolerance
            if onEdge {
                result.append(joint.displayName)
            }
        }
        return result
    }
}
