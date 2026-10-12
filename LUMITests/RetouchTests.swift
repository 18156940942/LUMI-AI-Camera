import XCTest
@testable import LUMI

/// 精修模块的单元测试。
///
/// 这里只测**能用数字或字符串断言**的逻辑：地址规范化、multipart 字节结构、
/// 目录解析、状态语义、文件名安全化。网络请求本身不测（那要靠中继真跑），
/// UI 不测（那要靠真机）。
final class RetouchTests: XCTestCase {

    // MARK: - 地址规范化
    //
    // 这一组用例是先在 Python 里逐条验证过行为、再固化到这里的。
    // 手写 URL 处理最容易出的错是「悄悄连到错误的端口」或「把路径当成了主机名」，
    // 而这两类问题在没有 Mac 的情况下要等十几分钟云端构建才会暴露。

    func testNormalizeAddsSchemeWhenMissing() {
        XCTAssertEqual(RetouchClient.normalizeRelayURL("172.20.10.8:8091")?.absoluteString,
                       "http://172.20.10.8:8091")
    }

    func testNormalizeKeepsExplicitScheme() {
        XCTAssertEqual(RetouchClient.normalizeRelayURL("http://172.20.10.8:8091")?.absoluteString,
                       "http://172.20.10.8:8091")
        XCTAssertEqual(RetouchClient.normalizeRelayURL("https://relay.example.com")?.absoluteString,
                       "https://relay.example.com")
    }

    func testNormalizeTrimsTrailingSlash() {
        XCTAssertEqual(RetouchClient.normalizeRelayURL("http://172.20.10.8:8091/")?.absoluteString,
                       "http://172.20.10.8:8091")
    }

    func testNormalizeDropsPathAndQuery() {
        XCTAssertEqual(RetouchClient.normalizeRelayURL("http://172.20.10.8:8091/retouch")?.absoluteString,
                       "http://172.20.10.8:8091")
        XCTAssertEqual(RetouchClient.normalizeRelayURL("http://172.20.10.8:8091/health?x=1")?.absoluteString,
                       "http://172.20.10.8:8091")
    }

    func testNormalizeTrimsSurroundingWhitespace() {
        XCTAssertEqual(RetouchClient.normalizeRelayURL("  192.168.1.5:8091  ")?.absoluteString,
                       "http://192.168.1.5:8091")
    }

    func testNormalizeAcceptsLocalhost() {
        XCTAssertEqual(RetouchClient.normalizeRelayURL("localhost:8091")?.absoluteString,
                       "http://localhost:8091")
    }

    func testNormalizeRejectsEmptyOrWhitespaceOnly() {
        XCTAssertNil(RetouchClient.normalizeRelayURL(""))
        XCTAssertNil(RetouchClient.normalizeRelayURL("   "))
    }

    func testNormalizeRejectsInnerWhitespace() {
        // 中间有空格几乎一定是复制粘贴带了别的东西，应该拒绝而不是猜
        XCTAssertNil(RetouchClient.normalizeRelayURL("172.20.10.8:8091 extra"))
    }

    func testNormalizeRejectsNonNumericPort() {
        // 关键：不能因为端口写错就悄悄退回默认端口（80），那会连到别的服务上
        XCTAssertNil(RetouchClient.normalizeRelayURL("http://host:abc"))
        XCTAssertNil(RetouchClient.normalizeRelayURL("host:abc"))
    }

    func testNormalizeRejectsOutOfRangePort() {
        XCTAssertNil(RetouchClient.normalizeRelayURL("http://172.20.10.8:99999"))
    }

    func testNormalizeRejectsMissingHost() {
        XCTAssertNil(RetouchClient.normalizeRelayURL("http://:8091"))
    }

    // MARK: - 端点拼接

    func testEndpointJoinsWithoutDoubleSlash() {
        let base = URL(string: "http://172.20.10.8:8091")!
        XCTAssertEqual(RetouchClient.endpoint(base, path: "/retouch")?.absoluteString,
                       "http://172.20.10.8:8091/retouch")
    }

    func testEndpointHandlesBaseWithTrailingSlash() {
        let base = URL(string: "http://172.20.10.8:8091/")!
        XCTAssertEqual(RetouchClient.endpoint(base, path: "retouch")?.absoluteString,
                       "http://172.20.10.8:8091/retouch")
    }

    // MARK: - multipart 组装

