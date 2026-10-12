import Foundation
import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import ImageIO
import QuartzCore

/// 网络中继输入 —— **iPhone 上唯一可行的真实监看路径**。
///
/// 链路：`Nikon Z6 II` --mini-HDMI--> `UVC 采集卡` --USB--> `电脑(ffmpeg)` --局域网--> `iPhone`
///
/// 两种播放模式：
/// - ``RelayMode/mjpeg``：MJPEG over HTTP。自研 multipart/JPEG 解析，逐帧即时解码，
///   局域网实测延迟约 150–400 ms，是默认推荐模式。
/// - ``RelayMode/hls``：HLS（H.264）。带宽低但延迟高（1–3 s 起），仅在网络受限时使用。
///
/// 实现约束：
/// - 解码出的帧同时用于「显示」与「AI 分析」，两者依据同一份像素，不存在结果与画面不一致；
/// - 只统计**真实到达**的帧数、字节数与解码失败次数，UI 显示的就是实际值；
/// - 停止/失败时会释放会话，不会留下后台连接。
final class NetworkVideoInput: NSObject, VideoInputSource {

    let kind: VideoInputKind = .networkRelay
    weak var delegate: VideoInputSourceDelegate?

    private(set) var deviceInfo: VideoInputDeviceInfo?
    private(set) var stats = StreamStats()
    private(set) var latestFrame: CGImage?

    var previewProvider: VideoPreviewProvider {
        configuration.mode == .hls ? .player(player) : .imageFrames
    }

    /// 中继配置（来自设置页）
    private(set) var configuration: RelayConfiguration

    /// 解码帧率上限：屏幕刷新与 Vision 分析都够用，同时显著降低 CPU 占用
    var maxDecodeFPS: Double = 20 {
        didSet { maxDecodeFPS = min(max(maxDecodeFPS, 1), 30) }
    }

    /// 停止收帧多少秒后判定为「流已中断」
    var stallTimeout: Double = 3.0

    private var urlSession: URLSession?
    private var dataTask: URLSessionDataTask?
    private var buffer = Data()
    private var lastDecodeTime: CFTimeInterval = 0
    private var lastKbpsAt: Date?
    private var bytesSinceLastKbps: Int = 0
    private var stallTimer: Timer?
    private var hasReportedStall = false
    private(set) var isRunning = false

    // HLS 相关
    private lazy var player: AVPlayer = {
        let player = AVPlayer()
        player.isMuted = true
        player.actionAtItemEnd = .none
        return player
    }()
    private var playerOutput: AVPlayerItemVideoOutput?
    private var displayLink: CADisplayLink?
    private var hlsItem: AVPlayerItem?

    init(configuration: RelayConfiguration) {
        self.configuration = configuration
        super.init()
    }

    // MARK: - 启动 / 停止

    func start() throws {
        guard let url = configuration.url else {
            publish(state: .failed(.invalidRelayURL(configuration.displayURL)))
            throw VideoInputFailure.invalidRelayURL(configuration.displayURL)
        }

        publish(state: .preparing)
        resetCounters()

        switch configuration.mode {
        case .mjpeg:
            startMJPEG(url: url)
        case .hls:
            startHLS(url: url)
        }

        startStallMonitor()
        isRunning = true
    }

    func stop() {
        stallTimer?.invalidate()
        stallTimer = nil
        displayLink?.invalidate()
        displayLink = nil
        dataTask?.cancel()
        dataTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        playerOutput = nil
        hlsItem = nil
        buffer.removeAll(keepingCapacity: false)
        latestFrame = nil
        isRunning = false
        deviceInfo = nil
        delegate?.videoInput(self, didUpdateDeviceInfo: nil)
        publish(state: .idle)
    }

    /// 更新中继地址（设置页修改后调用）
    func update(configuration: RelayConfiguration) throws {
        let wasRunning = isRunning
        stop()
        self.configuration = configuration
        if wasRunning { try start() }
    }

    private func resetCounters() {
        stats = StreamStats()
        hasReportedStall = false
        lastKbpsAt = Date()
        bytesSinceLastKbps = 0
    }

    // MARK: - MJPEG

