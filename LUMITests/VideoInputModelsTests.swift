import XCTest
import UIKit
@testable import LUMI

/// 视频输入相关的模型与「能力判定」。
///
/// 这些看起来是「数据类」的测试，但它们守住的是整个项目最重要的一条诚信规则：
/// **不能假装 iPhone 能接 UVC 采集卡**。一旦有人为了「让它看起来能用」而放宽判定，
/// 这些测试会立刻失败。
final class VideoInputModelsTests: XCTestCase {

    // MARK: - 设备能力判定

    func testUVCIsNeverAvailableOnIPhone() {
        XCTAssertFalse(VideoInputKind.uvcExternal.isAvailableOnIPhone,
                       "iPhone 不枚举 UVC 外接摄像头，这是 Apple 官方确认的行为")
        XCTAssertTrue(VideoInputKind.networkRelay.isAvailableOnIPhone)
        XCTAssertTrue(VideoInputKind.builtInCamera.isAvailableOnIPhone)
    }

    func testCapabilityMatchesCurrentIdiom() {
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        XCTAssertEqual(VideoInputCapability.supportsExternalCamera, isPad,
                       "只有 iPad 才支持外接摄像头")
        XCTAssertEqual(VideoInputCapability.isAvailable(.uvcExternal), isPad)
        XCTAssertTrue(VideoInputCapability.isAvailable(.networkRelay))
        XCTAssertTrue(VideoInputCapability.isAvailable(.builtInCamera))
    }

    func testUnavailableReasonExplainsTheSituationForIPhone() {
        let reason = VideoInputCapability.externalCameraUnavailableReason
        if VideoInputCapability.supportsExternalCamera {
            XCTAssertTrue(reason.contains("支持"))
        } else {
            XCTAssertTrue(reason.contains("iPhone"), "应说明本机是 iPhone")
            XCTAssertTrue(reason.contains("不支持"), "应明确说明不支持")
            XCTAssertTrue(reason.contains("网络中继"), "必须给出可执行的替代方案")
            XCTAssertTrue(reason.contains("HDMI"), "替代方案应说明链路（相机 HDMI → 采集卡 → 电脑）")
        }
    }

    func testNoInputProvidesCameraExposureMetadata() {
        for kind in VideoInputKind.allCases {
            XCTAssertFalse(kind.providesCameraExposureMetadata,
                           "\(kind.title) 无法拿到相机机身的曝光参数，UI 上不能显示伪造的测光值")
        }
    }

    func testEveryInputKindHasUserFacingText() {
        for kind in VideoInputKind.allCases {
            XCTAssertFalse(kind.title.isEmpty)
            XCTAssertFalse(kind.subtitle.isEmpty)
            XCTAssertFalse(kind.symbolName.isEmpty)
        }
    }

    // MARK: - 失败原因

    func testFailureCodesAreUniqueAndStable() {
        let failures: [VideoInputFailure] = [
            .externalDeviceNotSupportedOnIPhone,
            .noExternalDeviceFound,
            .builtInCameraPermissionDenied,
            .cannotCreateDeviceInput("a"),
            .cannotAddInputToSession("b"),
            .cannotAddOutputToSession("c"),
            .sessionRuntimeError("d"),
            .invalidRelayURL("e"),
            .networkUnreachable("f"),
            .streamStalled(seconds: 3),
            .streamDecodeFailed("g"),
            .configurationFailed("h"),
        ]
        let codes = failures.map(\.code)
        XCTAssertEqual(Set(codes).count, codes.count, "错误码不能重复，否则日志无法定位")
        XCTAssertEqual(VideoInputFailure.externalDeviceNotSupportedOnIPhone.code, "V-001")
        XCTAssertEqual(VideoInputFailure.streamStalled(seconds: 1).code, "V-022")
        XCTAssertEqual(VideoInputFailure.configurationFailed("").code, "V-030")
    }

