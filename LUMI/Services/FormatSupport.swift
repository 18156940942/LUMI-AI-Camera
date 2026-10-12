import Foundation

// MARK: - 格式串安全桥接

extension String {

    /// 把自身作为 `String(format:)` 里 `%@` 的参数。
    ///
    /// **为什么需要显式桥接。** `%@` 要的是 Objective-C 对象，而 Swift 的 `String`
    /// 是值类型。虽然 `String` 实现了 `CVarArg`、也会隐式桥接成 `NSString`，
    /// 但新版 iOS 的格式串校验器会因此打出 `<Fault>`。这不是推测 ——
    /// 2026-10-12 在真机上抓到的原文：
    ///
    /// ```
    /// LUMI(Foundation) <Fault>: String(format:locale:arguments:):
    ///   Provided argument types ["Swift.String", "Swift.String", "CoreGraphics.CGFloat"]
    ///   (with inferred specifiers ["%@", "%@", "%lf"])
    ///   do not match the format string's specifiers
    /// ```
    ///
    /// 参数类型与格式串逐个对得上（两个 `%@` 收两个字符串、`%.1f` 收一个 CGFloat），
    /// 唯一「不匹配」的就是 `%@` 拿到了 `Swift.String` 而不是对象。
    /// 显式写成 `NSString` 之后校验器不再报警，格式化语义与隐式桥接完全一致。
    ///
    /// 用法：
    ///
    /// ```swift
    /// String(format: "%@ 比 %@ 低 %.1f°",
    ///        lowerSide.formatObject, higherSide.formatObject, absTilt)
    /// ```
    ///
    /// - Note: 只用于 `%@` 位置。数字参数（`%.1f`、`%d`）保持原样，不要桥接。
    var formatObject: NSString { self as NSString }
}
