import Foundation
import ImageIO

/// 一次精修请求。
struct RetouchRequest {
    var imageData: Data
    var preset: RetouchPreset
    /// 生成式改动必填：描述你想要的改动。
    var prompt: String?
    /// 强度 0…100。中继会把它映射到各自的算法参数上。
    var intensity: Int
}

/// 一次精修结果。
struct RetouchResult {
    var imageData: Data
    /// 实际执行方（中继在响应头里回传，例如 `local` / `cloud:xxx`）。
    var provider: String
    /// 中继侧耗时（毫秒）。拿不到就是 nil —— 不编造。
    var elapsedMilliseconds: Int?
}

/// 电脑端精修中继的 HTTP 客户端。
///
/// **密钥永远不在这里**：客户端只认识中继的地址，云端服务商的密钥由电脑端脚本持有。
/// 这正是 App 内隐私说明所承诺的做法（「把密钥放在你自己的服务端，客户端只调用你的接口」）。
///
/// 「地址规范化」与「multipart 组装」刻意做成纯函数：这两处最容易写错，
/// 而在没有 Mac 的情况下写错一次，要等十几分钟云端构建才能暴露。
struct RetouchClient {

    // MARK: - 纯函数：地址处理

    /// 把用户随手输入的地址规范化成可用的 URL。
    ///
    /// 接受这些写法（没人会照着格式手册输入）：
    /// - `172.20.10.8:8090`          → `http://172.20.10.8:8090`
    /// - `http://172.20.10.8:8090/`  → 去掉尾部斜杠
    /// - `http://host:8090/retouch`  → 丢掉多余路径，只留 host:port
    /// - 前后空白自动去掉
    ///
    /// 返回 nil 表示这个输入不能用 —— 界面上会明确说「地址不合法」，而不是静默失败。
    static func normalizeRelayURL(_ raw: String) -> URL? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        // 中间有空白几乎一定是复制粘贴带了别的东西，直接拒绝而不是猜
        guard !text.contains(where: { $0.isWhitespace }) else { return nil }

        let lowered = text.lowercased()
        let hasScheme = lowered.hasPrefix("http://") || lowered.hasPrefix("https://")
        let withScheme = hasScheme ? text : "http://" + text

        guard let range = withScheme.range(of: "://") else { return nil }
        let afterScheme = withScheme[range.upperBound...]
        let authority = afterScheme.prefix { $0 != "/" && $0 != "?" && $0 != "#" }

        guard !authority.isEmpty else { return nil }

        // 端口必须是数字。写成 host:abc 时直接判不合法，
        // 而不是让 URLComponents 悄悄把端口丢掉、连到 80 上去。
        if let colon = authority.lastIndex(of: ":") {
            let portText = authority[authority.index(after: colon)...]
            guard let port = Int(portText), (1...65535).contains(port) else { return nil }
        }

        guard let parsed = URLComponents(string: withScheme),
              let host = parsed.host, !host.isEmpty else { return nil }

