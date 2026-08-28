import Foundation

public enum BoneWorkflowFailure: Error, Codable, Equatable, Sendable {
    case invalidIdentity
    case invalidStateTransition
    case invalidPlan
    case corruptedCheckpoint
    case checkpointTooLarge
    case checkpointNotEligible
    case revisionConflict
    case leaseConflict
}
