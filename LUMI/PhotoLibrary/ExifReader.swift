import Foundation
import ImageIO
import CoreGraphics

/// 从图片文件里读取真实 EXIF / TIFF 元数据。
///
/// 严格约束：
/// - **只读取文件里真实存在的字段**，读不到就返回 nil，绝不用默认值填充；
/// - 不联网、不上传；
/// - 使用 ImageIO 直接从数据解析，不依赖相册权限。
enum ExifReader {

    static func read(from data: Data) -> ExifSummary? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return read(from: source)
    }

    static func read(from url: URL) -> ExifSummary? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return read(from: source)
    }

    private static func read(from source: CGImageSource) -> ExifSummary? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }

        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]

        var summary = ExifSummary(hasExifDictionary: exif != nil)

        summary.pixelWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
        summary.pixelHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        summary.orientationRaw = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue
        summary.colorModel = properties[kCGImagePropertyColorModel] as? String

        if let tiff {
            summary.cameraMake = (tiff[kCGImagePropertyTIFFMake] as? String)?.trimmed
            summary.cameraModel = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmed
        }

        if let exif {
            summary.lensModel = (exif[kCGImagePropertyExifLensModel] as? String)?.trimmed
            summary.aperture = (exif[kCGImagePropertyExifFNumber] as? NSNumber)?.doubleValue
            summary.exposureTimeSeconds = (exif[kCGImagePropertyExifExposureTime] as? NSNumber)?.doubleValue
            summary.focalLengthMM = (exif[kCGImagePropertyExifFocalLength] as? NSNumber)?.doubleValue
            summary.focalLength35mm = (exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? NSNumber)?.doubleValue

            if let isoArray = exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber], let first = isoArray.first {
                summary.iso = first.intValue
            }

            if let dateString = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
                summary.dateTimeOriginal = Self.exifDateFormatter.date(from: dateString)
            }
        }

        // 拍摄时间兜底：EXIF 缺失时用 TIFF 的 DateTime（仍是文件里的真实值）
        if summary.dateTimeOriginal == nil,
           let tiffDate = (tiff?[kCGImagePropertyTIFFDateTime] as? String) {
            summary.dateTimeOriginal = Self.exifDateFormatter.date(from: tiffDate)
        }

        return summary
    }

    /// EXIF 的时间格式固定为 "yyyy:MM:dd HH:mm:ss"
    private static let exifDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.timeZone = TimeZone.current
        return formatter
    }()
}

private extension String {
    var trimmed: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
