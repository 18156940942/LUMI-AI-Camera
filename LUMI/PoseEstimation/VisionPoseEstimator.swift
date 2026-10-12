import Foundation
import Vision
import CoreGraphics
import ImageIO
import CoreVideo

/// Vision 人体姿态检测的封装。
///
/// - 只做一件事：把像素帧或图片变成 ``BodyPose``。
/// - 全部在本机运行，不上传任何像素或关键点数据。
/// - 低置信度不会被「抹平」成确定结论：置信度原样带出，由上层决定是否降级显示。
final class VisionPoseEstimator {

    private let bodyPoseRequest = VNDetectHumanBodyPoseRequest()
    private let faceRequest = VNDetectFaceLandmarksRequest()
    private let faceRectRequest = VNDetectFaceRectanglesRequest()

    /// 串行队列，避免多帧并发跑 Vision 造成内存峰值
    private let queue = DispatchQueue(label: "com.lumi.vision.pose", qos: .userInitiated)

    // MARK: - 人体姿态

    func detectBodyPose(in pixelBuffer: CVPixelBuffer,
                        orientation: CGImagePropertyOrientation = .up,
                        timestamp: Double) -> BodyPose? {
        var result: BodyPose?
        queue.sync {
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
            do {
                try handler.perform([bodyPoseRequest])
                guard let observation = bodyPoseRequest.results?.first else {
                    result = nil
                    return
                }
                result = Self.convert(observation: observation, timestamp: timestamp)
            } catch {
                AppLog.pose.error("人体姿态检测失败: \(String(describing: error))")
                result = nil
            }
        }
        return result
    }

    func detectBodyPose(in cgImage: CGImage,
                        orientation: CGImagePropertyOrientation = .up,
                        timestamp: Double = 0) -> BodyPose? {
        var result: BodyPose?
        queue.sync {
            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
            do {
                try handler.perform([bodyPoseRequest])
                guard let observation = bodyPoseRequest.results?.first else {
                    result = nil
                    return
                }
                result = Self.convert(observation: observation, timestamp: timestamp)
            } catch {
                AppLog.pose.error("人体姿态检测失败: \(String(describing: error))")
                result = nil
            }
        }
        return result
    }

    private static func convert(observation: VNHumanBodyPoseObservation, timestamp: Double) -> BodyPose {
        var points: [BodyJoint: BodyJointPoint] = [:]

        if let recognized = try? observation.recognizedPoints(.all) {
            for joint in BodyJoint.allCases {
                guard let point = recognized[joint.visionName] else { continue }
                points[joint] = BodyJointPoint(joint: joint,
                                               location: point.location,
                                               confidence: point.confidence)
            }
        }

        let pose = BodyPose(points: points,
                            overallConfidence: 0,
                            timestamp: timestamp,
                            detectedJointCount: points.count)

        // 综合置信度：以「躯干核心点」为主，因为这些点决定了角度计算是否可信
        let coreJoints: [BodyJoint] = [
            .neck, .leftShoulder, .rightShoulder, .leftHip, .rightHip, .nose
        ]
        let coreConfidences = coreJoints.map { pose.confidence($0) }
        let average = coreConfidences.reduce(0, +) / Float(coreConfidences.count)
        let reliableRatio = Float(pose.validJointCount) / Float(BodyJoint.allCases.count)
        let combined = average * 0.7 + reliableRatio * 0.3

        return BodyPose(points: points,
                        overallConfidence: combined,
                        timestamp: timestamp,
                        detectedJointCount: points.count)
    }

    // MARK: - 人脸（用于闭眼启发式判定与人数统计）

    struct FaceDetectionResult {
        var faceCount: Int
        var closedEyeRisk: ClosedEyeRisk
        /// 用于 UI 说明的细节，例如「眼睛开合比例 0.31」
        var detail: String
    }

    func detectFaces(in cgImage: CGImage,
                     orientation: CGImagePropertyOrientation = .up) -> FaceDetectionResult {
        var result = FaceDetectionResult(faceCount: 0, closedEyeRisk: .noFaceDetected, detail: "未检测到人脸")
        queue.sync {
            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
            do {
                try handler.perform([faceRectRequest, faceRequest])
                let rects = faceRectRequest.results ?? []
                result.faceCount = rects.count
                guard let face = faceRequest.results?.first, let landmarks = face.landmarks else {
                    result.closedEyeRisk = rects.isEmpty ? .noFaceDetected : .uncertain
                    result.detail = rects.isEmpty ? "未检测到人脸" : "检测到人脸但特征点不足，无法判断眼睛状态"
                    return
                }

                let imageSize = CGSize(width: cgImage.width, height: cgImage.height)
                let ratios = Self.eyeOpennessRatios(landmarks: landmarks, imageSize: imageSize)
                if let left = ratios.left, let right = ratios.right {
                    let mean = (left + right) / 2
                    result.detail = String(format: "眼部开合比例 左 %.2f / 右 %.2f（阈值 %.2f）",
                                           left, right, Self.closedEyeThreshold)
                    if mean < Self.closedEyeThreshold {
                        result.closedEyeRisk = .suspectedClosed
                    } else {
                        result.closedEyeRisk = .open
                    }
                } else {
                    result.closedEyeRisk = .uncertain
                    result.detail = "眼部特征点不可用，无法判断"
                }
            } catch {
                AppLog.photo.error("人脸检测失败: \(String(describing: error))")
                result.closedEyeRisk = .notAnalyzed
                result.detail = "人脸检测执行失败"
            }
        }
        return result
    }

    /// 眼部开合比例（heuristic）：
    /// 用「上下眼睑点之间的平均距离」除以「眼角点之间的水平距离」。
    /// 眼睛张开时该值较大（约 0.3-0.5），闭合时显著变小（约 <0.15）。
    /// 这是几何启发式，不是经过校准的闭眼分类器 —— UI 上必须如实标注。
    static let closedEyeThreshold: CGFloat = 0.17

    private static func eyeOpennessRatios(landmarks: VNFaceLandmarks2D,
                                          imageSize: CGSize) -> (left: CGFloat?, right: CGFloat?) {
        func ratio(_ region: VNFaceLandmarkRegion2D?) -> CGFloat? {
            guard let region, region.pointCount >= 4 else { return nil }
            // pointsInImage 返回像素坐标数组（与 normalizedPoints 的 C 指针不同，可直接遍历）
            let points = region.pointsInImage(imageSize: imageSize)
            guard points.count >= 4 else { return nil }
            // 眼角：最左与最右的点
            guard let leftMost = points.min(by: { $0.x < $1.x }),
                  let rightMost = points.max(by: { $0.x < $1.x }) else { return nil }
            let width = abs(rightMost.x - leftMost.x)
            guard width > 0.0001 else { return nil }
            let midX = (leftMost.x + rightMost.x) / 2
            // 上下眼睑：靠近中线的上下极值点
            let nearMid = points.filter { abs($0.x - midX) < width * 0.5 }
            guard let top = nearMid.max(by: { $0.y < $1.y }),
                  let bottom = nearMid.min(by: { $0.y < $1.y }) else { return nil }
            let height = abs(top.y - bottom.y)
            return height / width
        }
        return (ratio(landmarks.leftEye), ratio(landmarks.rightEye))
    }
}
