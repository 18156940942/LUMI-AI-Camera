import SwiftUI

/// 隐私与安全说明。
///
/// 首次启动时会以全屏方式展示，必须由用户确认后进入。
/// 内容与 ``LUMI/Resources/Info.plist`` 中的权限说明逐条对应，不写空话。
struct PrivacyView: View {

    @Environment(\.dismiss) private var dismiss

    let isFirstRun: Bool
    var onAcknowledge: (() -> Void)?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    permissionSection
                    localProcessingSection
                    noCloudSection
                    dataBoundarySection
                    limitsSection
                }
                .padding(LumiTheme.screenPadding)
                .padding(.bottom, 30)
            }
            .background(LumiTheme.background.ignoresSafeArea())
            .navigationTitle("隐私与安全")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !isFirstRun {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("关闭") { dismiss() }
                            .foregroundStyle(LumiTheme.accent)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if isFirstRun {
                    VStack(spacing: 8) {
                        PrimaryButton(title: "我已了解，进入 LUMI", symbol: "checkmark.shield") {
                            onAcknowledge?()
                        }
                        Text("授权与否由你在系统弹窗中决定；不授权也可以使用姿势库、照片分析与工具页。")
                            .font(.system(size: 10))
                            .foregroundStyle(LumiTheme.tertiaryText)
                            .multilineTextAlignment(.center)
                    }
                    .padding(LumiTheme.screenPadding)
                    .background(LumiTheme.background.opacity(0.95))
                }
            }
        }
        .interactiveDismissDisabled(isFirstRun)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(LumiTheme.accent)
                Text("LUMI 的数据边界")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(LumiTheme.primaryText)
            }
            Text("这份说明描述的是代码里**真实发生**的行为，不是模板文案。任何没做到的事都会在「已知限制」里写清楚。")
                .font(.system(size: 12))
                .foregroundStyle(LumiTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var permissionSection: some View {
        LumiCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "权限申请", subtitle: "只在需要时申请，且与 Info.plist 一致", trailingText: nil)
                permissionRow(icon: "camera",
                              title: "摄像头",
                              text: "仅用于「内置摄像头」备用监看模式。该模式默认不启动，必须由你点「开始监看」；LUMI 不会在后台或启动时自动开摄像头。")
                permissionRow(icon: "photo.on.rectangle",
                              title: "照片",
                              text: "通过系统照片选择器读取你主动挑选的照片。选择器由系统提供，LUMI 只能拿到你勾选的那些文件。")
                permissionRow(icon: "wifi",
                              title: "局域网",
                              text: "仅用于连接你自建的 MJPEG/HLS 中继流（相机 → 采集卡 → 电脑 → 手机）。不连接中继时不会发起任何局域网请求。")
                permissionRow(icon: "square.and.arrow.down",
                              title: "写入相册（可选）",
                              text: "当前版本未使用写入权限：LUMI 只在 App 沙盒内保存副本，不会往你的相册里写文件。")
            }
        }
    }

    private func permissionRow(icon: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(LumiTheme.accent)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LumiTheme.primaryText)
                Text(text)
                    .font(.system(size: 11))
                    .foregroundStyle(LumiTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var localProcessingSection: some View {
        LumiCard {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "本地优先处理", subtitle: nil, trailingText: nil)
                bullet("人体姿态检测：Apple Vision 框架，在 A17 Pro 的神经引擎上本机运行。")
                bullet("人脸与闭眼判定：Vision 特征点，本机运行。")
                bullet("画质指标（清晰度/亮度/过曝欠曝）：在降采样灰度缓冲上本机计算。")
                bullet("姿势推荐：随 App 打包的离线 JSON 库 + 本地规则引擎，完全离线。")
                bullet("人体关键点数据只存在于内存中用于当前帧分析，不会写入磁盘，也不会随任何请求发出。")
            }
        }
    }

    private var noCloudSection: some View {
        LumiCard {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "默认不出设备；联网由你决定", subtitle: nil, trailingText: nil)
                bullet("**照片精修功能默认是关闭的。** 你不主动打开，App 不会把任何照片发出去。")
                bullet("精修里的「画质增强 / 风格化调色 / 人像美化」全部在**你自己电脑上**用确定性算法完成，照片不出本机。")
                bullet("只有「生成式改动」这一类会把照片发给你**自己配置的**云端服务商 —— 因为它的本质是重绘画面内容，本地算法做不到。")
                bullet("**App 里没有任何云端密钥。** 密钥放在你自己电脑上的中继脚本里（`tools/lumi_retouch_server.py`），客户端只连你电脑的地址。这样不会出现「长期密钥硬编码进 iOS 客户端」这类风险。")
                bullet("中继地址、强度、文字指令都只存在本机；发送时只发这一张照片和对应的预设参数，不发姿态数据、不发照片库索引。")
                bullet("工程内没有任何追踪 SDK、没有埋点、没有广告。")
                bullet("要彻底不用联网：不打开精修总开关即可，其余功能（姿势库、照片分析、构图分析）完全本地运行。")
            }
        }
    }

    private var dataBoundarySection: some View {
        LumiCard {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "照片与相机的边界", subtitle: nil, trailingText: nil)
                bullet("LUMI 不读取相机存储卡，也无法读取尚未传输到 iPhone 的照片。")
                bullet("导入的照片会在 App 沙盒保存一份副本，分析、收藏、标签、删除都只作用于这份副本。")
                bullet("LUMI 永远不会删除或修改系统相册中的原始照片。")
                bullet("删除 App 内记录时会先弹出确认框，并明确写出「删除范围」与「不受影响的内容」。")
            }
        }
    }

    private var limitsSection: some View {
        LumiCard(highlighted: true) {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "已知限制（如实告知）", subtitle: nil, trailingText: nil)
                bullet("iPhone 不支持 UVC 外接摄像头，无法直连 HDMI 采集卡；实时监看需走网络中继或改用 iPad。")
                bullet("头部转动角度为单目 2D 关键点估算值，不是 3D 姿态解算，正对与背对时误差较大。")
                bullet("闭眼判定基于眼部特征点几何比例，属于启发式，只能提示「疑似」，必须人工确认。")
                bullet("视频输入不提供相机机身曝光参数（快门/光圈/ISO）。")
                bullet("网络中继的延迟在 150–400 ms 量级，可用于构图与姿态判断，不足以精确确认焦点。")
                bullet("本项目不提供模特示范照片，姿势详情中的示意图是由姿势参数生成的抽象方向示意。")
                bullet("照片精修不改变你的原始照片：结果只存在 App 沙盒内，不会写回相册，也不会覆盖任何原始文件。")
                bullet("生成式改动的结果**不确定**：云端模型可能改动画面内容，也可能改得超出你的预期。使用前请逐张确认。")
            }
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Circle()
                .fill(LumiTheme.accent.opacity(0.8))
                .frame(width: 4, height: 4)
                .padding(.top, 6)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(LumiTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
