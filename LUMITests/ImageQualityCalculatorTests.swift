import XCTest
import CoreGraphics
@testable import LUMI

/// 画质指标全部由像素真实计算。测试重点：
/// 1. 纯色图的方差/边缘密度必须是 0（而不是「看起来差不多」的值）；
/// 2. 高频图像的清晰度评分必须显著高于纯色图；
/// 3. 归一化映射在边界上必须被钳制到 0...1。
final class ImageQualityCalculatorTests: XCTestCase {

    // MARK: - 灰度缓冲

    func testGrayBufferFromSolidImageHasZeroVarianceAndNoEdges() {
        let image = Fixtures.solidGrayImage(value: 0.5, size: 64)
        guard let metrics = ImageQualityCalculator.metrics(from: image) else {
            return XCTFail("应能从 CGImage 生成灰度缓冲")
        }
        // 50% 灰 ≈ 127 或 128，允许 1 级量化误差
        XCTAssertEqual(metrics.meanLuminance, 0.5, accuracy: 0.01)
        XCTAssertLessThan(metrics.luminanceStdDev, 0.001, "纯色图标准差应为 0")
        XCTAssertLessThan(metrics.laplacianVariance, 0.001, "纯色图拉普拉斯方差应为 0")
        XCTAssertEqual(metrics.sharpnessScore, 0, accuracy: 0.0001)
        XCTAssertEqual(metrics.overallEdgeDensity, 0, accuracy: 0.0001)
        XCTAssertEqual(metrics.overexposedRatio, 0, accuracy: 0.0001)
        XCTAssertEqual(metrics.underexposedRatio, 0, accuracy: 0.0001)
    }

    func testGrayBufferFromBlackAndWhiteImagesIsAccurate() {
        let black = Fixtures.solidGrayImage(value: 0, size: 32)
        guard let blackMetrics = ImageQualityCalculator.metrics(from: black) else {
            return XCTFail("黑色图应可分析")
        }
        XCTAssertEqual(blackMetrics.meanLuminance, 0, accuracy: 0.01)
        XCTAssertEqual(blackMetrics.underexposedRatio, 1.0, accuracy: 0.0001,
                       "全黑图中所有像素都应计入欠曝")

        let white = Fixtures.solidGrayImage(value: 1, size: 32)
        guard let whiteMetrics = ImageQualityCalculator.metrics(from: white) else {
            return XCTFail("白色图应可分析")
        }
        XCTAssertEqual(whiteMetrics.meanLuminance, 1.0, accuracy: 0.01)
        XCTAssertEqual(whiteMetrics.overexposedRatio, 1.0, accuracy: 0.0001,
                       "全白图中所有像素都应计入过曝")
    }

    func testCheckerboardHasHighEdgeDensityAndSharpness() {
        let image = Fixtures.checkerboardImage(blockSize: 8, size: 64)
        guard let metrics = ImageQualityCalculator.metrics(from: image) else {
            return XCTFail("棋盘格应可分析")
        }
        // 实测参考值（同一算法在 64×64、8px 方块下）：边缘密度 ≈ 0.21，拉普拉斯方差 ≈ 36000
        XCTAssertGreaterThan(metrics.overallEdgeDensity, 0.15,
                             "棋盘格相邻像素差异极大，边缘密度应明显高于 0")
        XCTAssertGreaterThan(metrics.laplacianVariance, 1000,
                             "棋盘格的拉普拉斯方差应远高于纯色图的 0")
        XCTAssertGreaterThan(metrics.sharpnessScore, 0.5)
        XCTAssertEqual(metrics.sharpnessLabel, "锐利")
    }

    func testDecodedBufferMatchesRequestedTargetWidth() {
        let image = Fixtures.solidGrayImage(value: 0.5, size: 200)
        guard let gray = ImageQualityCalculator.makeGrayBuffer(from: image, targetWidth: 100) else {
            return XCTFail("应能降采样")
        }
        XCTAssertEqual(gray.width, 100)
        XCTAssertEqual(gray.height, 100, "等比缩放应保持宽高比")
        XCTAssertEqual(gray.data.count, gray.width * gray.height,
                       "缓冲必须是紧凑的（去掉 CGContext 的行填充），否则下标会算错")
    }

    func testSmallImageIsNotUpscaled() {
        let image = Fixtures.solidGrayImage(value: 0.5, size: 40)
        guard let gray = ImageQualityCalculator.makeGrayBuffer(from: image, targetWidth: 640) else {
            return XCTFail("应能处理小图")
        }
        XCTAssertEqual(gray.width, 40, "小图不应被放大（放大只会白费算力）")
    }

    // MARK: - 手写缓冲的精确断言

