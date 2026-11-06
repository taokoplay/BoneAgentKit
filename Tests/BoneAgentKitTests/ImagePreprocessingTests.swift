import Foundation
import XCTest
import BoneAgentKit
#if canImport(ImageIO) && canImport(CoreGraphics)
import ImageIO
import CoreGraphics
#endif

final class ImagePreprocessingTests: XCTestCase {
    func testPolicyDefaultsAndHardLimits() throws {
        let policy = BoneInferenceImagePreprocessingPolicy()
        XCTAssertEqual(policy.maxSourceBytes, 20 * 1_024 * 1_024)
        XCTAssertEqual(policy.maxSourcePixels, 64_000_000)
        XCTAssertEqual(policy.maxWidth, 2_048)
        XCTAssertEqual(policy.maxHeight, 2_048)
        XCTAssertEqual(policy.maxPixels, 4_000_000)
        XCTAssertEqual(policy.maximumPreparedBytes, 4 * 1_024 * 1_024)
        XCTAssertFalse(policy.allowsLossy)
        XCTAssertEqual(policy.jpegQuality, 0.85)
        for value in [Int.min, -1, 0, 20 * 1_024 * 1_024 + 1, Int.max] {
            assertImageError(.invalidPolicy) { _ = try BoneInferenceImagePreprocessingPolicy(maxSourceBytes: value) }
            assertImageError(.invalidPolicy) { _ = try BoneInferenceImagePreprocessingPolicy(maximumPreparedBytes: value) }
        }
        for value in [Int.min, -1, 0, 64_000_001, Int.max] {
            assertImageError(.invalidPolicy) { _ = try BoneInferenceImagePreprocessingPolicy(maxSourcePixels: value) }
            assertImageError(.invalidPolicy) { _ = try BoneInferenceImagePreprocessingPolicy(maxPixels: value) }
        }
        for value in [Int.min, -1, 0, 32_769, Int.max] {
            assertImageError(.invalidPolicy) { _ = try BoneInferenceImagePreprocessingPolicy(maxWidth: value) }
            assertImageError(.invalidPolicy) { _ = try BoneInferenceImagePreprocessingPolicy(maxHeight: value) }
        }
        for value in [Double.nan, .infinity, -.infinity, -0.01, 1.01] {
            assertImageError(.invalidPolicy) { _ = try BoneInferenceImagePreprocessingPolicy(jpegQuality: value) }
        }
        _ = try BoneInferenceImagePreprocessingPolicy(maxSourceBytes: 1, maxSourcePixels: 1, maxWidth: 1,
                                                      maxHeight: 1, maxPixels: 1, maximumPreparedBytes: 1, jpegQuality: 0)
        _ = try BoneInferenceImagePreprocessingPolicy(maxWidth: 32_768, maxHeight: 32_768, maxPixels: 64_000_000,
                                                      maximumPreparedBytes: 20 * 1_024 * 1_024, jpegQuality: 1)
    }

    func testInjectedOperationReceivesDataAndPolicy() async throws {
        let data = Data([1, 2, 3, 4])
        let policy = try BoneInferenceImagePreprocessingPolicy(maxWidth: 16, allowsLossy: true)
        let processor = BoneInferenceImagePreprocessor { received, receivedPolicy in
            XCTAssertEqual(received, data)
            XCTAssertEqual(receivedPolicy, policy)
            return try boneContractImage(received, width: 8, height: 4)
        }
        let result = try await processor.prepare(data, policy: policy)
        XCTAssertEqual(result.data, data)
        XCTAssertEqual(result.metadata.width, 8)
    }

    func testSourceBytesRejectedBeforeCallingOperation() async throws {
        let calls = BoneImageTestCalls()
        let processor = BoneInferenceImagePreprocessor { data, _ in
            await calls.record()
            return try boneContractImage(data)
        }
        await assertImageError(.sourceTooLarge) {
            _ = try await processor.prepare(Data([1, 2]), policy: .init(maxSourceBytes: 1))
        }
        await assertImageError(.invalidContent) { _ = try await processor.prepare(Data()) }
        let count = await calls.count
        XCTAssertEqual(count, 0)
    }

