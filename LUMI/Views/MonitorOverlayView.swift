import SwiftUI

/// 监看画面上的参考线叠加层。
///
/// 全部绘制在视频之上、且 `allowsHitTesting(false)`，因此不会挡住任何操作；
/// 所有元素都可以独立开关（对应需求「所有工具都应有明确的开启和关闭控制」）。
struct MonitorOverlayView: View {

    let config: OverlayConfiguration
    /// 人物检测框（Vision 归一化坐标，原点左下）。为 nil 时不绘制。
    var subjectBox: CGRect?
    /// 画面内容区（用于把参考线限制在有效画面内）
    var showsSubjectBox: Bool = false

    var body: some View {
        Canvas { context, size in
            let rect = contentRect(in: size)

            // 构图比例遮罩
            if config.aspect != .native {
                var mask = Path(CGRect(origin: .zero, size: size))
                mask.addRect(rect)
                context.fill(mask, with: .color(.black.opacity(0.55)), style: FillStyle(eoFill: true))
                context.stroke(Path(rect), with: .color(.white.opacity(0.35)), lineWidth: 1)
            }

            let lineColor = Color.white.opacity(0.32)
            let accentColor = LumiTheme.accent.opacity(0.75)

            // 三分法
            if config.showThirds {
                var path = Path()
                for index in 1...2 {
                    let x = rect.minX + rect.width * CGFloat(index) / 3.0
                    path.move(to: CGPoint(x: x, y: rect.minY))
                    path.addLine(to: CGPoint(x: x, y: rect.maxY))
                    let y = rect.minY + rect.height * CGFloat(index) / 3.0
                    path.move(to: CGPoint(x: rect.minX, y: y))
                    path.addLine(to: CGPoint(x: rect.maxX, y: y))
                }
                context.stroke(path, with: .color(lineColor), lineWidth: 1)
            }

            // 九宫格细分线（每格再对半）
            if config.showNineGrid {
                var path = Path()
                for index in 1..<6 {
                    let x = rect.minX + rect.width * CGFloat(index) / 6.0
                    path.move(to: CGPoint(x: x, y: rect.minY))
                    path.addLine(to: CGPoint(x: x, y: rect.maxY))
                    let y = rect.minY + rect.height * CGFloat(index) / 6.0
                    path.move(to: CGPoint(x: rect.minX, y: y))
                    path.addLine(to: CGPoint(x: rect.maxX, y: y))
                }
                context.stroke(path, with: .color(Color.white.opacity(0.14)), lineWidth: 0.75)
            }

            // 中心竖线
            if config.showCenterLines {
                var path = Path()
                path.move(to: CGPoint(x: rect.midX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
                context.stroke(path, with: .color(accentColor.opacity(0.55)), lineWidth: 1)
            }

            // 水平参考线
            if config.showHorizon {
                var path = Path()
                path.move(to: CGPoint(x: rect.minX, y: rect.midY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
                context.stroke(path, with: .color(accentColor.opacity(0.55)), lineWidth: 1)
            }

            // 中心十字标记
            if config.showCenterCross {
                let arm: CGFloat = 14
                var path = Path()
                path.move(to: CGPoint(x: rect.midX - arm, y: rect.midY))
                path.addLine(to: CGPoint(x: rect.midX + arm, y: rect.midY))
                path.move(to: CGPoint(x: rect.midX, y: rect.midY - arm))
                path.addLine(to: CGPoint(x: rect.midX, y: rect.midY + arm))
                context.stroke(path, with: .color(accentColor), lineWidth: 1.5)
            }

            // 安全构图区
            if config.showSafeArea {
                let insetX = rect.width * CGFloat(config.safeAreaInset)
                let insetY = rect.height * CGFloat(config.safeAreaInset)
                let safeRect = rect.insetBy(dx: insetX, dy: insetY)
                context.stroke(Path(safeRect),
                               with: .color(LumiTheme.warning.opacity(0.7)),
                               style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            }

            // 人物检测框（真实检测结果）
            if showsSubjectBox, let subjectBox {
                let boxRect = CGRect(x: rect.minX + subjectBox.minX * rect.width,
                                     y: rect.minY + (1 - subjectBox.maxY) * rect.height,
                                     width: subjectBox.width * rect.width,
                                     height: subjectBox.height * rect.height)
                context.stroke(Path(boxRect),
                               with: .color(LumiTheme.success.opacity(0.85)),
                               style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            }
        }
        .allowsHitTesting(false)
    }

    /// 根据构图比例计算内容区
    private func contentRect(in size: CGSize) -> CGRect {
        guard let ratio = config.aspect.ratio else {
            return CGRect(origin: .zero, size: size)
        }
        let containerRatio = size.width / max(size.height, 1)
        if containerRatio > ratio {
            let width = size.height * ratio
            return CGRect(x: (size.width - width) / 2, y: 0, width: width, height: size.height)
        } else {
            let height = size.width / ratio
            return CGRect(x: 0, y: (size.height - height) / 2, width: size.width, height: height)
        }
    }
}