    func testMetricsOnHandwrittenBuffer() {
        // 4×4：上半 100，下半 200 → 均值 150，标准差 50
        let buffer = Fixtures.grayBuffer([
            [100, 100, 100, 100],
            [100, 100, 100, 100],
            [200, 200, 200, 200],
            [200, 200, 200, 200],
        ])
        let metrics = ImageQualityCalculator.metrics(from: buffer)
        XCTAssertEqual(metrics.width, 4)
        XCTAssertEqual(metrics.height, 4)
        XCTAssertEqual(metrics.meanLuminance, 150.0 / 255.0, accuracy: 0.0001)
        XCTAssertEqual(metrics.luminanceStdDev, 50.0 / 255.0, accuracy: 0.001)
        XCTAssertEqual(metrics.overexposedRatio, 0, accuracy: 0.0001)
        XCTAssertEqual(metrics.underexposedRatio, 0, accuracy: 0.0001)
        XCTAssertGreaterThan(metrics.overallEdgeDensity, 0, "上下两半的落差应形成边缘")
    }

    func testOverexposedRatioCountsOnlyVeryBrightPixels() {
        let buffer = Fixtures.grayBuffer([
            [255, 255],
            [255, 100],
        ])
        let metrics = ImageQualityCalculator.metrics(from: buffer)
        XCTAssertEqual(metrics.overexposedRatio, 0.75, accuracy: 0.0001)
    }

    func testUnderexposedRatioCountsOnlyVeryDarkPixels() {
        let buffer = Fixtures.grayBuffer([
            [0, 0],
            [0, 100],
        ])
        let metrics = ImageQualityCalculator.metrics(from: buffer)
        XCTAssertEqual(metrics.underexposedRatio, 0.75, accuracy: 0.0001)
    }

    func testEmptyBufferDoesNotCrash() {
        let buffer = ImageQualityCalculator.GrayBuffer(data: [], width: 0, height: 0)
        let metrics = ImageQualityCalculator.metrics(from: buffer)
        XCTAssertEqual(metrics.meanLuminance, 0)
        XCTAssertEqual(metrics.sharpnessScore, 0)
        XCTAssertNil(metrics.backgroundEdgeDensity)
    }

    // MARK: - 清晰度归一化

    func testNormalizeSharpnessIsClampedToZeroOne() {
        XCTAssertEqual(ImageQualityCalculator.normalizeSharpness(0), 0, accuracy: 0.0001)
        XCTAssertEqual(ImageQualityCalculator.normalizeSharpness(1), 0, accuracy: 0.0001)
        XCTAssertEqual(ImageQualityCalculator.normalizeSharpness(100_000), 1, accuracy: 0.0001)
        XCTAssertEqual(ImageQualityCalculator.normalizeSharpness(-50), 0, accuracy: 0.0001,
                       "负方差是无效输入，应被钳制为 0 而不是产生负数评分")
    }

    func testNormalizeSharpnessIsMonotonic() {
        let samples = [0.0, 5, 20, 100, 300, 800, 2000, 50_000]
        let scores = samples.map { ImageQualityCalculator.normalizeSharpness($0) }
        for index in 1..<scores.count {
            XCTAssertGreaterThanOrEqual(scores[index], scores[index - 1],
                                        "清晰度评分应随方差单调不减")
        }
    }

    func testSharpnessLabelThresholds() {
        XCTAssertEqual(ImageQualityMetrics(width: 1, height: 1, meanLuminance: 0.5,
                                          luminanceStdDev: 0, laplacianVariance: 0,
                                          sharpnessScore: 0.80, overexposedRatio: 0,
                                          underexposedRatio: 0, overallEdgeDensity: 0,
                                          backgroundEdgeDensity: nil).sharpnessLabel,
                       "锐利")
        XCTAssertEqual(ImageQualityMetrics(width: 1, height: 1, meanLuminance: 0.5,
                                          luminanceStdDev: 0, laplacianVariance: 0,
                                          sharpnessScore: 0.40, overexposedRatio: 0,
                                          underexposedRatio: 0, overallEdgeDensity: 0,
                                          backgroundEdgeDensity: nil).sharpnessLabel,
                       "可用")
        XCTAssertEqual(ImageQualityMetrics(width: 1, height: 1, meanLuminance: 0.5,
                                          luminanceStdDev: 0, laplacianVariance: 0,
                                          sharpnessScore: 0.20, overexposedRatio: 0,
                                          underexposedRatio: 0, overallEdgeDensity: 0,
                                          backgroundEdgeDensity: nil).sharpnessLabel,
                       "偏软")
        XCTAssertEqual(ImageQualityMetrics(width: 1, height: 1, meanLuminance: 0.5,
                                          luminanceStdDev: 0, laplacianVariance: 0,
                                          sharpnessScore: 0.05, overexposedRatio: 0,
                                          underexposedRatio: 0, overallEdgeDensity: 0,
                                          backgroundEdgeDensity: nil).sharpnessLabel,
                       "明显虚焦或抖动")
    }

