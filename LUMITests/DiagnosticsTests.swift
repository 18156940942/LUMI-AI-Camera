import AVFoundation
import Photos
import UIKit
import XCTest
@testable import LUMI

/// 诊断模块的测试。
///
/// 这里守的是两件在真机排查时会造成误判的事：
/// 1. **环形缓冲的行为**（容量上限、清空后留下痕迹、并发写入不串号）——
///    日志串号或丢掉最新错误，会把排查方向带偏；
/// 2. **一切「取不到值」的场合必须显示「未知」** —— 绝不允许把缺失值渲染成
///    看上去合理的默认值（0、空串、30fps 之类）。这是本项目最基本的一条诚信规则。
final class DiagnosticsTests: XCTestCase {

    private let fixedEpoch: TimeInterval = 1_760_000_000   // 2025-10-09 08:53:20 UTC

    private func timeZone(_ identifier: String) throws -> TimeZone {
        try XCTUnwrap(TimeZone(identifier: identifier), "系统缺少时区数据：\(identifier)")
    }

    // MARK: - 环形缓冲

    func testRingBufferKeepsOnlyLatestEntries() {
        let log = DiagnosticsLog(capacity: 3)
        for index in 1...5 {
            log.info(.app, "第 \(index) 条")
        }
        let snapshot = log.snapshot
        XCTAssertEqual(snapshot.count, 3, "容量必须是不超过 capacity 的硬上限")
        XCTAssertEqual(snapshot.map(\.id), [3, 4, 5], "淘汰的必须是最旧的，保留最新")
        XCTAssertEqual(snapshot.last?.message, "第 5 条")
    }

    func testCapacityIsClampedToAtLeastOne() {
        let log = DiagnosticsLog(capacity: 0)
        XCTAssertEqual(log.capacity, 1)
        log.info(.app, "a")
        log.info(.app, "b")
        XCTAssertEqual(log.snapshot.count, 1)
        XCTAssertEqual(log.snapshot.first?.message, "b")
    }

    func testEntryIDsIncreaseMonotonically() {
        let log = DiagnosticsLog(capacity: 100)
        for index in 0..<10 {
            log.debug(.app, "\(index)")
        }
        let identifiers = log.snapshot.map(\.id)
        XCTAssertEqual(identifiers, identifiers.sorted(), "ID 必须单调递增，否则无法判断先后")
        XCTAssertEqual(Set(identifiers).count, identifiers.count, "ID 不能重复")
    }

    func testClearEmptiesBufferButLeavesBreadcrumb() {
        let log = DiagnosticsLog(capacity: 50)
        log.info(.app, "之前的记录")
        log.error(.videoInput, "之前的错误")
        log.clear()

        let snapshot = log.snapshot
        XCTAssertEqual(snapshot.count, 1, "清空后只应留下一条说明")
        XCTAssertEqual(snapshot.first?.level, .info)
        XCTAssertEqual(snapshot.first?.category, .diagnostics)
        XCTAssertTrue(snapshot.first?.message.contains("清空") == true,
                      "必须留下「被清空」的痕迹，否则报告里分不清「没发生过」和「被清掉了」")
        XCTAssertEqual(log.count(of: .error), 0)
    }

    func testLevelAndCategoryFiltering() {
        let log = DiagnosticsLog(capacity: 50)
        log.debug(.app, "d")
        log.info(.network, "i")
        log.warning(.pose, "w1")
        log.warning(.pose, "w2")
        log.error(.videoInput, "e")

        XCTAssertEqual(log.count(of: .debug), 1)
        XCTAssertEqual(log.count(of: .info), 1)
        XCTAssertEqual(log.count(of: .warning), 2)
        XCTAssertEqual(log.count(of: .error), 1)

        XCTAssertEqual(log.snapshot(minLevel: .debug).count, 5)
        XCTAssertEqual(log.snapshot(minLevel: .warning).count, 3)
        XCTAssertEqual(log.snapshot(minLevel: .error).count, 1)
    }

