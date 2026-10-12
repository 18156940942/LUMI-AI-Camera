import Foundation

/// 把结构化的姿势参数翻译成「模特听得懂、摄影师能执行」的具体语句。
///
/// 这是姿势助手真正可用性的关键：输出必须具体到方向、角度、位置和落脚点，
/// 而不是「放松一点」「自然一些」这类没有可执行性的形容词。
enum PoseScriptWriter {

    /// 输出完整的分步指令列表。
    static func steps(for pose: PoseSuggestion) -> [PoseStep] {
        var steps: [PoseStep] = []

        steps.append(PoseStep(
            id: "\(pose.id)-body",
            category: .body,
            text: bodyText(pose)
        ))

        steps.append(PoseStep(
            id: "\(pose.id)-head",
            category: .head,
            text: headText(pose)
        ))

        steps.append(PoseStep(
            id: "\(pose.id)-eyes",
            category: .eyes,
            text: pose.gaze.text
        ))

        steps.append(PoseStep(
            id: "\(pose.id)-shoulders",
            category: .shoulders,
            text: pose.shoulders.text
        ))

        steps.append(PoseStep(
            id: "\(pose.id)-hands",
            category: .hands,
            text: handsText(pose)
        ))

        steps.append(PoseStep(
            id: "\(pose.id)-weight",
            category: .weight,
            text: pose.weight.text
        ))

        steps.append(PoseStep(
            id: "\(pose.id)-legs",
            category: .legs,
            text: pose.legs.text
        ))

        if !pose.environment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            steps.append(PoseStep(
                id: "\(pose.id)-environment",
                category: .environment,
                text: pose.environment
            ))
        }

        steps.append(PoseStep(
            id: "\(pose.id)-camera",
            category: .camera,
            text: pose.cameraAngle.text
        ))

        steps.append(PoseStep(
            id: "\(pose.id)-composition",
            category: .composition,
            text: compositionText(pose)
        ))

        if !pose.photographerTips.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            steps.append(PoseStep(
                id: "\(pose.id)-tips",
                category: .tips,
                text: pose.photographerTips
            ))
        }

        return steps
    }

    // MARK: - 单项文案

    static func bodyText(_ pose: PoseSuggestion) -> String {
        if pose.bodyRotation.isFacing {
            return "身体正对镜头，胸口与镜头大致平行；先让模特深呼吸一次，把气吐完再进入拍摄，肩线自然就会落下来"
        }
        return "身体\(pose.bodyRotation.descriptiveText)；转动时先转胯、再带肩膀，双脚尽量保持不动，避免整个身体跟着平移"
    }

    static func headText(_ pose: PoseSuggestion) -> String {
        var parts: [String] = []
        if pose.headTurn.isFacing {
            parts.append("头部正对镜头")
        } else {
            parts.append("头部\(pose.headTurn.descriptiveText)")
        }
        parts.append(pose.chin.text)
        return parts.joined(separator: "；")
    }

    static func handsText(_ pose: PoseSuggestion) -> String {
        if let other = pose.otherHand, other != pose.nearestHand {
            return "① \(pose.nearestHand.text)；② \(other.text)"
        }
        return pose.nearestHand.text
    }

    static func compositionText(_ pose: PoseSuggestion) -> String {
        var parts: [String] = []
        parts.append(pose.composition.horizontalAnchorText)
        parts.append(pose.composition.headroomText)
        if pose.composition.needsLeadRoom {
            parts.append("视线方向留出比背后更多的空间，避免人物像贴在墙上")
        }
        if !pose.composition.note.isEmpty {
            parts.append(pose.composition.note)
        }
        return parts.joined(separator: "；")
    }

    /// 适合在卡片上直接显示的短句（用于列表页，避免信息过载）。
    static func shortDigest(_ pose: PoseSuggestion) -> String {
        var parts: [String] = []
        parts.append(pose.shotType.title)
        if !pose.bodyRotation.isFacing {
            parts.append("身体\(pose.bodyRotation.descriptiveText)")
        }
        parts.append(pose.gaze.anchor.title)
        return parts.joined(separator: " · ")
    }
}
