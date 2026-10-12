import Foundation
import CoreGraphics

/// 实时姿势指导引擎。
///
/// 铁律：**所有结论都必须由 ``PoseReport`` 中的真实测量值推导**。
/// - 置信度不足时，引擎只输出「识别不稳定」这一条，并明确说明不给角度结论；
/// - 每条建议都带上触发它的实测数值，让摄影师可以自己验证；
/// - 客观测量（``FindingKind/objective``）与经验建议（``FindingKind/heuristic``）分开标注。
enum PoseCoachEngine {

    struct Thresholds {
        /// 肩线倾斜超过该角度开始提示
        var shoulderTiltAttention: CGFloat = 3.0
        var shoulderTiltWarning: CGFloat = 8.0
        /// 躯干左右倾斜超过该角度开始提示
        var torsoLeanAttention: CGFloat = 4.0
        /// 头部转向超过该角度提示（估算值，阈值放宽）
        var headTurnNotice: CGFloat = 15.0
        /// 头部歪斜超过该角度提示
        var headTiltNotice: CGFloat = 6.0
        /// 肘部角度（伸直时趋近 180）
        var elbowTooStraight: CGFloat = 168.0
        var elbowTooClosed: CGFloat = 55.0
        /// 人物偏离画面中线的提示阈值
        var centerOffsetNotice: CGFloat = 0.10
        var centerOffsetBig: CGFloat = 0.22
        /// 低于该综合置信度时完全不给角度结论
        var minConfidenceForAdvice: Float = 0.30
        /// 有效关键点少于该数量时不给角度结论
        var minValidJointsForAdvice: Int = 8

        static let `default` = Thresholds()
    }

    /// 阈值比较的浮点容差。
    ///
    /// 真实检测坐标是任意浮点数。把人物整体平移 0.10 画面宽度后，包围框中点减画面
    /// 中线得到的是 `0.09999999999999998` —— 比阈值小 2e-17。若直接用 `>=` 比较，
    /// 这个「正好落在边界上」的测量值会掉到阈值下方，让结论取决于浮点噪声，
    /// 也违背了本项目「阈值边界算达到」的既定约定（见 PoseCoachEngineTests
    /// 的 testGateBoundaryIsInclusive）。
    ///
    /// 1e-9 远小于任何有意义的测量精度（归一化坐标下相当于百万分之一像素级），
    /// 又远大于双精度累加误差，因此只吸收噪声、不改变语义。
    private static let thresholdEpsilon: CGFloat = 1e-9

    /// `value` 是否已达到阈值（边界算达到）
    private static func reaches(_ value: CGFloat, _ threshold: CGFloat) -> Bool {
        value + thresholdEpsilon >= threshold
    }

    /// `value` 是否未超过阈值（边界算未超过）
    private static func within(_ value: CGFloat, _ threshold: CGFloat) -> Bool {
        value <= threshold + thresholdEpsilon
    }

