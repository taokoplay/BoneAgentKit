import Foundation

/// 绑定本地模型能力 Smoke 的完整执行组合；只保存稳定 ID、版本与摘要，不保存 Prompt 或模板正文。
public struct BoneLocalExecutionVerificationIdentity: Codable, Equatable, Hashable, Sendable {
    public static let currentSchemaVersion = 2

    public enum ValidationError: Error, Equatable, Sendable {
        case invalidIdentity
    }

    public let schemaVersion: Int
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
    public let grammarParserID: String?
    public let grammarParserVersion: String?
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
    public let grammarSamplerID: String?
    public let grammarSamplerVersion: String?
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
        grammarParserID: String?,
        grammarParserVersion: String?,
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
        grammarSamplerID: String? = nil,
        grammarSamplerVersion: String? = nil,
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
              Self.isValidPair(grammarParserID, grammarParserVersion),
              contextTokens > 0,
              batchTokens > 0,
              batchTokens <= contextTokens,
              maximumOutputTokens.map({ $0 > 0 && $0 < contextTokens }) ?? true,
              Self.isValidTriple(constraintCompilerID, constraintCompilerVersion, constraintDialect),
              Self.isValidPair(grammarSamplerID, grammarSamplerVersion),
              Self.isValidPair(stopMatcherID, stopMatcherVersion),
              Self.isValidConstraintIdentityGroup(
                  compilerID: constraintCompilerID,
                  schemaVersion: schemaCanonicalFormatVersion,
                  controlVersion: controlCanonicalFormatVersion,
                  digest: compiledConstraintDigest,
                  grammarParserID: grammarParserID,
                  grammarSamplerID: grammarSamplerID,
                  stopMatcherID: stopMatcherID,
                  terminationVersion: terminationContractVersion
              ) else {
            throw ValidationError.invalidIdentity
        }
        schemaVersion = Self.currentSchemaVersion
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
        self.grammarParserID = grammarParserID
        self.grammarParserVersion = grammarParserVersion
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
        self.grammarSamplerID = grammarSamplerID
        self.grammarSamplerVersion = grammarSamplerVersion
        self.stopMatcherID = stopMatcherID
        self.stopMatcherVersion = stopMatcherVersion
        self.terminationContractVersion = terminationContractVersion
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case artifactSHA256
        case runtimeID
        case runtimeVersion
        case tokenizerID
        case tokenizerVersion
        case templateDigest
        case rendererID
        case rendererVersion
        case reasoningMode
        case generationControlDigest
        case toolEnvelopeID
        case toolEnvelopeVersion
        case grammarParserID
        case grammarParserVersion
        case contextTokens
        case batchTokens
        case addGenerationPrompt
        case maximumOutputTokens
        case constraintCompilerID
        case constraintCompilerVersion
        case constraintDialect
        case schemaCanonicalFormatVersion
        case controlCanonicalFormatVersion
        case compiledConstraintDigest
        case grammarSamplerID
        case grammarSamplerVersion
        case stopMatcherID
        case stopMatcherVersion
        case terminationContractVersion
    }

    private enum LegacyCodingKeys: String, CodingKey, CaseIterable {
        case constraintDecoderID
        case constraintDecoderVersion
        case grammarRuntimeID
        case grammarRuntimeVersion
    }

    public init(from decoder: any Decoder) throws {
        let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
        guard !LegacyCodingKeys.allCases.contains(where: legacy.contains) else {
            throw DecodingError.dataCorruptedError(
                forKey: .constraintDecoderID,
                in: legacy,
                debugDescription: "Legacy local execution identity schema is unsupported"
            )
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported local execution identity schema version"
            )
        }

        do {
            try self.init(
                artifactSHA256: container.decode(String.self, forKey: .artifactSHA256),
                runtimeID: container.decode(String.self, forKey: .runtimeID),
                runtimeVersion: container.decode(Int.self, forKey: .runtimeVersion),
                tokenizerID: container.decode(String.self, forKey: .tokenizerID),
                tokenizerVersion: container.decode(String.self, forKey: .tokenizerVersion),
                templateDigest: container.decode(String.self, forKey: .templateDigest),
                rendererID: container.decode(String.self, forKey: .rendererID),
                rendererVersion: container.decode(String.self, forKey: .rendererVersion),
                reasoningMode: container.decode(String.self, forKey: .reasoningMode),
                generationControlDigest: container.decode(String.self, forKey: .generationControlDigest),
                toolEnvelopeID: container.decodeIfPresent(String.self, forKey: .toolEnvelopeID),
                toolEnvelopeVersion: container.decodeIfPresent(String.self, forKey: .toolEnvelopeVersion),
                grammarParserID: container.decodeIfPresent(String.self, forKey: .grammarParserID),
                grammarParserVersion: container.decodeIfPresent(String.self, forKey: .grammarParserVersion),
                contextTokens: container.decode(Int.self, forKey: .contextTokens),
                batchTokens: container.decode(Int.self, forKey: .batchTokens),
                addGenerationPrompt: container.decodeIfPresent(Bool.self, forKey: .addGenerationPrompt),
                maximumOutputTokens: container.decodeIfPresent(Int.self, forKey: .maximumOutputTokens),
                constraintCompilerID: container.decodeIfPresent(String.self, forKey: .constraintCompilerID),
                constraintCompilerVersion: container.decodeIfPresent(String.self, forKey: .constraintCompilerVersion),
                constraintDialect: container.decodeIfPresent(String.self, forKey: .constraintDialect),
                schemaCanonicalFormatVersion: container.decodeIfPresent(Int.self, forKey: .schemaCanonicalFormatVersion),
                controlCanonicalFormatVersion: container.decodeIfPresent(Int.self, forKey: .controlCanonicalFormatVersion),
                compiledConstraintDigest: container.decodeIfPresent(String.self, forKey: .compiledConstraintDigest),
                grammarSamplerID: container.decodeIfPresent(String.self, forKey: .grammarSamplerID),
                grammarSamplerVersion: container.decodeIfPresent(String.self, forKey: .grammarSamplerVersion),
                stopMatcherID: container.decodeIfPresent(String.self, forKey: .stopMatcherID),
                stopMatcherVersion: container.decodeIfPresent(String.self, forKey: .stopMatcherVersion),
                terminationContractVersion: container.decodeIfPresent(Int.self, forKey: .terminationContractVersion)
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Invalid local execution verification identity"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(artifactSHA256, forKey: .artifactSHA256)
        try container.encode(runtimeID, forKey: .runtimeID)
        try container.encode(runtimeVersion, forKey: .runtimeVersion)
        try container.encode(tokenizerID, forKey: .tokenizerID)
        try container.encode(tokenizerVersion, forKey: .tokenizerVersion)
        try container.encode(templateDigest, forKey: .templateDigest)
        try container.encode(rendererID, forKey: .rendererID)
        try container.encode(rendererVersion, forKey: .rendererVersion)
        try container.encode(reasoningMode, forKey: .reasoningMode)
        try container.encode(generationControlDigest, forKey: .generationControlDigest)
        try container.encodeIfPresent(toolEnvelopeID, forKey: .toolEnvelopeID)
        try container.encodeIfPresent(toolEnvelopeVersion, forKey: .toolEnvelopeVersion)
        try container.encodeIfPresent(grammarParserID, forKey: .grammarParserID)
        try container.encodeIfPresent(grammarParserVersion, forKey: .grammarParserVersion)
        try container.encode(contextTokens, forKey: .contextTokens)
        try container.encode(batchTokens, forKey: .batchTokens)
        try container.encodeIfPresent(addGenerationPrompt, forKey: .addGenerationPrompt)
        try container.encodeIfPresent(maximumOutputTokens, forKey: .maximumOutputTokens)
        try container.encodeIfPresent(constraintCompilerID, forKey: .constraintCompilerID)
        try container.encodeIfPresent(constraintCompilerVersion, forKey: .constraintCompilerVersion)
        try container.encodeIfPresent(constraintDialect, forKey: .constraintDialect)
        try container.encodeIfPresent(schemaCanonicalFormatVersion, forKey: .schemaCanonicalFormatVersion)
        try container.encodeIfPresent(controlCanonicalFormatVersion, forKey: .controlCanonicalFormatVersion)
        try container.encodeIfPresent(compiledConstraintDigest, forKey: .compiledConstraintDigest)
        try container.encodeIfPresent(grammarSamplerID, forKey: .grammarSamplerID)
        try container.encodeIfPresent(grammarSamplerVersion, forKey: .grammarSamplerVersion)
        try container.encodeIfPresent(stopMatcherID, forKey: .stopMatcherID)
        try container.encodeIfPresent(stopMatcherVersion, forKey: .stopMatcherVersion)
        try container.encodeIfPresent(terminationContractVersion, forKey: .terminationContractVersion)
    }

    public func matches(_ current: Self) -> Bool { self == current }

    /// 本地 constrained output 所需的完整执行身份。
    public var hasConstraintRuntimeIdentity: Bool {
        constraintCompilerID != nil
            && schemaCanonicalFormatVersion != nil
            && controlCanonicalFormatVersion != nil
            && compiledConstraintDigest != nil
            && grammarParserID != nil
            && grammarSamplerID != nil
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
        grammarParserID: String?,
        grammarSamplerID: String?,
        stopMatcherID: String?,
        terminationVersion: Int?
    ) -> Bool {
        if compilerID == nil {
            return schemaVersion == nil
                && controlVersion == nil
                && digest == nil
                && grammarParserID == nil
                && grammarSamplerID == nil
                && stopMatcherID == nil
                && terminationVersion == nil
        }
        return schemaVersion.map({ $0 > 0 }) == true
            && controlVersion.map({ $0 > 0 }) == true
            && digest.map(isSHA256) == true
            && grammarParserID != nil
            && grammarSamplerID != nil
            && stopMatcherID != nil
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