    func testReturnedMetadataMustFitEveryTargetLimit() async throws {
        let processor = BoneInferenceImagePreprocessor { _, _ in
            try boneContractImage(Data([1, 2, 3, 4]), width: 8, height: 4)
        }
        let policies = try [BoneInferenceImagePreprocessingPolicy(maxWidth: 7), .init(maxHeight: 3),
                            .init(maxPixels: 31), .init(maximumPreparedBytes: 3)]
        for policy in policies {
            await assertImageError(.preparedImageTooLarge) {
                _ = try await processor.prepare(Data([1]), policy: policy)
            }
        }
    }

    func testIncorrectByteCountAndCodecErrorAreRejected() async throws {
        let incorrect = BoneInferenceImagePreprocessor { data, _ in
            try .init(data: data, metadata: .init(format: .png, width: 1, height: 1, byteCount: data.count + 1))
        }
        await assertImageError(.invalidMetadata) { _ = try await incorrect.prepare(Data([1])) }
        let failing = BoneInferenceImagePreprocessor { _, _ in throw BoneInferenceImageInputError.decodingFailed }
        await assertImageError(.decodingFailed) { _ = try await failing.prepare(Data([1])) }
    }

    func testCancellationBeforeOperation() async throws {
        let calls = BoneImageTestCalls()
        let processor = BoneInferenceImagePreprocessor { data, _ in
            await calls.record()
            return try boneContractImage(data)
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await processor.prepare(Data([1]))
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let count = await calls.count
        XCTAssertEqual(count, 0)
    }

    func testCancellationAfterOperationCannotReturnAnImage() async throws {
        let processor = BoneInferenceImagePreprocessor { data, _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return try boneContractImage(data)
        }
        let task = Task { try await processor.prepare(Data([1])) }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    #if canImport(ImageIO) && canImport(CoreGraphics)
    func testInspectorReportsActualPNGAndJPEGFormatDimensionsAndBytes() throws {
        for (type, format) in [("public.png", BoneInferenceImageFormat.png), ("public.jpeg", .jpeg)] {
            let data = try boneEncodedImage(width: 13, height: 7, type: type)
            let metadata = try BoneInferenceImageIO.inspect(data)
            XCTAssertEqual(metadata.format, format)
            XCTAssertEqual(metadata.width, 13)
            XCTAssertEqual(metadata.height, 7)
            XCTAssertEqual(metadata.byteCount, data.count)
        }
    }

    func testWebPInspectionAndConversionWhenDecoderIsAvailable() async throws {
        let types = CGImageSourceCopyTypeIdentifiers() as! [String]
        guard types.contains("org.webmproject.webp") else { throw XCTSkip("System ImageIO has no WebP decoder") }
        let data = try XCTUnwrap(Data(base64Encoded: "UklGRiIAAABXRUJQVlA4IBYAAAAwAQCdASoBAAEADsD+JaQAA3AAAAAA"))
        let metadata = try BoneInferenceImageIO.inspect(data)
        XCTAssertEqual(metadata.format, .webp)
        XCTAssertEqual(metadata.width, 1)
        XCTAssertEqual(metadata.height, 1)
        XCTAssertEqual(metadata.byteCount, data.count)
        let result = try await BoneInferenceImageIO.preprocessor.prepare(data)
        XCTAssertEqual(result.metadata.format, .png)
    }

    func testDamagedAndTruncatedImagesAreRejected() async throws {
        let png = try boneEncodedImage(width: 16, height: 8)
        let jpeg = try boneEncodedImage(width: 16, height: 8, type: "public.jpeg")
        let damagedPixels = boneReplacingPNGChunk(png, name: "IDAT") { Data(repeating: 0xff, count: $0.count) }
        for invalid in [Data("not an image".utf8), Data(png.prefix(32)), Data(jpeg.dropLast(8)), damagedPixels] {
            XCTAssertThrowsError(try BoneInferenceImageIO.inspect(invalid))
            do { _ = try await BoneInferenceImageIO.preprocessor.prepare(invalid); XCTFail("Expected decode failure") }
            catch { XCTAssertTrue(error is BoneInferenceImageInputError) }
        }
    }

    func testAnimationsAndMultiplePagesAreRejected() async throws {
        for type in ["com.compuserve.gif", "public.tiff", "public.png"] {
            let data = try boneEncodedImage(width: 8, height: 8, type: type, frames: 2)
            assertImageError(.unsupportedAnimation) { _ = try BoneInferenceImageIO.inspect(data) }
            await assertImageError(.unsupportedAnimation) { _ = try await BoneInferenceImageIO.preprocessor.prepare(data) }
        }
    }

    func testStaticNonWireImageIsConvertedToPNG() async throws {
        let data = try boneEncodedImage(width: 20, height: 10, type: "public.tiff")
        assertImageError(.unsupportedFormat) { _ = try BoneInferenceImageIO.inspect(data) }
        let result = try await BoneInferenceImageIO.preprocessor.prepare(data)
        XCTAssertEqual(result.metadata.format, .png)
        XCTAssertEqual(result.metadata.width, 20)
        XCTAssertEqual(result.metadata.height, 10)
    }

    func testHEICIsOnlyAcceptedAsAConversionSourceWhenEncoderIsAvailable() async throws {
        let types = CGImageDestinationCopyTypeIdentifiers() as! [String]
        guard types.contains("public.heic") else { throw XCTSkip("System ImageIO has no HEIC encoder") }
        let data = try boneEncodedImage(width: 64, height: 32, type: "public.heic")
        assertImageError(.unsupportedFormat) { _ = try BoneInferenceImageIO.inspect(data) }
        let result = try await BoneInferenceImageIO.preprocessor.prepare(data)
        XCTAssertEqual(result.metadata.format, .png)
        XCTAssertEqual(result.metadata.width, 64)
        XCTAssertEqual(result.metadata.height, 32)
    }

    func testSmallImageIsAcceptedWithoutUpscaling() async throws {
        let data = try boneEncodedImage(width: 12, height: 6)
        let result = try await BoneInferenceImageIO.preprocessor.prepare(data)
        XCTAssertEqual(result.metadata.width, 12)
        XCTAssertEqual(result.metadata.height, 6)
        XCTAssertEqual(result.metadata, try BoneInferenceImageIO.inspect(result.data))
        let decoded = try boneDecodedImage(result.data)
        XCTAssertEqual(decoded.bitsPerComponent, 8)
        XCTAssertEqual(decoded.colorSpace?.name, CGColorSpace.sRGB)
    }

    func testResizePreservesAspectRatioAndOCRPolicyCanKeepSourceSize() async throws {
        let data = try boneEncodedImage(width: 2_400, height: 1_200)
        let standard = try await BoneInferenceImageIO.preprocessor.prepare(data)
        XCTAssertEqual(standard.metadata.width, 2_048)
        XCTAssertEqual(standard.metadata.height, 1_024)
        let pixels = try await BoneInferenceImageIO.preprocessor.prepare(data, policy: .init(maxPixels: 720_000))
        XCTAssertEqual(pixels.metadata.width, 1_200)
        XCTAssertEqual(pixels.metadata.height, 600)
        let ocr = try await BoneInferenceImageIO.preprocessor.prepare(data, policy: .init(maxWidth: 4_096,
                                                                                      maxHeight: 4_096, maxPixels: 16_000_000))
        XCTAssertEqual(ocr.metadata.width, 2_400)
        XCTAssertEqual(ocr.metadata.height, 1_200)
    }

    func testVeryNarrowImagesRespectExplicitPixelBudget() async throws {
        for (width, height) in [(1, 200), (200, 1)] {
            let data = try boneEncodedImage(width: width, height: height)
            let result = try await BoneInferenceImageIO.preprocessor.prepare(data, policy: .init(maxPixels: 4))
            XCTAssertEqual(result.metadata.width, width == 1 ? 1 : 4)
            XCTAssertEqual(result.metadata.height, height == 1 ? 1 : 4)
        }
    }

    func testWideGamutSourceIsConvertedToEightBitSRGB() async throws {
        let data = try boneEncodedImage(width: 24, height: 12, colorSpaceName: CGColorSpace.displayP3)
        XCTAssertEqual(try boneDecodedImage(data).colorSpace?.name, CGColorSpace.displayP3)
        let result = try await BoneInferenceImageIO.preprocessor.prepare(data)
        let image = try boneDecodedImage(result.data)
        XCTAssertEqual(image.bitsPerComponent, 8)
        XCTAssertEqual(image.colorSpace?.name, CGColorSpace.sRGB)
        XCTAssertEqual(result.metadata.format, .png)
    }

    func testPNGTextMetadataIsRemoved() async throws {
        let data = try boneEncodedImage(width: 24, height: 12,
                                       properties: [kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGDescription: "private-png-note"]])
        let sourceProperties = try boneProperties(data)[kCGImagePropertyPNGDictionary as String] as? [String: Any]
        XCTAssertEqual(sourceProperties?[kCGImagePropertyPNGDescription as String] as? String, "private-png-note")
        let result = try await BoneInferenceImageIO.preprocessor.prepare(data)
        let outputProperties = try boneProperties(result.data)[kCGImagePropertyPNGDictionary as String] as? [String: Any]
        XCTAssertNil(outputProperties?[kCGImagePropertyPNGDescription as String])
    }

    func testTransparentPixelsStayTransparentEvenWhenLossyIsAllowed() async throws {
        let data = try boneEncodedImage(width: 20, height: 10, alpha: true)
        let result = try await BoneInferenceImageIO.preprocessor.prepare(data, policy: .init(maxWidth: 10, allowsLossy: true))
        XCTAssertEqual(result.metadata.format, .png)
        XCTAssertEqual(result.metadata.width, 10)
        XCTAssertEqual(result.metadata.height, 5)
        let pixels = try boneRGBA(result.data)
        let alphas = stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] }
        XCTAssertTrue(alphas.contains { $0 == 0 })
        XCTAssertTrue(alphas.contains { $0 > 0 && $0 < 255 })
    }

    func testAllEXIFOrientationsAreNormalizedWithAxesSwappedWhenRequired() async throws {
        for orientation in 2...8 {
            let data = try boneEncodedImage(width: 40, height: 20, type: "public.jpeg",
                                           properties: [kCGImagePropertyOrientation: orientation], noise: true)
            assertImageError(.invalidMetadata) { _ = try BoneInferenceImageIO.inspect(data) }
            let result = try await BoneInferenceImageIO.preprocessor.prepare(data)
            XCTAssertEqual(result.metadata.width, orientation >= 5 ? 20 : 40)
            XCTAssertEqual(result.metadata.height, orientation >= 5 ? 40 : 20)
            let properties = try boneProperties(result.data)
            XCTAssertEqual((properties[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue ?? 1, 1)
            XCTAssertEqual(result.metadata, try BoneInferenceImageIO.inspect(result.data))
            // 用系统的方向转换作独立像素参照，验证镜像和旋转内容，而不只检查尺寸。
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                          kCGImageSourceCreateThumbnailWithTransform: true,
                                          kCGImageSourceThumbnailMaxPixelSize: 40]
            let reference = try XCTUnwrap(CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary))
            let expected = try boneRGBA(reference)
            let actual = try boneRGBA(result.data)
            XCTAssertEqual(actual.count, expected.count)
            let largestDifference = zip(actual, expected).map { abs(Int($0) - Int($1)) }.max() ?? 0
            XCTAssertLessThanOrEqual(largestDifference, 2, "Orientation \(orientation)")
        }
    }

    func testEXIFGPSAndTextMetadataAreRemovedForPNGAndJPEGOutput() async throws {
        let properties: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "private-camera-note",
                                             kCGImagePropertyExifDateTimeOriginal: "2025:01:02 03:04:05"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 37.3, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 122.0, kCGImagePropertyGPSLongitudeRef: "W"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFSoftware: "private-camera-software"]
        ]
        let data = try boneEncodedImage(width: 32, height: 16, type: "public.jpeg", properties: properties)
        XCTAssertNotNil(try boneProperties(data)[kCGImagePropertyGPSDictionary as String])
        for lossy in [false, true] {
            let result = try await BoneInferenceImageIO.preprocessor.prepare(data, policy: .init(allowsLossy: lossy))
            XCTAssertEqual(result.metadata.format, lossy ? .jpeg : .png)
            let output = try boneProperties(result.data)
            XCTAssertNil(output[kCGImagePropertyGPSDictionary as String])
            let exif = output[kCGImagePropertyExifDictionary as String] as? [String: Any]
            XCTAssertNil(exif?[kCGImagePropertyExifUserComment as String])
            XCTAssertNil(exif?[kCGImagePropertyExifDateTimeOriginal as String])
            let tiff = output[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
            XCTAssertNil(tiff?[kCGImagePropertyTIFFSoftware as String])
        }
    }

    func testByteBudgetFailsWithoutFurtherShrinkingAndJPEGQualityCanStepDown() async throws {
        let data = try boneEncodedImage(width: 128, height: 64, noise: true)
        for lossy in [false, true] {
            await assertImageError(.preparedImageTooLarge) {
                _ = try await BoneInferenceImageIO.preprocessor.prepare(data, policy: .init(maximumPreparedBytes: 1, allowsLossy: lossy))
            }
        }
        let low = try await BoneInferenceImageIO.preprocessor.prepare(data, policy: .init(allowsLossy: true, jpegQuality: 0.6))
        let high = try await BoneInferenceImageIO.preprocessor.prepare(data, policy: .init(allowsLossy: true, jpegQuality: 1))
        XCTAssertLessThan(low.data.count, high.data.count)
        let bounded = try await BoneInferenceImageIO.preprocessor.prepare(data, policy: .init(maximumPreparedBytes: low.data.count,
                                                                                           allowsLossy: true, jpegQuality: 1))
        XCTAssertEqual(bounded.metadata.width, 128)
        XCTAssertEqual(bounded.metadata.height, 64)
        XCTAssertLessThanOrEqual(bounded.data.count, low.data.count)
    }

    func testSourcePixelAndHardDimensionLimitsAreCheckedBeforeDecode() async throws {
        let data = try boneEncodedImage(width: 16, height: 8)
        await assertImageError(.sourceTooLarge) {
            _ = try await BoneInferenceImageIO.preprocessor.prepare(data, policy: .init(maxSourcePixels: 127))
        }
        for (width, height) in [(32_769, 1), (8_001, 8_000)] {
            let huge = boneReplacingPNGChunk(data, name: "IHDR") { original in
                var payload = original
                payload.replaceSubrange(0..<8, with: boneBigEndian(width) + boneBigEndian(height))
                return payload
            }
            assertImageError(.sourceTooLarge) { _ = try BoneInferenceImageIO.inspect(huge) }
            await assertImageError(.sourceTooLarge) { _ = try await BoneInferenceImageIO.preprocessor.prepare(huge) }
        }
        assertImageError(.sourceTooLarge) {
            _ = try BoneInferenceImageIO.inspect(Data(repeating: 0, count: BoneInferenceImageMetadata.maximumBytes + 1))
        }
    }

    func testResolverRejectsForgedDimensionsUsingActualInspection() async throws {
        let data = try boneEncodedImage(width: 16, height: 8)
        let forged = try BoneInferencePreparedImage(data: data, metadata: .init(format: .png, width: 8, height: 16, byteCount: data.count))
        let reference = try forged.reference(id: "image", version: "1")
        let resolver = BoneInferenceImageResolver(inspect: { try BoneInferenceImageIO.inspect($0) }, load: { _ in data })
        await assertImageError(.referenceMismatch) { _ = try await resolver.resolve(reference) }
    }
    #endif
}

