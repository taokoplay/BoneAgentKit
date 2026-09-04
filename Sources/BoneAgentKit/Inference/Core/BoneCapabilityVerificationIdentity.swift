import Foundation

/// 绑定模型能力 Smoke 的完整执行组合；只保存稳定 ID、版本与摘要，不保存 Prompt 或模板正文。
public struct BoneCapabilityVerificationIdentity: Codable, Equatable, Hashable, Sendable {
    public enum ValidationError: Error, Equatable, Sendable {
        case invalidIdentity
    }

    public let artifactSHA256: String
    public let runtimeID: String
    public let runtimeVersion: Int
    public let tokenizerID: String
    public let tokenizerVersion: String
    public let templateDigest: String
    public let rendererID: String
    public let rendererVersion: String
    public let reasoningMode: String
    public let generationControlDigest: String
    public let toolEnvelopeID: String?
    public let toolEnvelopeVersion: String?
    public let constraintDecoderID: String?
    public let constraintDecoderVersion: String?
    public let contextTokens: Int
    public let batchTokens: Int
    public let addGenerationPrompt: Bool?
    public let maximumOutputTokens: Int?
    public let constraintCompilerID: String?
    public let constraintCompilerVersion: String?
    public let constraintDialect: String?
    public let schemaCanonicalFormatVersion: Int?
    public let controlCanonicalFormatVersion: Int?
    public let compiledConstraintDigest: String?
    public let grammarRuntimeID: String?
    public let grammarRuntimeVersion: String?
    public let stopMatcherID: String?
    public let stopMatcherVersion: String?
    public let terminationContractVersion: Int?

    public init(
        artifactSHA256: String,
        runtimeID: String,
        runtimeVersion: Int,
        tokenizerID: String,
        tokenizerVersion: String,
        templateDigest: String,
        rendererID: String,
        rendererVersion: String,
        reasoningMode: String,
        generationControlDigest: String,
        toolEnvelopeID: String?,
        toolEnvelopeVersion: String?,
        constraintDecoderID: String?,
        constraintDecoderVersion: String?,
        contextTokens: Int,
        batchTokens: Int,
        addGenerationPrompt: Bool? = nil,
        maximumOutputTokens: Int? = nil,
        constraintCompilerID: String? = nil,
        constraintCompilerVersion: String? = nil,
        constraintDialect: String? = nil,
        schemaCanonicalFormatVersion: Int? = nil,
        controlCanonicalFormatVersion: Int? = nil,
        compiledConstraintDigest: String? = nil,
        grammarRuntimeID: String? = nil,
        grammarRuntimeVersion: String? = nil,
        stopMatcherID: String? = nil,
        stopMatcherVersion: String? = nil,
        terminationContractVersion: Int? = nil
    ) throws {
        guard Self.isSHA256(artifactSHA256),
              Self.isSHA256(templateDigest),
              Self.isSHA256(generationControlDigest),
              Self.isValidComponent(runtimeID),
              runtimeVersion > 0,
              Self.isValidComponent(tokenizerID),
              Self.isValidComponent(tokenizerVersion),
              Self.isValidComponent(rendererID),
              Self.isValidComponent(rendererVersion),
              Self.isValidComponent(reasoningMode),
              Self.isValidPair(toolEnvelopeID, toolEnvelopeVersion),
              Self.isValidPair(constraintDecoderID, constraintDecoderVersion),
              contextTokens > 0,
              batchTokens > 0,
              batchTokens <= contextTokens,
              maximumOutputTokens.map({ $0 > 0 && $0 < contextTokens }) ?? true,
              Self.isValidTriple(constraintCompilerID, constraintCompilerVersion, constraintDialect),
              Self.isValidPair(grammarRuntimeID, grammarRuntimeVersion),
              Self.isValidPair(stopMatcherID, stopMatcherVersion),
              Self.isValidConstraintIdentityGroup(
                  compilerID: constraintCompilerID,
                  schemaVersion: schemaCanonicalFormatVersion,
                  controlVersion: controlCanonicalFormatVersion,
                  digest: compiledConstraintDigest,
                  terminationVersion: terminationContractVersion
              ) else {
            throw ValidationError.invalidIdentity
        }
        self.artifactSHA256 = artifactSHA256.lowercased()
        self.runtimeID = runtimeID
        self.runtimeVersion = runtimeVersion
        self.tokenizerID = tokenizerID
        self.tokenizerVersion = tokenizerVersion
        self.templateDigest = templateDigest.lowercased()
        self.rendererID = rendererID
        self.rendererVersion = rendererVersion
        self.reasoningMode = reasoningMode
        self.generationControlDigest = generationControlDigest.lowercased()
        self.toolEnvelopeID = toolEnvelopeID
        self.toolEnvelopeVersion = toolEnvelopeVersion
        self.constraintDecoderID = constraintDecoderID
        self.constraintDecoderVersion = constraintDecoderVersion
        self.contextTokens = contextTokens
        self.batchTokens = batchTokens
        self.addGenerationPrompt = addGenerationPrompt
        self.maximumOutputTokens = maximumOutputTokens
        self.constraintCompilerID = constraintCompilerID
        self.constraintCompilerVersion = constraintCompilerVersion
        self.constraintDialect = constraintDialect
        self.schemaCanonicalFormatVersion = schemaCanonicalFormatVersion
        self.controlCanonicalFormatVersion = controlCanonicalFormatVersion
        self.compiledConstraintDigest = compiledConstraintDigest?.lowercased()
        self.grammarRuntimeID = grammarRuntimeID
        self.grammarRuntimeVersion = grammarRuntimeVersion
        self.stopMatcherID = stopMatcherID
        self.stopMatcherVersion = stopMatcherVersion
        self.terminationContractVersion = terminationContractVersion
    }

    public func matches(_ current: Self) -> Bool { self == current }

    /// Alpha.8 本地 constrained output 所需的完整执行身份。
    public var hasConstraintRuntimeIdentity: Bool {
        constraintCompilerID != nil
            && schemaCanonicalFormatVersion != nil
            && controlCanonicalFormatVersion != nil
            && compiledConstraintDigest != nil
            && grammarRuntimeID != nil
            && stopMatcherID != nil
            && terminationContractVersion != nil
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) != nil
    }

    private static func isValidComponent(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 128 && value.unicodeScalars.allSatisfy {
            $0.value >= 0x21 && $0.value <= 0x7E
        }
    }

    private static func isValidTriple(_ first: String?, _ second: String?, _ third: String?) -> Bool {
        switch (first, second, third) {
        case (nil, nil, nil): return true
        case let (.some(first), .some(second), .some(third)):
            return isValidComponent(first) && isValidComponent(second) && isValidComponent(third)
        default: return false
        }
    }

    private static func isValidConstraintIdentityGroup(
        compilerID: String?,
        schemaVersion: Int?,
        controlVersion: Int?,
        digest: String?,
        terminationVersion: Int?
    ) -> Bool {
        if compilerID == nil {
            return schemaVersion == nil && controlVersion == nil && digest == nil && terminationVersion == nil
        }
        return schemaVersion.map({ $0 > 0 }) == true
            && controlVersion.map({ $0 > 0 }) == true
            && digest.map(isSHA256) == true
            && terminationVersion.map({ $0 > 0 }) == true
    }

    private static func isValidPair(_ id: String?, _ version: String?) -> Bool {
        switch (id, version) {
        case (nil, nil): return true
        case let (.some(id), .some(version)):
            return isValidComponent(id) && isValidComponent(version)
        default: return false
        }
    }
}