    static func tips(for report: PoseReport,
                     pose: BodyPose,
                     thresholds: Thresholds = .default) -> [AnalysisFinding] {

        guard report.isDetected else {
            return [AnalysisFinding(key: "pose-none",
                                    kind: .objective,
                                    level: .info,
                                    title: "未检测到人物",
                                    detail: "当前帧没有识别到人体。请让被摄者进入画面，并保证身体轮廓光线充足、避免大面积遮挡。",
                                    confidence: 1.0)]
        }

        // 门控：关键点不可靠时，不给任何确定性角度结论
        if report.confidence < thresholds.minConfidenceForAdvice ||
            report.validJointCount < thresholds.minValidJointsForAdvice {
            let unreliable = pose.unreliableJoints.prefix(6).map(\.displayName).joined(separator: "、")
            return [AnalysisFinding(
                key: "pose-low-confidence",
                kind: .objective,
                level: .attention,
                title: "关键点识别不稳定，暂不给角度结论",
                detail: String(format: "综合置信度 %.0f%%，有效关键点 %d/19。识别不到的关节：%@。建议：让被摄者占画面更大比例、避免逆光、减少肢体遮挡，或把人从背景中分离出来。",
                               report.confidence * 100, report.validJointCount, unreliable.formatObject),
                confidence: report.confidence)]
        }

        var findings: [AnalysisFinding] = []

        // MARK: 肩线
        if let tilt = report.shoulderTiltDegrees {
            let absTilt = abs(tilt)
            let lowerSide = tilt > 0 ? "画面左侧" : "画面右侧"
            let higherSide = tilt > 0 ? "画面右侧" : "画面左侧"
            if reaches(absTilt, thresholds.shoulderTiltWarning) {
                findings.append(AnalysisFinding(
                    key: "pose-shoulder-tilt",
                    kind: .objective,
                    level: .warning,
                    title: "肩线明显倾斜",
                    detail: String(format: "实测：%@肩膀比%@低 %.1f°。这已经会让人读出「身体歪了」。建议让被摄者把%@肩膀抬起，或干脆加大侧身角度转成主动的斜线构图。", lowerSide.formatObject, higherSide.formatObject, absTilt),
                    confidence: report.confidence))
            } else if reaches(absTilt, thresholds.shoulderTiltAttention) {
                findings.append(AnalysisFinding(
                    key: "pose-shoulder-tilt",
                    kind: .objective,
                    level: .attention,
                    title: "肩线略有倾斜",
                    detail: String(format: "实测：%@肩膀比%@低 %.1f°。在自然松弛的方向上可以保留，但如果是正装/正式人像，建议把肩线拉平到 1° 以内。", lowerSide.formatObject, higherSide.formatObject, absTilt),
                    confidence: report.confidence))
            } else {
                findings.append(AnalysisFinding(
                    key: "pose-shoulder-tilt",
                    kind: .objective,
                    level: .good,
                    title: "肩线基本水平",
                    detail: String(format: "实测倾斜仅 %.1f°，站姿稳定。", absTilt),
                    confidence: report.confidence))
            }
        }

        // MARK: 躯干倾斜
        if let lean = report.torsoLeanDegrees {
            let absLean = abs(lean)
            if reaches(absLean, thresholds.torsoLeanAttention) {
                let side = lean > 0 ? "画面右侧" : "画面左侧"
                findings.append(AnalysisFinding(
                    key: "pose-torso-lean",
                    kind: .objective,
                    level: .attention,
                    title: "躯干向一侧偏",
                    detail: String(format: "实测：肩部相对髋部偏向%@ %.1f°。若想保持端正，让被摄者把胸口回正约 %.0f°；若想制造主动的倾斜造型，可以再加强到 8-10° 让意图更明确。", side.formatObject, absLean, absLean),
                    confidence: report.confidence))
            }
        }

        // MARK: 头部转向（估算）
        if let yaw = report.headTurnDegrees, reaches(abs(yaw), thresholds.headTurnNotice) {
            let side = yaw > 0 ? "画面右侧" : "画面左侧"
            findings.append(AnalysisFinding(
                key: "pose-head-yaw",
                kind: .objective,
                level: .info,
                title: "头部已转向一侧",
                detail: String(format: "估算：头部向%@转动约 %.0f°。三点提醒：① 转向超过 30° 时会看不到远侧眼睛，脸会显窄，适合清冷/电影感；② 转向时脖子容易跟着前伸，让对方「把头顶往后拉一点」；③ 如需眼神交流，把下巴回正约 %.0f° 即可。", side.formatObject, abs(yaw), abs(yaw) / 2),
                confidence: report.confidence * 0.8))
        }

        // MARK: 头部歪斜
        if let roll = report.headTiltDegrees, reaches(abs(roll), thresholds.headTiltNotice) {
            let side = roll > 0 ? "画面右侧" : "画面左侧"
            findings.append(AnalysisFinding(
                key: "pose-head-roll",
                kind: .objective,
                level: .info,
                title: "头部有歪斜",
                detail: String(format: "实测：%@的眼睛更高，头部歪斜约 %.1f°。5-10° 的歪头是自然松弛感的常用手段；超过 15° 会显得刻意，可通过让对侧肩膀下沉来抵消。", side.formatObject, abs(roll)),
                confidence: report.confidence))
        }

        // MARK: 肘关节
        let elbowFindings = elbowAdvice(report: report, thresholds: thresholds)
        findings.append(contentsOf: elbowFindings)

        // MARK: 手部高度
        let wristFindings = wristAdvice(report: report)
        findings.append(contentsOf: wristFindings)

        // MARK: 人物位置
        if let offset = report.personCenterOffset {
            let absOffset = abs(offset)
            if reaches(absOffset, thresholds.centerOffsetBig) {
                let side = offset > 0 ? "画面右侧" : "画面左侧"
                findings.append(AnalysisFinding(
                    key: "pose-center-offset",
                    kind: .objective,
                    level: .attention,
                    title: "人物明显偏离画面中心",
                    detail: String(format: "实测：整个人位于中线%@ %.0f%% 画面宽度处。如果这不是刻意的偏心构图，建议把镜头平移 %.0f%% 画面宽度让人物靠近三分线，留白会更舒服。", side.formatObject, absOffset * 100, absOffset * 100),
                    confidence: report.confidence))
            } else if reaches(absOffset, thresholds.centerOffsetNotice) {
                let side = offset > 0 ? "画面右侧" : "画面左侧"
                findings.append(AnalysisFinding(
                    key: "pose-center-offset",
                    kind: .objective,
                    level: .info,
                    title: "人物略微偏心",
                    detail: String(format: "实测：人物中心偏向%@ %.0f%% 画面宽度。偏移小于 20%% 属于可用范围，配合视线方向留白即可。", side.formatObject, absOffset * 100),
                    confidence: report.confidence))
            }
        }

        // MARK: 边缘截断
        if report.reachingFrameEdge {
            let sides = pose.truncatedSides()
            findings.append(AnalysisFinding(
                key: "pose-frame-edge",
                kind: .objective,
                level: .warning,
                title: "人物已触及画面边缘",
                detail: "实测：" + sides.joined(separator: "、") + "已经贴到画面边缘，存在被裁切的风险。请后退一步或调整镜头朝向；如果是刻意裁切，请确认切在关节之间而不是关节上。",
                confidence: report.confidence))
        }

        // MARK: 整体构图的景别提示
        if let center = pose.midpoint(.leftShoulder, .rightShoulder),
           let hip = pose.midpoint(.leftHip, .rightHip) {
            let torso = PoseGeometry.distance(center, hip)
            if torso > 0.0001 {
                let note = torso < 0.12
                    ? "躯干在画面中偏小，若要做半身构图可以再靠近一些"
                    : "躯干在画面中占比合适，支持半身到全身构图"
                findings.append(AnalysisFinding(
                    key: "pose-torso-scale",
                    kind: .heuristic,
                    level: .info,
                    title: "画面比例",
                    detail: String(format: "实测：肩到髋的距离占画面高度 %.0f%%。%@。", torso * 100, note.formatObject),
                    confidence: report.confidence))
            }
        }

        return findings
    }

