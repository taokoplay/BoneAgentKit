import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
import BoneAgentKit
@testable import WorkflowRunnerDemo
#if canImport(ImageIO) && canImport(CoreGraphics)
import ImageIO
import CoreGraphics
#endif

final class VisionIntegrationTests: XCTestCase {
    func testExplicitPoliciesAndDisabledConfiguration() async throws {
        XCTAssertEqual(DemoVisionPolicy.allCases.map(\.rawValue), ["disabled", "openAI41Mini", "customLinear"])
        XCTAssertThrowsError(try JSONDecoder().decode(DemoVisionPolicy.self, from: Data("\"unknown\"".utf8)))
        let settings = DemoLiveChatSettings()
        XCTAssertEqual(settings.visionPolicy, .disabled)
        let configuration = try await DemoChatImageStore().configuration(settings: settings)
        XCTAssertNil(configuration)
        XCTAssertThrowsError(try DemoVisionTokenProvider(settings: settings)) {
            XCTAssertEqual($0 as? DemoVisionError, .disabled)
        }
    }

    func testEveryBindingComponentMustStillMatch() throws {
        let original = visionSettings()
        try original.visionPolicy.validate(settings: original)
        for component in 0..<5 {
            var changed = original
            switch component {
            case 0: changed.provider = .customOpenAI
            case 1: changed.baseURL = "https://other-vision.invalid/v1"
            case 2: changed.modelID = "gpt-4.1-mini-2025-04-14"
            case 3: changed.usesFullEndpointURL = true
            default: changed.visionBindingID = ""
            }
            XCTAssertEqual(changed.visionPolicy, original.visionPolicy)
            XCTAssertThrowsError(try changed.visionPolicy.validate(settings: changed)) {
                XCTAssertEqual($0 as? DemoVisionError, .bindingMismatch)
            }
        }
    }

    func testKnownPolicyRequiresExactProviderAndModel() throws {
        for model in ["gpt-4.1-mini", "gpt-4.1-mini-2025-04-14"] {
            var settings = visionSettings()
            settings.modelID = model
            settings.visionBindingID = settings.visionBindingFingerprint
            try settings.visionPolicy.validate(settings: settings)
        }
        for model in ["gpt-4.1", "gpt-4.1-nano", "prefix-gpt-4.1-mini", "gpt-4.1-mini-latest", "gpt-4.1-mini "] {
            var settings = visionSettings()
            settings.modelID = model
            settings.visionBindingID = settings.visionBindingFingerprint
            XCTAssertThrowsError(try settings.visionPolicy.validate(settings: settings)) {
                XCTAssertEqual($0 as? DemoVisionError, .unsupportedModel)
            }
        }
        for provider in [DemoChatProvider.customOpenAI, .anthropic, .gemini] {
            var settings = visionSettings()
            settings.provider = provider
            settings.visionBindingID = settings.visionBindingFingerprint
            XCTAssertThrowsError(try settings.visionPolicy.validate(settings: settings)) {
                XCTAssertEqual($0 as? DemoVisionError, .unsupportedModel)
            }
        }
    }

    func testCustomPolicyRequiresExplicitPositiveBoundedParameters() throws {
        var settings = visionSettings(policy: .customLinear)
        settings.modelID = "host-explicit-model"
        settings.visionBindingID = settings.visionBindingFingerprint
        settings.visionTokenBase = 0
        settings.visionTokensPerMegapixel = 0
        XCTAssertThrowsError(try settings.visionPolicy.validate(settings: settings)) {
            XCTAssertEqual($0 as? DemoVisionError, .invalidCustomParameters)
        }
        for invalid in [Int.min, -1, 0, 100_001, Int.max] {
            for changingBase in [false, true] {
                settings.visionTokenBase = changingBase ? invalid : 100
                settings.visionTokensPerMegapixel = changingBase ? 100 : invalid
                XCTAssertThrowsError(try settings.visionPolicy.validate(settings: settings)) {
                    XCTAssertEqual($0 as? DemoVisionError, .invalidCustomParameters)
                }
            }
        }
        settings.visionTokenBase = 100_000
        settings.visionTokensPerMegapixel = 100_000
        try settings.visionPolicy.validate(settings: settings)
        XCTAssertTrue(settings.visionPolicy.sourceDescription.contains("用户配置"))
        XCTAssertTrue(settings.visionPolicy.sourceDescription.contains("实际用量"))
    }

