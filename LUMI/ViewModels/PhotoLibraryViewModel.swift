import Foundation
import Combine

/// 照片管理页的视图模型。
final class PhotoLibraryViewModel: ObservableObject {

    enum Grouping: String, CaseIterable, Identifiable {
        case date
        case scene
        case favorites
        case review

        var id: String { rawValue }

        var title: String {
            switch self {
            case .date: return "按日期"
            case .scene: return "按场景"
            case .favorites: return "收藏"
            case .review: return "待复核"
            }
        }
    }

    struct PhotoGroup: Identifiable {
        let id: String
        let title: String
        let records: [PhotoRecord]
    }

    @Published var grouping: Grouping = .date
    /// 待删除记录（点删除后先进入确认流程，不直接删）
    @Published var pendingDeletion: PhotoRecord?
    @Published var pendingBatchDeletion: [PhotoRecord] = []
    @Published var showsDeleteAllConfirmation = false
    @Published var importMessage: String?

    func groups(from store: PhotoLibraryStore) -> [PhotoGroup] {
        switch grouping {
        case .date:
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "yyyy 年 M 月 d 日"
            return store.groupedByDate.map { entry in
                PhotoGroup(id: "date-\(entry.date.timeIntervalSince1970)",
                           title: formatter.string(from: entry.date),
                           records: entry.records)
            }

        case .scene:
            return store.groupedByScene.map { entry in
                PhotoGroup(id: "scene-\(entry.scene?.rawValue ?? "untagged")",
                           title: entry.scene?.title ?? "未分类",
                           records: entry.records)
            }

        case .favorites:
            let favorites = store.favorites
            return favorites.isEmpty ? [] : [PhotoGroup(id: "favorites", title: "已收藏", records: favorites)]

        case .review:
            let review = store.needsReview
            return review.isEmpty ? [] : [PhotoGroup(id: "review", title: "需要人工复核", records: review)]
        }
    }

    /// 删除确认文案：把「删什么、不删什么」写清楚
    func deletionMessage(for records: [PhotoRecord]) -> String {
        if records.count == 1 {
            return """
            LUMI 会删除这份 App 内的副本文件、分析结果与标签记录：\(records[0].displayName)。

            ⚠️ 相册中的原始照片不会被删除，也不会被修改。\
            LUMI 没有、也不会对系统相册发起任何删除操作。
            """
        }
        return """
        LUMI 会删除这 \(records.count) 张照片在 App 内的副本文件与分析记录。

        ⚠️ 相册中的原始照片不会被删除，也不会被修改。
        """
    }
}
