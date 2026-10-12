import Foundation

/// 中继地址连通性探测。
///
/// **为什么需要它。** 真机上最常见的失败是「画面出不来」。它至少有四种互不相同的原因：
/// ① 地址写错；② 电脑上的服务没开；③ 防火墙静默丢包；④ 能连上、但服务根本没在推流。
/// 这四种在界面上都表现为「黑屏」，排查路径却完全不同。这个探测器把 HTTP 状态码、
/// 内容类型与首块字节数取回来，让「黑屏」变成一句可执行的结论。
///
/// 实现要点：MJPEG 是**永不结束**的流，普通的 `dataTask` 回调永远等不到响应体读完，
/// 所以这里在**收到第一块非空数据时就判定成功并主动断开**，用 `URLSessionDataDelegate`
/// 而不是 completion handler。
final class RelayProbe: NSObject {

    struct Result: Equatable {

        enum Outcome: String {
            case ok
            case reachableNoFrames
            case httpError
            case unreachable
            case timedOut
            case cancelled
        }

        var outcome: Outcome = .unreachable
        var statusCode: Int = 0
        var contentType: String = ""
        var elapsed: Double = 0
        var receivedHeadBytes: Int = 0
        var detail: String = ""

        var isSuccess: Bool { outcome == .ok }

        var title: String {
            switch outcome {
            case .ok: return "中继正常，正在推送画面"
            case .reachableNoFrames: return "能连上，但没有画面数据"
            case .httpError: return "服务器返回了错误状态"
            case .unreachable: return "连不上"
            case .timedOut: return "超时，没有任何响应"
            case .cancelled: return "已取消"
            }
        }

        /// 可执行的下一步。这一段是整次探测真正的产物。
        var advice: String {
            switch outcome {
            case .ok:
                return "内容类型应与 MJPEG（multipart/x-mixed-replace）一致。若画面仍不出来，请检查监看页是否选的是「网络中继」输入。"
            case .reachableNoFrames:
                return "电脑上的服务在监听，但没有把画面推出来。请确认中继脚本已成功打开采集卡（脚本日志会打印分辨率与帧率），以及相机 HDMI 已输出。"
            case .httpError:
                return "地址被服务器接受但路径不对。请核对端口与路径（默认 8090 / stream），并确认脚本仍在运行。"
            case .unreachable:
                return "请确认：手机与电脑在同一个 Wi-Fi；电脑防火墙已放行该端口；IP 没写错；中继脚本正在运行。"
            case .timedOut:
                return "数据包发出后没有回应，通常是 IP 不在同一网段，或被防火墙静默丢弃。"
            case .cancelled:
                return "探测被取消（例如离开页面）。"
            }
        }

        /// 一行摘要，便于同时写进日志与报告。
        var summaryLine: String {
            var parts = [title]
            if statusCode > 0 { parts.append("HTTP \(statusCode)") }
            if !contentType.isEmpty { parts.append(contentType) }
            parts.append(String(format: "耗时 %.2fs", elapsed))
            if receivedHeadBytes > 0 { parts.append("首块 \(receivedHeadBytes) 字节") }
            if !detail.isEmpty { parts.append(detail) }
            return parts.joined(separator: "｜")
        }
    }

    // MARK: - 内部状态（全部有默认值，因此不需要显式 init）

    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var completion: ((Result) -> Void)?
    private var startedAt = Date()
    private var timeoutSeconds: TimeInterval = 6
    private var didComplete = false
    private var partial = Result()
    private let lock = NSLock()

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !didComplete && task != nil
    }

    // MARK: - 外部接口

    func probe(url: URL, timeout: TimeInterval = 6, completion: @escaping (Result) -> Void) {
        cancel()

        lock.lock()
        startedAt = Date()
        timeoutSeconds = max(1, timeout)
        didComplete = false
        partial = Result()
        self.completion = completion
        lock.unlock()

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("LUMI-Diagnostics/1.0", forHTTPHeaderField: "User-Agent")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false

        let newSession = URLSession(configuration: configuration,
                                    delegate: self,
                                    delegateQueue: nil)
        let newTask = newSession.dataTask(with: request)

        lock.lock()
        session = newSession
        task = newTask
        lock.unlock()

        newTask.resume()
    }

    /// 静默取消：不会回调 completion，用于「重新探测」或页面消失。
    func cancel() {
        lock.lock()
        let existing = task
        didComplete = true
        completion = nil
        task = nil
        session = nil
        lock.unlock()
        existing?.cancel()
    }

    // MARK: - 收尾

    private func complete(with outcome: Result.Outcome, detail: String) {
        lock.lock()
        if didComplete {
            lock.unlock()
            return
        }
        didComplete = true
        var result = partial
        let callback = completion
        let runningSession = session
        completion = nil
        session = nil
        task = nil
        result.outcome = outcome
        result.detail = detail
        result.elapsed = Date().timeIntervalSince(startedAt)
        lock.unlock()

        // 先放锁再收尾：invalidateAndCancel 可能同步触发 delegate 回调，
        // 而在锁里回调会死锁。
        runningSession?.invalidateAndCancel()
        callback?(result)
    }
}

// MARK: - URLSessionDataDelegate

extension RelayProbe: URLSessionDataDelegate {

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        partial.statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        partial.contentType = response.mimeType ?? ""
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !data.isEmpty else { return }

        lock.lock()
        partial.receivedHeadBytes += data.count
        let status = partial.statusCode
        lock.unlock()

        if status == 200 {
            complete(with: .ok, detail: "收到首块画面数据 \(data.count) 字节")
        } else if status > 0 {
            complete(with: .httpError, detail: "服务器返回 HTTP \(status)")
        } else {
            complete(with: .reachableNoFrames, detail: "收到了数据，但没有 HTTP 状态码")
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let status = partial.statusCode
        let bytes = partial.receivedHeadBytes
        let timeout = timeoutSeconds
        lock.unlock()

        guard let error else {
            if status == 200, bytes > 0 {
                complete(with: .ok, detail: "连接正常结束，共收到 \(bytes) 字节")
            } else if status > 0 {
                complete(with: .reachableNoFrames, detail: "服务器响应了 HTTP \(status)，但流里没有画面数据")
            } else {
                complete(with: .reachableNoFrames, detail: "连接结束，但没有拿到有效响应")
            }
            return
        }

        let nsError = error as NSError
        if nsError.code == NSURLErrorCancelled {
            complete(with: .cancelled, detail: "探测被取消")
        } else if status > 0 {
            complete(with: .reachableNoFrames,
                     detail: "服务器响应了 HTTP \(status)，但读不到画面数据（\(nsError.localizedDescription)）")
        } else if nsError.code == NSURLErrorTimedOut {
            complete(with: .timedOut, detail: "在 \(Int(timeout)) 秒内没有任何响应")
        } else {
            complete(with: .unreachable, detail: nsError.localizedDescription)
        }
    }
}