    func testInvalidContextAndOutputBudgetsAreRejected() throws {
        for (window, output) in [(0, 128), (-1, 128), (32_768, 0), (32_768, -1),
                                 (4_096, 4_096), (4_096, 8_192), (2_048, 1_024)] {
            var settings = visionSettings()
            settings.contextWindowTokens = window
            settings.maximumOutputTokens = output
            XCTAssertThrowsError(try settings.visionPolicy.validate(settings: settings)) {
                XCTAssertEqual($0 as? DemoVisionError, .invalidContextBudget)
            }
        }
    }

    #if canImport(ImageIO) && canImport(CoreGraphics)
    func testActualPNGPreprocessingResolverAndHostProfile() async throws {
        let source = try visionEncodedImage(width: 23, height: 11,
            colorSpace: CGColorSpace.displayP3,
            properties: [kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGDescription: "synthetic-private-note"]])
        let store = DemoChatImageStore()
        let prepared = try await store.add(data: source)
        XCTAssertNotNil(UUID(uuidString: prepared.id))
        XCTAssertNotNil(UUID(uuidString: prepared.reference.version))
        XCTAssertNotEqual(prepared.id, prepared.reference.version)
        XCTAssertEqual(prepared.width, 23)
        XCTAssertEqual(prepared.height, 11)
        XCTAssertEqual(prepared.byteCount, prepared.previewData.count)
        XCTAssertEqual(try BoneInferenceImageIO.inspect(prepared.previewData), prepared.reference.metadata)
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithData(prepared.previewData as CFData, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        XCTAssertEqual(decoded.colorSpace?.name, CGColorSpace.sRGB)
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any])
        let png = properties[kCGImagePropertyPNGDictionary as String] as? [String: Any]
        XCTAssertNil(png?[kCGImagePropertyPNGDescription as String])
        let settings = visionSettings()
        let optional = try await store.configuration(settings: settings)
        let configuration = try XCTUnwrap(optional)
        XCTAssertEqual(Set(configuration.profiles.keys), [settings.modelID])
        let profile = try XCTUnwrap(configuration.profiles[settings.modelID])
        XCTAssertEqual(profile.contextBudget.source, .host)
        XCTAssertEqual(profile.contextBudget.contextWindowTokens, settings.contextWindowTokens)
        XCTAssertEqual(profile.contextBudget.maximumOutputTokens, settings.maximumOutputTokens)
        XCTAssertEqual(profile.maximumImagesPerRequest, 6)
        XCTAssertEqual(profile.maximumImageBytes, 2 * 1_024 * 1_024)
        XCTAssertEqual(profile.maximumBase64BytesPerRequest, DemoChatImageStore.maximumBase64Bytes)
        XCTAssertEqual(profile.maximumRequestBodyBytes, DemoChatImageStore.maximumRequestBodyBytes)
        for _ in 0..<2 {
            let resolved = try await configuration.resolver.resolve(prepared.reference)
            XCTAssertEqual(resolved.data, prepared.previewData)
            XCTAssertEqual(resolved.metadata, prepared.reference.metadata)
        }
        let inputs = try await store.inputs(for: [prepared.id])
        XCTAssertEqual(inputs, [.init(reference: prepared.reference)])
        XCTAssertThrowsError(try configuration.imageTokens(for: inputs[0], modelID: "gpt-4.1-mini-alias"))
    }

    func testEXIFOrientationAndLocationAreNormalizedBySDK() async throws {
        let source = try visionEncodedImage(width: 24, height: 12, type: "public.jpeg",
            colorSpace: CGColorSpace.displayP3,
            properties: [kCGImagePropertyOrientation: 6,
                         kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "synthetic-private-note"],
                         kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 1.0]])
        let image = try await DemoChatImageStore().add(data: source)
        XCTAssertEqual(image.width, 12)
        XCTAssertEqual(image.height, 24)
        let sourceRef = try XCTUnwrap(CGImageSourceCreateWithData(image.previewData as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(sourceRef, 0, nil) as? [String: Any])
        XCTAssertEqual((properties[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue ?? 1, 1)
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any]
        XCTAssertNil(exif?[kCGImagePropertyExifUserComment as String])
        XCTAssertNil(exif?[kCGImagePropertyExifDateTimeOriginal as String])
        XCTAssertNil(exif?[kCGImagePropertyExifMakerNote as String])
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary as String])
        XCTAssertEqual(try BoneInferenceImageIO.inspect(image.previewData), image.reference.metadata)
    }

    func testDocumentedPatchCountsAndCustomActualPixelCeiling() async throws {
        let store = DemoChatImageStore()
        let settings = visionSettings()
        let provider = try DemoVisionTokenProvider(settings: settings)
        for (width, height, expected) in [(32, 32, 2), (33, 33, 7), (1_024, 1_024, 1_659)] {
            let image = try await store.add(data: visionEncodedImage(width: width, height: height))
            XCTAssertEqual(try provider.imageTokens(for: .init(reference: image.reference), modelID: settings.modelID), expected)
        }
        var custom = visionSettings(policy: .customLinear)
        custom.visionTokenBase = 17
        custom.visionTokensPerMegapixel = 101
        let customProvider = try DemoVisionTokenProvider(settings: custom)
        for (width, height, expected) in [(1, 1, 118), (1_000, 1_000, 118), (1_001, 1_000, 219)] {
            let image = try await store.add(data: visionEncodedImage(width: width, height: height))
            XCTAssertEqual(try customProvider.imageTokens(for: .init(reference: image.reference), modelID: custom.modelID), expected)
        }
    }

    func testSourcePreparedAndImageCountCaps() async throws {
        let store = DemoChatImageStore()
        await expectVisionError(.imageTooLarge) {
            _ = try await store.add(data: Data(repeating: 0, count: DemoChatImageStore.maximumSourceBytes + 1))
        }
        let resized = try await store.add(data: visionEncodedImage(width: 2_048, height: 1_024))
        XCTAssertEqual(resized.width, 1_024)
        XCTAssertEqual(resized.height, 512)
        let tooManyPixels = try visionEncodedImage(width: 4_001, height: 4_000)
        do { _ = try await store.add(data: tooManyPixels); XCTFail("Expected source pixel cap") }
        catch { XCTAssertEqual(error as? BoneInferenceImageInputError, .sourceTooLarge) }
        let noisy = try visionEncodedImage(width: 1_024, height: 1_024, noise: true)
        do { _ = try await store.add(data: noisy); XCTFail("Expected prepared byte cap") }
        catch { XCTAssertEqual(error as? BoneInferenceImageInputError, .preparedImageTooLarge) }
        let small = try visionEncodedImage(width: 4, height: 4)
        for _ in 1..<DemoChatImageStore.maximumImages { _ = try await store.add(data: small) }
        await expectVisionError(.capacityReached) { _ = try await store.add(data: small) }
        await expectVisionError(.capacityReached) {
            _ = try await store.inputs(for: Array(repeating: resized.id, count: 7))
        }
        let entries = await store.entries()
        XCTAssertEqual(entries.count, 6)
        XCTAssertLessThanOrEqual(entries.reduce(0, { $0 + $1.byteCount }), 12 * 1_024 * 1_024)
    }

    func testRestoreRejectsTamperedBytesHashDimensionsVersionsAndCounts() async throws {
        let store = DemoChatImageStore()
        let image = try await store.add(data: visionEncodedImage(width: 17, height: 9))
        let archive = try await store.exportPrivateState()
        let restored = try DemoChatImageStore(privateState: archive)
        let restoredEntries = await restored.entries()
        XCTAssertEqual(restoredEntries.map(\.reference), [image.reference])
        XCTAssertEqual(restoredEntries.first?.previewData, image.previewData)
        let restoredConfiguration = try await restored.configuration(settings: visionSettings())
        let resolved = try await XCTUnwrap(restoredConfiguration).resolver.resolve(image.reference)
        XCTAssertEqual(resolved.data, image.previewData)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: archive) as? [String: Any])
        for failure in 0..<9 {
            var changed = object
            var images = try XCTUnwrap(changed["images"] as? [[String: Any]])
            var reference = try XCTUnwrap(images[0]["reference"] as? [String: Any])
            var metadata = try XCTUnwrap(reference["metadata"] as? [String: Any])
            switch failure {
            case 0:
                var bytes = image.previewData
                bytes[bytes.count / 2] ^= 1
                images[0]["bytes"] = bytes.base64EncodedString()
            case 1: reference["sha256"] = String(repeating: "0", count: 64)
            case 2: metadata["width"] = image.width + 1
            case 3: metadata["byteCount"] = image.byteCount + 1
            case 4: reference["version"] = "not-a-uuid"
            case 5: reference["id"] = "not-a-uuid"
            case 6: changed["formatVersion"] = 2
            case 7: images.append(images[0])
            default: images = Array(repeating: images[0], count: 7)
            }
            reference["metadata"] = metadata
            images[0]["reference"] = reference
            changed["images"] = images
            let tampered = try JSONSerialization.data(withJSONObject: changed)
            XCTAssertThrowsError(try DemoChatImageStore(privateState: tampered)) {
                XCTAssertEqual($0 as? DemoVisionError, .invalidPrivateState)
            }
        }
        XCTAssertThrowsError(try DemoChatImageStore(privateState:
            Data(repeating: 0, count: DemoChatImageStore.maximumPrivateStateBytes + 1))) {
            XCTAssertEqual($0 as? DemoVisionError, .invalidPrivateState)
        }
    }

    func testOldResolverRejectsChangedRemovedAndClearedReferences() async throws {
        let store = DemoChatImageStore()
        let bytes = try visionEncodedImage(width: 12, height: 6)
        let first = try await store.add(data: bytes)
        let second = try await store.add(data: bytes)
        let optional = try await store.configuration(settings: visionSettings())
        let resolver = try XCTUnwrap(optional).resolver
        let original = first.reference
        for changed in [
            try BoneInferenceImageReference(id: original.id, version: UUID().uuidString,
                sha256: original.sha256, metadata: original.metadata),
            try BoneInferenceImageReference(id: original.id, version: original.version,
                sha256: String(repeating: "0", count: 64), metadata: original.metadata)
        ] {
            await expectVisionError(.referenceMismatch) { _ = try await resolver.resolve(changed) }
        }
        await store.remove(id: first.id)
        await expectVisionError(.unavailableImage) { _ = try await resolver.resolve(first.reference) }
        _ = try await resolver.resolve(second.reference)
        await store.clear()
        await expectVisionError(.unavailableImage) { _ = try await resolver.resolve(second.reference) }
        await expectVisionError(.unavailableImage) { _ = try await store.inputs(for: [second.id]) }
        let replacement = try await store.add(data: bytes)
        XCTAssertNotEqual(replacement.id, second.id)
        XCTAssertNotEqual(replacement.reference.version, second.reference.version)
    }

    func testConcreteProvidersSendExactPreparedImageBytesOnlyOnInfer() async throws {
        for kind in [BoneInferenceProviderKind.openAI, .anthropic, .google] {
            let store = DemoChatImageStore()
            let prepared = try await store.add(data: visionEncodedImage(width: 21, height: 13))
            var settings = visionSettings(policy: kind == .openAI ? .openAI41Mini : .customLinear)
            settings.provider = kind == .openAI ? .openAI : kind == .anthropic ? .anthropic : .gemini
            settings.modelID = kind == .openAI ? "gpt-4.1-mini" : "host-explicit-model"
            settings.visionBindingID = settings.visionBindingFingerprint
            let images = try await store.configuration(settings: settings)
            let transport = DemoVisionTransport(kind: kind)
            let providerConfiguration = BoneInferenceProviderConfiguration(kind: kind, apiKey: "synthetic",
                baseURL: URL(string: "https://vision.invalid/v1")!,
                authenticationMode: kind == .anthropic ? .anthropicDual : kind == .google ? .googleAPIKey : .bearer)
            let engine: any BoneInferenceEngine
            switch kind {
            case .anthropic:
                engine = BoneAnthropicInferenceEngine(configuration: providerConfiguration,
                    transport: transport, imageInputConfiguration: images)
            case .google:
                engine = BoneGeminiInferenceEngine(configuration: providerConfiguration,
                    transport: transport, imageInputConfiguration: images)
            default:
                engine = BoneOpenAIInferenceEngine(configuration: providerConfiguration,
                    transport: transport, imageInputConfiguration: images)
            }
            let before = await transport.bodies
            XCTAssertTrue(before.isEmpty)
            let inputs = try await store.inputs(for: [prepared.id])
            let request = BoneInferenceRequest(modelID: settings.modelID,
                messages: [try .user(content: [.text("synthetic before"), .image(inputs[0]), .text("synthetic after")])],
                generationOptions: .init(maximumOutputTokens: settings.maximumOutputTokens))
            _ = try await engine.infer(request: request)
            let bodies = await transport.bodies
            XCTAssertEqual(bodies.count, 1)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(bodies.first)) as? [String: Any])
            let rows = try XCTUnwrap(body[kind == .google ? "contents" : "messages"] as? [[String: Any]])
            let parts = try XCTUnwrap(rows[0][kind == .google ? "parts" : "content"] as? [[String: Any]])
            XCTAssertEqual(parts[0]["text"] as? String, "synthetic before")
            XCTAssertEqual(parts[2]["text"] as? String, "synthetic after")
            switch kind {
            case .anthropic:
                let source = try XCTUnwrap(parts[1]["source"] as? [String: String])
                XCTAssertEqual(source["type"], "base64")
                XCTAssertEqual(source["media_type"], prepared.reference.metadata.format.rawValue)
                XCTAssertEqual(source["data"], prepared.previewData.base64EncodedString())
                XCTAssertEqual(body["max_tokens"] as? Int, settings.maximumOutputTokens)
            case .google:
                let inline = try XCTUnwrap(parts[1]["inlineData"] as? [String: String])
                XCTAssertEqual(inline["mimeType"], prepared.reference.metadata.format.rawValue)
                XCTAssertEqual(inline["data"], prepared.previewData.base64EncodedString())
                let generation = try XCTUnwrap(body["generationConfig"] as? [String: Any])
                XCTAssertEqual(generation["maxOutputTokens"] as? Int, settings.maximumOutputTokens)
            default:
                let imageURL = try XCTUnwrap(parts[1]["image_url"] as? [String: String])
                XCTAssertEqual(imageURL["url"], "data:\(prepared.reference.metadata.format.rawValue);base64,\(prepared.previewData.base64EncodedString())")
                XCTAssertEqual(imageURL["detail"], "auto")
                XCTAssertEqual(body["max_tokens"] as? Int, settings.maximumOutputTokens)
            }
        }
    }

    func testDisabledUnknownAndExcessImageRequestsRejectBeforeTransport() async throws {
        let store = DemoChatImageStore()
        let image = try await store.add(data: visionEncodedImage(width: 8, height: 8))
        for rejection in 0..<3 {
            var settings = visionSettings()
            if rejection == 0 { settings.visionPolicy = .disabled }
            let images = try await store.configuration(settings: settings)
            let transport = DemoVisionTransport(kind: .openAI)
            let engine = BoneOpenAIInferenceEngine(configuration: .init(kind: .openAI, apiKey: "synthetic",
                baseURL: URL(string: "https://vision.invalid/v1")!), transport: transport, imageInputConfiguration: images)
            let part = BoneInferenceInputContent.image(.init(reference: image.reference))
            let request = BoneInferenceRequest(modelID: rejection == 1 ? "unconfigured-model" : settings.modelID,
                messages: [try .user(content: Array(repeating: part, count: rejection == 2 ? 7 : 1))])
            do { _ = try await engine.infer(request: request); XCTFail("Expected preflight rejection") }
            catch {
                if rejection == 2 { XCTAssertEqual(error as? BoneInferenceImageInputError, .tooManyImages) }
                else { XCTAssertEqual(error as? BoneInferenceError, .unsupportedCapability(.imageInput)) }
            }
            let bodies = await transport.bodies
            XCTAssertTrue(bodies.isEmpty)
        }
    }

    func testCancellationPreventsImportResolveRestoreAndTransport() async throws {
        let store = DemoChatImageStore()
        let bytes = try visionEncodedImage(width: 8, height: 8)
        let cancelledAdd = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.add(data: bytes)
        }
        do { _ = try await cancelledAdd.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let entries = await store.entries()
        XCTAssertTrue(entries.isEmpty)
        let image = try await store.add(data: bytes)
        let optional = try await store.configuration(settings: visionSettings())
        let resolver = try XCTUnwrap(optional).resolver
        let cancelledResolve = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await resolver.resolve(image.reference)
        }
        do { _ = try await cancelledResolve.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let archive = try await store.exportPrivateState()
        let cancelledRestore = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try DemoChatImageStore(privateState: archive)
        }
        do { _ = try await cancelledRestore.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let transport = DemoVisionTransport(kind: .openAI)
        let engine = BoneOpenAIInferenceEngine(configuration: .init(kind: .openAI, apiKey: "synthetic",
            baseURL: URL(string: "https://vision.invalid/v1")!), transport: transport, imageInputConfiguration: optional)
        let request = BoneInferenceRequest(modelID: "gpt-4.1-mini",
            messages: [try .user(content: [.image(.init(reference: image.reference))])])
        let cancelledInfer = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await engine.infer(request: request)
        }
        do { _ = try await cancelledInfer.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let bodies = await transport.bodies
        XCTAssertTrue(bodies.isEmpty)
    }
    #else
    func testUnavailableImageIOFailsClearly() async throws {
        let store = DemoChatImageStore()
        await expectVisionError(.imageIOUnavailable) { _ = try await store.add(data: Data([1])) }
        await expectVisionError(.imageIOUnavailable) { _ = try await store.configuration(settings: self.visionSettings()) }
    }
    #endif

    private func visionSettings(policy: DemoVisionPolicy = .openAI41Mini) -> DemoLiveChatSettings {
        var settings = DemoLiveChatSettings()
        settings.provider = .openAI
        settings.baseURL = "https://vision.invalid/v1"
        settings.modelID = "gpt-4.1-mini"
        settings.visionPolicy = policy
        if policy == .customLinear {
            settings.visionTokenBase = 100
            settings.visionTokensPerMegapixel = 1_000
        }
        settings.visionBindingID = settings.visionBindingFingerprint
        return settings
    }

    private func expectVisionError(_ expected: DemoVisionError, operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected \(expected)") }
        catch { XCTAssertEqual(error as? DemoVisionError, expected) }
    }
}

