import XCTest
import CoreGraphics
import ImageIO
@testable import LUMI

/// EXIF 读取器的核心约束是**不编造**：
/// 文件里有什么就读什么，读不到就返回 nil，由 UI 显示「未提供」。
/// 这些测试用真实的 JPEG 数据（不是 mock）走完 ImageIO 全流程。
final class ExifReaderTests: XCTestCase {

    // MARK: - 拒绝非图像数据

    func testReadReturnsNilForGarbageData() {
        let garbage = Data("this is definitely not a jpeg".utf8)
        XCTAssertNil(ExifReader.read(from: garbage))
    }

    func testReadReturnsNilForEmptyData() {
        XCTAssertNil(ExifReader.read(from: Data()))
    }

    // MARK: - 完整 EXIF

    func testReadsEveryFieldFromARealJPEGWithEXIF() throws {
        let data = try makeJPEG(withEXIF: true)
        let summary = try XCTUnwrap(ExifReader.read(from: data))

        XCTAssertTrue(summary.hasExifDictionary, "应能读到 EXIF 段")
        XCTAssertEqual(summary.cameraMake, "NIKON CORPORATION")
        XCTAssertEqual(summary.cameraModel, "NIKON Z 6_2")
        XCTAssertEqual(summary.lensModel, "NIKKOR Z 85mm f/1.8 S")
        XCTAssertEqual(summary.iso, 400)
        XCTAssertEqual(summary.aperture ?? 0, 2.8, accuracy: 0.01)
        XCTAssertEqual(summary.exposureTimeSeconds ?? 0, 1.0 / 250.0, accuracy: 0.0001)
        XCTAssertEqual(summary.focalLengthMM ?? 0, 85.0, accuracy: 0.01)
        XCTAssertGreaterThan(summary.pixelWidth ?? 0, 0)
        XCTAssertGreaterThan(summary.pixelHeight ?? 0, 0)
        XCTAssertNotNil(summary.dateTimeOriginal)
    }

    func testExifDateIsParsedWithExifFormat() throws {
        let data = try makeJPEG(withEXIF: true)
        let summary = try XCTUnwrap(ExifReader.read(from: data))
        guard let date = summary.dateTimeOriginal else {
            return XCTFail("应解析出拍摄时间")
        }

        var components = DateComponents()
        components.year = 2024
        components.month = 5
        components.day = 18
        components.hour = 15
        components.minute = 32
        components.second = 7

        let calendar = Calendar(identifier: .gregorian)
        let expected = try XCTUnwrap(calendar.date(from: components))
        // EXIF 时间没有时区信息，按本地时区解析，允许 2 秒误差
        XCTAssertEqual(date.timeIntervalSince(expected), 0, accuracy: 2.0)
    }

    func testReadsFromFileURL() throws {
        let data = try makeJPEG(withEXIF: true)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumi-exif-\(UUID().uuidString).jpg")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let fromURL = ExifReader.read(from: url)
        let fromData = ExifReader.read(from: data)
        XCTAssertNotNil(fromURL)
        XCTAssertEqual(fromURL?.cameraModel, fromData?.cameraModel)
        XCTAssertEqual(fromURL?.iso, fromData?.iso)
    }

    // MARK: - 缺失字段不编造

    func testMissingFieldsStayNilInsteadOfBeingFabricated() throws {
        let data = try makeJPEG(withEXIF: false)
        let summary = try XCTUnwrap(ExifReader.read(from: data))

        XCTAssertNil(summary.cameraMake, "没有相机信息就必须是 nil，不能填默认机型")
        XCTAssertNil(summary.cameraModel)
        XCTAssertNil(summary.lensModel)
        XCTAssertNil(summary.iso)
        XCTAssertNil(summary.aperture)
        XCTAssertNil(summary.exposureTimeSeconds)
        XCTAssertNil(summary.focalLengthMM)
        XCTAssertNil(summary.dateTimeOriginal)
    }

    func testKeyValuePairsOmitNilFields() throws {
        let data = try makeJPEG(withEXIF: false)
        let summary = try XCTUnwrap(ExifReader.read(from: data))

        let keys = summary.keyValuePairs.map(\.0)
        XCTAssertFalse(keys.contains("机身"))
        XCTAssertFalse(keys.contains("感光度"))
        XCTAssertFalse(keys.contains("光圈"))
        XCTAssertFalse(keys.contains("拍摄时间"))
        // 图片本身有尺寸，这一项应该有
        XCTAssertTrue(keys.contains("尺寸"))
    }

