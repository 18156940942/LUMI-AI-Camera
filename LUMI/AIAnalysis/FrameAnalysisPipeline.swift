import Foundation
import QuartzCore
import CoreGraphics
import CoreVideo
import CoreImage
import ImageIO

/// 实时帧分析管线。
///
/// 职责：
/// 1. 接收视频源送来的像素帧（CVPixelBuffer / CGImage）；
/// 2. 按设定帧率**节流**（默认 8fps，可调），避免每帧都跑 Vision 导致发热掉电；
/// 3. 在后台队列完成降采样 → Vision 姿态检测 → 姿态/构图分析；
/// 4. 把结果回调到主线程交给 UI。
///
/// 设计要点：
/// - 分析与渲染分离：视频预览由预览图层直接显示（零拷贝、低延迟），
///   分析走这条异步管线，因此**分析卡顿不会拖慢监看画面**；
/// - 管线只输出结论，不修改任何像素，也不保存任何帧。
final class FrameAnalysisPipeline {

    struct Options: Equatable {
        var poseEnabled: Bool = false
        var compositionEnabled: Bool = false
        /// 亮度分布计量（曝光辅助）。由画面像素真实计算，**不是相机测光值**。
        var exposureMeterEnabled: Bool = true
        /// 分析帧率上限（1...15）
        var maxFPS: Int = 8
        /// 送入 Vision 的最大边长（越小越快；720 对人像姿态足够）
        var analysisMaxDimension: CGFloat = 720

        var needsAnyWork: Bool { poseEnabled || compositionEnabled || exposureMeterEnabled }
    }

    struct Diagnostics: Equatable {
        var analyzedFrames: Int = 0
        var skippedFrames: Int = 0
        var visionFailures: Int = 0
        var lastAnalysisDuration: Double = 0
        var lastAnalysisAt: Date?
        var personDetectedInLastFrame: Bool = false

        var analysisFPS: Double = 0

        /// 由相邻两次统计的「累计分析帧数 + 时间点」算出滚动帧率。
        ///
        /// 抽成纯函数是为了能被单元测试守住：这个值直接决定「实时分析到底跑得多快、
        /// 会不会拖垮耗电与发热」的判断，写错了会给出一个看着正常、其实毫无意义的数字。
        ///
        /// 边界约定（都有测试）：
        /// - 还没有基线 → 0（宁可显示 0，也不拿开机时长当分母）
        /// - 时间没有前进 → 0（不产生除零或无穷大）
        /// - 帧数倒退（`reset()` 之后）→ 0，而不是负数
        static func rollingRate(previousFrames: Int,
                                currentFrames: Int,
                                elapsed: TimeInterval,
                                hasBaseline: Bool) -> Double {
            guard hasBaseline, elapsed > 0 else { return 0 }
            let delta = currentFrames - previousFrames
            guard delta > 0 else { return 0 }
            return Double(delta) / elapsed
        }
    }

    // MARK: - 回调（均在主线程调用）

    /// 姿态分析结果（含原始关键点，供骨架绘制使用）
    var onPoseResult: ((BodyPose, PoseReport) -> Void)?
    /// 构图分析结果
    var onCompositionResult: ((CompositionReport) -> Void)?
    /// 亮度分布计量结果（曝光辅助，由像素真实计算）
    var onExposureMetrics: ((ImageQualityMetrics) -> Void)?
    /// 管线运行统计（真实分析帧数，可用于诊断耗电与性能）
    var onDiagnostics: ((Diagnostics) -> Void)?

    // MARK: - 内部状态

    private let analysisQueue = DispatchQueue(label: "com.lumi.analysis.pipeline", qos: .userInitiated)
    private let poseEstimator = VisionPoseEstimator()
    private let ciContext: CIContext
    private let stateLock = NSLock()

    private var lastSubmitTime: CFTimeInterval = 0
    private var lastDiagnosticsPublish: CFTimeInterval = 0

    /// 实测分析帧率的滚动窗口：上一次统计的时间点与当时的累计分析帧数。
    /// `fpsWindowStart == 0` 表示还没有基线，此时帧率按 0 报告（而不是拿
    /// 累计帧数去除以开机时长 —— 那会永远算出接近 0 的值）。
    /// 与 `diagnostics` 共用 `stateLock` 保护：`publishDiagnostics` 在分析队列上跑，
    /// `reset()` 在主线程上跑。
    private var fpsWindowStart: CFTimeInterval = 0
    private var fpsWindowFrames: Int = 0

