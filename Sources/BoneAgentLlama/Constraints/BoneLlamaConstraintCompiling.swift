public protocol BoneLlamaConstraintCompiling: Sendable {
    var identity: BoneLlamaConstraintCompilerIdentity { get }

    func compile(
        _ constraint: BoneLlamaGenerationConstraint
    ) throws -> BoneLlamaCompiledConstraint
}
