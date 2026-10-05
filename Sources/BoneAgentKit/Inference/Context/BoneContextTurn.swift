import Foundation

/// 用户 Turn；完整包含本轮的所有 Assistant/Tool 交换。
public struct BoneContextTurn: Equatable, Sendable {
    public let messages: [BoneInferenceMessage]
    public let containsToolCall: Bool
    public let containsUnresolvedToolCall: Bool

    public init(messages: [BoneInferenceMessage]) {
        self.messages = messages
        containsToolCall = messages.contains { !($0.assistantTurn?.toolCalls.isEmpty ?? true) || $0.role == .tool }
        containsUnresolvedToolCall = (try? Self.validate(messages)) == nil
    }

    public var estimatedTokenCount: Int { BoneTokenEstimator.estimateMessages(messages) }

    /// 仅接受前置 system 段，拒绝会改变指令时序的中途 system 消息。
    static func split(_ messages: [BoneInferenceMessage]) throws -> (head: [BoneInferenceMessage], turns: [BoneContextTurn]) {
        let head = Array(messages.prefix { $0.role == .system })
        let rest = messages.dropFirst(head.count)
        guard !rest.contains(where: { $0.role == .system }) else { throw BoneContextCompactionError.invalidHistory }
        var groups: [[BoneInferenceMessage]] = []
        for message in rest {
            if message.role == .user || groups.isEmpty { groups.append([]) }
            groups[groups.count - 1].append(message)
        }
        var calls = Set<String>()
        for group in groups {
            try validate(group)
            for call in group.flatMap({ $0.assistantTurn?.toolCalls ?? [] }) {
                guard calls.insert(call.id).inserted else { throw BoneContextCompactionError.invalidHistory }
            }
        }
        return (head, groups.map(Self.init(messages:)))
    }

    /// 不允许孤立/重复结果、错误 toolID/ordinal，或未完成调用跨越下一用户 Turn。
    static func validate(_ messages: [BoneInferenceMessage]) throws {
        var pending: [BoneInferenceToolCall] = []
        var seen = Set<String>()
        for message in messages {
            if message.role == .tool {
                let results = try message.requiredToolResults().results
                guard !pending.isEmpty, results.count == pending.count else { throw BoneContextCompactionError.invalidHistory }
                for (call, result) in zip(pending, results) {
                    guard call.id == result.callID, call.toolID == result.toolID, call.ordinal == result.ordinal else {
                        throw BoneContextCompactionError.invalidHistory
                    }
                }
                pending.removeAll()
            } else {
                guard pending.isEmpty else { throw BoneContextCompactionError.invalidHistory }
                pending = message.assistantTurn?.toolCalls ?? []
                for call in pending {
                    guard seen.insert(call.id).inserted else { throw BoneContextCompactionError.invalidHistory }
                }
            }
        }
        guard pending.isEmpty else { throw BoneContextCompactionError.invalidHistory }
    }
}
