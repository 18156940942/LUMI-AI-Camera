import Foundation
import Photos

/// 把图片写入系统相册。
///
/// ## 数据边界（与本项目其它部分保持一致）
/// - 只申请**「仅添加」权限**（`.addOnly`），不申请读权限 ——
///   所以本类型拿不到、也不会遍历你的相册，只能往里新增；
/// - 写入是**新增一张**，不会覆盖、不会删除、不会修改任何已有照片；
/// - 直接以文件 URL 作为相册资源写入，**不经过 `UIImage` 重新编码**，
///   因此原图的像素与 EXIF 保持原样，不会被二次压缩。
///
/// ## 为什么导出时要显式传 `creationDate`
/// 不传的话，相册会把这张照片记为「导出那一刻」，于是它排到时间轴最前面，
/// 而不是它真正的拍摄位置 —— 导出几张就会把相册顺序搅乱。所以调用方应当
/// 把原图的拍摄时间传进来（见 `PhotoDetailView` / `RetouchView`）。
enum PhotoExporter {

    // MARK: - 失败原因

    /// 导出失败的分类。
    ///
    /// 刻意不做成 `Bool`：这几种失败的处理方式完全不同 ——
    /// 权限被拒要去系统设置改，文件没了只能承认，写入失败可以重试。
    /// 把它们混成一句「导出失败」等于什么都没告诉用户。
    enum Failure: LocalizedError, Equatable {
        case permissionDenied
        case permissionRestricted
        case fileMissing(String)
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "没有相册写入权限。到「设置 → 隐私与安全性 → 照片 → LUMI」改成「添加照片」后重试。"
            case .permissionRestricted:
                return "系统限制了相册访问（通常是开了「屏幕使用时间」的内容与隐私限制），无法导出。"
            case .fileMissing(let name):
                return "文件读不到：\(name)。它可能已经被删掉了。"
            case .writeFailed(let reason):
                return "写入相册失败：\(reason)"
            }
        }
    }

    // MARK: - 权限

    /// 当前的写入权限（不弹窗，可以直接在界面上显示）。
    static var authorizationStatus: PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .addOnly)
    }

    /// 是否还没问过用户。首次导出前需要先弹一次系统授权框。
    static var needsAuthorizationRequest: Bool {
        authorizationStatus == .notDetermined
    }

    /// 把权限状态翻译成一句人话（设置页与导出结果都要显示同一个说法）。
    static func describe(_ status: PHAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "已允许添加照片"
        case .limited: return "已允许（受限）"
        case .denied: return "已拒绝"
        case .restricted: return "被系统限制"
        case .notDetermined: return "尚未询问"
        @unknown default: return "未知状态"
        }
    }

    /// 只在还没问过时弹窗；已经有结论就直接返回，不重复打扰用户。
    @discardableResult
    static func ensureAccess() async -> PHAuthorizationStatus {
        let status = authorizationStatus
        guard status == .notDetermined else { return status }
        return await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    }

    // MARK: - 写入

    /// 把本地图片文件写入相册（**新增一张**，不改动任何已有照片）。
    ///
    /// - Parameters:
    ///   - url: 本地 JPEG 文件路径（App 沙盒里的原图副本或精修结果）
    ///   - creationDate: 写进相册后显示的时间；传原图的拍摄时间可以让相册排序正确
    /// - Throws: ``Failure``
    static func save(at url: URL, creationDate: Date? = nil) async throws {
        // 先查文件再看权限：文件不存在是本地问题，没必要先弹一次授权框
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw Failure.fileMissing(url.lastPathComponent)
        }

        switch await ensureAccess() {
        case .authorized, .limited:
            break
        case .restricted:
            throw Failure.permissionRestricted
        default:
            throw Failure.permissionDenied
        }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.creationDate = creationDate

                let options = PHAssetResourceCreationOptions()
                // 源文件留在 App 沙盒里 —— 导出是复制，不是搬运。
                // 设成 true 的话相册会「吃掉」这份文件，App 内的照片就没了。
                options.shouldMoveFile = false
                options.originalFilename = url.lastPathComponent

                request.addResource(with: .photo, fileURL: url, options: options)
            }
        } catch {
            throw Failure.writeFailed(error.localizedDescription)
        }
    }

    /// 一次导出多张，返回逐张的结果。
    ///
    /// 不因为某一张失败就中断整批 —— 导出是用户可见的动作，
    /// 「3 张成功、1 张失败并说明原因」比「整个失败」有用得多。
    static func saveAll(_ urls: [URL], creationDate: Date? = nil) async -> (succeeded: Int, failures: [Failure]) {
        var succeeded = 0
        var failures: [Failure] = []
        for url in urls {
            do {
                try await save(at: url, creationDate: creationDate)
                succeeded += 1
            } catch let failure as Failure {
                failures.append(failure)
            } catch {
                failures.append(.writeFailed(error.localizedDescription))
            }
        }
        return (succeeded, failures)
    }
}
