import XCTest
import Photos
@testable import LUMI

/// 相册导出的单元测试。
///
/// **范围说明（重要）**：真正「把图片写进相册」这一步没法在这里断言 —— 它需要
/// 一个已授权相册权限的运行环境，而且会真的往相册里塞东西。所以这里只测
/// **在没有权限的情况下也能确定判断**的部分：失败分类、文案映射、批量导出的
/// 聚合行为，以及「检查顺序」这条容易被写错、又只在真机上才暴露的约束。
///
/// 实际写入由真机验收覆盖（见 `docs/06-真机验收清单.md`）。
final class PhotoExporterTests: XCTestCase {

    /// 一个确定不存在的文件路径。用 UUID 保证不会碰巧命中真实文件。
    private func missingFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("lumi-absent-\(UUID().uuidString).jpg")
    }

    private func failureFrom(_ operation: () async throws -> Void) async -> PhotoExporter.Failure? {
        do {
            try await operation()
            return nil
        } catch let failure as PhotoExporter.Failure {
            return failure
        } catch {
            return nil
        }
    }

    // MARK: - 文件不存在

    func testSaveThrowsFileMissingForAbsentFile() async {
        let url = missingFileURL()
        guard let failure = await failureFrom({ try await PhotoExporter.save(at: url) }) else {
            return XCTFail("文件不存在时不应该成功")
        }
        guard case .fileMissing(let name) = failure else {
            return XCTFail("期望 .fileMissing，实际是 \(failure)")
        }
        XCTAssertEqual(name, url.lastPathComponent)
    }

    /// 文件检查必须发生在权限检查**之前**。
    ///
    /// 顺序反了的话，用户会先看到一个系统授权弹窗，点了「允许」之后才被告知
    /// 「文件其实不存在」—— 一次完全多余的授权请求。这个顺序在真机上很难注意到，
    /// 所以在这里钉死。
    func testFileCheckRunsBeforePermissionRequest() async {
        guard let failure = await failureFrom({ try await PhotoExporter.save(at: missingFileURL()) }) else {
            return XCTFail("文件不存在时不应该成功")
        }
        guard case .fileMissing = failure else {
            return XCTFail("文件不存在时应先报 .fileMissing，而不是先走权限分支；实际是 \(failure)")
        }
    }

    func testFileMissingMessageCarriesTheFileName() {
        let failure = PhotoExporter.Failure.fileMissing("LUMI-0001.jpg")
        let message = failure.errorDescription ?? ""
        XCTAssertFalse(message.isEmpty)
        XCTAssertTrue(message.contains("LUMI-0001.jpg"), "提示里要带上具体文件名，否则用户不知道是谁丢了")
    }

    // MARK: - 文案映射
    //
    // 这一组是防「文案退化」的：导出失败的原因各不相同，处理方式也完全不同
    // （权限被拒要去系统设置改、文件没了只能承认、写入失败可以重试）。
    // 如果哪天它们被合并成同一句话，这几条会失败。

    func testEveryFailureCaseHasItsOwnMessage() {
        let failures: [PhotoExporter.Failure] = [
            .permissionDenied,
            .permissionRestricted,
            .fileMissing("a.jpg"),
            .writeFailed("boom")
        ]
        var messages: [String] = []
        for failure in failures {
            let message = failure.errorDescription ?? ""
            XCTAssertFalse(message.isEmpty, "\(failure) 没有可读说明")
            messages.append(message)
        }
        XCTAssertEqual(Set(messages).count, failures.count,
                       "每种失败要有各自的说法，不能混成同一句")
    }

    func testWriteFailedMessageIncludesUnderlyingReason() {
        let message = PhotoExporter.Failure.writeFailed("disk full").errorDescription ?? ""
        XCTAssertTrue(message.contains("disk full"), "要把底层原因带出来，否则没法排查")
    }

    func testDescribeCoversEveryAuthorizationStatus() {
        let statuses: [PHAuthorizationStatus] = [
            .notDetermined, .restricted, .denied, .authorized, .limited
        ]
        let descriptions = statuses.map { PhotoExporter.describe($0) }
        for text in descriptions {
            XCTAssertFalse(text.isEmpty)
        }
        XCTAssertEqual(Set(descriptions).count, statuses.count,
                       "每个权限状态要有各自的说法，设置页展示的就是它")
    }

    // MARK: - 批量导出

    func testSaveAllOnEmptyInputSucceedsTrivially() async {
        let result = await PhotoExporter.saveAll([])
        XCTAssertEqual(result.succeeded, 0)
        XCTAssertTrue(result.failures.isEmpty)
    }

    /// 批量导出里有一张失败，不能把剩下的全丢掉 —— 用户要的是
    /// 「3 张成功、1 张失败并说明原因」，不是「整批失败」。
    func testSaveAllKeepsGoingAfterAFailure() async {
        let urls = (0..<3).map { _ in missingFileURL() }
        let result = await PhotoExporter.saveAll(urls)

        XCTAssertEqual(result.succeeded, 0)
        XCTAssertEqual(result.failures.count, urls.count, "每一张都要单独记账")
        for failure in result.failures {
            guard case .fileMissing = failure else {
                return XCTFail("期望 .fileMissing，实际是 \(failure)")
            }
        }
    }
}
