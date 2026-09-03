import BoneAgentKit
import Foundation

public struct BoneLlamaGenerationControl: Equatable, Sendable {
    public static let maximumStopTokenCount = 128
    public static let maximumStopStringCount = 32
    public static let maximumStopStringByteCount = 256

    public let stopTokenIDs: [Int32]
    public let stopStrings: [String]
    public let constraint: BoneLlamaGenerationConstraint?

    public init(
        stopTokenIDs: [Int32] = [],
        stopStrings: [String] = [],
        constraint: BoneLlamaGenerationConstraint? = nil
    ) throws {
        let tokenIDs = Self.uniqued(stopTokenIDs)
        let strings = Self.uniqued(stopStrings)
        guard tokenIDs.count <= Self.maximumStopTokenCount,
              strings.count <= Self.maximumStopStringCount,
              strings.allSatisfy({
                  !$0.isEmpty && $0.lengthOfBytes(using: .utf8) <= Self.maximumStopStringByteCount
              }) else {
            throw BoneLlamaAdapterError.invalidGenerationControl
        }
        if let constraint {
            do {
                switch constraint {
                case let .jsonSchema(schema):
                    try BoneToolSchemaValidator.validateDefinition(schema)
                case let .enumChoice(values):
                    _ = try BoneInferenceOutputConstraint.enumChoice(values).validated()
                }
            } catch {
                throw BoneLlamaAdapterError.invalidGenerationControl
            }
        }
        self.stopTokenIDs = tokenIDs
        self.stopStrings = strings
        self.constraint = constraint
    }

    public var requiresControlledRuntime: Bool {
        !stopTokenIDs.isEmpty || !stopStrings.isEmpty || constraint != nil
    }

    private static func uniqued<T: Hashable>(_ values: [T]) -> [T] {
        var seen = Set<T>()
        return values.filter { seen.insert($0).inserted }
    }
}

public protocol BoneLlamaControlledGenerationRuntime: BoneLlamaRuntime {
    func generate(
        prompt: String,
        executionPlan: BoneLlamaPromptExecutionPlan,
        options: BoneLlamaGenerationOptions,
        control: BoneLlamaGenerationControl
    ) async throws -> BoneLlamaGenerationResult
}