    private var options: Options
    private var diagnostics = Diagnostics()

    init(options: Options = Options()) {
        self.options = options
        self.ciContext = CIContext(options: [.cacheIntermediates: false])
    }

    func update(options: Options) {
        stateLock.lock()
        self.options = options
        stateLock.unlock()
    }

    private var currentOptions: Options {
        stateLock.lock()
        defer { stateLock.unlock() }
        return options
    }

    func reset() {
        stateLock.lock()
        diagnostics = Diagnostics()
        fpsWindowStart = 0
        fpsWindowFrames = 0
        stateLock.unlock()
    }

    // MARK: - 帧提交

    /// 提交一帧。内部自行节流，调用方可以直接把每一帧都丢进来。
    func submit(pixelBuffer: CVPixelBuffer,
                frameSize: CGSize,
                orientation: CGImagePropertyOrientation,
                timestamp: Double) {
        let opts = currentOptions
        guard opts.needsAnyWork else { return }

        let now = CACurrentMediaTime()
        let minimumInterval = 1.0 / Double(max(opts.maxFPS, 1))
        if now - lastSubmitTime < minimumInterval {
            bump { $0.skippedFrames += 1 }
            return
        }
        lastSubmitTime = now

        // CVPixelBuffer 是引用计数对象：这里保留引用后异步处理是安全的，
        // 采集管线会在池中另行分配缓冲区，因此不会读到被复用的内存。
        analysisQueue.async { [weak self] in
            guard let self else { return }
            let started = CACurrentMediaTime()
            self.process(pixelBuffer: pixelBuffer,
                         frameSize: frameSize,
                         orientation: orientation,
                         timestamp: timestamp,
                         options: opts)
            let duration = CACurrentMediaTime() - started
            self.bump { d in
                d.analyzedFrames += 1
                d.lastAnalysisDuration = duration
                d.lastAnalysisAt = Date()
            }
        }
    }

    /// 提交一帧 CGImage（静态照片分析路径复用同一套 Vision 封装）
    func submit(cgImage: CGImage,
                frameSize: CGSize,
                orientation: CGImagePropertyOrientation,
                timestamp: Double = 0) {
        let opts = currentOptions
        guard opts.needsAnyWork else { return }
        analysisQueue.async { [weak self] in
            guard let self else { return }
            let started = CACurrentMediaTime()
            self.process(cgImage: cgImage,
                         frameSize: frameSize,
                         orientation: orientation,
                         timestamp: timestamp,
                         options: opts)
            let duration = CACurrentMediaTime() - started
            self.bump { d in
                d.analyzedFrames += 1
                d.lastAnalysisDuration = duration
                d.lastAnalysisAt = Date()
            }
        }
    }

    // MARK: - 处理

    private func process(pixelBuffer: CVPixelBuffer,
                         frameSize: CGSize,
                         orientation: CGImagePropertyOrientation,
                         timestamp: Double,
                         options: Options) {
        let scaled = scaledPixelBuffer(from: pixelBuffer, maxDimension: options.analysisMaxDimension)

        if options.exposureMeterEnabled {
            publishExposureMetrics(from: scaled)
        }

        guard options.poseEnabled || options.compositionEnabled else { return }

        guard let pose = poseEstimator.detectBodyPose(in: scaled,
                                                      orientation: orientation,
                                                      timestamp: timestamp) else {
            bump { $0.visionFailures += 1; $0.personDetectedInLastFrame = false }
            publishNoPerson(frameSize: frameSize, options: options)
            return
        }
        publish(pose: pose, frameSize: frameSize, options: options)
    }

    private func process(cgImage: CGImage,
                         frameSize: CGSize,
                         orientation: CGImagePropertyOrientation,
                         timestamp: Double,
                         options: Options) {
        if options.exposureMeterEnabled,
           let metrics = ImageQualityCalculator.metrics(from: cgImage, subjectBox: nil, targetWidth: 320) {
            DispatchQueue.main.async { [weak self] in
                self?.onExposureMetrics?(metrics)
            }
        }

        guard options.poseEnabled || options.compositionEnabled else { return }

        guard let pose = poseEstimator.detectBodyPose(in: cgImage,
                                                      orientation: orientation,
                                                      timestamp: timestamp) else {
            bump { $0.visionFailures += 1; $0.personDetectedInLastFrame = false }
            publishNoPerson(frameSize: frameSize, options: options)
            return
        }
        publish(pose: pose, frameSize: frameSize, options: options)
    }

