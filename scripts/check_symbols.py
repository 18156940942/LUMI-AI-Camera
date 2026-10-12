#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
LUMI —— Swift 源码交叉引用自检
==============================

Windows 上没有 Xcode / swiftc，无法真正编译。这个脚本用文本分析补上最容易漏掉的一类错误：

    「测试代码（或某个 View）引用了某个类型/成员，但它在源码里根本不存在」

这类错误在 Mac 上会以 `cannot find 'XXX' in scope` 的形式报出来，
但在写代码阶段极容易被漏掉 —— 尤其是类型分散在 50 多个文件里的时候。

做法：
  1. 扫出 LUMI/ 与 LUMITests/ 里所有声明的类型名（class/struct/enum/protocol/actor/typealias）
     与顶层函数名；
  2. 从测试文件里提取「明显是类型名的标识符」（首字母大写的驼峰标识符）；
  3. 报告哪些被引用但两个目录里都没声明 —— 同时排除 Swift 标准库/系统框架的常见类型。

这是一个启发式检查，不是编译器。它的价值在于：**零成本地把「拼错名字」这一类错误全部抓出来。**

用法：
    python3 scripts/check_symbols.py
退出码 0 = 通过（可能有少量白名单提示）；1 = 有可疑的未定义引用。
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

# Swift 标准库 + 本项目用到的系统框架类型（不需要在 LUMI/ 里声明）
SYSTEM_TYPES = {
    # Swift / Foundation
    "Any", "AnyObject", "Array", "Bool", "Character", "Codable", "Comparable",
    "Data", "Date", "DateComponents", "DateFormatter", "Decodable", "Dictionary",
    "Double", "Encodable", "Equatable", "Error", "FileManager", "Float", "Hashable",
    "Identifiable", "Int", "Int64", "JSONDecoder", "JSONEncoder", "Locale",
    "NSMutableData", "NSNumber", "NSError", "NSObject", "Optional", "Result", "Set",
    "String", "TimeZone", "URL", "URLComponents", "UUID", "UInt8", "Void",
    "CustomStringConvertible", "CaseIterable", "Sequence", "Collection",
    "RawRepresentable", "ObservableObject", "Published", "Timer", "Task",
    "ByteCountFormatter", "Calendar", "DispatchQueue", "Println", "MainActor",
    "DispatchTime", "Thread", "IndexSet", "CharacterSet", "NotificationCenter",
    "UserDefaults", "Bundle", "ProcessInfo", "NSLock", "FileAttributeKey",
    # CoreGraphics / CoreImage / CoreVideo / ImageIO
    "CGFloat", "CGPoint", "CGRect", "CGSize", "CGImage", "CGContext", "CGColorSpace",
    "CGImageAlphaInfo", "CGImagePropertyOrientation", "CGImageSourceCreateWithData",
    "CGImageDestination", "CGImageDestinationCreateWithData", "CGImageDestinationAddImage",
    "CGImageDestinationFinalize", "CGImagePropertyExifDictionary", "CIContext", "CIImage",
    "CVPixelBuffer", "CVImageBuffer", "CFString", "CFURL", "CFData", "CFDictionary",
    "FourCharCode", "CMVideoFormatDescriptionGetDimensions", "CMFormatDescriptionGetMediaSubType",
    "CGRectMake", "CTFont", "CTLine", "CGColorSpaceCreateDeviceGray",
    "CGColorSpaceCreateDeviceRGB", "CGImageSourceCreateWithURL",
    "CGImageSourceCreateImageAtIndex", "CGImageSourceCopyPropertiesAtIndex",
    # AVFoundation
    "AVCaptureSession", "AVCaptureDevice", "AVCaptureVideoPreviewLayer", "AVCaptureVideoDataOutput",
    "AVCaptureDeviceInput", "AVCaptureDeviceDiscoverySession", "AVCaptureVideoDataOutputSampleBufferDelegate",
    "AVPlayer", "AVPlayerLayer", "AVPlayerItem", "AVPlayerItemVideoOutput", "AVAudioSession",
    "AVCaptureConnection", "AVCaptureVideoRotationAngle", "AVCaptureDeviceRotationCoordinator",
    "AVLayerVideoGravity", "AVPlayerItemVideoOutputPixelBufferAttributesKey",
    "AVCaptureSessionPreset", "AVMediaType", "AVAuthorizationStatus",
    # Vision
    "Vision", "VNImageRequestHandler", "VNDetectHumanBodyPoseRequest", "VNHumanBodyPoseObservation",
    "VNDetectFaceLandmarksRequest", "VNDetectFaceRectanglesRequest", "VNFaceLandmarks2D",
    "VNFaceLandmarkRegion2D", "VNObservation", "VNRecognizedPointsObservation",
    # UIKit / SwiftUI
    "UIView", "UIViewController", "UIApplication", "UIApplicationDelegate", "UIColor", "UIImage",
    "UIDevice", "UIScreen", "UIWindow", "UIWindowScene", "UIInterfaceOrientation",
    "UIInterfaceOrientationMask", "UIUserInterfaceIdiom", "UITraitCollection", "NSLayoutConstraint",
    "SwiftUI", "View", "ViewBuilder", "Scene", "App", "Binding", "State", "StateObject",
    "ObservableObject", "EnvironmentObject", "Environment", "ObservedObject", "Published",
    "Color", "Font", "Text", "Image", "VStack", "HStack", "ZStack", "Spacer", "Divider",
    "ScrollView", "LazyVGrid", "LazyVStack", "GridItem", "List", "Form", "Section",
    "Button", "Toggle", "Slider", "Picker", "Stepper", "Menu", "Label", "TextField",
    "Canvas", "GraphicsContext", "Path", "Rectangle", "RoundedRectangle", "Circle", "Capsule",
    "GeometryReader", "GeometryProxy", "NavigationStack", "NavigationLink", "NavigationView",
    "TabView", "Sheet", "Alert", "fullScreenCover", "PhotosPicker", "PhotosPickerItem",
    "PhotosUI", "UIKit", "CoreGraphics", "CoreImage", "ImageIO", "Combine", "QuartzCore",
    "CADisplayLink", "CALayer", "CATransaction", "AnyView", "EmptyView", "ViewModifier",
    "Animation", "LinearGradient", "Material", "IonicColumn", "UnitPoint", "EdgeInsets",
    "ContentSizeCategory", "DynamicTypeSize", "Axis", "Edge", "ScrollViewProxy",
    "SafeAreaRegions", "PresentationDetents", "ToolbarItem", "ToolbarItemGroup",
    "UniformTypeIdentifiers", "UTType", "Foundation", "CoreVideo", "AVFoundation",
    "Photos", "PHPhotoLibrary", "PHAsset", "SoundAnalysis",
    "TimeInterval", "CodingKey", "Decoder", "Encoder", "KeyedDecodingContainer",
    "KeyedEncodingContainer", "SingleValueDecodingContainer", "UnsafeMutableRawPointer",
    "UnsafeRawBufferPointer", "UnsafePointer", "ManagedBuffer", "Mirror", "ObjectIdentifier",
    "Selector", "NSSelectorFromString", "OperationQueue", "RunLoop", "Autoreleasepool",
    "ContiguousArray", "Slice", "Range", "ClosedRange", "PartialRangeFrom", "StrideThrough",
    "Duration", "ContinuousClock", "SuspendingClock", "CheckedContinuation",
    "UnsafeContinuation", "Actor", "Sendable", "GlobalActor", "TaskPriority",
    "withAnimation", "withCheckedContinuation", "Result", "Never", "KeyPath",
    "WritableKeyPath", "ReferenceWritableKeyPath", "PartialKeyPath",
    "CGColor", "CGImageSource", "CGDataProvider", "CGDataProviderCopyData",
    "CGGradient", "CGShading", "CGAffineTransform", "CGBlendMode", "CGFont",
    "XCTestCase", "XCTAssert", "XCTUnwrap", "XCTAssertEqual", "XCTAssertTrue",
    "XCTAssertFalse", "XCTAssertNil", "XCTAssertNotNil", "XCTAssertGreaterThan",
    "XCTAssertLessThan", "XCTAssertGreaterThanOrEqual", "XCTAssertLessThanOrEqual",
    "XCTFail", "XCTSkip", "XCTest", "XCUIApplication", "XCTMain",
    # 常见的误判来源：模块名、属性包装器、宏、工具函数名
    "LUMI", "PoseScriptWriter", "AppLog", "LumiTheme", "T", "U",
    "XCTAssertNotEqual", "XCTAssertNoThrow", "XCTAssertThrowsError",
    "XCTAssertIdentical", "XCTAssertGreaterThanOrEqual",
    # ---- App 源码里出现的系统类型 / 嵌套类型 / 协议关联类型 ----
    # AVFoundation / CoreMedia / CoreVideo / CoreGraphics C API
    "AVCaptureOutput", "AVCaptureSessionErrorKey", "AVPlayerItemFailedToPlayToEndTime",
    "AVPlayerItemFailedToPlayToEndTimeErrorKey", "CACurrentMediaTime", "CFTimeInterval",
    "CMSampleBuffer", "CMSampleBufferGetImageBuffer", "CMSampleBufferGetPresentationTimeStamp",
    "CMTimeGetSeconds", "CVPixelBufferCreate", "CVPixelBufferGetHeight", "CVPixelBufferGetWidth",
    "CGImageSourceCreateThumbnailAtIndex", "CGImageSourceGetType", "CoreMedia",
    "AVCaptureDeviceInputSource", "AVCaptureVideoOrientation", "AVCaptureWhiteBalanceGains",
    "AVCaptureExposureMode", "AVCaptureFocusMode", "AVCaptureTorchMode",
    # Foundation / ObjC 运行时
    "AnyClass", "CChar", "DispatchSemaphore", "HTTPURLResponse", "LocalizedError", "Logger",
    "NSCache", "NSKeyValueObservation", "NSObjectProtocol", "NSString", "NSURLErrorCancelled",
    "Notification", "URLRequest", "URLResponse", "URLSession", "URLSessionConfiguration",
    "URLSessionDataDelegate", "URLSessionDataTask", "URLSessionTask", "os",
    # SwiftUI / UIKit
    "ForEach", "Group", "ProgressView", "TextEditor", "UIApplicationDelegateAdaptor",
    "UIDeviceOrientation", "UIKeyboardType", "UIPasteboard", "UIViewRepresentable",
    "WindowGroup", "FillStyle", "StrokeStyle", "GeometryPreferences", "UIWindowSceneGeometryPreferencesIOS",
    # 枚举/嵌套类型名（写成点号后缀形式时会被当作独立标识符扫到）
    "Content", "Context", "Format", "JointName", "Position", "Preview", "DiscoverySession",
    "ResponseDisposition", "Self", "CodingKeys", "DeviceType", "AuthorizationStatus",
    "RenderingMode", "SymbolVariants", "Axis", "AllCases", "MediaType",
}