    func testKeyValuePairsExposeRealValuesWhenPresent() throws {
        let data = try makeJPEG(withEXIF: true)
        let summary = try XCTUnwrap(ExifReader.read(from: data))
        let pairs = Dictionary(uniqueKeysWithValues: summary.keyValuePairs)

        XCTAssertEqual(pairs["机身"], "NIKON Z 6_2")
        XCTAssertEqual(pairs["镜头"], "NIKKOR Z 85mm f/1.8 S")
        XCTAssertEqual(pairs["感光度"], "ISO 400")
        XCTAssertEqual(pairs["光圈"], "f/2.8")
        XCTAssertEqual(pairs["快门"], "1/250 s")
        XCTAssertEqual(pairs["焦距"], "85 mm")
        XCTAssertTrue(summary.hasAnyValue)
    }

    // MARK: - 格式化

    func testApertureAndShutterFormatting() {
        var summary = ExifSummary(hasExifDictionary: true)
        summary.aperture = 1.8
        XCTAssertEqual(summary.apertureText, "f/1.8")

        summary.exposureTimeSeconds = 1.0 / 250.0
        XCTAssertEqual(summary.shutterText, "1/250 s")

        summary.exposureTimeSeconds = 2.5
        XCTAssertEqual(summary.shutterText, "2.5 s")

        summary.exposureTimeSeconds = 0
        XCTAssertNil(summary.shutterText, "0 秒是无效值，不应格式化成 1/0 s")
    }

    func testFocalTextShowsEquivalentWhenDifferent() {
        var summary = ExifSummary(hasExifDictionary: true)
        summary.focalLengthMM = 50
        summary.focalLength35mm = 75
        XCTAssertEqual(summary.focalText, "50 mm（等效 75 mm）")

        summary.focalLength35mm = 50.3
        XCTAssertEqual(summary.focalText, "50 mm",
                       "等效焦距与物理焦距一致时不该显示冗余说明")
    }

    func testMegapixelTextFormatting() {
        var summary = ExifSummary(hasExifDictionary: true)
        summary.pixelWidth = 6048
        summary.pixelHeight = 4024
        XCTAssertEqual(summary.megapixelText, "6048×4024 · 24.3 MP")

        summary.pixelWidth = nil
        XCTAssertNil(summary.megapixelText)
    }

    func testEmptySummaryHasNoValues() {
        let empty = ExifSummary(hasExifDictionary: false)
        XCTAssertFalse(empty.hasAnyValue)
        XCTAssertTrue(empty.keyValuePairs.isEmpty)
        XCTAssertNil(empty.isoText)
        XCTAssertNil(empty.focalText)
        XCTAssertNil(empty.apertureText)
        XCTAssertNil(empty.shutterText)
        XCTAssertNil(empty.megapixelText)
    }

    // MARK: - 辅助

    /// 生成一张带（或不带）EXIF 的真实 JPEG
    private func makeJPEG(withEXIF: Bool) throws -> Data {
        let image = Fixtures.solidGrayImage(value: 0.5, size: 96)
        let mutable = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(mutable, "public.jpeg" as CFString, 1, nil)
        )

        var properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.9
        ]

        if withEXIF {
            properties[kCGImagePropertyExifDictionary] = [
                kCGImagePropertyExifFNumber: 2.8,
                kCGImagePropertyExifExposureTime: 1.0 / 250.0,
                kCGImagePropertyExifFocalLength: 85.0,
                kCGImagePropertyExifISOSpeedRatings: [400],
                kCGImagePropertyExifDateTimeOriginal: "2024:05:18 15:32:07",
                kCGImagePropertyExifLensModel: "NIKKOR Z 85mm f/1.8 S",
            ] as [CFString: Any]
            properties[kCGImagePropertyTIFFDictionary] = [
                kCGImagePropertyTIFFMake: "NIKON CORPORATION",
                kCGImagePropertyTIFFModel: "NIKON Z 6_2",
            ] as [CFString: Any]
        }

        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination), "JPEG 编码应成功")
        XCTAssertGreaterThan(mutable.length, 0)
        return mutable as Data
    }
}