    func testConcurrentWritesAreSerialized() {
        let log = DiagnosticsLog(capacity: 200)
        let group = DispatchGroup()
        for worker in 0..<8 {
            DispatchQueue.global().async(group: group) {
                for index in 0..<50 {
                    log.info(.app, "worker \(worker) item \(index)")
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 20), .success)

        let snapshot = log.snapshot
        XCTAssertEqual(snapshot.count, 200, "并发写入后容量仍然是硬上限")
        let identifiers = snapshot.map(\.id)
        XCTAssertEqual(Set(identifiers).count, identifiers.count, "并发写入不能产生重复 ID")
        XCTAssertEqual(identifiers, identifiers.sorted(), "并发写入后 ID 仍须单调递增")
    }

    // MARK: - 枚举完备性

    func testLevelSeverityOrderingAndLabels() {
        let levels = DiagnosticsLog.Level.allCases
        XCTAssertEqual(levels.count, 4)
        XCTAssertEqual(levels, [.debug, .info, .warning, .error])

        XCTAssertLessThan(DiagnosticsLog.Level.debug.severity, DiagnosticsLog.Level.info.severity)
        XCTAssertLessThan(DiagnosticsLog.Level.info.severity, DiagnosticsLog.Level.warning.severity)
        XCTAssertLessThan(DiagnosticsLog.Level.warning.severity, DiagnosticsLog.Level.error.severity)

        var labels = Set<String>()
        for level in levels {
            XCTAssertFalse(level.label.isEmpty)
            XCTAssertFalse(level.symbolName.isEmpty, "\(level.rawValue) 缺少图标")
            XCTAssertEqual(level.id, level.rawValue)
            labels.insert(level.label)
        }
        XCTAssertEqual(labels.count, 4, "四个级别的文案不能重复，否则界面无法区分")
    }

    func testCategoryLabelsArePresentAndUnique() {
        let categories = DiagnosticsLog.Category.allCases
        XCTAssertEqual(categories.count, 8)
        var labels = Set<String>()
        for category in categories {
            XCTAssertFalse(category.label.isEmpty)
            XCTAssertEqual(category.id, category.rawValue)
            labels.insert(category.label)
        }
        XCTAssertEqual(labels.count, categories.count, "分类文案不能重复")
    }

    // MARK: - 时间格式化（必须与时区解耦）

    func testTimestampIsTimeZoneDeterministic() throws {
        let date = Date(timeIntervalSince1970: fixedEpoch)
        XCTAssertEqual(DiagnosticsLog.timestampString(date, timeZone: try timeZone("Asia/Shanghai")),
                       "16:53:20")
        XCTAssertEqual(DiagnosticsLog.timestampString(date, timeZone: try timeZone("UTC")),
                       "08:53:20")
        XCTAssertEqual(DiagnosticsLog.timestampString(date, timeZone: try timeZone("America/Los_Angeles")),
                       "01:53:20")
    }

    func testFullTimestampIsTimeZoneDeterministic() throws {
        let date = Date(timeIntervalSince1970: fixedEpoch)
        XCTAssertEqual(DiagnosticsLog.fullTimestampString(date, timeZone: try timeZone("Asia/Shanghai")),
                       "2025-10-09 16:53:20")
        XCTAssertEqual(DiagnosticsLog.fullTimestampString(date, timeZone: try timeZone("UTC")),
                       "2025-10-09 08:53:20")
    }

    // MARK: - 数值格式化

    func testFormatBytesBoundaries() {
        XCTAssertEqual(DiagnosticsEnvironment.formatBytes(0), "0 B")
        XCTAssertEqual(DiagnosticsEnvironment.formatBytes(1023), "1023 B")
        XCTAssertEqual(DiagnosticsEnvironment.formatBytes(1024), "1.0 KB")
        XCTAssertEqual(DiagnosticsEnvironment.formatBytes(1536), "1.5 KB")
        XCTAssertEqual(DiagnosticsEnvironment.formatBytes(1024 * 1024), "1.0 MB")
        XCTAssertEqual(DiagnosticsEnvironment.formatBytes(1024 * 1024 * 1024), "1.0 GB")
        XCTAssertEqual(DiagnosticsEnvironment.formatBytes(274_877_906_944), "256.0 GB")
        XCTAssertEqual(DiagnosticsEnvironment.formatBytes(1024 * 1024 * 1024 * 1024), "1.0 TB")
    }

    func testFormatBytesRejectsNegativeInsteadOfShowingGarbage() {
        // 取不到磁盘容量时会出现负数，必须明说「未知」，而不是显示 -1.0 B
        XCTAssertEqual(DiagnosticsEnvironment.formatBytes(-1), "未知")
        XCTAssertEqual(DiagnosticsEnvironment.formatBytes(Int64.min), "未知")
    }

    func testFormatDurationBuckets() {
        XCTAssertEqual(DiagnosticsEnvironment.formatDuration(0), "0 秒")
        XCTAssertEqual(DiagnosticsEnvironment.formatDuration(59), "59 秒")
        XCTAssertEqual(DiagnosticsEnvironment.formatDuration(60), "1 分 0 秒")
        XCTAssertEqual(DiagnosticsEnvironment.formatDuration(125), "2 分 5 秒")
        XCTAssertEqual(DiagnosticsEnvironment.formatDuration(3600), "1 小时 0 分 0 秒")
        XCTAssertEqual(DiagnosticsEnvironment.formatDuration(3661), "1 小时 1 分 1 秒")
    }

    func testFormatDurationRejectsNonFiniteValues() {
        XCTAssertEqual(DiagnosticsEnvironment.formatDuration(-1), "未知")
        XCTAssertEqual(DiagnosticsEnvironment.formatDuration(.infinity), "未知")
        XCTAssertEqual(DiagnosticsEnvironment.formatDuration(.nan), "未知")
    }

    // MARK: - 环境装配

    func testAssembleNormalizesBlankValuesToUnknown() throws {
        var inputs = DiagnosticsEnvironment.Inputs()
        inputs.appVersion = nil
        inputs.buildNumber = "   "           // 全空格也算「没给」
        inputs.bundleIdentifier = ""
        inputs.systemName = "iOS"
        inputs.systemVersion = "18.5"
        inputs.idiom = .phone
        inputs.machine = "iPhone17,1"
        inputs.localeIdentifier = "zh_CN"
        inputs.timeZoneIdentifier = "Asia/Shanghai"
        inputs.screenDescription = "393×852 pt @3x"
        inputs.freeDiskBytes = 1024 * 1024 * 1024
        inputs.totalDiskBytes = 274_877_906_944
        inputs.thermalState = .fair
        inputs.lowPowerMode = false
        inputs.supportsExternalCamera = false
        inputs.cpuCoreCount = 6
        inputs.physicalMemoryBytes = 8 * 1024 * 1024 * 1024
        inputs.processUptime = 3661

        let environment = DiagnosticsEnvironment.assemble(inputs)

        XCTAssertEqual(environment.appVersion, "未知", "nil 必须显示未知")
        XCTAssertEqual(environment.buildNumber, "未知", "全空白必须显示未知，而不是一片空白")
        XCTAssertEqual(environment.bundleIdentifier, "未知", "空串必须显示未知")

        XCTAssertEqual(environment.systemName, "iOS")
        XCTAssertEqual(environment.systemVersion, "18.5")
        XCTAssertEqual(environment.deviceIdiom, "iPhone")
        XCTAssertEqual(environment.deviceMachine, "iPhone17,1")
        XCTAssertEqual(environment.screenDescription, "393×852 pt @3x")
        XCTAssertEqual(environment.freeDiskText, "1.0 GB")
        XCTAssertEqual(environment.totalDiskText, "256.0 GB")
        XCTAssertEqual(environment.thermalStateText, "偏高")
        XCTAssertEqual(environment.lowPowerModeText, "关闭")
        XCTAssertEqual(environment.externalCameraText, "不支持（iPhone）")
        XCTAssertEqual(environment.cpuCoreCount, 6)
        XCTAssertEqual(environment.physicalMemoryText, "8.0 GB")
        XCTAssertEqual(environment.processUptimeText, "1 小时 1 分 1 秒")
    }

    func testAssembleWithoutDiskNumbersShowsUnknown() {
        var inputs = DiagnosticsEnvironment.Inputs()
        inputs.freeDiskBytes = nil
        inputs.totalDiskBytes = nil
        inputs.physicalMemoryBytes = 0
        let environment = DiagnosticsEnvironment.assemble(inputs)
        XCTAssertEqual(environment.freeDiskText, "未知")
        XCTAssertEqual(environment.totalDiskText, "未知")
        XCTAssertEqual(environment.physicalMemoryText, "未知")
    }

    func testLowPowerModeIsCalledOutBecauseItLimitsPerformance() {
        var inputs = DiagnosticsEnvironment.Inputs()
        inputs.lowPowerMode = true
        inputs.supportsExternalCamera = true
        let environment = DiagnosticsEnvironment.assemble(inputs)
        XCTAssertTrue(environment.lowPowerModeText.contains("已开启"))
        XCTAssertTrue(environment.lowPowerModeText.contains("限制"),
                      "低电量模式会限制性能，必须说清楚，否则会被误判成 App 太慢")
        XCTAssertEqual(environment.externalCameraText, "支持（iPad）")
    }

    func testRowsExposeEveryFieldWithNonEmptyValues() {
        let environment = DiagnosticsEnvironment.assemble(DiagnosticsEnvironment.Inputs())
        // 注意：Swift 的 key path 不能指向元组成员，所以这里必须用闭包而不是 `\.label`。
        let labels = environment.rows.map { $0.label }
        XCTAssertGreaterThanOrEqual(environment.rows.count, 12)
        for row in environment.rows {
            XCTAssertFalse(row.label.isEmpty)
            XCTAssertFalse(row.value.isEmpty, "\(row.label) 的值不能为空，取不到应写「未知」")
        }
        XCTAssertTrue(labels.contains("App 版本"))
        XCTAssertTrue(labels.contains("热状态"))
        XCTAssertTrue(labels.contains("UVC 外接能力"))
    }

    func testThermalStateLabelsAreDistinctAndActionable() {
        let states: [ProcessInfo.ThermalState] = [.nominal, .fair, .serious, .critical]
        let labels = states.map(DiagnosticsEnvironment.thermalStateLabel)
        XCTAssertEqual(labels, ["正常", "偏高", "较高（可能已降频）", "严重（系统正在强制降频）"])
        XCTAssertEqual(Set(labels).count, states.count)
        XCTAssertTrue(labels[2].contains("降频"))
        XCTAssertTrue(labels[3].contains("降频"))
    }

    func testIdiomLabelsCoverIPhoneAndIPad() {
        XCTAssertEqual(DiagnosticsEnvironment.idiomLabel(.phone), "iPhone")
        XCTAssertEqual(DiagnosticsEnvironment.idiomLabel(.pad), "iPad")
        XCTAssertFalse(DiagnosticsEnvironment.idiomLabel(.unspecified).isEmpty)
    }

    // MARK: - 权限

    func testCameraPermissionLabels() {
        let labels = [
            DiagnosticsPermissions.cameraLabel(.authorized),
            DiagnosticsPermissions.cameraLabel(.denied),
            DiagnosticsPermissions.cameraLabel(.restricted),
            DiagnosticsPermissions.cameraLabel(.notDetermined)
        ]
        XCTAssertEqual(labels[0], "已授权")
        XCTAssertEqual(labels[3], "尚未询问（首次使用时会弹窗）")
        XCTAssertEqual(Set(labels).count, labels.count)
        XCTAssertTrue(labels[1].contains("设置"), "被拒绝时必须告诉用户去哪儿开")
        for label in labels {
            XCTAssertFalse(label.isEmpty)
        }
    }

    func testPhotoPermissionLabelsDistinguishLimitedAccess() {
        let labels = [
            DiagnosticsPermissions.photoLabel(.authorized),
            DiagnosticsPermissions.photoLabel(.limited),
            DiagnosticsPermissions.photoLabel(.denied),
            DiagnosticsPermissions.photoLabel(.restricted),
            DiagnosticsPermissions.photoLabel(.notDetermined)
        ]
        XCTAssertEqual(labels[0], "已授权（完整访问）")
        XCTAssertTrue(labels[1].contains("有限"), "有限访问必须与完整访问区分开")
        XCTAssertNotEqual(labels[0], labels[1])
        XCTAssertEqual(Set(labels).count, labels.count)
    }

    func testPermissionsRowsAdmitLocalNetworkCannotBeQueried() {
        let permissions = DiagnosticsPermissions()
        let rows = permissions.rows
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows[3].label, "本地网络")
        XCTAssertTrue(rows[3].value.contains("查询"),
                      "iOS 没有本地网络权限的查询接口，只能如实说明无法查询")
        for row in rows {
            XCTAssertFalse(row.value.isEmpty)
        }
    }

