import Foundation
import CoreGraphics

// MARK: - 分析结论的「性质」标注

/// 结论的性质。UI 上必须区分，避免把规则建议包装成「AI 检测结果」。
enum FindingKind: String, Codable, Hashable {
    /// 客观检测：由关键点/像素直接算出的可测事实（如「头顶留白 3%」）
    case objective
    /// 规则建议：基于阈值与摄影经验给出的判断（如「建议加大留白」）
    case heuristic

    var badge: String {
        switch self {
        case .objective: return "实测"
        case .heuristic: return "建议"
        }
    }
}

enum FindingLevel: String, Codable, Hashable {
    case good
    case info
    case attention
    case warning

    var title: String {
        switch self {
        case .good: return "达标"
        case .info: return "提示"
        case .attention: return "注意"
        case .warning: return "需要调整"
        }
    }
}

/// 单条分析结论
struct AnalysisFinding: Identifiable, Hashable {
    let id: String
    let kind: FindingKind
    let level: FindingLevel
    let title: String
    let detail: String
    /// 该结论的置信度（0...1）。关键点不可靠时这里会很低，UI 需要据此降级显示。
    var confidence: Float

    init(key: String,
         kind: FindingKind,
         level: FindingLevel,
         title: String,
         detail: String,
         confidence: Float = 1.0) {
        self.id = key
        self.kind = kind
        self.level = level
        self.title = title
        self.detail = detail
        self.confidence = confidence
    }
}

// MARK: - 置信度分档

enum ConfidenceLevel: String, Hashable {
    case low
    case medium
    case high

    static func from(_ confidence: Float) -> ConfidenceLevel {
        if confidence >= 0.7 { return .high }
        if confidence >= 0.35 { return .medium }
        return .low
    }

    var title: String {
        switch self {
        case .low: return "置信度低"
        case .medium: return "置信度中"
        case .high: return "置信度高"
        }
    }

    /// 低置信度时必须显示的免责说明
    var caveat: String {
        switch self {
        case .low: return "关键点识别不稳定，以下结论仅供参考，请以你的判断为准"
        case .medium: return "关键点识别基本可用，个别角度可能有偏差"
        case .high: return "关键点识别稳定，结论可直接参考"
        }
    }
}

// MARK: - 构图分析报告

/// 一次构图分析的完整结果（实时帧与静态照片共用同一结构）。
struct CompositionReport: Equatable {

    /// 分析时刻的画面尺寸（像素）
    var frameSize: CGSize = .zero
    /// 是否检测到人物
    var isSubjectPresent: Bool = false
    /// 人物躯干/全身的归一化包围框（原点在左下，Vision 坐标系）
    var subjectBoundingBox: CGRect? = nil
    /// 人物高度占画面高度的比例（0...1）
    var subjectHeightRatio: CGFloat? = nil
    /// 人物中心的水平位置（0...1，0 = 左边缘）
    var horizontalCenter: CGFloat? = nil
    /// 头顶留白比例（0...1）
    var headroom: CGFloat? = nil
    /// 人物身体被画面边缘截断的位置
    var truncatedJoints: [String] = []
    /// 与三分法交点/线的偏离度（归一化距离，0 = 完全落在线上）
    var ruleOfThirdsDeviation: CGFloat? = nil
    /// 建议的景别
    var suggestedShotType: ShotType? = nil
    /// 人物与背景的分离度评估（基于人物区域外的边缘密度）
    var backgroundClutterScore: CGFloat? = nil
    var findings: [AnalysisFinding] = []
    /// 整体置信度
    var confidence: Float = 0
    /// 每个建议景别的判定依据（用于 UI 说明）
    var shotTypeReasons: [String] = []
    /// 检测来源说明，例如「Vision 人体关键点（7 个有效关键点）」
    var detectionSource: String = "尚未分析"

    static let empty = CompositionReport(frameSize: .zero,
                                        isSubjectPresent: false,
                                        findings: [],
                                        confidence: 0,
                                        detectionSource: "尚未分析")

    /// 低置信度时不应该展示确定性结论
    var reliability: ConfidenceLevel { ConfidenceLevel.from(confidence) }

    var objectiveFindings: [AnalysisFinding] { findings.filter { $0.kind == .objective } }
    var heuristicFindings: [AnalysisFinding] { findings.filter { $0.kind == .heuristic } }
}

// MARK: - 姿势分析报告

/// 一次人体姿态分析的结果。
struct PoseReport: Equatable {
    var isDetected: Bool = false
    var confidence: Float = 0
    /// 检测到的有效关键点数量（Vision 共 19 个点）
    var validJointCount: Int = 0
    var shoulderTiltDegrees: CGFloat? = nil
    var hipTiltDegrees: CGFloat? = nil
    var torsoLeanDegrees: CGFloat? = nil
    var headTurnDegrees: CGFloat? = nil
    var headTiltDegrees: CGFloat? = nil
    var leftElbowAngle: CGFloat? = nil
    var rightElbowAngle: CGFloat? = nil
    var leftWristZone: String? = nil
    var rightWristZone: String? = nil
    var personCenterOffset: CGFloat? = nil
    var reachingFrameEdge: Bool = false
    var coachTips: [AnalysisFinding] = []
    var boundingBox: CGRect? = nil

    static let empty = PoseReport(isDetected: false,
                                  confidence: 0,
                                  validJointCount: 0,
                                  reachingFrameEdge: false,
                                  coachTips: [],
                                  boundingBox: nil)

    var reliability: ConfidenceLevel { ConfidenceLevel.from(confidence) }
}