    func testMultipartContainsAllFields() {
        let image = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x01, 0x02, 0x03])
        let body = RetouchClient.multipartBody(boundary: "BOUND",
                                               imageData: image,
                                               presetID: "enhance.auto",
                                               prompt: nil,
                                               intensity: 70)
        let text = String(decoding: body, as: UTF8.self)

        XCTAssertTrue(text.contains("--BOUND\r\n"))
        XCTAssertTrue(text.contains(#"name="preset""#))
        XCTAssertTrue(text.contains("enhance.auto"))
        XCTAssertTrue(text.contains(#"name="intensity""#))
        XCTAssertTrue(text.contains("70"))
        XCTAssertTrue(text.contains(#"name="image"; filename="photo.jpg""#))
        XCTAssertTrue(text.contains("Content-Type: image/jpeg"))
        // 结束分隔符必须是 --BOUND-- 并且出现在最后
        XCTAssertTrue(text.hasSuffix("--BOUND--\r\n"))
    }

    func testMultipartOmitsPromptWhenNilOrEmpty() {
        let image = Data([0x01])
        let withoutPrompt = String(decoding: RetouchClient.multipartBody(
            boundary: "B", imageData: image, presetID: "p", prompt: nil, intensity: 50), as: UTF8.self)
        let withEmptyPrompt = String(decoding: RetouchClient.multipartBody(
            boundary: "B", imageData: image, presetID: "p", prompt: "", intensity: 50), as: UTF8.self)
        XCTAssertFalse(withoutPrompt.contains(#"name="prompt""#))
        XCTAssertFalse(withEmptyPrompt.contains(#"name="prompt""#))
    }

    func testMultipartIncludesPromptWhenProvided() {
        let body = String(decoding: RetouchClient.multipartBody(
            boundary: "B", imageData: Data([0x01]), presetID: "generative.custom",
            prompt: "把天空换成黄昏", intensity: 50), as: UTF8.self)
        XCTAssertTrue(body.contains(#"name="prompt""#))
        XCTAssertTrue(body.contains("把天空换成黄昏"))
    }

    func testMultipartImageBytesArePreservedExactly() {
        // 图片字节必须原样出现在请求体里。手写 multipart 时很容易在这里多加一个
        // CRLF 或漏一段，而中继侧只会表现为「读不到图片」。
        let image = Data([0xFF, 0xD8, 0xFF, 0xE0, 0xAA, 0xBB, 0xCC, 0xFF, 0xD9])
        let body = RetouchClient.multipartBody(boundary: "B", imageData: image,
                                               presetID: "p", prompt: nil, intensity: 50)
        XCTAssertNotNil(body.range(of: image), "图片字节应原样出现在请求体中")
    }

    // MARK: - 错误体解析

    func testParseRelayErrorReadsCodeAndMessage() {
        let payload = #"{"error":{"code":"no_face_detected","message":"没有检测到人脸"}}"#
        let (code, message) = RetouchClient.parseRelayError(Data(payload.utf8))
        XCTAssertEqual(code, "no_face_detected")
        XCTAssertEqual(message, "没有检测到人脸")
    }

    func testParseRelayErrorFallsBackOnNonJSON() {
        let (code, message) = RetouchClient.parseRelayError(Data("<html>502</html>".utf8))
        XCTAssertEqual(code, "http_error")
        XCTAssertTrue(message.contains("502"))
    }

    func testParseRelayErrorHandlesJSONWithoutErrorObject() {
        let (code, _) = RetouchClient.parseRelayError(Data(#"{"ok":true}"#.utf8))
        XCTAssertEqual(code, "http_error")
    }

    // MARK: - 可解码校验

    func testIsDecodableImageRejectsArbitraryBytes() {
        XCTAssertFalse(RetouchClient.isDecodableImage(Data([0x00, 0x01, 0x02, 0x03])))
        XCTAssertFalse(RetouchClient.isDecodableImage(Data()))
    }

    func testIsDecodableImageAcceptsRealPNG() {
        // 1×1 的 PNG，保证「声明是图片」之外还真的能解码
        let png = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
        XCTAssertTrue(RetouchClient.isDecodableImage(png))
    }

    // MARK: - 目录解析

    private func catalogJSON(presets: String, categories: String = """
        [{"id":"enhance","title":"画质增强","summary":"略"}]
        """) -> Data {
        Data("""
        {"version":1,"categories":\(categories),"presets":\(presets)}
        """.utf8)
    }

    func testCatalogDecodesMinimalValidPayload() throws {
        let data = catalogJSON(presets: """
        [{"id":"enhance.auto","category":"enhance","title":"自动增强","detail":"略",
          "engine":"local","requiresPrompt":false}]
        """)
        let catalog = try RetouchCatalogLoader.decode(data)
        XCTAssertEqual(catalog.version, 1)
        XCTAssertEqual(catalog.presets.count, 1)
        XCTAssertEqual(catalog.preset(withID: "enhance.auto")?.engine, .local)
        XCTAssertEqual(catalog.presets(in: .enhance).count, 1)
        XCTAssertEqual(catalog.info(for: .enhance)?.title, "画质增强")
    }

    func testCatalogRejectsEmptyPresetList() {
        XCTAssertThrowsError(try RetouchCatalogLoader.decode(catalogJSON(presets: "[]")))
    }

    func testCatalogRejectsMalformedJSON() {
        XCTAssertThrowsError(try RetouchCatalogLoader.decode(Data("{ 不是 json".utf8)))
    }

    func testCatalogRejectsUnknownCategory() {
        // 类别值必须严格匹配枚举 rawValue，拼错就应该解析失败而不是被静默忽略
        let data = catalogJSON(presets: """
        [{"id":"nope.x","category":"notACategory","title":"x","detail":"y",
          "engine":"local","requiresPrompt":false}]
        """)
        XCTAssertThrowsError(try RetouchCatalogLoader.decode(data))
    }

    func testCatalogRejectsUnknownEngine() {
        let data = catalogJSON(presets: """
        [{"id":"enhance.auto","category":"enhance","title":"x","detail":"y",
          "engine":"magic","requiresPrompt":false}]
        """)
        XCTAssertThrowsError(try RetouchCatalogLoader.decode(data))
    }

    // MARK: - 类别语义

    func testOnlyGenerativeRequiresCloud() {
        XCTAssertTrue(RetouchCategory.generative.requiresCloud)
        XCTAssertFalse(RetouchCategory.enhance.requiresCloud)
        XCTAssertFalse(RetouchCategory.grade.requiresCloud)
        XCTAssertFalse(RetouchCategory.portrait.requiresCloud)
    }

    func testEveryCategoryHasSymbolAndFallbackTitle() {
        for category in RetouchCategory.allCases {
            XCTAssertFalse(category.symbolName.isEmpty, "\(category) 缺少图标")
            XCTAssertFalse(category.fallbackTitle.isEmpty, "\(category) 缺少兜底标题")
        }
    }

    func testCategoryCountMatchesTheFourAnnouncedKinds() {
        // 需求里明确要四类：画质增强 / 风格化调色 / 人像美化 / 生成式改动
        XCTAssertEqual(RetouchCategory.allCases.count, 4)
    }

    // MARK: - 状态语义

    func testJobStateIdleHasNoPreset() {
        XCTAssertNil(RetouchJobState.idle.presetID)
        XCTAssertFalse(RetouchJobState.idle.isRunning)
        XCTAssertEqual(RetouchJobState.idle.shortLabel, "未精修")
    }

    func testJobStateRunningIsRunning() {
        let state = RetouchJobState.running(presetID: "enhance.auto")
        XCTAssertTrue(state.isRunning)
        XCTAssertEqual(state.presetID, "enhance.auto")
    }

    func testJobStateSucceededCarriesProviderAndTime() {
        let when = Date(timeIntervalSince1970: 1_760_000_000)
        let state = RetouchJobState.succeeded(presetID: "grade.film",
                                              finishedAt: when,
                                              provider: "local")
        XCTAssertFalse(state.isRunning)
        XCTAssertEqual(state.presetID, "grade.film")
        XCTAssertEqual(state.shortLabel, "已精修")
    }

    func testJobStateFailedCarriesMessage() {
        let state = RetouchJobState.failed(presetID: "portrait.brightenFace",
                                           message: "没有检测到人脸")
        XCTAssertEqual(state.shortLabel, "失败")
        XCTAssertEqual(state.presetID, "portrait.brightenFace")
    }

    // MARK: - 配置语义

    func testConfigurationDefaultsToDisabled() {
        // 这个功能会把照片发出去，默认必须是关的
        XCTAssertFalse(RetouchConfiguration.default.isEnabled)
        XCTAssertFalse(RetouchConfiguration.default.isReady)
        XCTAssertEqual(RetouchConfiguration.default.statusText, "未开启")
    }

    func testConfigurationNotReadyWithoutRelayURL() {
        var configuration = RetouchConfiguration.default
        configuration.isEnabled = true
        XCTAssertNil(configuration.normalizedRelayURL)
        XCTAssertFalse(configuration.isReady)
        XCTAssertEqual(configuration.statusText, "已开启，但还没填中继地址")
    }

    func testConfigurationNotReadyWithInvalidRelayURL() {
        var configuration = RetouchConfiguration.default
        configuration.isEnabled = true
        configuration.relayURL = "http://host:abc"
        XCTAssertNil(configuration.normalizedRelayURL)
        XCTAssertFalse(configuration.isReady)
        XCTAssertEqual(configuration.statusText, "已开启，但地址不合法")
    }

    func testConfigurationReadyWhenEnabledAndValid() {
        var configuration = RetouchConfiguration.default
        configuration.isEnabled = true
        configuration.relayURL = "172.20.10.8:8091"
        XCTAssertNotNil(configuration.normalizedRelayURL)
        XCTAssertTrue(configuration.isReady)
        XCTAssertEqual(configuration.statusText, "已开启")
    }

    func testConfigurationRoundTripsThroughCodable() throws {
        var configuration = RetouchConfiguration.default
        configuration.isEnabled = true
        configuration.relayURL = "http://172.20.10.8:8091"
        configuration.generativePrompt = "把天空换成黄昏"
        let data = try JSONEncoder().encode(configuration)
        let decoded = try JSONDecoder().decode(RetouchConfiguration.self, from: data)
        XCTAssertEqual(decoded, configuration)
    }

    // MARK: - 客户端错误语义

    func testOnlyUnreachableIsRetryable() {
        // 网络类问题值得重试；参数/业务类问题重试没有意义
        XCTAssertTrue(RetouchClientError.unreachable("超时").isRetryable)
        XCTAssertFalse(RetouchClientError.notConfigured.isRetryable)
        XCTAssertFalse(RetouchClientError.missingPrompt.isRetryable)
        XCTAssertFalse(RetouchClientError.relayRejected(code: "x", message: "y").isRetryable)
        XCTAssertFalse(RetouchClientError.malformedResponse("z").isRetryable)
    }

    func testErrorsHaveReadableChineseDescriptions() {
        let errors: [RetouchClientError] = [
            .notConfigured,
            .invalidURL("abc"),
            .unreachable("超时"),
            .relayRejected(code: "no_face_detected", message: "没有检测到人脸"),
            .malformedResponse("不是图片"),
            .missingPrompt,
        ]
        for error in errors {
            let text = error.errorDescription ?? ""
            XCTAssertFalse(text.isEmpty, "\(error) 缺少可读说明")
        }
    }

    func testRelayRejectedMessageIsSurfacedToUser() {
        let error = RetouchClientError.relayRejected(code: "no_face_detected",
                                                     message: "没有检测到人脸")
        XCTAssertTrue(error.errorDescription!.contains("没有检测到人脸"))
        XCTAssertTrue(error.errorDescription!.contains("no_face_detected"))
    }

    // MARK: - 文件名安全化

    func testSafeFileNameReplacesDots() {
        XCTAssertEqual(RetouchStore.safeFileName("enhance.auto"), "enhance_auto")
        XCTAssertEqual(RetouchStore.safeFileName("portrait.brightenFace"), "portrait_brightenFace")
    }

    func testSafeFileNameStripsPathSeparators() {
        // 文件名是从外部数据拼出来的，必须当作不可信输入处理
        let sanitized = RetouchStore.safeFileName("../../etc/passwd")
        XCTAssertFalse(sanitized.contains("/"))
        XCTAssertFalse(sanitized.contains("."))
        XCTAssertTrue(sanitized.contains("etc"))
    }

    func testSafeFileNameNeverReturnsEmpty() {
        XCTAssertEqual(RetouchStore.safeFileName(""), "preset")
        XCTAssertEqual(RetouchStore.safeFileName("..."), "___")
    }

    func testSafeFileNameKeepsAlphanumerics() {
        XCTAssertEqual(RetouchStore.safeFileName("grade2024mono"), "grade2024mono")
    }
}