    // MARK: - 分析帧率的滚动窗口

    func testRollingRateNeedsABaseline() {
        XCTAssertEqual(FrameAnalysisPipeline.Diagnostics.rollingRate(
            previousFrames: 0, currentFrames: 30, elapsed: 0.5, hasBaseline: false), 0,
            "还没有基线时必须报 0，不能拿开机时长当分母算出废数")
    }

    func testRollingRateComputesFramesPerSecond() {
        XCTAssertEqual(FrameAnalysisPipeline.Diagnostics.rollingRate(
            previousFrames: 0, currentFrames: 30, elapsed: 0.5, hasBaseline: true),
            60, accuracy: 0.0001)
        XCTAssertEqual(FrameAnalysisPipeline.Diagnostics.rollingRate(
            previousFrames: 100, currentFrames: 104, elapsed: 2.0, hasBaseline: true),
            2, accuracy: 0.0001)
        XCTAssertEqual(FrameAnalysisPipeline.Diagnostics.rollingRate(
            previousFrames: 100, currentFrames: 101, elapsed: 0.5, hasBaseline: true),
            2, accuracy: 0.0001)
    }

    func testRollingRateNeverReturnsNegativeOrInfinite() {
        // 时间没有前进
        XCTAssertEqual(FrameAnalysisPipeline.Diagnostics.rollingRate(
            previousFrames: 0, currentFrames: 10, elapsed: 0, hasBaseline: true), 0)
        // 时间倒退
        XCTAssertEqual(FrameAnalysisPipeline.Diagnostics.rollingRate(
            previousFrames: 0, currentFrames: 10, elapsed: -1, hasBaseline: true), 0)
        // 帧数倒退（reset() 之后会发生）
        XCTAssertEqual(FrameAnalysisPipeline.Diagnostics.rollingRate(
            previousFrames: 500, currentFrames: 3, elapsed: 0.5, hasBaseline: true), 0)
        // 帧数没变
        XCTAssertEqual(FrameAnalysisPipeline.Diagnostics.rollingRate(
            previousFrames: 42, currentFrames: 42, elapsed: 0.5, hasBaseline: true), 0)
    }