    func testExposureLabelThresholds() {
        func label(mean: Double, over: Double, under: Double) -> String {
            ImageQualityMetrics(width: 1, height: 1, meanLuminance: mean,
                                luminanceStdDev: 0, laplacianVariance: 0, sharpnessScore: 0,
                                overexposedRatio: over, underexposedRatio: under,
                                overallEdgeDensity: 0, backgroundEdgeDensity: nil).exposureLabel
        }
        XCTAssertEqual(label(mean: 0.5, over: 0.10, under: 0), "高光溢出偏多")
        XCTAssertEqual(label(mean: 0.5, over: 0, under: 0.40), "整体欠曝")
        XCTAssertEqual(label(mean: 0.10, over: 0, under: 0), "偏暗")
        XCTAssertEqual(label(mean: 0.90, over: 0, under: 0), "偏亮")
        XCTAssertEqual(label(mean: 0.50, over: 0, under: 0), "曝光分布正常")
    }

    // MARK: - 边缘密度与背景分离

    func testEdgeDensityOnSolidRegionIsZero() {
        let buffer = Fixtures.grayBuffer(Array(repeating: Array(repeating: UInt8(120), count: 16),
                                              count: 16))
        XCTAssertEqual(ImageQualityCalculator.edgeDensity(gray: buffer), 0, accuracy: 0.0001)
    }

    func testExcludingRegionReducesSampleCount() {
        // 左半 0 / 右半 255：分界线处有强边缘
        var rows: [[UInt8]] = []
        for _ in 0..<16 {
            rows.append(Array(repeating: 0, count: 8) + Array(repeating: 255, count: 8))
        }
        let buffer = Fixtures.grayBuffer(rows)

        let overall = ImageQualityCalculator.edgeDensity(gray: buffer)
        XCTAssertGreaterThan(overall, 0)
        // 排除左半区（包含分界线）后，剩下的都是纯色 → 边缘密度应下降
        let excludingLeft = ImageQualityCalculator.edgeDensity(
            gray: buffer,
            excludingRegion: CGRect(x: 0, y: 0, width: 9, height: 16)
        )
        XCTAssertLessThan(excludingLeft, overall)
    }

    func testBackgroundEdgeDensityIsNilWithoutSubjectBox() {
        let image = Fixtures.checkerboardImage(size: 32)
        guard let metrics = ImageQualityCalculator.metrics(from: image, subjectBox: nil) else {
            return XCTFail("应可分析")
        }
        XCTAssertNil(metrics.backgroundEdgeDensity,
                     "没有人物框时不该给「背景」下结论")
    }

    func testBackgroundEdgeDensityIsComputedWithSubjectBox() {
        let image = Fixtures.checkerboardImage(size: 64)
        // Vision 归一化坐标（原点左下）
        let subjectBox = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        guard let metrics = ImageQualityCalculator.metrics(from: image, subjectBox: subjectBox) else {
            return XCTFail("应可分析")
        }
        let background = metrics.backgroundEdgeDensity
        XCTAssertNotNil(background)
        // 挖掉中间 32×32 之后，四周仍是棋盘格 → 背景密度应与整体接近（实测 0.205 vs 0.213）
        XCTAssertEqual(background ?? 0, metrics.overallEdgeDensity, accuracy: 0.1)
        XCTAssertGreaterThan(background ?? 0, 0.15)
    }

    func testDegenerateRegionReturnsZeroInsteadOfCrashing() {
        let buffer = Fixtures.grayBuffer([[10, 20], [30, 40]])
        XCTAssertEqual(ImageQualityCalculator.edgeDensity(gray: buffer,
                                                          region: CGRect(x: 0, y: 0, width: 1, height: 1)),
                       0, accuracy: 0.0001)
    }

    // MARK: - 图像解码

    func testDecodeImageReturnsOrientation() throws {
        let image = Fixtures.solidGrayImage(value: 0.5, size: 32)
        let data = try XCTUnwrap(jpegData(from: image))
        let decoded = ImageQualityCalculator.decodeImage(data: data)
        XCTAssertNotNil(decoded)
        XCTAssertGreaterThan(decoded?.image.width ?? 0, 0)
        XCTAssertEqual(decoded?.orientation, .up)
    }

    func testDecodeImageRejectsGarbageData() {
        let garbage = Data(repeating: 0x41, count: 256)
        XCTAssertNil(ImageQualityCalculator.decodeImage(data: garbage),
                     "非图像数据必须返回 nil，而不是给出一个空图或默认图")
    }

    // MARK: - 辅助

    private func jpegData(from image: CGImage) -> Data? {
        let mutable = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutable, "public.jpeg" as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return mutable as Data
    }
}
