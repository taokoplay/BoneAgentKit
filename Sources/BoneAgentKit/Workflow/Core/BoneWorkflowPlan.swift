import Foundation

public struct BoneWorkflowPlan: Codable, Equatable, Sendable {
    public struct Step: Codable, Equatable, Sendable {
        public let id: BoneStepID
        public let kind: String
        public let revision: UInt64

        public init(id: BoneStepID, kind: String, revision: UInt64) {
            self.id = id
            self.kind = kind
            self.revision = revision
        }
    }

    public let identity: String
    public let revision: UInt64
    public let steps: [Step]

    public init(identity: String, revision: UInt64, steps: [Step]) throws {
        guard !identity.isEmpty, identity.count <= 128,
              revision > 0, !steps.isEmpty,
              steps.allSatisfy({ !$0.kind.isEmpty && $0.kind.count <= 128 && $0.revision > 0 }),
              Set(steps.map(\.id)).count == steps.count else {
            throw BoneWorkflowFailure.invalidPlan
        }
        self.identity = identity
        self.revision = revision
        self.steps = steps
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            identity: container.decode(String.self, forKey: .identity),
            revision: container.decode(UInt64.self, forKey: .revision),
            steps: container.decode([Step].self, forKey: .steps)
        )
    }

    private enum CodingKeys: CodingKey { case identity, revision, steps }
}

public enum BoneWorkflowCheckpointRestartReason: String, Codable, Equatable, Sendable {
    case workflowChanged
}
public enum BoneWorkflowCheckpointDecisionReason: String, Codable, Equatable, Sendable {
    case unknownFormat
    case newerWorkflowRevision
}
public enum BoneWorkflowCheckpointCompatibility: Codable, Equatable, Sendable {
    case resumeCompatible
    case requiresRestart(BoneWorkflowCheckpointRestartReason)
    case requiresUserDecision(BoneWorkflowCheckpointDecisionReason)
}

public struct BoneWorkflowCheckpointDescriptor: Codable, Equatable, Sendable {
    public let formatVersion: UInt64
    public let workflowIdentity: String
    public let workflowRevision: UInt64

    public init(formatVersion: UInt64, workflowIdentity: String, workflowRevision: UInt64) {
        self.formatVersion = formatVersion
        self.workflowIdentity = workflowIdentity
        self.workflowRevision = workflowRevision
    }

    public func compatibility(
        with plan: BoneWorkflowPlan,
        supportedFormatVersions: Set<UInt64>
    ) -> BoneWorkflowCheckpointCompatibility {
        guard supportedFormatVersions.contains(formatVersion) else {
            return .requiresUserDecision(.unknownFormat)
        }
        guard workflowIdentity == plan.identity else {
            return .requiresRestart(.workflowChanged)
        }
        if workflowRevision > plan.revision {
            return .requiresUserDecision(.newerWorkflowRevision)
        }
        guard workflowRevision == plan.revision else {
            return .requiresRestart(.workflowChanged)
        }
        return .resumeCompatible
    }
}