    // MARK: - 报告拼装

    func testEntryLineFormat() throws {
        let entry = DiagnosticsLog.Entry(id: 7,
                                         date: Date(timeIntervalSince1970: fixedEpoch),
                                         level: .error,
                                         category: .videoInput,
                                         message: "启动失败 [V-001]")
        XCTAssertEqual(DiagnosticsReport.entryLine(entry, timeZone: try timeZone("Asia/Shanghai")),
                       "16:53:20 [错误] 视频输入 · 启动失败 [V-001]")
    }

    func testReportRenderContainsHeaderSectionsAndFooter() throws {
        let text = DiagnosticsReport.render(
            generatedAt: Date(timeIntervalSince1970: fixedEpoch),
            timeZone: try timeZone("Asia/Shanghai"),
            sections: [
                DiagnosticsReport.Section(title: "运行环境", lines: ["App 版本：1.0.0（1）"]),
                DiagnosticsReport.Section(title: "日志", lines: ["16:53:20 [信息] 应用 · 就绪"])
            ],
            footer: "本报告未上传到任何服务器。")

        XCTAssertTrue(text.hasPrefix(DiagnosticsReport.header))
        XCTAssertTrue(text.contains("生成时间：2025-10-09 16:53:20（Asia/Shanghai）"))
        XCTAssertTrue(text.contains("【运行环境】"))
        XCTAssertTrue(text.contains("App 版本：1.0.0（1）"))
        XCTAssertTrue(text.contains("【日志】"))
        XCTAssertTrue(text.contains("16:53:20 [信息] 应用 · 就绪"))
        XCTAssertTrue(text.hasSuffix("本报告未上传到任何服务器。"))
        XCTAssertTrue(text.contains(DiagnosticsReport.divider))
    }

