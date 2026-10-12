import Foundation
import CoreGraphics
import ImageIO

/// 静态照片分析器。
///
/// 输入：用户主动挑选并导入 App 的照片副本数据。
/// 输出：``PhotoAnalysisSummary`` ——每一项都有真实计算依据：
/// - 清晰度：拉普拉斯方差（像素计算）
/// - 曝光：亮度均值 / 过曝欠曝像素比例（像素计算）
/// - 闭眼：Vision 人脸特征点的眼部开合比例（启发式，标注清楚）
/// - 姿态：Vision 人体关键点几何（真实角度）
/// - 构图：``CompositionAnalyzer``（真实关键点 + 背景边缘密度）
enum PhotoAnalyzer {

    struct Result {
        var exif: ExifSummary?
        var summary: PhotoAnalysisSummary
        /// 原始姿态报告，便于详情页展示角度明细
        var poseReport: PoseReport?
        var compositionReport: CompositionReport?
        var metrics: ImageQualityMetrics?
    }

    static func analyze(data: Data, importedAt: Date = Date()) -> Result? {
        guard let decoded = ImageQualityCalculator.decodeImage(data: data) else { return nil }
        let image = decoded.image
        let orientation = decoded.orientation

        let exif = ExifReader.read(from: data)

        // 1. 人体姿态
        let estimator = VisionPoseEstimator()
        let pose = estimator.detectBodyPose(in: image, orientation: orientation, timestamp: 0)
        let poseReport = pose.map { PoseAnalyzer.analyze($0) }

        // 2. 构图（传入人物框用于计算背景细节密度）
        let frameSize = CGSize(width: image.width, height: image.height)
        let composition = CompositionAnalyzer.analyze(pose: pose ?? .empty,
                                                     frameSize: frameSize,
                                                     backgroundClutter: nil)

        // 3. 画质指标（人物框用于分离背景区域）
        let metrics = ImageQualityCalculator.metrics(from: image,
                                                    subjectBox: composition.subjectBoundingBox)

        // 4. 背景细节密度回填到构图报告
        var finalComposition = composition
        if let density = metrics?.backgroundEdgeDensity {
            finalComposition = CompositionAnalyzer.analyze(pose: pose ?? .empty,
                                                          frameSize: frameSize,
                                                          backgroundClutter: CGFloat(density))
        }

        // 5. 人脸 / 闭眼
        let face = estimator.detectFaces(in: image, orientation: orientation)

        let summary = buildSummary(metrics: metrics,
                                   pose: poseReport,
                                   composition: finalComposition,
                                   face: face,
                                   analyzedAt: Date())

        return Result(exif: exif,
                      summary: summary,
                      poseReport: poseReport,
                      compositionReport: finalComposition,
                      metrics: metrics)
    }

    // MARK: - 汇总为可展示的结果