private actor BoneImageTestCalls {
    var count = 0
    func record() { count += 1 }
}

private func boneContractImage(_ data: Data, width: Int = 1, height: Int = 1) throws -> BoneInferencePreparedImage {
    try .init(data: data, metadata: .init(format: .png, width: width, height: height, byteCount: data.count))
}

private func assertImageError(_ expected: BoneInferenceImageInputError, file: StaticString = #filePath, line: UInt = #line,
                              _ body: () throws -> Void) {
    XCTAssertThrowsError(try body(), file: file, line: line) { XCTAssertEqual($0 as? BoneInferenceImageInputError, expected, file: file, line: line) }
}

private func assertImageError(_ expected: BoneInferenceImageInputError, file: StaticString = #filePath, line: UInt = #line,
                              _ body: () async throws -> Void) async {
    do { try await body(); XCTFail("Expected \(expected)", file: file, line: line) }
    catch { XCTAssertEqual(error as? BoneInferenceImageInputError, expected, file: file, line: line) }
}

#if canImport(ImageIO) && canImport(CoreGraphics)
private func boneEncodedImage(width: Int, height: Int, type: String = "public.png", alpha: Bool = false,
                              properties: [CFString: Any] = [:], frames: Int = 1, noise: Bool = false,
                              colorSpaceName: CFString = CGColorSpace.sRGB) throws -> Data {
    let space = try XCTUnwrap(CGColorSpace(name: colorSpaceName))
    let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                         bytesPerRow: width * 4, space: space,
                                         bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue |
                                            (alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue)))
    if noise {
        let buffer = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        var value: UInt32 = 42
        for index in 0..<(width * height * 4) {
            value = value &* 1_664_525 &+ 1_013_904_223
            buffer[index] = index % 4 == 3 ? 255 : UInt8(truncatingIfNeeded: value >> 24)
        }
    } else {
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: alpha ? 0.5 : 1)
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        if !alpha {
            context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
            context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        }
    }
    let image = try XCTUnwrap(context.makeImage())
    let data = NSMutableData()
    let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type as CFString, frames, nil))
    for _ in 0..<frames { CGImageDestinationAddImage(destination, image, properties as CFDictionary) }
    guard CGImageDestinationFinalize(destination) else { throw BoneInferenceImageInputError.decodingFailed }
    return data as Data
}