        // 只保留 scheme + host + port，丢掉用户粘进来的路径与查询串
        var clean = URLComponents()
        clean.scheme = parsed.scheme
        clean.host = parsed.host
        clean.port = parsed.port
        return clean.url
    }

    /// 拼出端点地址，避免出现 `//retouch` 这类重复斜杠。
    static func endpoint(_ base: URL, path: String) -> URL? {
        var text = base.absoluteString
        while text.hasSuffix("/") { text.removeLast() }
        let suffix = path.hasPrefix("/") ? path : "/" + path
        return URL(string: text + suffix)
    }

    // MARK: - 纯函数：multipart 组装

    /// 组装 `multipart/form-data` 请求体。
    ///
    /// 做成纯函数是为了能直接断言字节内容。手写 multipart 最常出的错是
    /// 少一个 `\r\n` 或 boundary 前后不一致，而这两类错误在中继侧只表现为
    /// 「读不到图片」，非常难定位。
    static func multipartBody(boundary: String,
                              imageData: Data,
                              presetID: String,
                              prompt: String?,
                              intensity: Int,
                              filename: String = "photo.jpg") -> Data {
        var body = Data()
        let crlf = "\r\n"

        func appendText(_ text: String) {
            body.append(Data(text.utf8))
        }

        func appendField(name: String, value: String) {
            appendText("--\(boundary)\(crlf)")
            appendText("Content-Disposition: form-data; name=\"\(name)\"\(crlf)\(crlf)")
            appendText(value)
            appendText(crlf)
        }

        appendField(name: "preset", value: presetID)
        appendField(name: "intensity", value: String(intensity))
        if let prompt, !prompt.isEmpty {
            appendField(name: "prompt", value: prompt)
        }

        appendText("--\(boundary)\(crlf)")
        appendText("Content-Disposition: form-data; name=\"image\"; filename=\"\(filename)\"\(crlf)")
        appendText("Content-Type: image/jpeg\(crlf)\(crlf)")
        body.append(imageData)
        appendText(crlf)

        appendText("--\(boundary)--\(crlf)")
        return body
    }

    // MARK: - 图片真实性校验

    /// 这份数据真的能解码成图片吗？
    ///
    /// 只读头部即可，不必解出全图。中继回了 JSON 却被当成图片存下来，
    /// 等于交付一张坏图 —— 所以这里必须校验，不能只看 Content-Type。
    static func isDecodableImage(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetCount(source) > 0
    }

    /// 解析中继的错误体。中继约定返回 `{"error":{"code":"…","message":"…"}}`。
    static func parseRelayError(_ data: Data) -> (code: String, message: String) {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = object["error"] as? [String: Any] {
            let code = error["code"] as? String ?? "unknown"
            let message = error["message"] as? String ?? "中继返回了错误但没写原因"
            return (code, message)
        }
        let text = String(data: data.prefix(200), encoding: .utf8) ?? ""
        return ("http_error", text.isEmpty ? "中继返回了错误但没有说明原因" : text)
    }

    // MARK: - 网络

    /// 发一次精修请求。
    ///
    /// - Parameters:
    ///   - relayBase: 已经用 `normalizeRelayURL` 规范化过的地址
    ///   - session: 便于测试注入
    func retouch(_ request: RetouchRequest,
                 relayBase: URL,
                 session: URLSession = .shared) async throws -> RetouchResult {

        if request.preset.requiresPrompt {
            let trimmed = request.prompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmed.isEmpty else { throw RetouchClientError.missingPrompt }
        }

        guard let url = Self.endpoint(relayBase, path: "/retouch") else {
            throw RetouchClientError.invalidURL(relayBase.absoluteString)
        }

        let boundary = "lumi-\(UUID().uuidString)"
        let body = Self.multipartBody(boundary: boundary,
                                      imageData: request.imageData,
                                      presetID: request.preset.id,
                                      prompt: request.prompt,
                                      intensity: request.intensity)

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("multipart/form-data; boundary=\(boundary)",
                            forHTTPHeaderField: "Content-Type")
        // 单张全分辨率照片 + 云端推理，给足时间；超时就明确报失败，不无限等
        urlRequest.timeoutInterval = 120

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.upload(for: urlRequest, from: body)
        } catch {
            throw RetouchClientError.unreachable(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw RetouchClientError.malformedResponse("响应不是 HTTP")
        }

        guard (200..<300).contains(http.statusCode) else {
            let (code, message) = Self.parseRelayError(data)
            throw RetouchClientError.relayRejected(code: code, message: message)
        }

        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        guard contentType.lowercased().hasPrefix("image/"), !data.isEmpty else {
            throw RetouchClientError.malformedResponse(
                "Content-Type = \(contentType.isEmpty ? "（空）" : contentType)，\(data.count) 字节"
            )
        }
        guard Self.isDecodableImage(data) else {
            throw RetouchClientError.malformedResponse("声明是图片但无法解码（\(data.count) 字节）")
        }

        let provider = http.value(forHTTPHeaderField: "X-Lumi-Provider") ?? "unknown"
        let elapsed = http.value(forHTTPHeaderField: "X-Lumi-Elapsed-Ms").flatMap(Int.init)

        return RetouchResult(imageData: data, provider: provider, elapsedMilliseconds: elapsed)
    }
}