    // MARK: - 子项

    private static func elbowAdvice(report: PoseReport, thresholds: Thresholds) -> [AnalysisFinding] {
        var result: [AnalysisFinding] = []
        let pairs: [(String, CGFloat?)] = [("左臂", report.leftElbowAngle), ("右臂", report.rightElbowAngle)]
        for (label, angle) in pairs {
            guard let angle else { continue }
            if reaches(angle, thresholds.elbowTooStraight) {
                result.append(AnalysisFinding(
                    key: "pose-elbow-straight-\(label)",
                    kind: .heuristic,
                    level: .attention,
                    title: "\(label)几乎完全伸直",
                    detail: String(format: "实测肘部角度 %.0f°（越接近 180° 越直）。完全伸直的手臂在画面上会显得僵硬，建议屈 20-30°，也就是让手掌朝镜头方向轻轻内收。", angle),
                    confidence: report.confidence))
            } else if within(angle, thresholds.elbowTooClosed) {
                result.append(AnalysisFinding(
                    key: "pose-elbow-closed-\(label)",
                    kind: .heuristic,
                    level: .attention,
                    title: "\(label)弯曲过紧",
                    detail: String(format: "实测肘部角度 %.0f°。夹得太紧会让轮廓缩成一团，建议把手肘向外打开一些，让手臂与躯干之间留出三角形空隙。", angle),
                    confidence: report.confidence))
            } else if reaches(angle, 100) && within(angle, 150) {
                result.append(AnalysisFinding(
                    key: "pose-elbow-good-\(label)",
                    kind: .objective,
                    level: .good,
                    title: "\(label)弯曲自然",
                    detail: String(format: "实测肘部角度 %.0f°，属于人像中最好用的屈曲区间（100-150°）。", angle),
                    confidence: report.confidence))
            }
        }
        return result
    }

    private static func wristAdvice(report: PoseReport) -> [AnalysisFinding] {
        var result: [AnalysisFinding] = []
        let zones = [report.leftWristZone, report.rightWristZone].compactMap { $0 }
        guard !zones.isEmpty else { return result }

        let lowZones = ["低于髋部", "在髋部高度"]
        let lowCount = zones.filter { lowZones.contains($0) }.count

        if lowCount == zones.count && zones.count >= 2 {
            result.append(AnalysisFinding(
                key: "pose-wrist-low",
                kind: .heuristic,
                level: .info,
                title: "双手位置都偏低",
                detail: "实测：左右手腕都落在髋部或更低。半身与特写构图时，双手都在下方会让画面上半部分空且无力。建议把一只手抬到腰线以上（例如放在腰侧、领口或轻触面颊），形成高低错落。",
                confidence: report.confidence))
        } else if lowCount == 0 && zones.count >= 2 {
            result.append(AnalysisFinding(
                key: "pose-wrist-high",
                kind: .objective,
                level: .good,
                title: "手部高度有层次",
                detail: "实测：左右手腕处于不同高度带，避免了双手平行的呆板感。",
                confidence: report.confidence))
        }
        return result
    }
}
