#if canImport(ImageIO) && canImport(CoreGraphics)
import Foundation
import ImageIO
import CoreGraphics

/// Apple 的内存编解码器。可直接将 inspect 注入 BoneInferenceImageResolver。
/// 只接受可验证的单帧位图；非 wire 格式（例如 HEIC）只能经 prepare 转换。
public enum BoneInferenceImageIO {
    public static var preprocessor: BoneInferenceImagePreprocessor {
        .init { data, policy in try prepare(data, policy: policy) }
    }

    public static func inspect(_ data: Data) throws -> BoneInferenceImageMetadata {
        try Task.checkCancellation()
        let details = try source(data, maxPixels: BoneInferenceImageMetadata.maximumPixels)
        guard let format = details.format else { throw BoneInferenceImageInputError.unsupportedFormat }
        guard details.orientation == 1 else { throw BoneInferenceImageInputError.invalidMetadata }
        _ = try decodedImage(details)
        try Task.checkCancellation()
        return try .init(format: format, width: details.width, height: details.height, byteCount: data.count)
    }

    private struct BoneImageSourceDetails {
        let source: CGImageSource
        let format: BoneInferenceImageFormat?
        let width: Int
        let height: Int
        let orientation: Int
        let properties: [String: Any]
        let containerProperties: [String: Any]
        let hasOnlySafePNGChunks: Bool
    }

    private static func source(_ data: Data, maxPixels: Int) throws -> BoneImageSourceDetails {
        guard !data.isEmpty else { throw BoneInferenceImageInputError.decodingFailed }
        guard data.count <= BoneInferenceImageMetadata.maximumBytes else {
            throw BoneInferenceImageInputError.sourceTooLarge
        }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              let type = CGImageSourceGetType(source) as String? else {
            throw BoneInferenceImageInputError.decodingFailed
        }
        // 不猜测未知容器的分页、方向或辅助图像语义。
        let supported = ["public.png", "public.jpeg", "org.webmproject.webp", "com.compuserve.gif",
                         "public.tiff", "com.microsoft.bmp", "public.heic", "public.heif"]
        guard supported.contains(type) else { throw BoneInferenceImageInputError.unsupportedFormat }
        let format: BoneInferenceImageFormat?
        switch type {
        case "public.png": format = .png
        case "public.jpeg": format = .jpeg
        case "org.webmproject.webp": format = .webp
        default: format = nil
        }
        let safePNG = try validateContainer(data, format: format, maxPixels: maxPixels)
        guard CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetCount(source) > 0 else { throw BoneInferenceImageInputError.decodingFailed }
        guard CGImageSourceGetCount(source) == 1 else { throw BoneInferenceImageInputError.unsupportedAnimation }
        guard CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [String: Any],
              let container = CGImageSourceCopyProperties(source, options) as? [String: Any],
              let width = integer(properties[kCGImagePropertyPixelWidth as String]),
              let height = integer(properties[kCGImagePropertyPixelHeight as String]),
              width > 0, height > 0 else { throw BoneInferenceImageInputError.decodingFailed }
        // 在创建 CGImage 或缩略图之前检查，避免压缩体积很小的超大位图。
        guard width <= BoneInferenceImageMetadata.maximumDimension,
              height <= BoneInferenceImageMetadata.maximumDimension,
              width <= maxPixels / height else { throw BoneInferenceImageInputError.sourceTooLarge }
        let orientation = try orientation(in: properties)
        if type == "com.compuserve.gif" {
            let animation = container[kCGImagePropertyGIFDictionary as String] as? [String: Any]
            let frame = properties[kCGImagePropertyGIFDictionary as String] as? [String: Any]
            if animation?[kCGImagePropertyGIFLoopCount as String] != nil ||
                (frame?[kCGImagePropertyGIFDelayTime as String] as? NSNumber)?.doubleValue ?? 0 > 0 ||
                (frame?[kCGImagePropertyGIFUnclampedDelayTime as String] as? NSNumber)?.doubleValue ?? 0 > 0 {
                throw BoneInferenceImageInputError.unsupportedAnimation
            }
        }
        return .init(source: source, format: format, width: width, height: height, orientation: orientation,
                     properties: properties, containerProperties: container, hasOnlySafePNGChunks: safePNG)
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double >= 0, double < Double(Int.max), double.rounded(.down) == double else { return nil }
        return Int(double)
    }

