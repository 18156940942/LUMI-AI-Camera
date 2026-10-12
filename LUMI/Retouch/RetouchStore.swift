import Foundation
import Combine

/// 一条精修结果记录（持久化用）。
struct RetouchRecord: Codable, Hashable {
    var photoID: UUID
    var presetID: String
    var fileName: String
    var finishedAt: Date
    /// 实际执行方，由中继在响应头回传（`local` / `cloud:xxx`）。
    var provider: String
    var byteSize: Int
}

/// 精修队列与结果存储。
///
/// ## 为什么用独立存储、不改 `PhotoRecord`
///
/// `PhotoRecord` 被 `PhotoLibraryStore` 序列化进 `index.json`。给它加**非可选**字段
/// 会让已经存在的 `index.json` 解码失败 —— 那等于把用户已有的照片索引弄丢。
/// 所以精修结果单独存一份索引，两者通过 `photoID` 关联。
///
/// ## 状态语义
///
/// 每张照片的精修状态只有四种（见 ``RetouchJobState``）。**没有「假的成功」**：
/// 中继连不上、出错、或者返回的不是图片，都会落到 `.failed` 并带上可读原因。
/// - Note: **不要在类级别加 `@MainActor`。**
///   `AppState` 把它作为 `init` 的默认参数构造，而 `AppState.init` 不是 main actor
///   隔离的 —— 类级隔离会让 `init(directory:)` 变成 main-actor 隔离，
///   于是编译直接报「call to main actor-isolated initializer in a synchronous
///   nonisolated context」。本项目的约定是：**Store 类不加类级隔离，只给需要
///   在主线程序列化访问的方法加 `@MainActor`**（`PhotoLibraryStore` 也是这样）。
final class RetouchStore: ObservableObject {

    /// 每张照片当前状态。界面上直接读它。
    @Published private(set) var states: [UUID: RetouchJobState] = [:]

    /// 最近的提示语（成功/失败都写这里，避免界面各处各写一套）。
    @Published private(set) var lastMessage: String?

    /// 正在排队或执行的数量，用于进度显示。
    @Published private(set) var runningCount: Int = 0

    /// 强度 0…100。用户可调，会随请求发给中继。
    @Published var intensity: Int = 60

    private let directory: URL
    private let indexURL: URL
    private let client = RetouchClient()
    private var records: [UUID: RetouchRecord] = [:]

    // MARK: - 初始化

    init(directory: URL? = nil) {
        let base: URL
        if let directory {
            base = directory
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                   in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            base = support.appendingPathComponent("LUMIRetouch", isDirectory: true)
        }
        self.directory = base
        self.indexURL = base.appendingPathComponent("index.json")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        loadIndex()
    }

    // MARK: - 查询

    func state(for photoID: UUID) -> RetouchJobState {
        states[photoID] ?? .idle
    }

    func record(for photoID: UUID) -> RetouchRecord? {
        records[photoID]
    }

    func isRetouched(_ photoID: UUID) -> Bool {
        records[photoID] != nil
    }

    /// 已有精修结果的照片数量（只读统计，供设置页展示）。
    var retouchedCount: Int {
        records.count
    }

