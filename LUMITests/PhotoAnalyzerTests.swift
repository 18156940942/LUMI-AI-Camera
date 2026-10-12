import XCTest
import CoreGraphics
import ImageIO
@testable import LUMI

/// 静态照片分析器。
///
/// 用真实的 JPEG 数据走完整链路（EXIF → Vision → 像素指标 → 汇总），
/// 重点验证：拿到的是**真实计算结果**，而不是一堆看起来合理的默认值。
final class PhotoAnalyzerTests: XCTestCase {

    // MARK: - 输入保护

    func testGarbageDataReturnsNil() {
        XCTAssertNil(PhotoAnalyzer.analyze(data: Data(repeating: 0x42, count: 512)),
                     "非图像数据必须返回 nil，让 UI 明确报错，而不是给一份空的「分析报告」")
    }

    func testEmptyDataReturnsNil() {
        XCTAssertNil(PhotoAnalyzer.analyze(data: Data()))
    }

    // MARK: - 无人物的真实照片

    func testAnalyzeProducesMeasuredResultForRealPhoto() throws {
        let data = try makeJPEG(size: 256)
        let result = try XCTUnwrap(PhotoAnalyzer.analyze(data: data))

        // EXIF 段：ImageIO 至少会给出尺寸，且绝不允许出现编造的机身型号
        let exif = try XCTUnwrap(result.exif)
        XCTAssertGreaterThan(exif.pixelWidth ?? 0, 0)
        XCTAssertGreaterThan(exif.pixelHeight ?? 0, 0)
        XCTAssertNil(exif.cameraModel, "合成图没有机身信息，不能被填上默认机型")

        // 像素指标必须存在且自洽
        let metrics = try XCTUnwrap(result.metrics)
        XCTAssertGreaterThan(metrics.width, 0)
        XCTAssertGreaterThan(metrics.height, 0)
        XCTAssertEqual(metrics.meanLuminance, 0.5, accuracy: 0.05)
        XCTAssertGreaterThanOrEqual(metrics.meanLuminance, 0)
        XCTAssertLessThanOrEqual(metrics.meanLuminance, 1)
        XCTAssertGreaterThanOrEqual(metrics.sharpnessScore, 0)
        XCTAssertLessThanOrEqual(metrics.sharpnessScore, 1)
    }

    func testBlankPhotoReportsNoPersonInsteadOfFabricatingPose() throws {
        let data = try makeJPEG(size: 256)
        let result = try XCTUnwrap(PhotoAnalyzer.analyze(data: data))

        XCTAssertNil(result.poseReport, "纯色图里没有人，不应产生姿态报告")

        let composition = try XCTUnwrap(result.compositionReport)
        XCTAssertFalse(composition.isSubjectPresent)
        XCTAssertNil(composition.suggestedShotType)
        XCTAssertTrue(composition.findings.contains { $0.id == "composition-no-subject" })

        let summary = result.summary
        XCTAssertEqual(summary.personCount, 0)
        XCTAssertEqual(summary.compositionScore, 0,
                       "没有人时构图分应为 0，而不是「默认 100 分」")
        XCTAssertEqual(summary.closedEyeRisk, .noFaceDetected)
        XCTAssertTrue(summary.poseFindings.contains { $0.contains("未检测到人体") },
                      "实际: \(summary.poseFindings)")
        XCTAssertTrue(summary.compositionFindings.contains { $0.contains("未检测到人物") },
                      "实际: \(summary.compositionFindings)")
    }

    func testSummaryAlwaysProvidesAtLeastOneSuggestion() throws {
        let data = try makeJPEG(size: 128)
        let result = try XCTUnwrap(PhotoAnalyzer.analyze(data: data))
        XCTAssertFalse(result.summary.suggestions.isEmpty,
                       "筛选建议不能为空，否则 UI 上会是一块空白")
    }

    func testOverallScoreIsClampedToValidRange() throws {
        let data = try makeJPEG(size: 128)
        let result = try XCTUnwrap(PhotoAnalyzer.analyze(data: data))
        XCTAssertGreaterThanOrEqual(result.summary.overallScore, 0)
        XCTAssertLessThanOrEqual(result.summary.overallScore, 100)
        XCTAssertGreaterThanOrEqual(result.summary.compositionScore, 0)
        XCTAssertLessThanOrEqual(result.summary.compositionScore, 100)
    }

    func testAnalyzedAtTimestampIsRecorded() throws {
        let before = Date()
        let data = try makeJPEG(size: 64)
        let result = try XCTUnwrap(PhotoAnalyzer.analyze(data: data))
        XCTAssertGreaterThanOrEqual(result.summary.analyzedAt, before)
        XCTAssertLessThanOrEqual(result.summary.analyzedAt, Date())
    }

