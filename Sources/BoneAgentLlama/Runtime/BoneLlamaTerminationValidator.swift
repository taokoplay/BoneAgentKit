public enum BoneLlamaTerminationValidator {
    public static func validate(
        _ termination: BoneLlamaGenerationTermination,
        control: BoneLlamaGenerationControl,
        requiresCompleteOutput: Bool
    ) throws {
        if case .maximumTokens = termination {
            throw BoneLlamaAdapterError.outputTruncated
        }
        guard requiresCompleteOutput else { return }
        switch termination {
        case .eog:
            return
        case let .stopToken(id):
            guard control.stopTokenIDs.contains(id) else {
                throw BoneLlamaAdapterError.invalidToolCallingResponse
            }
        case let .stopString(index):
            guard control.stopStrings.indices.contains(index) else {
                throw BoneLlamaAdapterError.invalidToolCallingResponse
            }
        case .maximumTokens:
            throw BoneLlamaAdapterError.outputTruncated
        case .runtimeCompleted:
            throw BoneLlamaAdapterError.invalidToolCallingResponse
        }
    }
}
