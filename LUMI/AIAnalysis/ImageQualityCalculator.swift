import Foundation
import CoreGraphics
import CoreImage
import ImageIO

/// 画质客观指标。全部由像素真实计算，不使用任何预设或估计值。
struct ImageQualityMetrics: Equatable {
    var width: Int
    var height: Int
    /// 平均亮度（0...1）
    var meanLuminance: Double
    /// 亮度标准差（0...1），反映明暗反差
    var luminanceStdDev: Double
    /// 拉普拉斯方差原始值（清晰度指标）
    var laplacianVariance: Double
    /// 归一化清晰度评分（0...1）
    var sharpnessScore: Double
    /// 过曝像素比例（亮度 >= 250）
    var overexposedRatio: Double
    /// 欠曝像素比例（亮度 <= 5）
    var underexposedRatio: Double
    /// 边缘密度（0...1），用于评估背景细节量
    var overallEdgeDensity: Double
    /// 人物区域外的边缘密度（0...1）。没有人物框时为 nil。
    var backgroundEdgeDensity: Double?

    var brightnessPercent: Int { Int((meanLuminance * 100).rounded()) }
    var contrastPercent: Int { Int((luminanceStdDev * 100).rounded()) }
    var overexposedPercent: Double { overexposedRatio * 100 }
    var underexposedPercent: Double { underexposedRatio * 100 }

    var sharpnessLabel: String {
        if sharpnessScore >= 0.6 { return "锐利" }
        if sharpnessScore >= 0.35 { return "可用" }
        if sharpnessScore >= 0.15 { return "偏软" }
        return "明显虚焦或抖动"
    }

    var exposureLabel: String {
        if overexposedRatio > 0.06 { return "高光溢出偏多" }
        if underexposedRatio > 0.35 { return "整体欠曝" }
        if meanLuminance < 0.22 { return "偏暗" }
        if meanLuminance > 0.8 { return "偏亮" }
        return "曝光分布正常"
    }
}

/// 纯像素计算。使用灰度降采样缓冲，保证在手机上的开销可控。
enum ImageQualityCalculator {

    /// 拉普拉斯方差到 0...1 评分的映射区间。
    ///
    /// 说明：这是**经验映射**，不是绝对锐度标准。同一张图在不同分辨率/不同镜头下
    /// 绝对值会有差异，因此它适合做「同一批照片之间的相对比较」。
    static let varianceLowerBound: Double = 8
    static let varianceUpperBound: Double = 1200

    /// 降采样后的分析宽度（越小越快，640 已足够反映清晰度与曝光分布）
    static let analysisWidth = 640

    struct GrayBuffer {
        var data: [UInt8]
        var width: Int
        var height: Int

        subscript(x: Int, y: Int) -> UInt8 {
            data[y * width + x]
        }
    }

    // MARK: - 灰度缓冲

    static func makeGrayBuffer(from cgImage: CGImage, targetWidth: Int = analysisWidth) -> GrayBuffer? {
        let scale = min(1.0, Double(targetWidth) / Double(max(cgImage.width, 1)))
        let width = max(Int(Double(cgImage.width) * scale), 8)
        let height = max(Int(Double(cgImage.height) * scale), 8)

        guard let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return nil
        }

        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let rawPointer = context.data else { return nil }
        let byteCount = context.bytesPerRow * height
        let buffer = UnsafeRawBufferPointer(start: rawPointer, count: byteCount)

