import SwiftUI
import UIKit

/// 全屏图片查看器：双指缩放、双击放大、放大后拖动。
///
/// **为什么需要它。** 精修前后到底差在哪，看的是皮肤质感、边缘过渡和噪点 ——
/// 这些东西在 120pt 高的对比缩略图里根本分辨不出来。所以这个页面刻意按
/// **长边约 3000 像素**解码：足够看清细节，又不至于把 2400 万像素的原图
/// 整个读进内存（那会是一次几十 MB 的分配，放大查看这种动作不该有这种代价）。
struct ImageViewerView: View {

    /// 一张可查看的图。
    struct Item: Identifiable {
        let id: String
        let title: String
        let url: URL
        /// 导出到相册时用它，保证相册里的时间排序正确。
        let creationDate: Date?

        init(id: String, title: String, url: URL, creationDate: Date? = nil) {
            self.id = id
            self.title = title
            self.url = url
            self.creationDate = creationDate
        }
    }

    let items: [Item]
    /// 底部「导出到相册」的动作。传 nil 时不显示该按钮。
    var onExport: ((Item) -> Void)?

    @Environment(\.dismiss) private var dismiss

    @State private var index = 0
    @State private var image: UIImage?
    @State private var isLoading = true

    // 缩放 + 平移。`base*` 保存手势开始前的值，避免每一帧都从零累加导致抖动。
    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero

    private let minimumScale: CGFloat = 1
    private let maximumScale: CGFloat = 8
    private let doubleTapScale: CGFloat = 3

    private var current: Item? {
        items.indices.contains(index) ? items[index] : items.first
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                viewer
                footer
            }
        }
        .task(id: current?.url) { await loadImage() }
        .statusBarHidden(true)
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(spacing: 10) {
            Text(current?.title ?? "")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)

            if scale > 1.01 {
                Text(scale.formatted(.number.precision(.fractionLength(1))) + "×")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.13))
                    .clipShape(Capsule())
            }

            Spacer(minLength: 0)

            if scale > 1.01 {
                Button {
                    resetTransform()
                } label: {
                    Text("还原")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.13))
                        .clipShape(Capsule())
                }
            }

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(Color.white.opacity(0.15))
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    // MARK: - 图片

    private var viewer: some View {
        GeometryReader { proxy in
            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .scaleEffect(scale)
                        .offset(offset)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { toggleZoom() }
                        .simultaneousGesture(magnification(in: proxy.size))
                        .simultaneousGesture(drag(in: proxy.size))
                } else if isLoading {
                    ProgressView().tint(.white)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "photo")
                            .font(.system(size: 26, weight: .light))
                        Text("这张图读不出来")
                            .font(.system(size: 12))
                    }
                    .foregroundStyle(.white.opacity(0.55))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 底部

    private var footer: some View {
        VStack(spacing: 10) {
            if items.count > 1 {
                HStack(spacing: 8) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { position, item in
                        Button {
                            index = position
                        } label: {
                            Text(item.title)
                                .font(.system(size: 12, weight: position == index ? .semibold : .regular))
                                .foregroundStyle(position == index ? Color.black : Color.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(position == index ? Color.white : Color.white.opacity(0.15))
                                .clipShape(Capsule())
                        }
                    }
                }
            }

            HStack(spacing: 12) {
                Text("双指缩放 · 双击放大 · 放大后拖动")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.45))

                Spacer(minLength: 0)

                if let onExport, let current {
                    Button {
                        onExport(current)
                    } label: {
                        Label("导出到相册", systemImage: "square.and.arrow.down")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Color.white.opacity(0.15))
                            .clipShape(Capsule())
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 22)
    }

    // MARK: - 手势

    private func magnification(in size: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let proposed = baseScale * value.magnification
                scale = min(max(proposed, minimumScale), maximumScale)
                offset = clamped(offset, in: size)
            }
            .onEnded { _ in
                baseScale = scale
                if scale <= minimumScale + 0.01 {
                    resetTransform()
                } else {
                    offset = clamped(offset, in: size)
                    baseOffset = offset
                }
            }
    }

    private func drag(in size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                // 没放大时拖动没有意义，忽略掉，免得图片莫名其妙地移动
                guard scale > minimumScale + 0.01 else { return }
                offset = clamped(CGSize(width: baseOffset.width + value.translation.width,
                                        height: baseOffset.height + value.translation.height),
                                 in: size)
            }
            .onEnded { _ in
                baseOffset = offset
            }
    }

    /// 把位移限制在放大后多出来的那部分范围内，不让用户把图片拖出屏幕再也找不回来。
    private func clamped(_ proposed: CGSize, in size: CGSize) -> CGSize {
        let limitX = max(0, size.width * (scale - minimumScale) / 2)
        let limitY = max(0, size.height * (scale - minimumScale) / 2)
        return CGSize(width: min(max(proposed.width, -limitX), limitX),
                      height: min(max(proposed.height, -limitY), limitY))
    }

    private func toggleZoom() {
        withAnimation(.easeInOut(duration: 0.22)) {
            if scale > minimumScale + 0.01 {
                scale = minimumScale
                baseScale = minimumScale
                offset = .zero
                baseOffset = .zero
            } else {
                scale = doubleTapScale
                baseScale = doubleTapScale
            }
        }
    }

    private func resetTransform() {
        withAnimation(.easeInOut(duration: 0.22)) {
            scale = minimumScale
            baseScale = minimumScale
            offset = .zero
            baseOffset = .zero
        }
    }

    // MARK: - 加载

    @MainActor
    private func loadImage() async {
        guard let current else {
            image = nil
            isLoading = false
            return
        }
        isLoading = true
        image = nil
        scale = minimumScale
        baseScale = minimumScale
        offset = .zero
        baseOffset = .zero

        let url = current.url
        let loaded = await Task.detached(priority: .userInitiated) {
            PhotoLibraryStore.downsampledImage(at: url, maxPixel: 3000)
        }.value

        image = loaded
        isLoading = false
    }
}
