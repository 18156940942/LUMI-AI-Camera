import Foundation

// MARK: - 精修类别

/// 精修类别。
///
/// `rawValue` 必须与 `LUMI/Resources/retouch_presets.json` 里 `categories[].id` 完全一致，
/// `scripts/preflight.py` 会校验这一点（与姿势库同一套做法）。
///
/// **这里刻意只放「行为」与「图标」，不放展示文案** —— 标题与说明来自 JSON，
/// 避免同一句话在代码和数据里各写一份然后慢慢漂移。
enum RetouchCategory: String, Codable, CaseIterable, Identifiable, Hashable {

    /// 画质增强：只按像素统计处理亮度/对比/细节，不改变画面内容。
    case enhance

    /// 风格化调色：整体影调与色彩方向，仍然只改色不改内容。
    case grade

    /// 人像美化：皮肤与面部的局部处理。
    case portrait

    /// 生成式改动：**会改变画面内容**，必须由云端模型完成。
    case generative

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .enhance: return "wand.and.rays"
        case .grade: return "camera.filters"
        case .portrait: return "person.crop.circle.badge.checkmark"
        case .generative: return "sparkles"
        }
    }

    /// 是否必须联网。
    ///
    /// 前三类都能在电脑端用确定性算法算出来（更快、免费、可复现、不上传）；
    /// 只有生成式改动需要真的调用云端模型，因为它的本质是「重绘内容」，
    /// 本地算法做不到，也不该假装能做到。
    var requiresCloud: Bool {
        self == .generative
    }

    /// 万一目录没加载出来时的兜底标题（正常情况下用 JSON 里的文案）。
    var fallbackTitle: String {
        switch self {
        case .enhance: return "画质增强"
        case .grade: return "风格化调色"
        case .portrait: return "人像美化"
        case .generative: return "生成式改动"
        }
    }
}

// MARK: - 执行位置

/// 一条精修实际在哪里算。
///
/// 注意：**手机端不区分这个** —— 所有精修都发给电脑端中继，由中继决定是本地算还是调云端。
/// 这个枚举是给界面标注用的，让用户知道「这一条会不会上传到云端」。
enum RetouchEngine: String, Codable, Hashable {
    case local
    case cloud

    var title: String {
        switch self {
        case .local: return "本地计算"
        case .cloud: return "云端处理"
        }
    }

    var symbolName: String {
        switch self {
        case .local: return "desktopcomputer"
        case .cloud: return "cloud"
        }
    }
}

// MARK: - 目录数据模型

/// 一个类别的展示信息（来自 JSON）。
struct RetouchCategoryInfo: Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var summary: String

    /// 映射回强类型枚举；JSON 里出现未知类别时为 nil（预检会拦住这种情况）。
    var category: RetouchCategory? { RetouchCategory(rawValue: id) }
}

/// 一条精修预设（来自 JSON）。
struct RetouchPreset: Codable, Hashable, Identifiable {
    var id: String
    var category: RetouchCategory
    var title: String
    var detail: String
    var engine: RetouchEngine
    /// 生成式改动需要用户填写文字指令。
    var requiresPrompt: Bool
}

/// 预设目录：手机端与电脑端中继共读同一份 `retouch_presets.json`。
struct RetouchPresetCatalog: Codable, Hashable {
    var version: Int
    var note: String?
    var categories: [RetouchCategoryInfo]
    var presets: [RetouchPreset]

    func presets(in category: RetouchCategory) -> [RetouchPreset] {
        presets.filter { $0.category == category }
    }

    func preset(withID id: String) -> RetouchPreset? {
        presets.first { $0.id == id }
    }

    func info(for category: RetouchCategory) -> RetouchCategoryInfo? {
        categories.first { $0.id == category.rawValue }
    }
}

// MARK: - 加载

enum RetouchCatalogError: Error, LocalizedError {
    case missingResource
    case decodeFailed(String)
    case empty

    var errorDescription: String? {
        switch self {
        case .missingResource:
            return "App 包里找不到 retouch_presets.json（工程未把资源挂进 Copy Bundle Resources）"
        case .decodeFailed(let detail):
            return "精修预设目录解析失败：\(detail)"
        case .empty:
            return "精修预设目录里没有任何预设"
        }
    }
}

/// 目录加载器。
///
/// 刻意拆成「纯函数 decode」+「从 Bundle 取数据」两层：
/// 纯函数部分可以在没有 App 运行时的情况下写单元测试。
enum RetouchCatalogLoader {

