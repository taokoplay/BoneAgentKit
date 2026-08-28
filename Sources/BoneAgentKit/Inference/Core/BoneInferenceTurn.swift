import Foundation

/// Assistant 轮次中按 Provider 原始顺序排列的内容块。
public enum BoneInferenceAssistantContent: Codable, Equatable, Sendable {
    case text(String)
    case structured(Data)
    case toolCall(BoneInferenceToolCall)
}

/// 一个完整、可继续推理的 Assistant 轮次。
public struct BoneInferenceAssistantTurn: Codable, Equatable, Sendable {
    public static let maximumToolCallCount = 32
    public static let maximumTotalToolArgumentsByteCount = 4 * 1_048_576

    public let content: [BoneInferenceAssistantContent]

    public init(content: [BoneInferenceAssistantContent]) throws {
        guard !content.isEmpty else { throw BoneInferenceError.invalidResponse }
        var callIDs = Set<String>()
        var totalArgumentBytes = 0
        var callCount = 0
        for block in content {
            switch block {
            case let .text(value):
                guard !value.isEmpty else { throw BoneInferenceError.invalidResponse }
            case let .structured(data):
                guard Self.isJSONValue(data) else { throw BoneInferenceError.invalidResponse }
            case let .toolCall(call):
                guard Self.isValidCall(call), callIDs.insert(call.id).inserted else {
                    throw BoneInferenceError.invalidResponse
                }
                callCount += 1
                let (nextTotal, overflow) = totalArgumentBytes.addingReportingOverflow(call.arguments.count)
                guard !overflow else { throw BoneInferenceError.toolArgumentsTooLarge }
                totalArgumentBytes = nextTotal
            }
        }
        guard callCount <= Self.maximumToolCallCount else {
            throw BoneInferenceError.tooManyToolCalls
        }
        guard totalArgumentBytes <= Self.maximumTotalToolArgumentsByteCount else {
            throw BoneInferenceError.toolArgumentsTooLarge
        }
        self.content = content
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let content = try container.decode([BoneInferenceAssistantContent].self, forKey: .content)
        try self.init(content: content)
    }

    public var text: String? {
        let values = content.compactMap { block -> String? in
            guard case let .text(value) = block else { return nil }
            return value
        }
        return values.isEmpty ? nil : values.joined()
    }

    public var structuredOutputs: [Data] {
        content.compactMap { block in
            guard case let .structured(value) = block else { return nil }
            return value
        }
    }

    public var toolCalls: [BoneInferenceToolCall] {
        var ordinal = 0
        return content.compactMap { block in
            guard case let .toolCall(value) = block else { return nil }
            let call = value.withOrdinal(ordinal)
            ordinal += 1
            return call
        }
    }

    private enum CodingKeys: CodingKey { case content }
}

private extension BoneInferenceAssistantTurn {
    static func isJSONValue(_ data: Data) -> Bool {
        (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil
    }

    static func isValidCall(_ call: BoneInferenceToolCall) -> Bool {
        guard !call.id.isEmpty,
              call.id.count <= 256,
              !call.toolID.isEmpty,
              call.toolID.count <= 128,
              call.arguments.count <= BoneInferenceToolCall.maximumArgumentsByteCount,
              let object = try? JSONSerialization.jsonObject(with: call.arguments) as? [String: Any] else {
            return false
        }
        return object.count <= 1_024
    }
}
