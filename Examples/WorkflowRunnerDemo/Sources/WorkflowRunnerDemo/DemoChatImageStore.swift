import Foundation
import BoneAgentKit

/// Only normalized, prepared bytes are retained. Host persistence must keep this
/// private; this value and exportPrivateState() must never be placed in logs.
struct DemoPreparedChatImage: Identifiable, Sendable {
    let reference: BoneInferenceImageReference
    let previewData: Data
    var id: String { reference.id }
    var width: Int { reference.metadata.width }
    var height: Int { reference.metadata.height }
    var byteCount: Int { reference.metadata.byteCount }
    var pixelCount: Int { width * height }
}

/// An in-memory attachment authority. No file paths, URLs, uploads, or networking.
/// Constructing a configuration does not resolve or send any image bytes.
actor DemoChatImageStore {
    static let maximumSourceBytes = 20 * 1_024 * 1_024
    static let maximumSourcePixels = 16_000_000
    static let maximumDimension = 1_024
    static let maximumPreparedPixels = 1_048_576
    static let maximumPreparedBytes = 2 * 1_024 * 1_024
    static let maximumImages = 6
    static let maximumTotalBytes = 12 * 1_024 * 1_024
    // Each occurrence has its own base64 padding, including repeated references.
    static let maximumBase64Bytes = maximumImages * (((maximumPreparedBytes + 2) / 3) * 4)
    static let maximumRequestBodyBytes = maximumBase64Bytes + 1_024 * 1_024
    static let maximumPrivateStateBytes = maximumBase64Bytes + 16 * 1_024

    private struct PrivateImage: Codable {
        let reference: BoneInferenceImageReference
        let bytes: Data
    }

    private struct PrivateState: Codable {
        let formatVersion: Int
        let images: [PrivateImage]
    }

    private var active: [DemoPreparedChatImage] = []
    private var generation = UUID()

    init() {}

    init(privateState: Data) throws {
        active = try Self.decodePrivateState(privateState)
    }

    /// 将已验证的私有图片状态恢复到当前 actor，保持外部 Host 捕获的存储身份稳定。
    /// - Parameter privateState: 由 `exportPrivateState()` 生成的受限状态数据。
    func restore(privateState: Data) throws {
        active = try Self.decodePrivateState(privateState)
        generation = UUID()
    }

    /// 清空当前会话的图片内容，同时使旧的图片引用失效。
    func reset() {
        active.removeAll(keepingCapacity: false)
        generation = UUID()
    }

    @discardableResult
    func add(data: Data) async throws -> DemoPreparedChatImage {
        try Task.checkCancellation()
        guard !data.isEmpty else { throw BoneInferenceImageInputError.invalidContent }
        guard data.count <= Self.maximumSourceBytes else { throw DemoVisionError.imageTooLarge }
        guard active.count < Self.maximumImages else { throw DemoVisionError.capacityReached }
        let activeGeneration = generation
        #if canImport(ImageIO) && canImport(CoreGraphics)
        let policy = try BoneInferenceImagePreprocessingPolicy(maxSourceBytes: Self.maximumSourceBytes,
            maxSourcePixels: Self.maximumSourcePixels, maxWidth: Self.maximumDimension,
            maxHeight: Self.maximumDimension, maxPixels: Self.maximumPreparedPixels,
            maximumPreparedBytes: Self.maximumPreparedBytes)
        let prepared = try await BoneInferenceImageIO.preprocessor.prepare(data, policy: policy)
        try Task.checkCancellation()
        // Recheck after the async preprocessor: concurrent additions or clear()
        // must not exceed capacity or resurrect a cleared attachment collection.
        guard generation == activeGeneration else { throw DemoVisionError.unavailableImage }
        try Self.validatePreparedMetadata(prepared.metadata)
        guard active.count < Self.maximumImages,
              prepared.data.count <= Self.maximumTotalBytes - active.reduce(0, { $0 + $1.byteCount }) else {
            throw DemoVisionError.capacityReached
        }
        let reference = try prepared.reference(id: UUID().uuidString, version: UUID().uuidString)
        let image = DemoPreparedChatImage(reference: reference, previewData: prepared.data)
        try Task.checkCancellation()
        active.append(image)
        return image
        #else
        _ = activeGeneration
        throw DemoVisionError.imageIOUnavailable
        #endif
    }

    func entries() -> [DemoPreparedChatImage] { active }

    /// 读取已登记图片的规范化字节，供相册 Host 按不透明 imageID 保存。
    /// - Parameter id: 当前 Host 已登记的图片身份。
    /// - Returns: 经过图片预处理的 PNG、JPEG 或 WebP 字节。
    func data(for id: String) throws -> Data {
        try Task.checkCancellation()
        guard let image = active.first(where: { $0.id == id }) else { throw DemoVisionError.unavailableImage }
        return image.previewData
    }

    func inputs(for ids: [String]) throws -> [BoneInferenceImageInput] {
        try Task.checkCancellation()
        guard ids.count <= Self.maximumImages else { throw DemoVisionError.capacityReached }
        return try ids.map { id in
            guard let image = active.first(where: { $0.id == id }) else { throw DemoVisionError.unavailableImage }
            return .init(reference: image.reference)
        }
    }

    func remove(id: String) { active.removeAll { $0.id == id } }

    func clear() {
        active.removeAll()
        generation = UUID()
    }

    func configuration(settings: DemoLiveChatSettings) throws -> BoneInferenceImageInputConfiguration? {
        try Task.checkCancellation()
        try settings.visionPolicy.validate(settings: settings)
        guard settings.visionPolicy != .disabled else { return nil }
        let provider: any BoneInferenceImageTokenProviding = try DemoVisionTokenProvider(settings: settings)
        let modelID = settings.modelID
        let budget = try BoneContextWindowBudget(contextWindowTokens: settings.contextWindowTokens,
            maximumOutputTokens: settings.maximumOutputTokens, source: .host)
        let profile = try BoneInferenceImageInputProfile(contextBudget: budget,
            maximumImagesPerRequest: Self.maximumImages, maximumImageBytes: Self.maximumPreparedBytes,
            maximumBase64BytesPerRequest: Self.maximumBase64Bytes,
            maximumRequestBodyBytes: Self.maximumRequestBodyBytes,
            safetyMarginTokens: provider.imageInputSafetyMarginTokens(for: modelID),
            tokenEstimator: { try provider.imageTokens(for: $0, modelID: modelID) })
        return try .init(profiles: [modelID: profile], resolver: makeResolver())
    }

    /// Private image bytes and opaque references; persistence/encryption belongs
    /// to the parent host. Only the prepared bytes survive, never source metadata.
    func exportPrivateState() throws -> Data {
        try Task.checkCancellation()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(PrivateState(formatVersion: 1,
            images: active.map { .init(reference: $0.reference, bytes: $0.previewData) }))
        guard bytes.count <= Self.maximumPrivateStateBytes else { throw DemoVisionError.invalidPrivateState }
        try Task.checkCancellation()
        return bytes
    }

    private nonisolated func makeResolver() throws -> BoneInferenceImageResolver {
        #if canImport(ImageIO) && canImport(CoreGraphics)
        // The SDK rechecks byte count, SHA-256, and real decoded metadata on EACH
        // resolve. The actor's loader first requires an active, exact reference.
        return .init(inspect: { try Self.inspect($0) }, load: { [self] reference in
            try await readBytes(reference)
        })
        #else
        throw DemoVisionError.imageIOUnavailable
        #endif
    }

    private func readBytes(_ reference: BoneInferenceImageReference) throws -> Data {
        try Task.checkCancellation()
        guard let image = active.first(where: { $0.id == reference.id }) else {
            throw DemoVisionError.unavailableImage
        }
        guard image.reference == reference else { throw DemoVisionError.referenceMismatch }
        return image.previewData
    }

    static func validatePreparedMetadata(_ metadata: BoneInferenceImageMetadata) throws {
        guard metadata.width <= maximumDimension, metadata.height <= maximumDimension,
              metadata.width <= maximumPreparedPixels / metadata.height,
              metadata.byteCount <= maximumPreparedBytes else { throw DemoVisionError.imageTooLarge }
    }

    private static func inspect(_ bytes: Data) throws -> BoneInferenceImageMetadata {
        #if canImport(ImageIO) && canImport(CoreGraphics)
        let metadata = try BoneInferenceImageIO.inspect(bytes)
        try validatePreparedMetadata(metadata)
        return metadata
        #else
        throw DemoVisionError.imageIOUnavailable
        #endif
    }

    /// 解码并重新校验图片私有状态，避免归档中的元数据替代 SDK 实际解析结果。
    /// - Parameter privateState: 待恢复的图片状态。
    /// - Returns: 通过大小、引用、图像格式和内容摘要校验的图片列表。
    private static func decodePrivateState(_ privateState: Data) throws -> [DemoPreparedChatImage] {
        try Task.checkCancellation()
        guard privateState.count <= Self.maximumPrivateStateBytes else {
            throw DemoVisionError.invalidPrivateState
        }
        let state: PrivateState
        do { state = try JSONDecoder().decode(PrivateState.self, from: privateState) }
        catch { throw DemoVisionError.invalidPrivateState }
        guard state.formatVersion == 1, state.images.count <= Self.maximumImages else {
            throw DemoVisionError.invalidPrivateState
        }
        var restored: [DemoPreparedChatImage] = []
        var identifiers = Set<String>()
        var versions = Set<String>()
        var totalBytes = 0
        for image in state.images {
            try Task.checkCancellation()
            let reference = image.reference
            guard Self.isRandomUUID(reference.id), Self.isRandomUUID(reference.version),
                  reference.id != reference.version,
                  identifiers.insert(reference.id).inserted,
                  versions.insert(reference.version).inserted,
                  image.bytes.count == reference.metadata.byteCount,
                  image.bytes.count <= Self.maximumPreparedBytes,
                  image.bytes.count <= Self.maximumTotalBytes - totalBytes else {
                throw DemoVisionError.invalidPrivateState
            }
            do {
                try Self.validatePreparedMetadata(reference.metadata)
                let metadata = try Self.inspect(image.bytes)
                let prepared = try BoneInferencePreparedImage(data: image.bytes, metadata: metadata)
                guard try prepared.reference(id: reference.id, version: reference.version) == reference else {
                    throw DemoVisionError.invalidPrivateState
                }
            } catch is CancellationError { throw CancellationError() }
            catch DemoVisionError.imageIOUnavailable { throw DemoVisionError.imageIOUnavailable }
            catch { throw DemoVisionError.invalidPrivateState }
            restored.append(.init(reference: reference, previewData: image.bytes))
            totalBytes += image.bytes.count
        }
        try Task.checkCancellation()
        return restored
    }

    private static func isRandomUUID(_ text: String) -> Bool {
        guard let uuid = UUID(uuidString: text), uuid.uuidString == text else { return false }
        return uuid.uuid.6 & 0xf0 == 0x40 && uuid.uuid.8 & 0xc0 == 0x80
    }
}
