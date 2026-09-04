import BoneAgentKit
import Foundation

public enum BoneLlamaConstraintCompilerError: Error, Equatable, Sendable {
    case invalidConstraint
    case unsupportedSchema
    case resourceLimitExceeded
}

public struct BoneLlamaGBNFCompilerLimits: Equatable, Sendable {
    public let maximumGrammarByteCount: Int
    public let maximumRuleCount: Int
    public let maximumExpandedNodeCount: Int
    public let maximumEnumTerminalByteCount: Int

    public init(
        maximumGrammarByteCount: Int = 256 * 1_024,
        maximumRuleCount: Int = 4_096,
        maximumExpandedNodeCount: Int = 16_384,
        maximumEnumTerminalByteCount: Int = 64 * 1_024
    ) {
        self.maximumGrammarByteCount = maximumGrammarByteCount
        self.maximumRuleCount = maximumRuleCount
        self.maximumExpandedNodeCount = maximumExpandedNodeCount
        self.maximumEnumTerminalByteCount = maximumEnumTerminalByteCount
    }
}

public struct BoneLlamaGBNFCompiler: BoneLlamaConstraintCompiling, Sendable {
    public let identity: BoneLlamaConstraintCompilerIdentity
    public let limits: BoneLlamaGBNFCompilerLimits

    public init(limits: BoneLlamaGBNFCompilerLimits = .init()) {
        self.limits = limits
        identity = try! .init(id: "bone.gbnf", version: "1", dialect: "bone-gbnf-v1")
    }

    public func compile(
        _ constraint: BoneLlamaGenerationConstraint
    ) throws -> BoneLlamaCompiledConstraint {
        switch constraint {
        case let .enumChoice(values):
            guard !values.isEmpty,
                  values.count <= BoneInferenceOutputConstraint.maximumEnumChoiceCount,
                  Set(values).count == values.count,
                  values.allSatisfy({ !$0.isEmpty && $0.count <= BoneInferenceOutputConstraint.maximumEnumChoiceLength }) else {
                throw BoneLlamaConstraintCompilerError.invalidConstraint
            }
            let terminalBytes = values.reduce(0) { $0 + $1.utf8.count }
            guard values.count <= limits.maximumExpandedNodeCount,
                  terminalBytes <= limits.maximumEnumTerminalByteCount,
                  limits.maximumRuleCount >= 1 else {
                throw BoneLlamaConstraintCompilerError.resourceLimitExceeded
            }
            var writer = BoneLlamaGBNFWriter()
            writer.addRule(
                name: "root",
                expression: values.map(BoneLlamaGBNFWriter.literal).joined(separator: " | ")
            )
            return try makeCompiled(source: writer.source())

        case let .jsonSchema(schema):
            do {
                try BoneToolSchemaValidator.validateDefinition(schema)
            } catch {
                throw BoneLlamaConstraintCompilerError.invalidConstraint
            }
            var builder = SchemaGrammarBuilder(limits: limits)
            let source = try builder.compile(schema)
            return try makeCompiled(source: source)
        }
    }

    private func makeCompiled(source: String) throws -> BoneLlamaCompiledConstraint {
        guard source.utf8.count <= limits.maximumGrammarByteCount else {
            throw BoneLlamaConstraintCompilerError.resourceLimitExceeded
        }
        let digest = try BoneLlamaCompiledConstraintDigest.digest(source)
        return try .init(
            format: .gbnf,
            source: source,
            sourceDigest: digest,
            rootRule: "root",
            compilerIdentity: identity
        )
    }
}
