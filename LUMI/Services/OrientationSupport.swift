import Foundation
import UIKit

/// 屏幕方向控制。
///
/// 用途：全屏监看时把界面锁到横屏，退出后恢复。
/// 实现方式：`supportedInterfaceOrientationsFor` 返回锁定的方向集合，
/// 再用 `requestGeometryUpdate` 主动请求旋转（iOS 16+ 的官方做法）。
///
/// 说明：这不会影响其它页面 —— 非全屏时返回 nil，即恢复 Info.plist 中声明的全部方向。
final class OrientationAppDelegate: NSObject, UIApplicationDelegate {

    /// nil = 不限制（使用 Info.plist 声明的方向）
    static var lockedMask: UIInterfaceOrientationMask?

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationAppDelegate.lockedMask ?? .allButUpsideDown
    }
}

enum OrientationSupport {

    /// 锁定/解锁横屏监看
    static func setLandscapeLock(_ enabled: Bool) {
        OrientationAppDelegate.lockedMask = enabled ? .landscape : nil

        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        let orientations: UIInterfaceOrientationMask = enabled ? .landscape : .allButUpsideDown
        let preferences = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: orientations)
        scene.requestGeometryUpdate(preferences) { error in
            AppLog.app.error("方向切换请求失败: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 当前是否为横屏（用于 UI 提示）
    static var isLandscape: Bool {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return false }
        return scene.interfaceOrientation.isLandscape
    }
}