private func boneProperties(_ data: Data) throws -> [String: Any] {
    let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
    return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
}

private func boneDecodedImage(_ data: Data) throws -> CGImage {
    let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
    return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary))
}

private func boneRGBA(_ data: Data) throws -> [UInt8] {
    try boneRGBA(boneDecodedImage(data))
}

private func boneRGBA(_ image: CGImage) throws -> [UInt8] {
    let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                         bytesPerRow: image.width * 4, space: space,
                                         bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let buffer = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
    return Array(UnsafeBufferPointer(start: buffer, count: image.width * image.height * 4))
}

private func boneBigEndian(_ value: Int) -> [UInt8] {
    [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) }
}

private func boneReplacingPNGChunk(_ data: Data, name: String, transform: (Data) -> Data) -> Data {
    var result = Data(data.prefix(8))
    var offset = 8
    while offset + 12 <= data.count {
        let length = (0..<4).reduce(0) { ($0 << 8) | Int(data[offset + $1]) }
        let chunk = data[(offset + 4)..<(offset + 8)]
        let original = Data(data[(offset + 8)..<(offset + 8 + length)])
        if String(data: chunk, encoding: .ascii) == name {
            let payload = transform(original)
            let checked = Data(chunk) + payload
            var crc: UInt32 = .max
            for byte in checked {
                crc ^= UInt32(byte)
                for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 0 ? 0 : 0xedb88320) }
            }
            result.append(contentsOf: boneBigEndian(payload.count))
            result.append(checked)
            result.append(contentsOf: boneBigEndian(Int(crc ^ .max)))
        } else {
            result.append(data[offset..<(offset + length + 12)])
        }
        offset += length + 12
    }
    return result
}
#endif
