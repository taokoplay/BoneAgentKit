import Foundation

/// 必须绑定具体站点/精确模型的视觉 Token 估算。参数描述最终发送尺寸与 detail。
/// 不能用 Base64 字符数代替视觉 Token，也不能未知时返回 0。调用方负责规则来源及保守性。
public typealias BoneInferenceImageTokenEstimator = @Sendable (BoneInferenceImageInput) throws -> Int

/// 精确模型的图片支持与硬容量配置；没有此配置不会自动启用 imageInput。
public struct BoneInferenceImageInputProfile: Sendable {
    public let contextBudget: BoneContextWindowBudget
    public let maximumImagesPerRequest: Int
    public let maximumImageBytes: Int
    public let maximumBase64BytesPerRequest: Int
    public let maximumRequestBodyBytes: Int
    public let safetyMarginTokens: Int
    public let tokenEstimator: BoneInferenceImageTokenEstimator

    public init(contextBudget: BoneContextWindowBudget, maximumImagesPerRequest: Int = 20,
                maximumImageBytes: Int = 5 * 1_024 * 1_024,
                maximumBase64BytesPerRequest: Int = 20 * 1_024 * 1_024,
                maximumRequestBodyBytes: Int = 32 * 1_024 * 1_024, safetyMarginTokens: Int = 1_024,
                tokenEstimator: @escaping BoneInferenceImageTokenEstimator) throws {
        guard contextBudget.maximumOutputTokens != nil,
              (1...128).contains(maximumImagesPerRequest),
              (1...BoneInferenceImageMetadata.maximumBytes).contains(maximumImageBytes),
              maximumBase64BytesPerRequest > 0, maximumBase64BytesPerRequest <= 128 * 1_024 * 1_024,
              maximumRequestBodyBytes > 0, maximumRequestBodyBytes <= 192 * 1_024 * 1_024,
              safetyMarginTokens >= 0, safetyMarginTokens < contextBudget.contextWindowTokens else {
            throw BoneInferenceImageInputError.invalidPolicy
        }
        self.contextBudget = contextBudget; self.maximumImagesPerRequest = maximumImagesPerRequest
        self.maximumImageBytes = maximumImageBytes; self.maximumBase64BytesPerRequest = maximumBase64BytesPerRequest
        self.maximumRequestBodyBytes = maximumRequestBodyBytes; self.safetyMarginTokens = safetyMarginTokens
        self.tokenEstimator = tokenEstimator
    }

    public func estimatedTokens(for image: BoneInferenceImageInput) throws -> Int {
        let tokens = try tokenEstimator(image)
        guard tokens > 0 else { throw BoneInferenceImageInputError.invalidTokenEstimate }
        return tokens
    }
}

/// 可选的模型视觉预算能力，不增加现有 Engine 必需方法。
public protocol BoneInferenceImageTokenProviding: Sendable {
    func imageTokens(for image: BoneInferenceImageInput, modelID: String) throws -> Int
    /// 压缩不得使用比发送阶段更小的视觉安全余量。
    func imageInputSafetyMarginTokens(for modelID: String) throws -> Int
}

public extension BoneInferenceImageTokenProviding {
    func imageInputSafetyMarginTokens(for modelID: String) throws -> Int { 0 }
}