    /// 纯函数：只负责解析。测试直接用这个。
    static func decode(_ data: Data) throws -> RetouchPresetCatalog {
        do {
            let catalog = try JSONDecoder().decode(RetouchPresetCatalog.self, from: data)
            guard !catalog.presets.isEmpty else { throw RetouchCatalogError.empty }
            return catalog
        } catch let error as RetouchCatalogError {
            throw error
        } catch {
            throw RetouchCatalogError.decodeFailed(String(describing: error))
        }
    }

    static func loadFromBundle(_ bundle: Bundle = .main) throws -> RetouchPresetCatalog {
        guard let url = bundle.url(forResource: "retouch_presets", withExtension: "json") else {
            throw RetouchCatalogError.missingResource
        }
        return try decode(try Data(contentsOf: url))
    }
}

// MARK: - 单张照片的精修状态

/// 一张照片的精修任务状态。
///
/// **这里没有 `.fake` / `.pretend` 这类状态是刻意的**：拿不到结果就是 `.failed`，
/// 绝不出现「看起来成功了但其实是占位图」的情况。
enum RetouchJobState: Equatable, Hashable {
    /// 还没做过精修
    case idle
    /// 正在上传并等待结果
    case running(presetID: String)
    /// 成功，结果已落盘
    case succeeded(presetID: String, finishedAt: Date, provider: String)
    /// 失败，附带可读原因
    case failed(presetID: String, message: String)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    var presetID: String? {
        switch self {
        case .idle: return nil
        case .running(let id): return id
        case .succeeded(let id, _, _): return id
        case .failed(let id, _): return id
        }
    }

    var shortLabel: String {
        switch self {
        case .idle: return "未精修"
        case .running: return "处理中"
        case .succeeded: return "已精修"
        case .failed: return "失败"
        }
    }
}

// MARK: - 配置

/// 精修相关设置（持久化在 UserDefaults）。
///
/// **默认关闭，这是刻意的。** 这个功能会把照片发给电脑端中继（生成式改动还会
/// 继续发往云端），和本项目「照片不出设备」的默认立场相反，所以必须由用户
/// 主动打开，并且打开前能看懂会发生什么。
struct RetouchConfiguration: Codable, Hashable {

    /// 总开关。关闭时界面上所有精修入口都会说明「未开启」，不会静默做任何事。
    var isEnabled: Bool

    /// 电脑端中继地址（用户自己填，形如 `http://172.20.10.8:8091`）。
    var relayURL: String

    /// 默认预设（导入后一键精修时用哪一条）。
    var defaultPresetID: String?

    /// 生成式改动的文字指令。存在本机，随请求发给中继。
    var generativePrompt: String

    static let `default` = RetouchConfiguration(
        isEnabled: false,
        relayURL: "",
        defaultPresetID: "enhance.auto",
        generativePrompt: ""
    )

    /// 规范化后的中继地址。nil 表示「还没填」或「填得不合法」——
    /// 两种情况在界面上要明确区分，不能混成一句「失败」。
    var normalizedRelayURL: URL? {
        RetouchClient.normalizeRelayURL(relayURL)
    }

    /// 能不能真的发起精修：开关打开 **且** 地址合法。
    var isReady: Bool {
        isEnabled && normalizedRelayURL != nil
    }

    /// 给界面用的一句话状态。真实反映当前能不能工作。
    var statusText: String {
        if !isEnabled { return "未开启" }
        if relayURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "已开启，但还没填中继地址"
        }
        if normalizedRelayURL == nil { return "已开启，但地址不合法" }
        return "已开启"
    }
}

// MARK: - 客户端错误

enum RetouchClientError: Error, LocalizedError, Equatable {
    /// 没配中继地址
    case notConfigured
    /// 中继地址不合法
    case invalidURL(String)
    /// 连不上中继
    case unreachable(String)
    /// 中继返回了业务错误
    case relayRejected(code: String, message: String)
    /// 中继返回的不是图片
    case malformedResponse(String)
    /// 生成式改动但没填文字指令
    case missingPrompt

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "还没配置电脑端中继地址。请到「设置 → 云端精修」填入电脑上脚本打印的地址。"
        case .invalidURL(let raw):
            return "中继地址不合法：\(raw)"
        case .unreachable(let detail):
            return "连不上中继：\(detail)"
        case .relayRejected(let code, let message):
            return "中继拒绝了这个请求（\(code)）：\(message)"
        case .malformedResponse(let detail):
            return "中继的响应不是有效图片：\(detail)"
        case .missingPrompt:
            return "这条预设需要填写文字指令描述你想要的改动。"
        }
    }

    /// 是否值得让用户重试（网络类问题值得，业务类问题不值得）。
    var isRetryable: Bool {
        switch self {
        case .unreachable: return true
        default: return false
        }
    }
}