        // 逐行拷贝，去掉 padding，得到紧凑的 width*height 缓冲
        var data = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let sourceOffset = y * context.bytesPerRow
            let destinationOffset = y * width
            for x in 0..<width {
                data[destinationOffset + x] = buffer[sourceOffset + x]
            }
        }
        return GrayBuffer(data: data, width: width, height: height)
    }

    // MARK: - 指标计算

    static func metrics(from cgImage: CGImage,
                        subjectBox: CGRect? = nil,
                        targetWidth: Int = analysisWidth) -> ImageQualityMetrics? {
        guard let gray = makeGrayBuffer(from: cgImage, targetWidth: targetWidth) else { return nil }
        return metrics(from: gray, subjectBox: subjectBox)
    }

    static func metrics(from gray: GrayBuffer, subjectBox: CGRect? = nil) -> ImageQualityMetrics {
        let count = gray.width * gray.height
        guard count > 0 else {
            return ImageQualityMetrics(width: gray.width, height: gray.height,
                                       meanLuminance: 0, luminanceStdDev: 0,
                                       laplacianVariance: 0, sharpnessScore: 0,
                                       overexposedRatio: 0, underexposedRatio: 0,
                                       overallEdgeDensity: 0, backgroundEdgeDensity: nil)
        }

        // 均值与标准差：纯 Swift 循环，24 万像素级别开销可忽略，且不依赖可变指针 API
        var sum: Double = 0
        var squareSum: Double = 0
        for value in gray.data {
            let v = Double(value)
            sum += v
            squareSum += v * v
        }
        let meanValue = sum / Double(count)
        var varianceOfLuminance = squareSum / Double(count) - meanValue * meanValue
        if varianceOfLuminance < 0 { varianceOfLuminance = 0 }

        let meanLuminance = meanValue / 255.0
        let stdDev = varianceOfLuminance.squareRoot() / 255.0

        // 过曝/欠曝比例
        var over = 0
        var under = 0
        for value in gray.data {
            if value >= 250 { over += 1 }
            if value <= 5 { under += 1 }
        }

        // 拉普拉斯方差（4 邻域核 [0,1,0;1,-4,1;0,1,0]），跳过 1 像素边界
        var laplacianValues = [Float]()
        laplacianValues.reserveCapacity(count)
        var laplacianSum: Double = 0
        var laplacianSquareSum: Double = 0
        var laplacianCount = 0
        for y in 1..<(gray.height - 1) {
            for x in 1..<(gray.width - 1) {
                let center = Double(gray[x, y])
                let left = Double(gray[x - 1, y])
                let right = Double(gray[x + 1, y])
                let up = Double(gray[x, y - 1])
                let down = Double(gray[x, y + 1])
                let lap = left + right + up + down - 4 * center
                laplacianSum += lap
                laplacianSquareSum += lap * lap
                laplacianCount += 1
            }
        }
        var variance: Double = 0
        if laplacianCount > 0 {
            let lapMean = laplacianSum / Double(laplacianCount)
            variance = laplacianSquareSum / Double(laplacianCount) - lapMean * lapMean
            if variance < 0 { variance = 0 }
        }

        // 边缘密度（简单梯度阈值法，用于评估背景细节量）
        let overallEdgeDensity = edgeDensity(gray: gray, region: nil)
        let backgroundDensity = subjectBox.map { box -> Double in
            // subjectBox 使用 Vision 归一化坐标（原点左下），转换为像素矩形
            let pixelRect = CGRect(x: box.minX * CGFloat(gray.width),
                                   y: (1 - box.maxY) * CGFloat(gray.height),
                                   width: box.width * CGFloat(gray.width),
                                   height: box.height * CGFloat(gray.height))
            return edgeDensity(gray: gray, excludingRegion: pixelRect)
        }

        return ImageQualityMetrics(
            width: gray.width,
            height: gray.height,
            meanLuminance: meanLuminance,
            luminanceStdDev: stdDev,
            laplacianVariance: variance,
            sharpnessScore: normalizeSharpness(variance),
            overexposedRatio: Double(over) / Double(count),
            underexposedRatio: Double(under) / Double(count),
            overallEdgeDensity: overallEdgeDensity,
            backgroundEdgeDensity: backgroundDensity
        )
    }

    /// 把拉普拉斯方差映射到 0...1（对数尺度，避免大数值把区间压扁）
    static func normalizeSharpness(_ variance: Double) -> Double {
        let value = max(variance, 0) + 1
        let lower = log10(varianceLowerBound)
        let upper = log10(varianceUpperBound)
        let mapped = (log10(value) - lower) / (upper - lower)
        return min(max(mapped, 0), 1)
    }

    /// 边缘密度：相邻像素差超过阈值即计为边缘像素。
    /// `region == nil` 表示统计整幅图；给出 `excludingRegion` 时排除该矩形。
    static func edgeDensity(gray: GrayBuffer,
                            region: CGRect? = nil,
                            excludingRegion excluded: CGRect? = nil,
                            threshold: Int = 24) -> Double {
        let bounds: CGRect
        if let region {
            bounds = region.intersection(CGRect(x: 0, y: 0, width: gray.width, height: gray.height))
        } else {
            bounds = CGRect(x: 0, y: 0, width: gray.width, height: gray.height)
        }
        guard bounds.width > 2, bounds.height > 2 else { return 0 }

        var edgeCount = 0
        var sampleCount = 0
        let startX = max(Int(bounds.minX), 1)
        let endX = min(Int(bounds.maxX), gray.width - 1)
        let startY = max(Int(bounds.minY), 1)
        let endY = min(Int(bounds.maxY), gray.height - 1)

        for y in startY..<endY {
            for x in startX..<endX {
                let point = CGPoint(x: x, y: y)
                if let excluded, excluded.contains(point) { continue }
                sampleCount += 1
                let center = Int(gray[x, y])
                let dx = abs(center - Int(gray[x + 1, y]))
                let dy = abs(center - Int(gray[x, y + 1]))
                if dx >= threshold || dy >= threshold { edgeCount += 1 }
            }
        }

        guard sampleCount > 0 else { return 0 }
        return Double(edgeCount) / Double(sampleCount)
    }

    // MARK: - 图像加载

    /// 以正确方向解码图片数据（应用 EXIF 方向），供 Vision 与像素计算共用
    static func decodeImage(data: Data) -> (image: CGImage, orientation: CGImagePropertyOrientation)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientationRaw = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        let orientation = CGImagePropertyOrientation(rawValue: orientationRaw) ?? .up
        return (cgImage, orientation)
    }
}
