import SwiftUI

/// 人体骨架绘制层。
///
/// 关键点与连线**全部来自当帧 Vision 检测结果**：没有检测到就没有骨架，绝不绘制示意骨架。
/// 低置信度的关节会以更低透明度、更小半径绘制，让摄影师一眼看出哪些部位不可信。
struct PoseSkeletonView: View {

    let pose: BodyPose
    /// 低于该置信度的关节不绘制
    var minimumConfidence: Float = 0.2
    var lineWidth: CGFloat = 2
    var showsJoints: Bool = true
    var dimsUnreliableJoints: Bool = true

    var body: some View {
        Canvas { context, size in
            guard !pose.isEmpty else { return }

            // 1. 骨架连线
            for edge in BodyJoint.skeletonEdges {
                guard let a = pose.points[edge.0], let b = pose.points[edge.1] else { continue }
                let confidence = min(a.confidence, b.confidence)
                guard confidence >= minimumConfidence else { continue }

                var path = Path()
                path.move(to: renderPoint(a.location, in: size))
                path.addLine(to: renderPoint(b.location, in: size))

                let opacity = dimsUnreliableJoints ? Double(0.35 + 0.6 * Double(min(confidence, 1))) : 1.0
                context.stroke(path,
                               with: .color(LumiTheme.jointColor(confidence: confidence).opacity(opacity)),
                               style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            }

            // 2. 关节
            if showsJoints {
                for point in pose.points.values where point.confidence >= minimumConfidence {
                    let center = renderPoint(point.location, in: size)
                    let radius = 2.5 + CGFloat(point.confidence) * 3.0
                    let rect = CGRect(x: center.x - radius, y: center.y - radius,
                                      width: radius * 2, height: radius * 2)
                    let opacity = dimsUnreliableJoints ? Double(0.4 + 0.6 * Double(min(point.confidence, 1))) : 1.0
                    context.fill(Path(ellipseIn: rect),
                                 with: .color(LumiTheme.jointColor(confidence: point.confidence).opacity(opacity)))
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// Vision 坐标（原点左下）→ 屏幕坐标（原点左上）
    private func renderPoint(_ normalized: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: normalized.x * size.width, y: (1 - normalized.y) * size.height)
    }
}

/// 人物包围框叠加层（可选开启，用于验证检测范围是否合理）
struct SubjectBoundingBoxView: View {
    let boundingBox: CGRect

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let rect = CGRect(x: boundingBox.minX * size.width,
                              y: (1 - boundingBox.maxY) * size.height,
                              width: boundingBox.width * size.width,
                              height: boundingBox.height * size.height)
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .stroke(LumiTheme.accent.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                Text("检测区域")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(LumiTheme.accent)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(LumiTheme.surfaceSunken.opacity(0.75))
                    .cornerRadius(4)
                    .position(x: rect.midX, y: max(rect.minY - 10, 8))
            }
        }
        .allowsHitTesting(false)
    }
}
