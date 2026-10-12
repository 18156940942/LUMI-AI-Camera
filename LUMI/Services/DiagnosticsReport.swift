import Foundation

/// 诊断报告的纯文本拼装。
///
/// 刻意做成无副作用、无 IO 的纯函数：生成时间与时区都由调用方传入，
/// 因此输出可以**逐字符断言**。项目里这类「能断言就别靠肉眼」的原则一律照办。
enum DiagnosticsReport {

    struct Section: Equatable {
        var title: String = ""
        var lines: [String] = []
    }

    static let header = "LUMI AI Camera · 诊断报告"
    static let divider = String(repeating: "─", count: 46)

    /// 单条日志：`16:53:20 [错误] 视频输入 · 启动失败 [V-001] …`
    static func entryLine(_ entry: DiagnosticsLog.Entry, timeZone: TimeZone) -> String {
        let time = DiagnosticsLog.timestampString(entry.date, timeZone: timeZone)
        return "\(time) [\(entry.level.label)] \(entry.category.label) · \(entry.message)"
    }

    /// 日志段。空日志会得到「（无）」而不是留白 —— 否则报告上看不出是没日志还是渲染出错。
    static func logSection(_ entries: [DiagnosticsLog.Entry],
                           timeZone: TimeZone,
                           title: String = "日志") -> Section {
        Section(title: title, lines: entries.map { entryLine($0, timeZone: timeZone) })
    }

    static func render(title: String = DiagnosticsReport.header,
                       generatedAt: Date,
                       timeZone: TimeZone,
                       sections: [Section],
                       footer: String? = nil) -> String {
        var out: [String] = []
        out.append(title)
        out.append("生成时间："
                   + DiagnosticsLog.fullTimestampString(generatedAt, timeZone: timeZone)
                   + "（\(timeZone.identifier)）")
        out.append(divider)

        for section in sections {
            out.append("")
            out.append("【\(section.title)】")
            if section.lines.isEmpty {
                out.append("（无）")
            } else {
                out.append(contentsOf: section.lines)
            }
        }

        if let footer, !footer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out.append("")
            out.append(divider)
            out.append(footer)
        }

        return out.joined(separator: "\n")
    }

    /// 把「标签 / 值」行渲染成报告行。与 UI 用同一份数据源，避免两处文案走样。
    static func lines(from rows: [(label: String, value: String)]) -> [String] {
        rows.map { "\($0.label)：\($0.value)" }
    }
}
