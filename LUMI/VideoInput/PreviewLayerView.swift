import SwiftUI
import AVFoundation
import UIKit

/// AVCaptureVideoPreviewLayer 的 SwiftUI 封装。
///
/// 使用预览图层而不是「取像素再画」的原因：这是 iOS 上延迟最低的路径 ——
/// 像素在显示管线内部直接合成，不经过 App 进程的拷贝与 CPU 绘制。
/// 因此监看画面不会被 AI 分析拖慢。
struct CapturePreviewView: UIViewRepresentable {

    let session: AVCaptureSession
    var gravity: VideoGravityMode = .aspectFit
    /// 数字变焦倍数（1.0 为原始）
    var zoom: CGFloat = 1.0
    /// 预览层旋转角度（外接设备固定 0°，内置摄像头跟随设备方向）
    var rotationAngle: CGFloat?

    func makeUIView(context: Context) -> PreviewContainerView {
        let view = PreviewContainerView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = gravity.avLayerGravity
        view.previewLayer.backgroundColor = UIColor.black.cgColor
        return view
    }

    func updateUIView(_ uiView: PreviewContainerView, context: Context) {
        if uiView.previewLayer.session !== session {
            uiView.previewLayer.session = session
        }
        uiView.previewLayer.videoGravity = gravity.avLayerGravity
        uiView.setZoom(zoom)
        if let rotationAngle, let connection = uiView.previewLayer.connection {
            if connection.isVideoRotationAngleSupported(rotationAngle) {
                connection.videoRotationAngle = rotationAngle
            }
        }
    }
}

/// 承载 AVCaptureVideoPreviewLayer 的 UIView。
/// 数字变焦通过对预览图层做仿射变换实现（**只影响预览显示，不改变相机光学参数**）。
final class PreviewContainerView: UIView {

    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }

    private var currentZoom: CGFloat = 1.0

    override func layoutSubviews() {
        super.layoutSubviews()
        applyZoom()
    }

    func setZoom(_ zoom: CGFloat) {
        let clamped = min(max(zoom, 1.0), 5.0)
        guard abs(clamped - currentZoom) > 0.001 else { return }
        currentZoom = clamped
        applyZoom()
    }

    private func applyZoom() {
        guard abs(currentZoom - 1.0) > 0.001 else {
            previewLayer.setAffineTransform(.identity)
            return
        }
        previewLayer.setAffineTransform(CGAffineTransform(scaleX: currentZoom, y: currentZoom))
    }
}

/// AVPlayerLayer 的 SwiftUI 封装（HLS 中继模式使用）
struct PlayerPreviewView: UIViewRepresentable {

    let player: AVPlayer
    var gravity: VideoGravityMode = .aspectFit

    func makeUIView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = gravity.avLayerGravity
        view.playerLayer.backgroundColor = UIColor.black.cgColor
        return view
    }

    func updateUIView(_ uiView: PlayerContainerView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
        uiView.playerLayer.videoGravity = gravity.avLayerGravity
    }
}

final class PlayerContainerView: UIView {

    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }
}

extension VideoGravityMode {
    var avLayerGravity: AVLayerVideoGravity {
        switch self {
        case .aspectFit: return .resizeAspect
        case .aspectFill: return .resizeAspectFill
        }
    }
}
