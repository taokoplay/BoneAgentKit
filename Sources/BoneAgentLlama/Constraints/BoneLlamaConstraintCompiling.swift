public protocol BoneLlamaConstraintCompiling: Sendable {
    /// Stable identity of the concrete compiler used to derive runtime grammar artifacts.
    /// Engines compare this with the verified execution identity before generation.
    var identity: BoneLlamaConstraintCompilerIdentity { get }

    func compile(
        _ constraint: BoneLlamaGenerationConstraint
    ) throws -> BoneLlamaCompiledConstraint
}