    func testEveryFailureHasMessageAndRecoverySuggestion() {
        let failures: [VideoInputFailure] = [
            .externalDeviceNotSupportedOnIPhone,
            .noExternalDeviceFound,
            .builtInCameraPermissionDenied,
            .cannotCreateDeviceInput("x"),
            .cannotAddInputToSession("x"),
            .cannotAddOutputToSession("x"),
            .sessionRuntimeError("x"),
            .invalidRelayURL("http://"),
            .networkUnreachable("timeout"),
            .streamStalled(seconds: 3),
            .streamDecodeFailed("bad"),
            .configurationFailed("x"),
        ]
        for failure in failures {
            XCTAssertFalse(failure.message.isEmpty, "\(failure.code) 缺少错误文案")
            XCTAssertFalse(failure.recoverySuggestion.isEmpty, "\(failure.code) 缺少解决建议")
            XCTAssertEqual(failure.id, failure.code)
        }
    }

    func testUnsupportedUVCFailureExplainsAppleLimitationAndAlternative() {
        let failure = VideoInputFailure.externalDeviceNotSupportedOnIPhone
        XCTAssertTrue(failure.message.contains("不支持"))
        XCTAssertTrue(failure.recoverySuggestion.contains("iPad"),
                      "应说明 iPad 上可用")
        XCTAssertTrue(failure.recoverySuggestion.contains("网络中继"),
                      "应给出 iPhone 上真正可行的路径")
    }

    func testParameterizedFailuresIncludeTheirDetail() {
        XCTAssertTrue(VideoInputFailure.sessionRuntimeError("设备被拔出")
            .message.contains("设备被拔出"))
        XCTAssertTrue(VideoInputFailure.invalidRelayURL("http://x")
            .message.contains("http://x"))
        XCTAssertTrue(VideoInputFailure.streamStalled(seconds: 3)
            .message.contains("3"))
    }

    func testFailureIsEquatableSoStateComparisonWorks() {
        XCTAssertEqual(VideoInputFailure.streamStalled(seconds: 3),
                       VideoInputFailure.streamStalled(seconds: 3))
        XCTAssertNotEqual(VideoInputFailure.streamStalled(seconds: 3),
                          VideoInputFailure.streamStalled(seconds: 4))
        XCTAssertNotEqual(VideoInputFailure.noExternalDeviceFound,
                          VideoInputFailure.builtInCameraPermissionDenied)
    }

    // MARK: - 状态

    func testStateLabelsAndRunningFlag() {
        XCTAssertEqual(VideoInputState.idle.shortLabel, "未连接")
        XCTAssertEqual(VideoInputState.preparing.shortLabel, "连接中")
        XCTAssertEqual(VideoInputState.running.shortLabel, "监看中")
        XCTAssertEqual(VideoInputState.unsupported(reason: "x").shortLabel, "不支持")
        XCTAssertEqual(VideoInputState.failed(.noExternalDeviceFound).shortLabel, "异常")

        XCTAssertTrue(VideoInputState.running.isRunning)
        XCTAssertFalse(VideoInputState.idle.isRunning)
        XCTAssertFalse(VideoInputState.preparing.isRunning)
        XCTAssertFalse(VideoInputState.unsupported(reason: "x").isRunning)
    }

    // MARK: - 设备信息

    func testDeviceInfoTextHelpers() {
        let known = VideoInputDeviceInfo(kind: .uvcExternal, name: "USB Video",
                                         uniqueID: "0x1234", pixelWidth: 1920,
                                         pixelHeight: 1080, nominalFrameRate: 59.94,
                                         pixelFormat: "420f", isExternal: true)
        XCTAssertEqual(known.resolutionText, "1920×1080")
        XCTAssertEqual(known.frameRateText, "59.94 fps")
        XCTAssertEqual(known.connectionBadge, "USB-C / UVC")
        XCTAssertTrue(known.isExternal)
    }

    func testDeviceInfoShowsUnknownWhenSystemReportsNothing() {
        let unknown = VideoInputDeviceInfo(kind: .networkRelay, name: "relay",
                                           uniqueID: "-", pixelWidth: 0, pixelHeight: 0,
                                           nominalFrameRate: 0, pixelFormat: nil,
                                           isExternal: false)
        XCTAssertEqual(unknown.resolutionText, "未知")
        XCTAssertEqual(unknown.frameRateText, "未知",
                       "系统没给帧率时显示「未知」，不能编一个 30fps")
        XCTAssertEqual(unknown.connectionBadge, "局域网 HTTP")
    }