    private static func buildSummary(metrics: ImageQualityMetrics?,
                                     pose: PoseReport?,
                                     composition: CompositionReport,
                                     face: VisionPoseEstimator.FaceDetectionResult,
                                     analyzedAt: Date) -> PhotoAnalysisSummary {

        let sharpness = metrics?.sharpnessScore ?? 0
        let brightness = metrics?.meanLuminance ?? 0
        let contrast = metrics?.luminanceStdDev ?? 0

        var suggestions: [String] = []
        var penaltyScore = 0.0

        // 清晰度
        switch ImageQualityCalculator.normalizeSharpness(metrics?.laplacianVariance ?? 0) {
        case 0.6...:
            break
        case 0.35..<0.6:
            suggestions.append("清晰度尚可（拉普拉斯方差 \(format(metrics?.laplacianVariance))），放大到 100% 复核眼部与发丝。")
            penaltyScore += 8
        case 0.15..<0.35:
            suggestions.append("画面偏软（拉普拉斯方差 \(format(metrics?.laplacianVariance))）。这类片子适合缩略图使用，不建议放大或重裁。")
            penaltyScore += 22
        default:
            suggestions.append("清晰度明显不足（拉普拉斯方差 \(format(metrics?.laplacianVariance))），大概率是虚焦或快门过慢，建议优先剔除。")
            penaltyScore += 38
        }

        // 曝光
        if let metrics {
            if metrics.overexposedRatio > 0.06 {
                suggestions.append(String(format: "高光溢出像素占 %.1f%%，注意面部高光与白色衣物是否已经死白。", metrics.overexposedPercent))
                penaltyScore += 10
            }
            if metrics.underexposedRatio > 0.35 {
                suggestions.append(String(format: "暗部像素占 %.1f%%，画面整体欠曝，提亮时噪点会明显。", metrics.underexposedPercent))
                penaltyScore += 10
            }
        }

        // 闭眼
        switch face.closedEyeRisk {
        case .suspectedClosed:
            suggestions.append("疑似闭眼（\(face.detail)）。这是基于特征点比例的启发式判断，请放大确认后再决定是否剔除。")
            penaltyScore += 30
        case .uncertain:
            suggestions.append("眼部状态无法确定（\(face.detail)），建议人工确认。")
        case .noFaceDetected:
            if pose?.isDetected == true {
                suggestions.append("检测到人体但未检测到人脸，可能是侧背身或面部被遮挡。")
            }
        default:
            break
        }

        // 姿态
        var poseFindings: [String] = []
        if let pose, pose.isDetected {
            poseFindings = pose.coachTips.map { "\($0.title)：\($0.detail)" }
            if pose.confidence < 0.3 {
                suggestions.append(String(format: "人体关键点置信度偏低（%.0f%%），姿态结论仅供参考。", pose.confidence * 100))
            }
        } else {
            poseFindings = ["未检测到人体姿态，无法给出姿态评估。"]
        }

        // 构图
        var compositionFindings = composition.findings.map { "\($0.title)：\($0.detail)" }
        var compositionScore = 100.0
        for finding in composition.findings {
            switch finding.level {
            case .warning: compositionScore -= 25
            case .attention: compositionScore -= 12
            case .good, .info: break
            }
        }
        compositionScore = min(max(compositionScore, 0), 100)

        if !composition.isSubjectPresent {
            compositionFindings = ["未检测到人物，无法进行人像构图评估。"]
            compositionScore = 0
        }

        let overall = min(max(100 - penaltyScore - (100 - compositionScore) * 0.35, 0), 100)

        if suggestions.isEmpty {
            suggestions.append("各项客观指标均在可用范围内：清晰度 \(ImageQualityCalculator.normalizeSharpness(metrics?.laplacianVariance ?? 0) >= 0.6 ? "锐利" : "可用")，曝光分布正常，未发现明显问题。")
        }

        return PhotoAnalysisSummary(sharpnessScore: sharpness,
                                    sharpnessLabel: metrics?.sharpnessLabel ?? "未评估",
                                    brightness: brightness,
                                    exposureLabel: metrics?.exposureLabel ?? "未评估",
                                    contrast: contrast,
                                    closedEyeRisk: face.closedEyeRisk,
                                    faceCount: face.faceCount,
                                    personCount: (pose?.isDetected ?? false) ? 1 : 0,
                                    poseFindings: poseFindings,
                                    compositionFindings: compositionFindings,
                                    compositionScore: compositionScore,
                                    suggestions: suggestions,
                                    overallScore: overall,
                                    analyzedAt: analyzedAt)
    }

    private static func format(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.1f", value)
    }

    /// 顶层筛选结论（供列表页快速判断）
    static func verdict(for summary: PhotoAnalysisSummary) -> ScreeningVerdict {
        if summary.closedEyeRisk == .suspectedClosed { return .review }
        if summary.sharpnessScore < 0.15 { return .considerDiscard }
        if summary.overallScore >= 70 { return .keep }
        if summary.overallScore >= 45 { return .review }
        return .considerDiscard
    }
}