DECL_RE = re.compile(
    r"^\s*(?:public\s+|internal\s+|private\s+|fileprivate\s+|final\s+|open\s+)*"
    r"(class|struct|enum|protocol|actor|typealias)\s+([A-Za-z_][A-Za-z0-9_]*)",
    re.M,
)
EXT_RE = re.compile(r"^\s*extension\s+([A-Za-z_][A-Za-z0-9_]*)", re.M)
FUNC_RE = re.compile(r"^\s*(?:public\s+|internal\s+|private\s+|fileprivate\s+|static\s+|final\s+)*func\s+([A-Za-z_][A-Za-z0-9_]*)", re.M)
# 「首字母大写的驼峰标识符」—— 在测试里基本只可能是类型名
TYPE_USE_RE = re.compile(r"\b([A-Z][A-Za-z0-9_]{2,})\b")


def declared_names(paths: list[Path]) -> set[str]:
    names: set[str] = set()
    for path in paths:
        text = path.read_text(encoding="utf-8", errors="replace")
        names.update(m.group(2) for m in DECL_RE.finditer(text))
        names.update(EXT_RE.findall(text))
        names.update(FUNC_RE.findall(text))
    return names


def scan(files: list[Path], declared: set[str]) -> dict[str, set[str]]:
    unknown: dict[str, set[str]] = {}
    for path in files:
        text = path.read_text(encoding="utf-8", errors="replace")
        # 顺序很重要：必须先剥字符串，再剥注释。
        # 反过来的话，URL 里的 "http://" 会被当成行注释开头，把后面的引号切断，
        # 进而让「字符串内容」被误判成代码（实测踩过一次）。
        text = re.sub(r'"""(?:.|\n)*?"""', '""', text)          # 多行字符串
        text = re.sub(r'"(?:[^"\\\n]|\\.)*"', '""', text)       # 单行字符串
        text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)        # 块注释
        text = re.sub(r"//[^\n]*", "", text)                     # 行注释

        for match in TYPE_USE_RE.finditer(text):
            name = match.group(1)
            if name in declared or name in SYSTEM_TYPES:
                continue
            unknown.setdefault(name, set()).add(path.name)
    return unknown


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    app_dir = root / "LUMI"
    test_dir = root / "LUMITests"
    scan_app = "--all" in sys.argv

    app_files = sorted(app_dir.rglob("*.swift"))
    test_files = sorted(test_dir.rglob("*.swift"))

    if not app_files:
        print("!! 找不到 LUMI/ 下的 Swift 源码", file=sys.stderr)
        return 1

    declared = declared_names(app_files + test_files)
    # 同一模块内可直接访问（@testable import），所以测试文件本身声明的也算

    unknown = scan(test_files, declared)
    unknown_app = scan(app_files, declared) if scan_app else {}

    print(f"源码目录    : {app_dir}")
    print(f"App 文件    : {len(app_files)}")
    print(f"测试文件    : {len(test_files)}")
    print(f"已声明符号  : {len(declared)}")
    print(f"扫描范围    : {'App + 测试' if scan_app else '仅测试（加 --all 可同时扫 App）'}")

    failed = False

    if unknown_app:
        failed = True
        print(f"\n[App 源码] 以下 {len(unknown_app)} 个标识符没有声明（可能是系统类型，"
              f"也可能是拼错的类型名）：\n", file=sys.stderr)
        for name in sorted(unknown_app):
            files = ", ".join(sorted(unknown_app[name]))
            print(f"  ? {name}   ← {files}", file=sys.stderr)

    if unknown:
        failed = True
        print(f"\n[测试] 以下 {len(unknown)} 个标识符在 LUMI/ 与 LUMITests/ 里都没有声明，"
              f"也不在系统类型白名单里：\n", file=sys.stderr)
        for name in sorted(unknown):
            files = ", ".join(sorted(unknown[name]))
            print(f"  ? {name}   ← {files}", file=sys.stderr)

    if failed:
        print("\n提示：如果是 Swift 标准库/系统框架类型，请把它加进本脚本的 SYSTEM_TYPES 白名单；",
              file=sys.stderr)
        print("      否则很可能是拼写错误或漏写的类型。", file=sys.stderr)
        return 1

    print("\n✓ 所有被引用的类型名都能在源码或系统框架中找到")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