    func testSharpnessLabelMatchesScore() throws {
        let data = try makeJPEG(size: 256)
        let result = try XCTUnwrap(PhotoAnalyzer.analyze(data: data))
        let summary = result.summary
        let expected: String
        switch summary.sharpnessScore {
        case 0.6...: expected = "锐利"
        case 0.35..<0.6: expected = "可用"
        case 0.15..<0.35: expected = "偏软"
        default: expected = "明显虚焦或抖动"
        }
        XCTAssertEqual(summary.sharpnessLabel, expected)
    }

    func testSharpnessLevelMapping() {
        func level(_ score: Double) -> FindingLevel {
            PhotoAnalysisSummary(sharpnessScore: score, sharpnessLabel: "",
                                 brightness: 0.5, exposureLabel: "",
                                 contrast: 0, closedEyeRisk: .open, faceCount: 0,
                                 personCount: 0, poseFindings: [], compositionFindings: [],
                                 compositionScore: 0, suggestions: [], overallScore: 0,
                                 analyzedAt: Date()).sharpnessLevel
        }
        XCTAssertEqual(level(0.80), .good)
        XCTAssertEqual(level(0.40), .info)
        XCTAssertEqual(level(0.20), .attention)
        XCTAssertEqual(level(0.05), .warning)
    }

    // MARK: - 筛选结论

    func testVerdictPrefersReviewWhenEyesMayBeClosed() {
        XCTAssertEqual(PhotoAnalyzer.verdict(for: summary(overall: 95,
                                                         sharpness: 0.9,
                                                         eyes: .suspectedClosed)),
                       .review,
                       "疑似闭眼必须先人工复核，哪怕其他指标满分")
    }

    func testVerdictConsidersDiscardWhenClearlySoft() {
        XCTAssertEqual(PhotoAnalyzer.verdict(for: summary(overall: 95,
                                                         sharpness: 0.05,
                                                         eyes: .open)),
                       .considerDiscard,
                       "明显虚焦的片子应优先剔除，即使综合分被其他项拉高")
    }

    func testVerdictMappingByOverallScore() {
        XCTAssertEqual(PhotoAnalyzer.verdict(for: summary(overall: 85, sharpness: 0.8, eyes: .open)),
                       .keep)
        XCTAssertEqual(PhotoAnalyzer.verdict(for: summary(overall: 55, sharpness: 0.8, eyes: .open)),
                       .review)
        XCTAssertEqual(PhotoAnalyzer.verdict(for: summary(overall: 20, sharpness: 0.8, eyes: .open)),
                       .considerDiscard)
    }

    func testVerdictTitlesAreNonEmpty() {
        for verdict in [ScreeningVerdict.keep, .review, .considerDiscard] {
            XCTAssertFalse(verdict.title.isEmpty)
        }
    }

    // MARK: - 闭眼判定的措辞

    func testClosedEyeRisksCarryHonestCaveats() {
        XCTAssertTrue(ClosedEyeRisk.suspectedClosed.caveat.contains("启发式"),
                      "闭眼是基于特征点比例的启发式判断，必须说明")
        XCTAssertTrue(ClosedEyeRisk.suspectedClosed.caveat.contains("人工确认"))
        XCTAssertTrue(ClosedEyeRisk.uncertain.caveat.contains("人工"))
        XCTAssertTrue(ClosedEyeRisk.noFaceDetected.caveat.contains("未检测到"))
        for risk in [ClosedEyeRisk.notAnalyzed, .noFaceDetected, .open, .uncertain, .suspectedClosed] {
            XCTAssertFalse(risk.title.isEmpty)
            XCTAssertFalse(risk.caveat.isEmpty)
        }
    }

    // MARK: - 辅助

    private func summary(overall: Double,
                         sharpness: Double,
                         eyes: ClosedEyeRisk) -> PhotoAnalysisSummary {
        PhotoAnalysisSummary(sharpnessScore: sharpness,
                             sharpnessLabel: "",
                             brightness: 0.5,
                             exposureLabel: "",
                             contrast: 0.3,
                             closedEyeRisk: eyes,
                             faceCount: 1,
                             personCount: 1,
                             poseFindings: [],
                             compositionFindings: [],
                             compositionScore: 80,
                             suggestions: [],
                             overallScore: overall,
                             analyzedAt: Date())
    }

    private func makeJPEG(size: Int) throws -> Data {
        let image = Fixtures.solidGrayImage(value: 0.5, size: size)
        let mutable = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(mutable, "public.jpeg" as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, image,
                                   [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return mutable as Data
    }
}