    /// 精修结果的本地路径。没有结果时返回 nil —— 调用方据此决定显示原图。
    func resultURL(for photoID: UUID) -> URL? {
        guard let record = records[photoID] else { return nil }
        let url = directory.appendingPathComponent(record.fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// 结果文件是否存在且可读。索引有记录但文件被删时不该假装还有结果。
    func hasUsableResult(for photoID: UUID) -> Bool {
        resultURL(for: photoID) != nil
    }

    // MARK: - 索引持久化

    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        guard let list = try? JSONDecoder().decode([RetouchRecord].self, from: data) else {
            // 解析失败不阻断启动：精修结果丢了比整个照片库打不开要好得多
            DiagnosticsLog.shared.error(.photo, "精修索引解析失败，本次以空索引启动")
            return
        }
        records = Dictionary(uniqueKeysWithValues: list.map { ($0.photoID, $0) })
    }

    private func saveIndex() {
        let list = records.values.sorted { $0.finishedAt > $1.finishedAt }
        guard let data = try? JSONEncoder().encode(list) else { return }
        do {
            try data.write(to: indexURL, options: .atomic)
        } catch {
            DiagnosticsLog.shared.error(.photo, "精修索引写入失败: \(error.localizedDescription)")
        }
    }

    // MARK: - 执行

    /// 对单张照片执行一次精修。
    ///
    /// - Parameters:
    ///   - photoID: 关联的照片
    ///   - sourceData: 原图 JPEG 数据（不再经过任何转码，避免二次损失）
    ///   - preset: 要用的预设
    ///   - relayBase: 已规范化过的中继地址
    ///   - prompt: 生成式改动的文字指令
    /// - Returns: 成功与否（界面可以据此继续批处理）
    @MainActor
    @discardableResult
    func retouch(photoID: UUID,
                 sourceData: Data,
                 preset: RetouchPreset,
                 relayBase: URL,
                 prompt: String? = nil) async -> Bool {

        states[photoID] = .running(presetID: preset.id)
        runningCount += 1
        defer {
            runningCount = max(0, runningCount - 1)
        }

        DiagnosticsLog.shared.info(.photo,
            "开始精修 [\(preset.id)]，源图 \(sourceData.count) 字节")

        let request = RetouchRequest(imageData: sourceData,
                                     preset: preset,
                                     prompt: prompt,
                                     intensity: intensity)

        do {
            let result = try await client.retouch(request, relayBase: relayBase)

            let fileName = "\(photoID.uuidString)-\(Self.safeFileName(preset.id)).jpg"
            let destination = directory.appendingPathComponent(fileName)
            try result.imageData.write(to: destination, options: .atomic)

            let record = RetouchRecord(photoID: photoID,
                                       presetID: preset.id,
                                       fileName: fileName,
                                       finishedAt: Date(),
                                       provider: result.provider,
                                       byteSize: result.imageData.count)
            records[photoID] = record
            saveIndex()

            states[photoID] = .succeeded(presetID: preset.id,
                                         finishedAt: record.finishedAt,
                                         provider: result.provider)

            let elapsed = result.elapsedMilliseconds.map { "，耗时 \($0) ms" } ?? ""
            lastMessage = "「\(preset.title)」完成\(elapsed)（执行方：\(result.provider)）"
            DiagnosticsLog.shared.info(.photo,
                "精修完成 [\(preset.id)]，结果 \(result.imageData.count) 字节，执行方 \(result.provider)")
            return true

        } catch let error as RetouchClientError {
            states[photoID] = .failed(presetID: preset.id,
                                      message: error.errorDescription ?? "未知错误")
            lastMessage = error.errorDescription
            DiagnosticsLog.shared.error(.photo, "精修失败 [\(preset.id)]: \(error)")
            return false

        } catch {
            states[photoID] = .failed(presetID: preset.id,
                                      message: error.localizedDescription)
            lastMessage = error.localizedDescription
            DiagnosticsLog.shared.error(.photo, "精修失败 [\(preset.id)]: \(error)")
            return false
        }
    }

    /// 丢掉某张照片的精修结果（保留原图，不影响照片本身）。
    @MainActor
    func clearResult(for photoID: UUID) {
        guard let record = records.removeValue(forKey: photoID) else { return }
        let url = directory.appendingPathComponent(record.fileName)
        try? FileManager.default.removeItem(at: url)
        states[photoID] = .idle
        saveIndex()
        lastMessage = "已删除这张照片的精修副本（原图不受影响）"
    }

    /// 清掉所有精修结果。
    @MainActor
    func clearAllResults() {
        for record in records.values {
            try? FileManager.default.removeItem(
                at: directory.appendingPathComponent(record.fileName))
        }
        records.removeAll()
        states = states.mapValues { _ in .idle }
        saveIndex()
        lastMessage = "已删除全部精修副本（原图不受影响）"
    }

    /// 清掉所有状态（切库或重置时用）。
    @MainActor
    func resetStates() {
        states.removeAll()
        runningCount = 0
    }

    /// 报告一个发生在本地、还没到网络阶段的问题（例如读不到源图）。
    ///
    /// 单独开一个方法而不是把 `lastMessage` 放成可写：提示语是这个类型的对外
    /// 一致性来源，不应该让每个调用方随手改。
    @MainActor
    func reportLocalProblem(_ message: String) {
        lastMessage = message
        DiagnosticsLog.shared.error(.photo, "精修本地问题：\(message)")
    }

    // MARK: - 纯函数

    /// 把预设 id 转成安全的文件名片段。
    ///
    /// 预设 id 形如 `enhance.auto`，含点号。这里把非字母数字统一换成下划线，
    /// 避免出现路径分隔符或平台非法字符 —— 文件名是从外部数据拼出来的，
    /// 必须当作不可信输入处理。
    static func safeFileName(_ presetID: String) -> String {
        var out = ""
        for character in presetID {
            if character.isLetter || character.isNumber {
                out.append(character)
            } else {
                out.append("_")
            }
        }
        return out.isEmpty ? "preset" : out
    }
}
