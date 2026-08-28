import Foundation

/// Checkpoint payload 的持久化数据分类。普通 Persistence 只接受前两类；
/// 其余类型必须留在受控临时内存或由 Host 的专用加密/egress 策略处理。
public enum BoneCheckpointDataClassification: String, Codable, Equatable, Sendable {
    case safeState
    case opaqueReference
    case userPrivate
    case credential
    case providerContinuation
    case rawModelExchange

    var isEligibleForStandardPersistence: Bool {
        self == .safeState || self == .opaqueReference
    }
}

public enum BoneCheckpointRetention: String, Codable, Equatable, Sendable {
    case untilRunTerminal
    case untilExplicitCleanup
}

public struct BoneRunCheckpoint: Codable, Equatable, Sendable {
    public static let maximumPayloadByteCount = 4 * 1_048_576

    public let descriptor: BoneWorkflowCheckpointDescriptor
    public let payload: Data
    public let dataClassification: BoneCheckpointDataClassification
    public let retention: BoneCheckpointRetention
    public let revision: UInt64

    public init(
        descriptor: BoneWorkflowCheckpointDescriptor,
        payload: Data,
        dataClassification: BoneCheckpointDataClassification,
        retention: BoneCheckpointRetention = .untilRunTerminal,
        revision: UInt64 = 0
    ) throws {
        guard !payload.isEmpty else { throw BoneWorkflowFailure.corruptedCheckpoint }
        guard payload.count <= Self.maximumPayloadByteCount else {
            throw BoneWorkflowFailure.checkpointTooLarge
        }
        guard dataClassification.isEligibleForStandardPersistence else {
            throw BoneWorkflowFailure.checkpointNotEligible
        }
        guard (try? JSONSerialization.jsonObject(with: payload, options: [.fragmentsAllowed])) != nil else {
            throw BoneWorkflowFailure.corruptedCheckpoint
        }
        self.descriptor = descriptor
        self.payload = payload
        self.dataClassification = dataClassification
        self.retention = retention
        self.revision = revision
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            descriptor: container.decode(BoneWorkflowCheckpointDescriptor.self, forKey: .descriptor),
            payload: container.decode(Data.self, forKey: .payload),
            dataClassification: container.decode(
                BoneCheckpointDataClassification.self,
                forKey: .dataClassification
            ),
            retention: container.decodeIfPresent(
                BoneCheckpointRetention.self,
                forKey: .retention
            ) ?? .untilRunTerminal,
            revision: container.decodeIfPresent(UInt64.self, forKey: .revision) ?? 0
        )
    }

    func stored(revision: UInt64) throws -> Self {
        try .init(
            descriptor: descriptor,
            payload: payload,
            dataClassification: dataClassification,
            retention: retention,
            revision: revision
        )
    }

    private enum CodingKeys: CodingKey {
        case descriptor, payload, dataClassification, retention, revision
    }
}
