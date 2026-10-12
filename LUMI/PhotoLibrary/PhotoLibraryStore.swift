import Foundation
import UIKit
import ImageIO
import Combine

/// App 内照片库。
///
/// **数据边界（非常重要）**
/// - 只处理用户通过系统照片选择器**主动挑选**的照片；
/// - 导入时在 App 沙盒内保存一份**副本**，后续所有分析、收藏、标签、删除都作用于这份副本；
/// - **永远不会删除、修改或覆盖相册里的原始照片**（本类型内没有任何 PhotoKit 的删除调用）；
/// - 不读取相机存储卡，也不声称能读取尚未传输到 iPhone 的照片 ——
///   照片必须先出现在系统相册（相机 Wi-Fi/读卡器/USB 传输入库）才能被选择器选中。
final class PhotoLibraryStore: ObservableObject {

    @Published private(set) var records: [PhotoRecord] = []
    @Published private(set) var isImporting = false
    @Published private(set) var analyzingRecordIDs: Set<UUID> = []
    @Published private(set) var lastError: String?
    @Published private(set) var lastImportMessage: String?

    private let directory: URL
    private let indexURL: URL
    private let thumbnailCache = NSCache<NSString, UIImage>()

    // MARK: - 初始化

    init(directory: URL? = nil) {
        let base: URL
        if let directory {
            base = directory
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            base = support.appendingPathComponent("LUMIPhotos", isDirectory: true)
        }
        self.directory = base
        self.indexURL = base.appendingPathComponent("index.json")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        thumbnailCache.countLimit = 120
        loadIndex()
    }