    /// 曝光辅助：把已缩放的像素缓冲转成 CGImage，再按 320px 灰度缓冲计算亮度分布。
    /// 计算量很小（约 10 万像素），因此可以跟随分析帧率实时运行。
    private func publishExposureMetrics(from pixelBuffer: CVPixelBuffer) {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let rect = image.extent
        guard rect.width > 1, rect.height > 1,
              let cgImage = ciContext.createCGImage(image, from: rect) else { return }
        guard let metrics = ImageQualityCalculator.metrics(from: cgImage,
                                                          subjectBox: nil,
                                                          targetWidth: 320) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onExposureMetrics?(metrics)
        }
    }

    private func publish(pose: BodyPose, frameSize: CGSize, options: Options) {
        bump { $0.personDetectedInLastFrame = true }

        if options.compositionEnabled {
            let composition = CompositionAnalyzer.analyze(pose: pose,
                                                         frameSize: frameSize,
                                                         backgroundClutter: nil)
            DispatchQueue.main.async { [weak self] in
                self?.onCompositionResult?(composition)
            }
        }

        if options.poseEnabled {
            let poseReport = PoseAnalyzer.analyze(pose)
            DispatchQueue.main.async { [weak self] in
                self?.onPoseResult?(pose, poseReport)
            }
        }

        publishDiagnostics()
    }

    private func publishNoPerson(frameSize: CGSize, options: Options) {
        if options.compositionEnabled {
            let report = CompositionAnalyzer.analyze(pose: .empty,
                                                     frameSize: frameSize,
                                                     backgroundClutter: nil)
            DispatchQueue.main.async { [weak self] in
                self?.onCompositionResult?(report)
            }
        }
        if options.poseEnabled {
            DispatchQueue.main.async { [weak self] in
                self?.onPoseResult?(BodyPose.empty, PoseReport.empty)
            }
        }
        publishDiagnostics()
    }

    private func publishDiagnostics() {
        let now = CACurrentMediaTime()
        // 统计信息最多每 0.5 秒推一次，避免 UI 高频刷新
        guard now - lastDiagnosticsPublish >= 0.5 else { return }
        lastDiagnosticsPublish = now

        stateLock.lock()
        var snapshot = diagnostics
        let previousWindowStart = fpsWindowStart
        let previousWindowFrames = fpsWindowFrames
        fpsWindowStart = now
        fpsWindowFrames = snapshot.analyzedFrames
        stateLock.unlock()

        // 实测分析帧率 = 本窗口内新增的分析帧数 ÷ 窗口时长。
        //
        // 这里刻意不用「累计帧数 ÷ 开机时长」：CACurrentMediaTime() 是**开机以来的秒数**
        // （真机上动辄几万秒），拿它当分母会让帧率恒等于 0.0 —— 属于「界面上有指标、
        // 但数值是废数」的那类错误。诊断页要显示它，所以必须先让它是对的。
        snapshot.analysisFPS = Diagnostics.rollingRate(
            previousFrames: previousWindowFrames,
            currentFrames: snapshot.analyzedFrames,
            elapsed: now - previousWindowStart,
            hasBaseline: previousWindowStart > 0
        )

        DispatchQueue.main.async { [weak self] in
            self?.onDiagnostics?(snapshot)
        }
    }

    private func bump(_ mutate: (inout Diagnostics) -> Void) {
        stateLock.lock()
        mutate(&diagnostics)
        stateLock.unlock()
    }

    // MARK: - 降采样

    /// 把输入帧缩放到最大边长 `maxDimension`，减少 Vision 计算量。
    /// 缩放失败时退化为原帧（宁可慢一点，也不能丢帧）。
    private func scaledPixelBuffer(from pixelBuffer: CVPixelBuffer, maxDimension: CGFloat) -> CVPixelBuffer {
        let width = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        let longest = max(width, height)
        guard longest > maxDimension, longest > 0 else { return pixelBuffer }

        let scale = maxDimension / longest
        let targetWidth = max(Int((width * scale).rounded()), 16)
        let targetHeight = max(Int((height * scale).rounded()), 16)

        var destination: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault,
                                         targetWidth,
                                         targetHeight,
                                         kCVPixelFormatType_32BGRA,
                                         attributes as CFDictionary,
                                         &destination)
        guard status == kCVReturnSuccess, let output = destination else { return pixelBuffer }

        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        ciContext.render(scaled,
                         to: output,
                         bounds: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight),
                         colorSpace: CGColorSpaceCreateDeviceRGB())
        return output
    }
}