    private static func orientation(in properties: [String: Any]) throws -> Int {
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        let top = properties[kCGImagePropertyOrientation as String]
        let nested = tiff?[kCGImagePropertyTIFFOrientation as String]
        let values = [top, nested].compactMap { $0 }
        let parsed = values.compactMap(integer)
        guard values.count == parsed.count, parsed.allSatisfy({ (1...8).contains($0) }),
              Set(parsed).count <= 1 else { throw BoneInferenceImageInputError.invalidMetadata }
        return parsed.first ?? 1
    }

    /// ImageIO 在某些系统上会把动画 PNG/WebP 暴露成一帧；仍按容器声明拒绝。
    /// PNG 的未知块也可能携带 ImageIO 未公开的私有信息，不能原样透传。
    private static func validateContainer(_ data: Data, format: BoneInferenceImageFormat?, maxPixels: Int) throws -> Bool {
        try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            func text(_ start: Int, _ count: Int) -> String {
                String(bytes: bytes[start..<(start + count)], encoding: .ascii) ?? ""
            }
            func uint32(_ offset: Int, littleEndian: Bool = false) -> Int {
                let shifts = littleEndian ? [0, 8, 16, 24] : [24, 16, 8, 0]
                return (0..<4).reduce(0) { $0 | (Int(bytes[offset + $1]) << shifts[$1]) }
            }
            switch format {
            case .png:
                guard bytes.count >= 8, Array(bytes[0..<8]) == [137, 80, 78, 71, 13, 10, 26, 10] else {
                    throw BoneInferenceImageInputError.decodingFailed
                }
                let safeChunks = Set(["IHDR", "PLTE", "IDAT", "IEND", "tRNS", "sRGB", "gAMA", "cHRM"])
                var offset = 8
                var safe = true
                var hasPixels = false
                while offset <= bytes.count - 12 {
                    let length = uint32(offset)
                    guard length <= bytes.count - offset - 12 else { throw BoneInferenceImageInputError.decodingFailed }
                    let chunk = text(offset + 4, 4)
                    if chunk == "IHDR" {
                        guard offset == 8, length == 13 else { throw BoneInferenceImageInputError.decodingFailed }
                        let width = uint32(offset + 8), height = uint32(offset + 12)
                        guard width > 0, height > 0 else { throw BoneInferenceImageInputError.decodingFailed }
                        guard width <= BoneInferenceImageMetadata.maximumDimension,
                              height <= BoneInferenceImageMetadata.maximumDimension,
                              width <= maxPixels / height else { throw BoneInferenceImageInputError.sourceTooLarge }
                    } else if offset == 8 {
                        throw BoneInferenceImageInputError.decodingFailed
                    }
                    if ["acTL", "fcTL", "fdAT"].contains(chunk) { throw BoneInferenceImageInputError.unsupportedAnimation }
                    safe = safe && safeChunks.contains(chunk)
                    if chunk == "IDAT" { hasPixels = true }
                    offset += length + 12
                    if chunk == "IEND" {
                        guard length == 0, offset == bytes.count, hasPixels else { throw BoneInferenceImageInputError.decodingFailed }
                        return safe
                    }
                }
                throw BoneInferenceImageInputError.decodingFailed
            case .jpeg:
                guard bytes.count >= 4, bytes[0] == 0xff, bytes[1] == 0xd8,
                      bytes[bytes.count - 2] == 0xff, bytes[bytes.count - 1] == 0xd9 else {
                    throw BoneInferenceImageInputError.decodingFailed
                }
                return false
            case .webp:
                guard bytes.count >= 12, text(0, 4) == "RIFF", text(8, 4) == "WEBP",
                      uint32(4, littleEndian: true) == bytes.count - 8 else { throw BoneInferenceImageInputError.decodingFailed }
                var offset = 12
                while offset <= bytes.count - 8 {
                    let chunk = text(offset, 4)
                    let length = uint32(offset + 4, littleEndian: true)
                    guard length <= bytes.count - offset - 8 else { throw BoneInferenceImageInputError.decodingFailed }
                    if chunk == "ANIM" || chunk == "ANMF" ||
                        (chunk == "VP8X" && length > 0 && bytes[offset + 8] & 2 != 0) {
                        throw BoneInferenceImageInputError.unsupportedAnimation
                    }
                    offset += 8 + length + length % 2
                }
                guard offset == bytes.count else { throw BoneInferenceImageInputError.decodingFailed }
                return false
            case nil:
                return false
            }
        }
    }

    private static func decodedImage(_ details: BoneImageSourceDetails) throws -> CGImage {
        let options = [kCGImageSourceShouldCache: true, kCGImageSourceShouldCacheImmediately: true,
                       kCGImageSourceShouldAllowFloat: false] as CFDictionary
        guard let image = CGImageSourceCreateImageAtIndex(details.source, 0, options),
              image.width == details.width, image.height == details.height,
              !image.isMask, image.colorSpace != nil, hasDecodedPixels(image),
              CGImageSourceGetStatus(details.source) == .statusComplete,
              CGImageSourceGetStatusAtIndex(details.source, 0) == .statusComplete else {
            throw BoneInferenceImageInputError.decodingFailed
        }
        return image
    }

    private static func hasDecodedPixels(_ image: CGImage) -> Bool {
        guard image.height > 0, image.bytesPerRow > 0, image.bytesPerRow <= Int.max / image.height,
              let pixels = image.dataProvider?.data else { return false }
        return CFDataGetLength(pixels) >= image.bytesPerRow * image.height
    }

    private static func safeProperties(_ properties: [String: Any]) -> Bool {
        let allowed: Set<String> = [kCGImagePropertyFileSize, kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight,
                                   kCGImagePropertyDepth, kCGImagePropertyColorModel, kCGImagePropertyProfileName,
                                   kCGImagePropertyHasAlpha, kCGImagePropertyOrientation].map { $0 as String }.reduce(into: []) { $0.insert($1) }
        let pngKeys: Set<String> = [kCGImagePropertyPNGInterlaceType, kCGImagePropertyPNGGamma,
                                   kCGImagePropertyPNGChromaticities, kCGImagePropertyPNGsRGBIntent].map { $0 as String }.reduce(into: []) { $0.insert($1) }
        return properties.allSatisfy { key, value in
            if allowed.contains(key) { return true }
            if key == kCGImagePropertyPNGDictionary as String, let png = value as? [String: Any] {
                return png.keys.allSatisfy(pngKeys.contains)
            }
            return false
        }
    }

    private static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    private static func transform(orientation: Int, width: Int, height: Int) -> CGAffineTransform {
        let w = CGFloat(width), h = CGFloat(height)
        switch orientation {
        case 2: return .init(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)
        case 3: return .init(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case 4: return .init(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
        case 5: return .init(a: 0, b: -1, c: -1, d: 0, tx: h, ty: w)
        case 6: return .init(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        case 7: return .init(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case 8: return .init(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        default: return .identity
        }
    }

    private static func prepare(_ data: Data, policy: BoneInferenceImagePreprocessor.Policy) throws -> BoneInferencePreparedImage {
        try Task.checkCancellation()
        let details = try source(data, maxPixels: policy.maxSourcePixels)
        let swapsAxes = (5...8).contains(details.orientation)
        let width = swapsAxes ? details.height : details.width
        let height = swapsAxes ? details.width : details.height
        var scale = min(1, Double(policy.maxWidth) / Double(width), Double(policy.maxHeight) / Double(height),
                        sqrt(Double(policy.maxPixels) / (Double(width) * Double(height))))
        // 极窄图片的一边取整为 1 时，按同一比例限制长边，仍满足总像素预算。
        if Double(min(width, height)) * scale < 1 {
            scale = min(scale, Double(policy.maxPixels) / Double(max(width, height)))
        }
        let targetWidth = max(1, Int((Double(width) * scale).rounded(.down)))
        let targetHeight = max(1, Int((Double(height) * scale).rounded(.down)))

        try Task.checkCancellation()
        // ImageIO 缩略图路径可能把损坏的像素流替换成空白图。
        // 先在已验证的原图像素上限内完成真实解码，再用 CGContext 一次绘制到目标大小。
        let decoded = try decodedImage(details)
        try Task.checkCancellation()
        if details.format == .png, details.orientation == 1, details.hasOnlySafePNGChunks,
           width == targetWidth, height == targetHeight, data.count <= policy.maximumPreparedBytes,
           safeProperties(details.properties), safeProperties(details.containerProperties),
           decoded.bitsPerComponent == 8, decoded.colorSpace?.name == CGColorSpace.sRGB {
            let metadata = try BoneInferenceImageMetadata(format: .png, width: width, height: height, byteCount: data.count)
            return try .init(data: data, metadata: metadata)
        }
        let alpha = hasAlpha(decoded)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: targetWidth, height: targetHeight, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue |
                                        (alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue)) else {
            throw BoneInferenceImageInputError.decodingFailed
        }
        context.interpolationQuality = .high
        context.scaleBy(x: CGFloat(targetWidth) / CGFloat(width), y: CGFloat(targetHeight) / CGFloat(height))
        context.concatenate(transform(orientation: details.orientation, width: details.width, height: details.height))
        context.draw(decoded, in: CGRect(x: 0, y: 0, width: details.width, height: details.height))
        guard let normalized = context.makeImage() else { throw BoneInferenceImageInputError.decodingFailed }
        try Task.checkCancellation()
        if policy.allowsLossy && !alpha {
            // 只降低质量，不因字节预算再次缩小；低于阶梯的配置也不会被提高。
            let qualities = [policy.jpegQuality] + [0.75, 0.6].filter { $0 < policy.jpegQuality }
            for quality in qualities {
                try Task.checkCancellation()
                let encoded = try encode(normalized, type: "public.jpeg", quality: quality)
                if encoded.count <= policy.maximumPreparedBytes {
                    return try prepared(encoded, width: targetWidth, height: targetHeight)
                }
            }
        } else {
            let encoded = try encode(normalized, type: "public.png", quality: nil)
            if encoded.count <= policy.maximumPreparedBytes {
                return try prepared(encoded, width: targetWidth, height: targetHeight)
            }
        }
        throw BoneInferenceImageInputError.preparedImageTooLarge
    }

    private static func encode(_ image: CGImage, type: String, quality: Double?) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else {
            throw BoneInferenceImageInputError.unsupportedFormat
        }
        var properties: [CFString: Any] = [:]
        if let quality { properties[kCGImageDestinationLossyCompressionQuality] = quality }
        // 从 CGImage 编码，仅写入编码参数和必要的 sRGB 配置，不复制源 EXIF/GPS/文本。
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw BoneInferenceImageInputError.decodingFailed }
        return data as Data
    }

    private static func prepared(_ data: Data, width: Int, height: Int) throws -> BoneInferencePreparedImage {
        let metadata = try inspect(data)
        guard metadata.width == width, metadata.height == height else { throw BoneInferenceImageInputError.invalidMetadata }
        return try .init(data: data, metadata: metadata)
    }
}
#endif
