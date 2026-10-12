import SwiftUI

/// LUMI 卡片容器：统一深色层级、圆角与描边
struct LumiCard<Content: View>: View {
    var padding: CGFloat = LumiTheme.cardPadding
    var highlighted: Bool = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: LumiTheme.cornerRadius, style: .continuous)
                    .fill(highlighted ? LumiTheme.surfaceElevated : LumiTheme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: LumiTheme.cornerRadius, style: .continuous)
                    .stroke(highlighted ? LumiTheme.accent.opacity(0.45) : LumiTheme.stroke, lineWidth: 1)
            )
    }
}

/// 分区标题（带可选计数）
struct SectionHeader: View {
    let title: String
    var subtitle: String?
    var trailingText: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(LumiTheme.sectionTitle)
                    .foregroundStyle(LumiTheme.primaryText)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(LumiTheme.tertiaryText)
                }
            }
            Spacer(minLength: 8)
            if let trailingText {
                Text(trailingText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(LumiTheme.secondaryText)
            }
        }
        .textCase(.uppercase)
    }
}

/// 状态胶囊（连接状态、硬件状态等）
struct StatusPill: View {
    let text: String
    let color: Color
    var symbol: String?

    var body: some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .bold))
            }
            Text(text)
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.13))
        .clipShape(Capsule())
    }
}

/// 指标块（分辨率、帧率、延迟等真实数值）
struct MetricTile: View {
    let label: String
    let value: String
    var caption: String?
    var accent: Color = LumiTheme.primaryText

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(LumiTheme.monitorLabel)
                .foregroundStyle(LumiTheme.tertiaryText)
            Text(value)
                .font(LumiTheme.monitorNumber)
                .foregroundStyle(accent)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let caption {
                Text(caption)
                    .font(.system(size: 10))
                    .foregroundStyle(LumiTheme.tertiaryText)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 键值行
struct InfoRow: View {
    let label: String
    let value: String
    var valueColor: Color = LumiTheme.primaryText

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(LumiTheme.secondaryText)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(valueColor)
                .multilineTextAlignment(.trailing)
        }
    }
}

/// 分析结论行：区分「实测」与「建议」，并显示置信度
struct FindingRow: View {
    let finding: AnalysisFinding
    var showsConfidence: Bool = true

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: LumiTheme.levelSymbol(finding.level))
                .font(.system(size: 13))
                .foregroundStyle(LumiTheme.levelColor(finding.level))
                .frame(width: 18)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(finding.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(LumiTheme.primaryText)
                    Text(finding.kind.badge)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(finding.kind == .objective ? LumiTheme.accent : LumiTheme.warning)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background((finding.kind == .objective ? LumiTheme.accent : LumiTheme.warning).opacity(0.14))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    if showsConfidence, finding.confidence < 0.5 {
                        Text("置信度 \(Int(finding.confidence * 100))%")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(LumiTheme.danger)
                    }
                }
                Text(finding.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(LumiTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// 置信度横幅：低置信度时必须出现，避免用户把不可靠结果当成结论
struct ConfidenceBanner: View {
    let level: ConfidenceLevel
    var validJointCount: Int?
    var totalJointCount: Int = 19

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: level == .low ? "exclamationmark.triangle.fill" : "checkmark.seal")
                .font(.system(size: 12))
            VStack(alignment: .leading, spacing: 2) {
                Text(level.title + (validJointCount.map { "　有效关键点 \($0)/\(totalJointCount)" } ?? ""))
                    .font(.system(size: 12, weight: .semibold))
                Text(level.caveat)
                    .font(.system(size: 11))
            }
        }
        .foregroundStyle(LumiTheme.confidenceColor(level))
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LumiTheme.confidenceColor(level).opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: LumiTheme.smallCornerRadius, style: .continuous))
    }
}

/// 硬件/能力要求卡：把「为什么不可用」和「替代方案」说清楚
struct HardwareRequirementCard: View {
    let title: String
    let requirement: String
    let reason: String
    var alternatives: [String] = []
    var icon: String = "cable.connector.slash"
    var tint: Color = LumiTheme.warning

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(LumiTheme.primaryText)
            }
            Text(requirement)
                .font(.system(size: 12))
                .foregroundStyle(LumiTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Text(reason)
                .font(.system(size: 12))
                .foregroundStyle(LumiTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if !alternatives.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("可验证的替代方案")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(LumiTheme.primaryText)
                    ForEach(Array(alternatives.enumerated()), id: \.offset) { index, item in
                        HStack(alignment: .top, spacing: 6) {
                            Text("\(index + 1).")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(LumiTheme.accent)
                            Text(item)
                                .font(.system(size: 11))
                                .foregroundStyle(LumiTheme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.09))
        .overlay(
            RoundedRectangle(cornerRadius: LumiTheme.cornerRadius, style: .continuous)
                .stroke(tint.opacity(0.35), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: LumiTheme.cornerRadius, style: .continuous))
    }
}

/// 空状态 / 引导视图
struct EmptyStateCard: View {
    let symbol: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(LumiTheme.tertiaryText)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(LumiTheme.primaryText)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(LumiTheme.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(LumiTheme.onAccentText)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .background(LumiTheme.accent)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}

/// 可多选的标签组（场景 / 风格选择）
struct SelectableChip: View {
    let title: String
    let symbol: String?
    let isSelected: Bool
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? LumiTheme.onAccentText : LumiTheme.secondaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(isSelected ? tint : LumiTheme.surfaceElevated)
            .overlay(
                RoundedRectangle(cornerRadius: LumiTheme.smallCornerRadius, style: .continuous)
                    .stroke(isSelected ? Color.clear : LumiTheme.stroke, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: LumiTheme.smallCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// 主按钮
struct PrimaryButton: View {
    let title: String
    var symbol: String?
    var tint: Color = LumiTheme.accent
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(isEnabled ? LumiTheme.onAccentText : LumiTheme.tertiaryText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(isEnabled ? tint : LumiTheme.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: LumiTheme.smallCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

/// 次级按钮
struct SecondaryButton: View {
    let title: String
    var symbol: String?
    var tint: Color = LumiTheme.secondaryText
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 14, weight: .medium))
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(LumiTheme.surfaceElevated)
            .overlay(
                RoundedRectangle(cornerRadius: LumiTheme.smallCornerRadius, style: .continuous)
                    .stroke(LumiTheme.stroke, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: LumiTheme.smallCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// 「未实现 / 受限」标记，用于如实告知用户当前功能状态
struct LimitationBadge: View {
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "info.circle")
                .font(.system(size: 10))
            Text(text)
                .font(.system(size: 10, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(LumiTheme.tertiaryText)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(LumiTheme.surfaceSunken)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