/// 一组绑定到 Engine 站点的精确模型配置和 Host 读取器；不按目录名称猜能力或隐式发起上传。
public struct BoneInferenceImageInputConfiguration: Sendable {
    public let profiles: [String: BoneInferenceImageInputProfile]
    public let resolver: BoneInferenceImageResolver
    public init(profiles: [String: BoneInferenceImageInputProfile], resolver: BoneInferenceImageResolver) throws {
        guard !profiles.isEmpty, profiles.keys.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw BoneInferenceImageInputError.invalidPolicy
        }
        self.profiles = profiles; self.resolver = resolver
    }
    public func imageTokens(for image: BoneInferenceImageInput, modelID: String) throws -> Int {
        try profile(modelID).estimatedTokens(for: image)
    }
    func profile(_ modelID: String) throws -> BoneInferenceImageInputProfile {
        guard let value = profiles[modelID] else { throw BoneInferenceError.unsupportedCapability(.imageInput) }
        return value
    }
    func contextBudget(for modelID: String, constrainedBy other: BoneContextWindowBudget?) throws -> BoneContextWindowBudget? {
        guard let value = profiles[modelID] else { return other }
        return try value.contextBudget.constrained(by: other)
    }

    /// 先按引用计数/字节/视觉 Token 校验，超限不会调用解析器。重复引用按每次出现计预算。
    func prepare(_ request: BoneInferenceRequest, engineBudget: BoneContextWindowBudget?,
                 supportsDetail: Bool) async throws -> [BoneInferenceImageReference: BoneInferencePreparedImage] {
        let inputs = request.imageInputs
        guard !inputs.isEmpty else { return [:] }
        let profile = try profile(request.modelID)
        let budget = try profile.contextBudget.constrained(by: engineBudget)
        guard inputs.count <= profile.maximumImagesPerRequest else { throw BoneInferenceImageInputError.tooManyImages }
        var base64Bytes = 0
        for image in inputs {
            guard supportsDetail || image.detail == .automatic else { throw BoneInferenceImageInputError.unsupportedDetail }
            guard image.reference.metadata.byteCount <= profile.maximumImageBytes else { throw BoneInferenceImageInputError.imageBytesExceeded }
            base64Bytes = try BoneTokenEstimator.checkedAdd(base64Bytes, image.base64ByteCount)
        }
        guard base64Bytes <= profile.maximumBase64BytesPerRequest else { throw BoneInferenceImageInputError.imageBytesExceeded }
        guard base64Bytes <= profile.maximumRequestBodyBytes else { throw BoneInferenceImageInputError.requestBytesExceeded }
        let output = try maximumOutputTokens(for: request, budget: budget)
        let capacity = try budget.availableInputTokens(configuredOutputTokens: output, preferredOutputTokens: nil,
            protocolReserveTokens: 128, safetyMarginTokens: profile.safetyMarginTokens)
        let inputTokens = try BoneTokenEstimator.estimateRequestTokens(request,
            imageTokenEstimator: { try profile.estimatedTokens(for: $0) })
        guard inputTokens <= capacity.availableInputTokens else { throw BoneInferenceImageInputError.inputTokensExceeded }
        try Task.checkCancellation()
        await BoneInferenceActivityReporting.report(.resolvingImages)
        try Task.checkCancellation()
        var resolved: [BoneInferenceImageReference: BoneInferencePreparedImage] = [:]
        for image in inputs where resolved[image.reference] == nil {
            try Task.checkCancellation()
            resolved[image.reference] = try await resolver.resolve(image.reference)
        }
        try Task.checkCancellation()
        return resolved
    }

    func maximumOutputTokens(for request: BoneInferenceRequest, budget: BoneContextWindowBudget?) throws -> Int {
        let profile = try profile(request.modelID)
        let effective = try profile.contextBudget.constrained(by: budget)
        let maximum = effective.maximumOutputTokens ?? 4_096
        if let configured = request.generationOptions.maximumOutputTokens {
            guard configured > 0, configured <= maximum else { throw BoneInferenceError.invalidGenerationOptions }
            return configured
        }
        return min(4_096, maximum)
    }
    func validateBody(_ body: Data, for request: BoneInferenceRequest) throws {
        guard !request.imageInputs.isEmpty else { return }
        guard body.count <= (try profile(request.modelID)).maximumRequestBodyBytes else {
            throw BoneInferenceImageInputError.requestBytesExceeded
        }
    }
}

extension BoneInferenceImageInput {
    var base64ByteCount: Int { ((reference.metadata.byteCount + 2) / 3) * 4 }
}
public extension BoneInferenceMessage {
    /// 每次出现均计入，不因相同引用已缓存而减免模型上下文预算。
    var imageInputs: [BoneInferenceImageInput] {
        let user: [BoneInferenceImageInput] = inputContent?.compactMap {
            if case .image(let image) = $0 { return image }
            return nil
        } ?? []
        let results = toolResults?.results ?? toolResult.map { [$0] } ?? []
        return user + results.flatMap { $0.content.imageInputs }
    }
}
public extension BoneInferenceRequest {
    var imageInputs: [BoneInferenceImageInput] { messages.flatMap(\.imageInputs) }
}