    func testReportRendersPlaceholderForEmptySection() throws {
        let text = DiagnosticsReport.render(
            generatedAt: Date(timeIntervalSince1970: fixedEpoch),
            timeZone: try timeZone("Asia/Shanghai"),
            sections: [DiagnosticsReport.Section(title: "日志", lines: [])],
            footer: nil)
        XCTAssertTrue(text.contains("【日志】\n（无）"),
                      "空日志必须显式写出「无」，否则看不出是没有日志还是渲染出错")
        XCTAssertFalse(text.contains(DiagnosticsReport.divider + "\n" + DiagnosticsReport.divider))
    }

    func testReportOmitsFooterWhenItIsBlank() throws {
        let text = DiagnosticsReport.render(
            generatedAt: Date(timeIntervalSince1970: fixedEpoch),
            timeZone: try timeZone("Asia/Shanghai"),
            sections: [DiagnosticsReport.Section(title: "A", lines: ["a"])],
            footer: "   \n  ")
        XCTAssertTrue(text.hasSuffix("a"), "空白页脚不应留下多余分隔线")
    }

    func testLogSectionKeepsEntryOrder() throws {
        let log = DiagnosticsLog(capacity: 10)
        log.info(.app, "第一条")
        log.warning(.network, "第二条")
        let section = DiagnosticsReport.logSection(log.snapshot, timeZone: try timeZone("Asia/Shanghai"))
        XCTAssertEqual(section.title, "日志")
        XCTAssertEqual(section.lines.count, 2)
        XCTAssertTrue(section.lines[0].contains("第一条"))
        XCTAssertTrue(section.lines[1].contains("第二条"))
        XCTAssertTrue(section.lines[1].contains("[警告]"))
    }

