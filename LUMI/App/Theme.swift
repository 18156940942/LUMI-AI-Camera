import SwiftUI

/// LUMI 的视觉系统：深色、专业监视器质感。
///
/// 设计原则（对应需求「适合户外拍摄和摄影棚使用」）：
/// - 底色极暗，避免监看时屏幕发出的杂光影响摄影师判断；
/// - 重要信息（电池/连接/帧率/置信度）用高对比度大字；
/// - 只用一条冷调强调色 + 三个语义色（达标/注意/警告），不堆颜色；
/// - 控件集中在画面边缘，不遮挡人物。
enum LumiTheme {

    // MARK: - 背景层级

    static let background = Color(red: 0.039, green: 0.043, blue: 0.051)
    static let surface = Color(red: 0.078, green: 0.086, blue: 0.098)
    static let surfaceElevated = Color(red: 0.114, green: 0.125, blue: 0.141)
    static let surfaceSunken = Color(red: 0.024, green: 0.027, blue: 0.031)

    // MARK: - 文字

    static let primaryText = Color.white.opacity(0.95)
    static let secondaryText = Color.white.opacity(0.62)
    static let tertiaryText = Color.white.opacity(0.36)
    static let onAccentText = Color(red: 0.031, green: 0.055, blue: 0.078)

    // MARK: - 线条

    static let stroke = Color.white.opacity(0.085)
    static let strokeStrong = Color.white.opacity(0.16)

    // MARK: - 强调与语义色

    static let accent = Color(red: 0.478, green: 0.784, blue: 0.976)
    static let accentSoft = Color(red: 0.478, green: 0.784, blue: 0.976).opacity(0.16)
    static let success = Color(red: 0.345, green: 0.816, blue: 0.549)
    static let warning = Color(red: 0.980, green: 0.722, blue: 0.310)
    static let danger = Color(red: 0.933, green: 0.384, blue: 0.353)

    // MARK: - 关键点置信度配色

    static let jointHigh = Color(red: 0.345, green: 0.898, blue: 0.749)
    static let jointMedium = Color(red: 0.980, green: 0.722, blue: 0.310)
    static let jointLow = Color(red: 0.933, green: 0.384, blue: 0.353)

    static func jointColor(confidence: Float) -> Color {
        if confidence >= 0.6 { return jointHigh }
        if confidence >= 0.3 { return jointMedium }
        return jointLow
    }

    static func levelColor(_ level: FindingLevel) -> Color {
        switch level {
        case .good: return success
        case .info: return accent
        case .attention: return warning
        case .warning: return danger
        }
    }

    static func levelSymbol(_ level: FindingLevel) -> String {
        switch level {
        case .good: return "checkmark.circle.fill"
        case .info: return "info.circle.fill"
        case .attention: return "exclamationmark.triangle.fill"
        case .warning: return "exclamationmark.octagon.fill"
        }
    }

    static func confidenceColor(_ level: ConfidenceLevel) -> Color {
        switch level {
        case .low: return danger
        case .medium: return warning
        case .high: return success
        }
    }

    // MARK: - 尺寸

    static let cornerRadius: CGFloat = 16
    static let smallCornerRadius: CGFloat = 10
    static let cardPadding: CGFloat = 16
    static let screenPadding: CGFloat = 16

    // MARK: - 字体

    static let sectionTitle = Font.system(size: 13, weight: .semibold, design: .rounded)
    static let monitorNumber = Font.system(size: 22, weight: .semibold, design: .monospaced)
    static let monitorLabel = Font.system(size: 11, weight: .medium, design: .rounded)
    static let bodyStrong = Font.system(size: 15, weight: .semibold)
}