    // MARK: - 索引持久化

    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexURL) else {
            records = []
            return
        }
        do {
            records = try JSONDecoder().decode([PhotoRecord].self, from: data)
            records.sort { $0.sortDate > $1.sortDate }
        } catch {
            DiagnosticsLog.shared.error(.photo, "照片索引解析失败: \(String(describing: error))")
            lastError = "照片索引读取失败：\(error.localizedDescription)"
            records = []
        }
    }

    private func saveIndex() {
        do {
            let data = try JSONEncoder().encode(records)
            try data.write(to: indexURL, options: .atomic)
        } catch {
            DiagnosticsLog.shared.error(.photo, "照片索引写入失败: \(String(describing: error))")
            lastError = "照片索引保存失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 文件

    func fileURL(for record: PhotoRecord) -> URL {
        directory.appendingPathComponent(record.fileName)
    }

    func image(for record: PhotoRecord, maxPixel: CGFloat = 1600) -> UIImage? {
        let key = "\(record.id.uuidString)-\(Int(maxPixel))" as NSString
        if let cached = thumbnailCache.object(forKey: key) { return cached }
        guard let image = Self.downsampledImage(at: fileURL(for: record), maxPixel: maxPixel) else { return nil }
        thumbnailCache.setObject(image, forKey: key)
        return image
    }

    /// 用 ImageIO 直接做降采样解码，避免把整张 2400 万像素原图读进内存。
    static func downsampledImage(at url: URL, maxPixel: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    // MARK: - 导入

    /// 从照片选择器导入。返回成功导入的数量。
    @MainActor
    func importItems(_ items: [PhotosPickerItemWrapper]) async -> Int {
        guard !items.isEmpty else { return 0 }
        isImporting = true
        defer { isImporting = false }

        var imported = 0
        var failed = 0

        for item in items {
            do {
                guard let data = try await item.loadData() else {
                    failed += 1
                    continue
                }
                let record = try importData(data, originalName: item.suggestedName, analyzeImmediately: true)
                records.insert(record, at: 0)
                imported += 1
            } catch {
                failed += 1
                DiagnosticsLog.shared.error(.photo, "导入失败: \(error.localizedDescription)")
            }
        }

        records.sort { $0.sortDate > $1.sortDate }
        saveIndex()

        lastImportMessage = "已导入 \(imported) 张照片副本到 LUMI"
            + (failed > 0 ? "，\(failed) 张失败（可能是格式不支持或未完成下载）" : "")
            + "。原始照片未被修改。"
        return imported
    }

    /// 写入一份副本并立即分析（分析在后台线程完成）
    @discardableResult
    func importData(_ data: Data, originalName: String?, analyzeImmediately: Bool = true) throws -> PhotoRecord {
        let identifier = UUID()
        let fileName = identifier.uuidString + ".jpg"
        let destination = directory.appendingPathComponent(fileName)

        // 统一转成 JPEG 副本，既压缩体积又保证后续解码路径一致。
        // 若数据本身已经是不支持解码的格式，这里会抛错，不会写入半成品。
        guard let uniformData = Self.uniformJPEGData(from: data) else {
            throw PhotoLibraryError.undecodableData
        }
        try uniformData.write(to: destination, options: .atomic)

        let exif = ExifReader.read(from: uniformData)

        var record = PhotoRecord(id: identifier,
                                 fileName: fileName,
                                 originalName: originalName,
                                 importedAt: Date(),
                                 captureDate: exif?.dateTimeOriginal,
                                 isFavorite: false,
                                 sceneTag: nil,
                                 exif: exif,
                                 analysis: nil,
                                 byteSize: uniformData.count)

        if analyzeImmediately, let result = PhotoAnalyzer.analyze(data: uniformData, importedAt: Date()) {
            record.analysis = result.summary
            record.exif = result.exif ?? record.exif
            if let date = result.exif?.dateTimeOriginal { record.captureDate = date }
        }
        return record
    }

    /// 把任意可解码的图片数据统一转写为 JPEG（保留 EXIF 中的拍摄日期与机身信息）
    static func uniformJPEGData(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let uti = CGImageSourceGetType(source) else { return nil }
        // 已经是 JPEG 且带完整元数据时直接复用，避免二次转码损失
        if uti as String == "public.jpeg" {
            return data
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else {
            return nil
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary?)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    // MARK: - 分析

    func analyze(recordID: UUID) {
        guard let record = records.first(where: { $0.id == recordID }) else { return }
        analyzingRecordIDs.insert(recordID)
        let url = fileURL(for: record)

        Task.detached(priority: .userInitiated) { [weak self] in
            let result: PhotoAnalyzer.Result?
            if let data = try? Data(contentsOf: url) {
                result = PhotoAnalyzer.analyze(data: data, importedAt: Date())
            } else {
                result = nil
            }
            await MainActor.run {
                guard let self else { return }
                self.analyzingRecordIDs.remove(recordID)
                guard let result else {
                    self.lastError = "无法读取「\(record.displayName)」的文件副本，分析已跳过。"
                    return
                }
                if let index = self.records.firstIndex(where: { $0.id == recordID }) {
                    self.records[index].analysis = result.summary
                    if let exif = result.exif { self.records[index].exif = exif }
                    self.saveIndex()
                }
            }
        }
    }

    func analyzeAll() {
        for record in records {
            analyze(recordID: record.id)
        }
    }

    // MARK: - 收藏 / 标签 / 删除

    func toggleFavorite(recordID: UUID) {
        guard let index = records.firstIndex(where: { $0.id == recordID }) else { return }
        records[index].isFavorite.toggle()
        saveIndex()
    }

    func setScene(_ scene: PoseScene?, for recordID: UUID) {
        guard let index = records.firstIndex(where: { $0.id == recordID }) else { return }
        records[index].sceneTag = scene
        saveIndex()
    }

    /// 删除 App 内记录。
    ///
    /// - Parameters:
    ///   - removeFile: 是否同时删除沙盒内的副本文件（默认 true）。
    /// - Important: 这里**只操作 App 沙盒**，相册中的原始照片不受任何影响。
    func delete(recordID: UUID, removeFile: Bool = true) {
        guard let index = records.firstIndex(where: { $0.id == recordID }) else { return }
        let record = records[index]
        if removeFile {
            try? FileManager.default.removeItem(at: fileURL(for: record))
            thumbnailCache.removeAllObjects()
        }
        records.remove(at: index)
        saveIndex()
    }

    /// 批量删除 App 内记录（UI 必须先让用户确认范围）
    func delete(recordIDs: [UUID], removeFile: Bool = true) {
        for id in recordIDs {
            delete(recordID: id, removeFile: removeFile)
        }
    }

    /// 清空 App 内全部记录与副本
    func deleteAll() {
        for record in records {
            try? FileManager.default.removeItem(at: fileURL(for: record))
        }
        thumbnailCache.removeAllObjects()
        records.removeAll()
        saveIndex()
    }

    // MARK: - 分组与查询

    /// 按日期分组（同一天归为一组，按时间倒序）
    var groupedByDate: [(date: Date, records: [PhotoRecord])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: records) { record -> Date in
            let components = calendar.dateComponents([.year, .month, .day], from: record.sortDate)
            return calendar.date(from: components) ?? record.sortDate
        }
        return grouped
            .map { (date: $0.key, records: $0.value.sorted { $0.sortDate > $1.sortDate }) }
            .sorted { $0.date > $1.date }
    }

    /// 按拍摄场景分类（未标注的归入「未分类」）
    var groupedByScene: [(scene: PoseScene?, records: [PhotoRecord])] {
        var result: [(scene: PoseScene?, records: [PhotoRecord])] = []
        for scene in PoseScene.allCases {
            let matched = records.filter { $0.sceneTag == scene }
            if !matched.isEmpty {
                result.append((scene: scene, records: matched.sorted { $0.sortDate > $1.sortDate }))
            }
        }
        let untagged = records.filter { $0.sceneTag == nil }
        if !untagged.isEmpty {
            result.append((scene: nil, records: untagged.sorted { $0.sortDate > $1.sortDate }))
        }
        return result
    }

    var favorites: [PhotoRecord] {
        records.filter(\.isFavorite).sorted { $0.sortDate > $1.sortDate }
    }

    /// 需要人工复核的照片（疑似闭眼 / 分数处于中间区间）
    var needsReview: [PhotoRecord] {
        records.filter { record in
            guard let analysis = record.analysis else { return false }
            return PhotoAnalyzer.verdict(for: analysis) != .keep
        }
    }

    func record(withID id: UUID) -> PhotoRecord? {
        records.first { $0.id == id }
    }
}

enum PhotoLibraryError: LocalizedError {
    case undecodableData

    var errorDescription: String? {
        switch self {
        case .undecodableData:
            return "该文件无法解码为图片（可能是 HEIF/RAW 等需要额外解码器的格式，或文件未完整下载）。"
        }
    }
}

// MARK: - 照片选择器包装

/// 对 `PhotosPickerItem` 的轻量包装。
///
/// 这样做的好处：``PhotoLibraryStore`` 不直接依赖 SwiftUI/PhotosUI，
/// 因此可以在单元测试里注入假数据，也便于将来换用别的方式取照片。
struct PhotosPickerItemWrapper {
    let suggestedName: String?
    private let loader: () async throws -> Data?

    init(suggestedName: String?, loader: @escaping () async throws -> Data?) {
        self.suggestedName = suggestedName
        self.loader = loader
    }

    func loadData() async throws -> Data? {
        try await loader()
    }
}