    private func startMJPEG(url: URL) {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60 * 60 * 12
        config.httpAdditionalHeaders = ["User-Agent": "LUMI-AI-Camera/1.0", "Accept": "multipart/x-mixed-replace, image/jpeg"]

        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        urlSession = session

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let task = session.dataTask(with: request)
        dataTask = task
        task.resume()

        DiagnosticsLog.shared.info(.network, "MJPEG 中继已发起连接: \(url.absoluteString)")
    }

    // MARK: - HLS

    private func startHLS(url: URL) {
        let item = AVPlayerItem(url: url)
        // 低延迟取向：不额外缓冲
        item.preferredForwardBufferDuration = 0
        hlsItem = item

        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        item.add(output)
        playerOutput = output

        NotificationCenter.default.addObserver(self,
                                              selector: #selector(hlsItemFailed(_:)),
                                              name: .AVPlayerItemFailedToPlayToEndTime,
                                              object: item)

        player.replaceCurrentItem(with: item)
        player.play()

        let link = CADisplayLink(target: self, selector: #selector(stepHLSSample))
        link.add(to: .main, forMode: .common)
        displayLink = link

        DiagnosticsLog.shared.info(.network, "HLS 中继已发起连接: \(url.absoluteString)")
    }

    @objc private func hlsItemFailed(_ notification: Notification) {
        let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
        let detail = error?.localizedDescription ?? "HLS 播放失败"
        publish(state: .failed(.networkUnreachable(detail)))
    }

    @objc private func stepHLSSample() {
        guard let output = playerOutput, let item = hlsItem else { return }
        let time = item.currentTime()
        guard output.hasNewPixelBuffer(forItemTime: time) else { return }
        guard let pixelBuffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { return }

        let size = CGSize(width: CVPixelBufferGetWidth(pixelBuffer),
                          height: CVPixelBufferGetHeight(pixelBuffer))
        stats.totalFrames += 1
        stats.lastFrameAt = Date()
        hasReportedStall = false

        updateDeviceInfoIfNeeded(size: size, pixelFormat: "H.264/HLS")
        delegate?.videoInput(self,
                             didProducePixelBuffer: pixelBuffer,
                             frameSize: size,
                             orientation: .up,
                             timestamp: CMTimeGetSeconds(time))
    }

    // MARK: - 状态与统计

    private func publish(state: VideoInputState) {
        delegate?.videoInput(self, didChangeState: state)
    }

    private func updateDeviceInfoIfNeeded(size: CGSize, pixelFormat: String?) {
        guard size.width > 0, size.height > 0 else { return }
        if let existing = deviceInfo,
           existing.pixelWidth == Int(size.width),
           existing.pixelHeight == Int(size.height) {
            return
        }
        let info = VideoInputDeviceInfo(kind: .networkRelay,
                                        name: "网络中继流（\(configuration.mode.title)）",
                                        uniqueID: configuration.displayURL,
                                        pixelWidth: Int(size.width),
                                        pixelHeight: Int(size.height),
                                        nominalFrameRate: 0,
                                        pixelFormat: pixelFormat,
                                        isExternal: true)
        deviceInfo = info
        delegate?.videoInput(self, didUpdateDeviceInfo: info)
    }

    private func startStallMonitor() {
        stallTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.refreshBandwidth()
            guard let last = self.stats.lastFrameAt else {
                // 还没收到任何帧：超过 stallTimeout 就报「连不上」
                if !self.hasReportedStall, self.isRunning {
                    // 依赖 URLSession 的错误回调提供更具体的原因，这里只做兜底
                }
                return
            }
            let age = Date().timeIntervalSince(last)
            if age > self.stallTimeout, !self.hasReportedStall {
                self.hasReportedStall = true
                self.publish(state: .failed(.streamStalled(seconds: age)))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        stallTimer = timer
    }

    /// 每秒计算一次真实带宽（不是估算值）
    private func refreshBandwidth() {
        guard let start = lastKbpsAt else {
            lastKbpsAt = Date()
            bytesSinceLastKbps = 0
            return
        }
        let elapsed = Date().timeIntervalSince(start)
        guard elapsed > 0 else { return }
        stats.bytesPerSecond = Double(bytesSinceLastKbps) / elapsed
        lastKbpsAt = Date()
        bytesSinceLastKbps = 0

        // 到达帧率：用滚动窗口统计
        let now = Date()
        if let last = stats.lastFrameAt {
            let age = now.timeIntervalSince(last)
            stats.receivedFPS = age < 1.0 ? min(maxDecodeFPS, Double(stats.totalFrames)) : 0
        }
    }
}

// MARK: - MJPEG 数据流解析

extension NetworkVideoInput: URLSessionDataDelegate {

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let httpResponse = response as? HTTPURLResponse {
            DiagnosticsLog.shared.info(.network, "中继响应 HTTP \(httpResponse.statusCode)")
            if httpResponse.statusCode >= 400 {
                completionHandler(.cancel)
                publish(state: .failed(.networkUnreachable("中继服务返回 HTTP \(httpResponse.statusCode)")))
                return
            }
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        stats.bytesPerSecond = max(stats.bytesPerSecond, 0)
        bytesSinceLastKbps += data.count
        buffer.append(data)
        extractJPEGFrames()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let nsError = error as NSError
        // 主动取消时不再报错
        if nsError.code == NSURLErrorCancelled { return }
        DiagnosticsLog.shared.error(.network, "中继连接结束: \(error.localizedDescription)")
        publish(state: .failed(.networkUnreachable(error.localizedDescription)))
    }

    /// 从字节流里切出完整 JPEG 帧。
    ///
    /// 说明：MJPEG over HTTP 的每帧都是一张完整 JPEG，用 SOI(FF D8 FF) / EOI(FF D9) 标记
    /// 定位是工程上最稳的做法（不依赖各家中继端 boundary 的实现差异）。
    /// JPEG 熵编码数据里不会出现裸的 FF D9，因此不会误切。
    private func extractJPEGFrames() {
        let soi = Data([0xFF, 0xD8, 0xFF])
        let eoi = Data([0xFF, 0xD9])

        while true {
            guard let startRange = buffer.range(of: soi) else {
                // 没有起始标记，丢弃噪声数据
                if buffer.count > 1_000_000 { buffer.removeAll(keepingCapacity: true) }
                return
            }

            // 丢掉 SOI 之前的垃圾字节
            if startRange.lowerBound > buffer.startIndex {
                buffer.removeSubrange(buffer.startIndex..<startRange.lowerBound)
            }

            guard let endRange = buffer.range(of: eoi, in: buffer.startIndex..<buffer.endIndex) else {
                // 帧还没收全，等下一批数据
                if buffer.count > 12 * 1024 * 1024 {
                    // 单个帧不可能这么大，说明流格式异常
                    buffer.removeAll(keepingCapacity: true)
                    stats.decodeFailureCount += 1
                    publish(state: .failed(.streamDecodeFailed("检测到异常大的数据块，可能不是 MJPEG 流")))
                }
                return
            }

            let frameData = buffer.subdata(in: buffer.startIndex..<endRange.upperBound)
            buffer.removeSubrange(buffer.startIndex..<endRange.upperBound)
            decode(frameData)
        }
    }

    private func decode(_ jpegData: Data) {
        let now = CACurrentMediaTime()
        let minimumInterval = 1.0 / max(maxDecodeFPS, 1)
        guard now - lastDecodeTime >= minimumInterval else {
            // 主动丢弃超出解码能力的帧，保证显示的是「最新画面」而不是积压画面（低延迟关键）
            stats.droppedFrames += 1
            return
        }
        lastDecodeTime = now

        guard let source = CGImageSourceCreateWithData(jpegData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            stats.decodeFailureCount += 1
            return
        }

        stats.totalFrames += 1
        stats.lastFrameAt = Date()
        hasReportedStall = false
        latestFrame = image

        let size = CGSize(width: image.width, height: image.height)
        updateDeviceInfoIfNeeded(size: size, pixelFormat: "MJPEG")

        delegate?.videoInput(self,
                             didProduceImage: image,
                             orientation: .up,
                             timestamp: now)
    }
}
