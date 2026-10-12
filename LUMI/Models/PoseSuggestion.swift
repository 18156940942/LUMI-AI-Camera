import Foundation

// MARK: - 构图建议（姿势自带）

/// 每条姿势自带的构图参数，既是给摄影师的文字建议，也是构图分析的对照基准。
struct PoseComposition: Codable, Hashable {
    /// 建议的人物在画面中的水平位置（0 = 左边缘，0.5 = 居中，1 = 右边缘）
    var horizontalAnchor: Double
    /// 建议的人物在画面中的垂直位置（0 = 顶边，1 = 底边，指头部位置）
    var headAnchor: Double
    /// 建议头顶留白占画面高度的比例
    var headroomRatio: Double
    /// 视线方向是否需要留出空间
    var needsLeadRoom: Bool
    var note: String

    var horizontalAnchorText: String {
        if horizontalAnchor < 0.42 { return "人物重心放在画面左三分之一线附近" }
        if horizontalAnchor > 0.58 { return "人物重心放在画面右三分之一线附近" }
        return "人物居中，左右对称留白"
    }

    var headroomText: String {
        "头顶留白约占画面高度的 \(Int((headroomRatio * 100).rounded()))%"
    }
}

// MARK: - 一条完整姿势

/// 姿势库的基本单元。
///
/// 设计说明：这里**不直接存大段文案**，而是存结构化的动作参数（旋转角度、手位、重心等），
/// 由 ``PoseScriptWriter`` 统一生成具体指导语句。好处是：
/// 1. 角度数值和文字描述永远一致，不会出现「写 30 度、实际参数 45 度」的矛盾；
/// 2. 同一条姿势可以按不同景别/风格微调输出；
/// 3. 结构可被单元测试直接断言。
struct PoseSuggestion: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let summary: String
    let scenes: [PoseScene]
    let styles: [PoseStyle]
    let shotType: ShotType

    let bodyRotation: PoseRotation
    let headTurn: PoseRotation
    let chin: ChinCue
    let gaze: PoseGaze
    let shoulders: ShoulderCue
    let nearestHand: HandPlacement
    let otherHand: HandPlacement?
    let weight: WeightCue
    let legs: LegCue

    /// 与现场环境的互动方式（「如何利用现场环境」）
    let environment: String
    let cameraAngle: CameraAngle
    let composition: PoseComposition
    /// 摄影师执行提示
    let photographerTips: String
    /// 1 = 新手可直接执行，3 = 需要模特配合度较高
    let difficulty: Int
    let keywords: [String]
}

// MARK: - 生成后的指导语句

enum PoseStepCategory: String, Codable, CaseIterable, Hashable {
    case body
    case head
    case eyes
    case shoulders
    case hands
    case weight
    case legs
    case environment
    case camera
    case composition
    case tips

    var title: String {
        switch self {
        case .body: return "身体朝向"
        case .head: return "头部与下巴"
        case .eyes: return "视线落点"
        case .shoulders: return "肩颈"
        case .hands: return "手臂与双手"
        case .weight: return "重心"
        case .legs: return "双腿"
        case .environment: return "环境互动"
        case .camera: return "摄影师机位"
        case .composition: return "建议构图"
        case .tips: return "执行提示"
        }
    }

    var symbolName: String {
        switch self {
        case .body: return "arrow.trianglehead.turn.up.right.circle"
        case .head: return "person.crop.circle"
        case .eyes: return "eye"
        case .shoulders: return "figure.walk.motion"
        case .hands: return "hand.raised"
        case .weight: return "scalemass"
        case .legs: return "figure.stand"
        case .environment: return "tree"
        case .camera: return "camera"
        case .composition: return "rectangle.inset.filled"
        case .tips: return "lightbulb"
        }
    }
}

/// 一条可执行的具体指令。
struct PoseStep: Identifiable, Hashable {
    let id: String
    let category: PoseStepCategory
    let text: String
}

// MARK: - 推荐结果

/// 推荐结果：分成「硬匹配的理由」和「风格倾向的理由」，便于 UI 说明为什么推荐它。
struct PoseRecommendation: Identifiable, Hashable {
    var id: String { pose.id }
    let pose: PoseSuggestion
    let score: Int
    let reasons: [String]
}