    func testLinesFromRowsUsesLabelColonValue() {
        let rows: [(label: String, value: String)] = [("App 版本", "1.0.0"), ("系统", "iOS 18.5")]
        XCTAssertEqual(DiagnosticsReport.lines(from: rows), ["App 版本：1.0.0", "系统：iOS 18.5"])
    }

    // MARK: - 中继探测结论

    func testRelayProbeOutcomesHaveDistinctTitlesAndAdvice() {
        let outcomes: [RelayProbe.Result.Outcome] = [
            .ok, .reachableNoFrames, .httpError, .unreachable, .timedOut, .cancelled
        ]
        var titles = Set<String>()
        var advices = Set<String>()
        for outcome in outcomes {
            var result = RelayProbe.Result()
            result.outcome = outcome
            XCTAssertFalse(result.title.isEmpty)
            XCTAssertFalse(result.advice.isEmpty, "\(outcome.rawValue) 必须给出可执行的下一步")
            titles.insert(result.title)
            advices.insert(result.advice)
        }
        XCTAssertEqual(titles.count, outcomes.count, "六种结论的标题必须互不相同，否则等于没拆开")
        XCTAssertEqual(advices.count, outcomes.count)
        XCTAssertTrue(RelayProbe.Result().isSuccess == false, "默认值不是成功")
    }

    func testRelayProbeSummaryLineCarriesMeasuredFacts() {
        var result = RelayProbe.Result()
        result.outcome = .ok
        result.statusCode = 200
        result.contentType = "multipart/x-mixed-replace"
        result.elapsed = 0.25
        result.receivedHeadBytes = 4096
        result.detail = "收到首块画面数据 4096 字节"

        let line = result.summaryLine
        XCTAssertTrue(result.isSuccess)
        XCTAssertTrue(line.contains("HTTP 200"))
        XCTAssertTrue(line.contains("multipart/x-mixed-replace"))
        XCTAssertTrue(line.contains("0.25s"))
        XCTAssertTrue(line.contains("4096"))
    }

    func testRelayProbeSummaryOmitsFactsItDoesNotHave() {
        var result = RelayProbe.Result()
        result.outcome = .unreachable
        result.elapsed = 0.01
        result.detail = "连接被拒绝"
        let line = result.summaryLine
        XCTAssertFalse(line.contains("HTTP"), "没有状态码就不能编一个出来")
        XCTAssertFalse(line.contains("首块"))
        XCTAssertTrue(line.contains("连接被拒绝"))
    }

    // MARK: - 共享实例

    func testSharedInstanceIsUsableAndBounded() {
        XCTAssertEqual(DiagnosticsLog.shared.capacity, 400)
        XCTAssertTrue(DiagnosticsLog.shared.snapshot.count <= 400)
        // 写入共享实例不应影响上面那些隔离实例的断言；这里只确认它可用。
        DiagnosticsLog.shared.debug(.diagnostics, "测试写入")
        XCTAssertTrue(DiagnosticsLog.shared.snapshot.contains { $0.message == "测试写入" })
    }
}
