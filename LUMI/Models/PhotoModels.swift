import Foundation

// MARK: - EXIF 摘要（全部来自文件本身的真实元数据）

/// 只存放**实际从文件里读出来的**字段。读不到就为 nil，UI 显示「未提供」，绝不编造。
struct ExifSummary: Codable, Hashable {
    var cameraMake: String?
    var cameraModel: String?
    var lensModel: String?
    var iso: Int?
    var aperture: Double?
    var exposureTimeSeconds: Double?
    var focalLengthMM: Double?
    var focalLength35mm: Double?
    var pixelWidth: Int?
    var pixelHeight: Int?
    var dateTimeOriginal: Date?
    var orientationRaw: Int?
    var colorModel: String?
    /// 文件里是否存在 EXIF 段
    var hasExifDictionary: Bool

    var apertureText: String? {
        guard let aperture else { return nil }
        return String(format: "f/%.1f", aperture)
    }

    var shutterText: String? {
        guard let exposureTimeSeconds, exposureTimeSeconds > 0 else { return nil }
        if exposureTimeSeconds >= 1 {
            return String(format: "%.1f s", exposureTimeSeconds)
        }
        return "1/\(Int((1.0 / exposureTimeSeconds).rounded())) s"
    }

    var isoText: String? {
        guard let iso else { return nil }
        return "ISO \(iso)"
    }

    var focalText: String? {
        guard let focalLengthMM else { return nil }
        if let focalLength35mm, abs(focalLength35mm - focalLengthMM) > 0.6 {
            return String(format: "%.0f mm（等效 %.0f mm）", focalLengthMM, focalLength35mm)
        }
        return String(format: "%.0f mm", focalLengthMM)
    }

    var megapixelText: String? {
        guard let pixelWidth, let pixelHeight, pixelWidth > 0, pixelHeight > 0 else { return nil }
        let mp = Double(pixelWidth * pixelHeight) / 1_000_000.0
        return String(format: "%d×%d · %.1f MP", pixelWidth, pixelHeight, mp)
    }

    /// 面向 UI 的「关键参数」键值对，nil 的项会被过滤掉
    var keyValuePairs: [(String, String)] {
        var pairs: [(String, String)] = []
        if let cameraModel { pairs.append(("机身", cameraModel)) }
        if let lensModel { pairs.append(("镜头", lensModel)) }
        if let focalText { pairs.append(("焦距", focalText)) }
        if let apertureText { pairs.append(("光圈", apertureText)) }
        if let shutterText { pairs.append(("快门", shutterText)) }
        if let isoText { pairs.append(("感光度", isoText)) }
        if let megapixelText { pairs.append(("尺寸", megapixelText)) }
        if let dateTimeOriginal {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            pairs.append(("拍摄时间", formatter.string(from: dateTimeOriginal)))
        }
        return pairs
    }

    /// 是否有任何真实可显示的参数
    var hasAnyValue: Bool { !keyValuePairs.isEmpty }
}

// MARK: - 闭眼判定

enum ClosedEyeRisk: String, Codable, Hashable {
    case notAnalyzed
    case noFaceDetected
    case open
    case uncertain
    case suspectedClosed

    var title: String {
        switch self {
        case .notAnalyzed: return "未分析"
        case .noFaceDetected: return "未检测到人脸"
        case .open: return "眼睛张开"
        case .uncertain: return "无法确定"
        case .suspectedClosed: return "疑似闭眼"
        }
    }

    /// 说明这项判定的可靠程度 —— 闭眼检测基于脸部特征点几何比例，属于启发式
    var caveat: String {
        switch self {
        case .notAnalyzed: return "尚未分析"
        case .noFaceDetected: return "画面中未检测到可用的人脸，无法判断"
        case .open: return "基于眼部特征点比例判定，可靠性中等"
        case .uncertain: return "特征点置信度不足，建议人工放大确认"
        case .suspectedClosed: return "基于眼部特征点比例判定，属启发式结果，请人工确认后再剔除"
        }
    }
}

// MARK: - 单张照片的分析结果

struct PhotoAnalysisSummary: Codable, Hashable {
    /// 清晰度评分（0...1，来自拉普拉斯方差的归一化结果，由像素真实计算）
    var sharpnessScore: Double
    var sharpnessLabel: String
    /// 平均亮度（0...1）
    var brightness: Double
    var exposureLabel: String
    /// 对比度（标准差归一化）
    var contrast: Double
    var closedEyeRisk: ClosedEyeRisk
    var faceCount: Int
    var personCount: Int
    var poseFindings: [String]
    var compositionFindings: [String]
    var compositionScore: Double
    /// 筛选建议
    var suggestions: [String]
    /// 综合推荐度（0...100）
    var overallScore: Double
    var analyzedAt: Date

    var sharpnessLevel: FindingLevel {
        if sharpnessScore >= 0.55 { return .good }
        if sharpnessScore >= 0.3 { return .info }
        if sharpnessScore >= 0.15 { return .attention }
        return .warning
    }
}

// MARK: - App 内照片记录

/// App 内的一条照片记录。
///
/// 重要设计：LUMI 通过照片选择器读取你**主动挑选**的照片，并把一份**副本**存进 App 沙盒。
/// 所有分析、收藏、标签、删除都只作用于这条记录与副本，
/// **永远不会删除或修改相册中的原始照片**。
struct PhotoRecord: Identifiable, Codable, Hashable {
    var id: UUID
    var fileName: String
    var originalName: String?
    var importedAt: Date
    var captureDate: Date?
    var isFavorite: Bool
    var sceneTag: PoseScene?
    var exif: ExifSummary?
    var analysis: PhotoAnalysisSummary?
    var byteSize: Int

    init(id: UUID = UUID(),
         fileName: String,
         originalName: String? = nil,
         importedAt: Date = Date(),
         captureDate: Date? = nil,
         isFavorite: Bool = false,
         sceneTag: PoseScene? = nil,
         exif: ExifSummary? = nil,
         analysis: PhotoAnalysisSummary? = nil,
         byteSize: Int = 0) {
        self.id = id
        self.fileName = fileName
        self.originalName = originalName
        self.importedAt = importedAt
        self.captureDate = captureDate
        self.isFavorite = isFavorite
        self.sceneTag = sceneTag
        self.exif = exif
        self.analysis = analysis
        self.byteSize = byteSize
    }

    /// 用于分组/排序的日期：优先使用拍摄时间，缺失时退回导入时间
    var sortDate: Date { captureDate ?? importedAt }

    var displayName: String { originalName ?? fileName }

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: Int64(byteSize), countStyle: .file)
    }
}

// MARK: - 照片筛选建议（顶层结论）

enum ScreeningVerdict: String, Hashable {
    case keep
    case review
    case considerDiscard

    var title: String {
        switch self {
        case .keep: return "建议保留"
        case .review: return "建议人工复核"
        case .considerDiscard: return "可考虑剔除"
        }
    }
}
