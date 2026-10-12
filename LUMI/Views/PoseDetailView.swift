import SwiftUI
import UIKit

/// 姿势详情：把一条姿势拆成可以直接照做的步骤。
struct PoseDetailView: View {

    @EnvironmentObject private var favorites: FavoritesStore

    let pose: PoseSuggestion
    var reasons: [String] = []

    @State private var copied = false

    private var steps: [PoseStep] { PoseScriptWriter.steps(for: pose) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                schematic
                stepSection
                compositionSection
                sceneSection
                if !reasons.isEmpty { reasonSection }
                copyButton
            }
            .padding(LumiTheme.screenPadding)
            .padding(.bottom, 28)
        }
        .background(LumiTheme.background.ignoresSafeArea())
        .navigationTitle(pose.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    favorites.toggleFavorite(pose.id)
                } label: {
                    Image(systemName: favorites.isFavorite(pose.id) ? "heart.fill" : "heart")
                        .foregroundStyle(favorites.isFavorite(pose.id) ? LumiTheme.danger : LumiTheme.secondaryText)
                }
            }
        }
        .onAppear {
            favorites.markVisited(pose.id)
        }
    }

    // MARK: - 头部信息

    private var header: some View {
        LumiCard(highlighted: true) {
            VStack(alignment: .leading, spacing: 10) {
                Text(pose.name)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(LumiTheme.primaryText)
                Text(pose.summary)
                    .font(.system(size: 13))
                    .foregroundStyle(LumiTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    StatusPill(text: pose.shotType.title, color: LumiTheme.accent, symbol: nil)
                    StatusPill(text: "难度 \(pose.difficulty)", color: difficultyColor, symbol: nil)
                    if pose.difficulty == 1 {
                        StatusPill(text: "新手友好", color: LumiTheme.success, symbol: "checkmark")
                    }
                }

                if !pose.keywords.isEmpty {
                    Text("关键词：" + pose.keywords.joined(separator: " / "))
                        .font(.system(size: 11))
                        .foregroundStyle(LumiTheme.tertiaryText)
                }
            }
        }
    }

    private var difficultyColor: Color {
        switch pose.difficulty {
        case 1: return LumiTheme.success
        case 2: return LumiTheme.warning
        default: return LumiTheme.danger
        }
    }

    // MARK: - 示意（由参数生成，明确标注为抽象示意）

    private var schematic: some View {
        LumiCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "方向与位置示意", subtitle: "由本条姿势的参数生成", trailingText: nil)

                HStack(alignment: .center, spacing: 16) {
                    PoseDirectionDiagram(pose: pose)
                        .frame(width: 130, height: 130)
                    VStack(alignment: .leading, spacing: 8) {
                        InfoRow(label: "身体朝向", value: pose.bodyRotation.isFacing ? "正对镜头" : pose.bodyRotation.descriptiveText)
                        InfoRow(label: "头部转动", value: pose.headTurn.isFacing ? "正对镜头" : pose.headTurn.descriptiveText)
                        InfoRow(label: "视线", value: pose.gaze.anchor.title)
                        InfoRow(label: "重心", value: pose.weight == .even ? "均匀" : "偏向一侧")
                    }
                }

                PoseCompositionDiagram(pose: pose)
                    .frame(height: 96)

                LimitationBadge(text: "以上为抽象方向示意，用于说明角度与位置关系，不是参考照片。本项目不提供模特示例图。")
            }
        }
    }

    // MARK: - 动作分解

    private var stepSection: some View {
        LumiCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "动作分解", subtitle: "按顺序执行，每一句都可直接照做", trailingText: "\(steps.count) 步")

                ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                    HStack(alignment: .top, spacing: 10) {
                        ZStack {
                            Circle()
                                .fill(LumiTheme.accentSoft)
                                .frame(width: 24, height: 24)
                            Text("\(index + 1)")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundStyle(LumiTheme.accent)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 5) {
                                Image(systemName: step.category.symbolName)
                                    .font(.system(size: 10))
                                    .foregroundStyle(LumiTheme.tertiaryText)
                                Text(step.category.title)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(LumiTheme.secondaryText)
                            }
                            Text(step.text)
                                .font(.system(size: 13))
                                .foregroundStyle(LumiTheme.primaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if index != steps.count - 1 {
                        Divider().overlay(LumiTheme.stroke)
                    }
                }
            }
        }
    }

    // MARK: - 构图

    private var compositionSection: some View {
        LumiCard {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "建议构图", subtitle: nil, trailingText: nil)
                InfoRow(label: "人物位置", value: pose.composition.horizontalAnchorText)
                InfoRow(label: "头顶留白", value: pose.composition.headroomText)
                InfoRow(label: "视线留白", value: pose.composition.needsLeadRoom ? "需要在视线方向留出空间" : "不强制")
                if !pose.composition.note.isEmpty {
                    Text(pose.composition.note)
                        .font(.system(size: 12))
                        .foregroundStyle(LumiTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - 适用场景与提示

    private var sceneSection: some View {
        LumiCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "适合的拍摄场景", subtitle: nil, trailingText: nil)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
                    ForEach(pose.scenes) { scene in
                        Text(scene.title)
                            .font(.system(size: 12))
                            .foregroundStyle(LumiTheme.secondaryText)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .frame(maxWidth: .infinity)
                            .background(LumiTheme.surfaceElevated)
                            .clipShape(RoundedRectangle(cornerRadius: LumiTheme.smallCornerRadius, style: .continuous))
                    }
                }

                SectionHeader(title: "适合的风格", subtitle: nil, trailingText: nil)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
                    ForEach(pose.styles) { style in
                        Text(style.title)
                            .font(.system(size: 12))
                            .foregroundStyle(LumiTheme.secondaryText)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .frame(maxWidth: .infinity)
                            .background(LumiTheme.surfaceElevated)
                            .clipShape(RoundedRectangle(cornerRadius: LumiTheme.smallCornerRadius, style: .continuous))
                    }
                }

                Divider().overlay(LumiTheme.stroke)

                SectionHeader(title: "摄影师执行提示", subtitle: nil, trailingText: nil)
                Text(pose.photographerTips)
                    .font(.system(size: 13))
                    .foregroundStyle(LumiTheme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)

                SectionHeader(title: "环境互动", subtitle: nil, trailingText: nil)
                Text(pose.environment)
                    .font(.system(size: 13))
                    .foregroundStyle(LumiTheme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var reasonSection: some View {
        LumiCard {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "为什么推荐这条", subtitle: "本地规则引擎给出的匹配理由", trailingText: nil)
                ForEach(Array(reasons.enumerated()), id: \.offset) { _, reason in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 10))
                            .foregroundStyle(LumiTheme.accent)
                            .padding(.top, 2)
                        Text(reason)
                            .font(.system(size: 12))
                            .foregroundStyle(LumiTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var copyButton: some View {
        PrimaryButton(title: copied ? "已复制到剪贴板" : "复制全部指令", symbol: copied ? "checkmark" : "doc.on.doc") {
            let text = pose.name + "\n" + pose.summary + "\n\n"
                + steps.map { "· \($0.category.title)：\($0.text)" }.joined(separator: "\n")
            UIPasteboard.general.string = text
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
        }
    }
}

// MARK: - 方向示意（俯视图）

/// 俯视方向示意：相机在下方，箭头表示身体朝向，虚线箭头表示头部朝向。
/// 角度与方向**直接来自姿势参数**，不做任何美化或估算。
struct PoseDirectionDiagram: View {

    let pose: PoseSuggestion

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2 - 6)
            let radius = min(size.width, size.height) / 2 - 18

            // 参考圆
            context.stroke(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                                  width: radius * 2, height: radius * 2)),
                           with: .color(Color.white.opacity(0.12)),
                           style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

            // 相机位置（下方）
            let cameraY = size.height - 10
            var cameraPath = Path()
            cameraPath.move(to: CGPoint(x: center.x - 22, y: cameraY))
            cameraPath.addLine(to: CGPoint(x: center.x + 22, y: cameraY))
            context.stroke(cameraPath, with: .color(LumiTheme.accent.opacity(0.8)), lineWidth: 3)
            context.draw(Text("相机").font(.system(size: 8)).foregroundColor(LumiTheme.accent),
                         at: CGPoint(x: center.x, y: cameraY + 7))

            // 身体朝向箭头（0° = 指向相机 = 屏幕向下）
            let bodyAngle = angleFor(direction: pose.bodyRotation.direction, degrees: pose.bodyRotation.degrees, base: 90)
            drawArrow(context: &context,
                      from: center,
                      angleDegrees: bodyAngle,
                      length: radius * 0.85,
                      color: LumiTheme.primaryText,
                      lineWidth: 2,
                      label: pose.bodyRotation.isFacing ? "0°" : "\(pose.bodyRotation.degrees)°")

            // 头部朝向（更短的箭头）
            let headAngle = angleFor(direction: pose.headTurn.direction, degrees: pose.headTurn.degrees, base: 90)
            if !pose.headTurn.isFacing {
                drawArrow(context: &context,
                          from: center,
                          angleDegrees: headAngle,
                          length: radius * 0.5,
                          color: LumiTheme.warning,
                          lineWidth: 1.5,
                          label: "\(pose.headTurn.degrees)°")
            }

            // 人物位置点
            context.fill(Path(ellipseIn: CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8)),
                         with: .color(LumiTheme.accent))
        }
    }

    /// 屏幕坐标系（y 向下）：90° = 指向下方（相机方向）
    private func angleFor(direction: RotationDirection, degrees: Int, base: Double) -> Double {
        switch direction {
        case .none: return base
        case .left: return base + Double(degrees)
        case .right: return base - Double(degrees)
        }
    }

    private func drawArrow(context: inout GraphicsContext,
                           from center: CGPoint,
                           angleDegrees: Double,
                           length: CGFloat,
                           color: Color,
                           lineWidth: CGFloat,
                           label: String) {
        let radians = angleDegrees * .pi / 180
        let end = CGPoint(x: center.x + length * CGFloat(cos(radians)),
                          y: center.y + length * CGFloat(sin(radians)))

        var path = Path()
        path.move(to: center)
        path.addLine(to: end)
        context.stroke(path, with: .color(color.opacity(0.9)),
                       style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))

        // 箭头
        let headLength: CGFloat = 7
        let left = angleDegrees + 155
        let right = angleDegrees - 155
        for angle in [left, right] {
            let r = angle * .pi / 180
            var head = Path()
            head.move(to: end)
            head.addLine(to: CGPoint(x: end.x + headLength * CGFloat(cos(r)),
                                     y: end.y + headLength * CGFloat(sin(r))))
            context.stroke(head, with: .color(color.opacity(0.9)), lineWidth: lineWidth)
        }

        // 角度标注
        context.draw(Text(label)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(color),
                     at: CGPoint(x: end.x + 10, y: end.y - 6))
    }
}