    func testFourCharCodeConversion() {
        XCTAssertEqual(CaptureFormatSelector.fourCharCodeToString(0x34323066), "420f")
        XCTAssertEqual(CaptureFormatSelector.fourCharCodeToString(0x42475241), "BGRA")
        // 全空格的编码（系统未上报时可能出现的值）应归一化为 nil，而不是返回一串空格
        XCTAssertNil(CaptureFormatSelector.fourCharCodeToString(0x20202020))
    }

    // MARK: - 流统计

    func testStreamStatsFrameAgeIsNilBeforeFirstFrame() {
        var stats = StreamStats()
        XCTAssertNil(stats.lastFrameAge)
        stats.lastFrameAt = Date().addingTimeInterval(-2)
        XCTAssertEqual(stats.lastFrameAge ?? 0, 2, accuracy: 0.5)
    }

    func testStreamStatsDefaultsAreZeroed() {
        let stats = StreamStats()
        XCTAssertEqual(stats.receivedFPS, 0)
        XCTAssertEqual(stats.totalFrames, 0)
        XCTAssertEqual(stats.droppedFrames, 0)
        XCTAssertEqual(stats.decodeFailureCount, 0)
        XCTAssertEqual(stats.bytesPerSecond, 0)
    }

    // MARK: - 中继配置

    func testRelayConfigurationBuildsURL() {
        let relay = RelayConfiguration(host: "192.168.1.10", port: 8090,
                                       path: "/stream", mode: .mjpeg)
        XCTAssertEqual(relay.url?.absoluteString, "http://192.168.1.10:8090/stream")
        XCTAssertEqual(relay.displayURL, "http://192.168.1.10:8090/stream")
    }

    func testRelayConfigurationNormalizesMissingLeadingSlash() {
        let relay = RelayConfiguration(host: "10.0.0.5", port: 8080,
                                       path: "stream", mode: .mjpeg)
        XCTAssertEqual(relay.url?.absoluteString, "http://10.0.0.5:8080/stream",
                       "用户忘记写斜杠时也要能拼出正确地址")
    }

    func testRelayConfigurationTrimsWhitespaceInHost() {
        let relay = RelayConfiguration(host: "  192.168.1.10  ", port: 8090,
                                       path: "/stream", mode: .mjpeg)
        XCTAssertEqual(relay.url?.absoluteString, "http://192.168.1.10:8090/stream")
    }

    func testRelayModeLatencyHints() {
        XCTAssertTrue(RelayMode.mjpeg.latencyHint.contains("ms"))
        XCTAssertTrue(RelayMode.hls.latencyHint.contains("s"))
        XCTAssertFalse(RelayMode.mjpeg.title.isEmpty)
        XCTAssertFalse(RelayMode.hls.title.isEmpty)
    }