#if canImport(ImageIO) && canImport(CoreGraphics)
private func visionEncodedImage(width: Int, height: Int, type: String = "public.png",
                                colorSpace: CFString = CGColorSpace.sRGB,
                                properties: [CFString: Any] = [:], noise: Bool = false) throws -> Data {
    let space = try XCTUnwrap(CGColorSpace(name: colorSpace))
    let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    if noise {
        let memory = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        var state: UInt32 = 0x12345678
        for index in 0..<(width * height * 4) {
            state = state &* 1_664_525 &+ 1_013_904_223
            memory[index] = UInt8(truncatingIfNeeded: state >> 24)
        }
    } else {
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }
    let image = try XCTUnwrap(context.makeImage())
    let data = NSMutableData()
    let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return data as Data
}
#endif

private actor DemoVisionTransport: BoneInferenceHTTPTransport {
    let kind: BoneInferenceProviderKind
    private(set) var bodies: [Data] = []

    init(kind: BoneInferenceProviderKind) { self.kind = kind }

    func send(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse {
        try Task.checkCancellation()
        bodies.append(request.httpBody ?? Data())
        let response: String
        switch kind {
        case .anthropic: response = #"{"content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn"}"#
        case .google: response = #"{"candidates":[{"content":{"parts":[{"text":"ok"}]},"finishReason":"STOP"}]}"#
        default: response = #"{"choices":[{"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}"#
        }
        return .init(statusCode: 200, data: Data(response.utf8))
    }

    func sendRetryableForModels(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse {
        try await send(request)
    }

    func sendEventStream(_ request: URLRequest, options: BoneInferenceEventStreamOptions) async throws -> BoneInferenceEventStreamResponse {
        XCTFail("This fixture exercises non-streaming requests only")
        return .init(statusCode: 500, events: [])
    }
}
