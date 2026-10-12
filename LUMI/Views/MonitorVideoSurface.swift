import SwiftUI

/// 监看画面本体：预览 + 参考线 + 骨架 + 状态徽标。
///
/// 监看页与实时指导页共用这一个视图，保证两处看到的画面完全一致
/// （同一个视频源、同一帧、同一套参考线）。
struct MonitorVideoSurface: View {

    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var videoInput: VideoInputManager

    var showsOverlay: Bool = true
    var showsSkeleton: Bool = false
    var subjectBox: CGRect?
    var showsStatusBar: Bool = true
    /// 内容未连接时是否显示详细引导（全屏模式下简化为一行）
    var showsGuidance: Bool = true

    var body: some View {
        ZStack {
            Color.black

            if let provider = videoInput.previewProvider {
                switch provider {
                case .captureSession(let session):
                    CapturePreviewView(session: session,
                                       gravity: settings.gravity,
                                       zoom: previewZoom,
                                       rotationAngle: nil)
                        .transition(.opacity)

                case .player(let player):
                    PlayerPreviewView(player: player, gravity: settings.gravity)
                        .transition(.opacity)

                case .imageFrames:
                    if let image = videoInput.lastFrameImage {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: settings.gravity == .aspectFit ? .fit : .fill)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()
                    } else {
                        waitingForFrames
                    }
                }

                if showsOverlay {
                    MonitorOverlayView(config: settings.overlay,
                                       subjectBox: subjectBox,
                                       showsSubjectBox: settings.overlay.showsSubjectBox)
                }

                if showsSkeleton, !videoInput.bodyPose.isEmpty {
                    PoseSkeletonView(pose: videoInput.bodyPose)
                }

                if let box = subjectBox, settings.overlay.showsSubjectBox, !showsSkeleton {
                    SubjectBoundingBoxView(boundingBox: box)
                }

                if showsStatusBar {
                    statusBar
                }
            } else {
                disconnectedContent
            }
        }
    }

    private var previewZoom: CGFloat { settings.monitorZoom }

    // MARK: - 未连接时的内容

    @ViewBuilder
    private var disconnectedContent: some View {
        if showsGuidance {
            VStack(spacing: 14) {
                Image(systemName: disconnectedSymbol)
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(LumiTheme.tertiaryText)
                Text(disconnectedTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(LumiTheme.primaryText)
                    .multilineTextAlignment(.center)
                Text(disconnectedMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(LumiTheme.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 24)
                if !VideoInputCapability.supportsExternalCamera {
                    LimitationBadge(text: "iPhone 不支持 UVC 外接摄像头 · 请使用网络中继或内置摄像头")
                        .padding(.horizontal, 24)
                }
            }
            .padding(.vertical, 30)
        } else {
            Text(disconnectedTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(LumiTheme.secondaryText)
        }
    }

    private var disconnectedSymbol: String {
        switch videoInput.state {
        case .preparing: return "arrow.triangle.2.circlepath"
        case .unsupported: return "cable.connector.slash"
        case .failed: return "exclamationmark.triangle"
        default: return "rectangle.dashed"
        }
    }

    private var disconnectedTitle: String {
        switch videoInput.state {
        case .preparing: return "正在建立视频输入…"
        case .unsupported: return "该输入方式在本机不可用"
        case .failed: return "视频输入异常"
        default: return "暂无真实视频输入"
        }
    }

    private var disconnectedMessage: String {
        switch videoInput.state {
        case .preparing:
            return "正在申请权限并配置采集会话。"
        case .unsupported(let reason):
            return reason
        case .failed(let failure):
            return failure.message + "\n" + failure.recoverySuggestion
        default:
            return "请在下方选择输入方式并点「开始」。这里不会显示任何模拟画面或预录视频 —— 没有真实输入时就是黑场。"
        }
    }

    // MARK: - 状态条

    private var statusBar: some View {
        VStack {
            HStack(spacing: 6) {
                StatusPill(text: videoInput.state.shortLabel,
                           color: stateColor,
                           symbol: "dot.radiowaves.left.and.right")

                if let info = videoInput.deviceInfo {
                    StatusPill(text: info.resolutionText, color: LumiTheme.accent, symbol: nil)
                }

                if videoInput.measuredFPS > 0 {
                    StatusPill(text: String(format: "%.1f fps", videoInput.measuredFPS),
                               color: LumiTheme.success,
                               symbol: nil)
                }

                if settings.livePoseEnabled || settings.liveCompositionEnabled {
                    StatusPill(text: "AI \(settings.analysisFPS)fps",
                               color: LumiTheme.warning,
                               symbol: "brain")
                }

                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)

            if settings.showsFrameStats, let last = videoInput.stats.lastFrameAt {
                HStack(spacing: 6) {
                    Text(String(format: "上一帧 %.1fs 前", Date().timeIntervalSince(last)))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(LumiTheme.tertiaryText)
                    if videoInput.stats.droppedFrames > 0 {
                        Text("丢弃 \(videoInput.stats.droppedFrames)")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(LumiTheme.warning)
                    }
                    Spacer()
                }
            }
        }
        .padding(10)
    }

    private var stateColor: Color {
        switch videoInput.state {
        case .running: return LumiTheme.success
        case .preparing: return LumiTheme.warning
        case .idle: return LumiTheme.secondaryText
        case .unsupported: return LumiTheme.warning
        case .failed: return LumiTheme.danger
        }
    }

    private var waitingForFrames: some View {
        VStack(spacing: 10) {
            ProgressView()
                .tint(LumiTheme.accent)
            Text("已连接中继，正在等待第一帧…")
                .font(.system(size: 12))
                .foregroundStyle(LumiTheme.secondaryText)
        }
    }
}