    func testRelayConfigurationCodableRoundTrip() throws {
        let original = RelayConfiguration(host: "192.168.0.2", port: 9000,
                                          path: "/live", mode: .hls)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RelayConfiguration.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - 显示与参考线

    func testGravityModesHaveTitles() {
        XCTAssertFalse(VideoGravityMode.aspectFit.title.isEmpty)
        XCTAssertFalse(VideoGravityMode.aspectFill.title.isEmpty)
        XCTAssertTrue(VideoGravityMode.aspectFit.title.contains("黑边"))
    }

    func testCaptureAspectRatios() {
        XCTAssertNil(CaptureAspect.native.ratio, "原始比例应跟随输入，而不是固定值")
        XCTAssertEqual(CaptureAspect.square.ratio ?? 0, 1.0, accuracy: 0.0001)
        XCTAssertEqual(CaptureAspect.fourThree.ratio ?? 0, 4.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(CaptureAspect.threeTwo.ratio ?? 0, 1.5, accuracy: 0.0001)
        XCTAssertEqual(CaptureAspect.sixteenNine.ratio ?? 0, 16.0 / 9.0, accuracy: 0.0001)
        XCTAssertEqual(CaptureAspect.nineSixteen.ratio ?? 0, 9.0 / 16.0, accuracy: 0.0001)
        for aspect in CaptureAspect.allCases {
            XCTAssertFalse(aspect.title.isEmpty)
        }
    }

    func testOverlayDefaultsShowThirdsOnly() {
        let overlay = OverlayConfiguration()
        XCTAssertTrue(overlay.showThirds, "三分法是最常用的参考线，默认开启")
        XCTAssertFalse(overlay.showNineGrid)
        XCTAssertFalse(overlay.showCenterCross)
        XCTAssertFalse(overlay.showCenterLines)
        XCTAssertFalse(overlay.showHorizon)
        XCTAssertFalse(overlay.showSafeArea)
        XCTAssertFalse(overlay.showsSubjectBox)
        XCTAssertEqual(overlay.aspect, .native)
        XCTAssertEqual(overlay.safeAreaInset, 0.05, accuracy: 0.0001)
    }

    func testOverlayCodableRoundTripPreservesEveryToggle() throws {
        var overlay = OverlayConfiguration()
        overlay.showThirds = false
        overlay.showNineGrid = true
        overlay.showCenterCross = true
        overlay.showCenterLines = true
        overlay.showHorizon = true
        overlay.showSafeArea = true
        overlay.safeAreaInset = 0.12
        overlay.aspect = .sixteenNine
        overlay.showsSubjectBox = true

        let data = try JSONEncoder().encode(overlay)
        let decoded = try JSONDecoder().decode(OverlayConfiguration.self, from: data)
        XCTAssertEqual(decoded, overlay,
                       "参考线开关必须完整持久化，否则重启 App 后设置会丢")
    }

    // MARK: - 分析结论模型

    func testFindingKindsAreDistinguishableInUI() {
        XCTAssertEqual(FindingKind.objective.badge, "实测")
        XCTAssertEqual(FindingKind.heuristic.badge, "建议")
        XCTAssertNotEqual(FindingKind.objective.badge, FindingKind.heuristic.badge)
    }

    func testFindingLevelsHaveTitles() {
        for level in [FindingLevel.good, .info, .attention, .warning] {
            XCTAssertFalse(level.title.isEmpty)
        }
    }

    func testConfidenceLevelMappingAndCaveats() {
        XCTAssertEqual(ConfidenceLevel.from(0.10), .low)
        XCTAssertEqual(ConfidenceLevel.from(0.34), .low)
        XCTAssertEqual(ConfidenceLevel.from(0.35), .medium)
        XCTAssertEqual(ConfidenceLevel.from(0.69), .medium)
        XCTAssertEqual(ConfidenceLevel.from(0.70), .high)
        XCTAssertEqual(ConfidenceLevel.from(1.00), .high)

        XCTAssertTrue(ConfidenceLevel.low.caveat.contains("不稳定"))
        XCTAssertTrue(ConfidenceLevel.medium.caveat.contains("偏差"))
        XCTAssertTrue(ConfidenceLevel.high.caveat.contains("稳定"))
        for level in [ConfidenceLevel.low, .medium, .high] {
            XCTAssertFalse(level.title.isEmpty)
        }
    }

    func testEmptyReportsHaveNoReliability() {
        XCTAssertEqual(CompositionReport.empty.reliability, .low)
        XCTAssertEqual(PoseReport.empty.reliability, .low)
        XCTAssertFalse(CompositionReport.empty.isSubjectPresent)
        XCTAssertFalse(PoseReport.empty.isDetected)
    }

    func testAnalysisFindingIdentifiableByKey() {
        let first = AnalysisFinding(key: "k1", kind: .objective, level: .good,
                                    title: "t", detail: "d", confidence: 0.8)
        let second = AnalysisFinding(key: "k2", kind: .heuristic, level: .info,
                                     title: "t", detail: "d")
        XCTAssertEqual(first.id, "k1")
        XCTAssertEqual(second.id, "k2")
        XCTAssertEqual(second.confidence, 1.0, "未指定置信度时应默认为 1.0")
    }
}