// MARK: - 构图位置示意

/// 构图位置示意：在取景框里标出建议的人物水平位置与头顶留白。
/// 位置数值来自 ``PoseComposition`` 参数，与姿势建议文字保持一致。
struct PoseCompositionDiagram: View {

    let pose: PoseSuggestion

    var body: some View {
        Canvas { context, size in
            let frame = CGRect(x: 6, y: 6, width: size.width - 12, height: size.height - 12)
            context.stroke(Path(frame), with: .color(LumiTheme.strokeStrong), lineWidth: 1)

            // 三分线参考
            var thirds = Path()
            for index in 1...2 {
                let x = frame.minX + frame.width * CGFloat(index) / 3
                thirds.move(to: CGPoint(x: x, y: frame.minY))
                thirds.addLine(to: CGPoint(x: x, y: frame.maxY))
            }
            context.stroke(thirds, with: .color(Color.white.opacity(0.12)), lineWidth: 1)

            // 建议人物水平位置
            let anchorX = frame.minX + frame.width * CGFloat(pose.composition.horizontalAnchor)
            var anchorLine = Path()
            anchorLine.move(to: CGPoint(x: anchorX, y: frame.minY))
            anchorLine.addLine(to: CGPoint(x: anchorX, y: frame.maxY))
            context.stroke(anchorLine,
                           with: .color(LumiTheme.accent.opacity(0.8)),
                           style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))

            // 建议头顶位置
            let headY = frame.minY + frame.height * CGFloat(pose.composition.headAnchor)
            var headLine = Path()
            headLine.move(to: CGPoint(x: frame.minX, y: headY))
            headLine.addLine(to: CGPoint(x: frame.maxX, y: headY))
            context.stroke(headLine, with: .color(LumiTheme.warning.opacity(0.7)),
                           style: StrokeStyle(lineWidth: 1, dash: [4, 3]))

            context.draw(Text("建议人物位置").font(.system(size: 8)).foregroundColor(LumiTheme.accent),
                         at: CGPoint(x: max(anchorX - 34, 42), y: frame.maxY - 10))
            context.draw(Text(String(format: "头顶留白 %.0f%%", pose.composition.headroomRatio * 100))
                .font(.system(size: 8)).foregroundColor(LumiTheme.warning),
                         at: CGPoint(x: frame.midX + 40, y: max(headY - 8, frame.minY + 10)))
        }
    }
}
