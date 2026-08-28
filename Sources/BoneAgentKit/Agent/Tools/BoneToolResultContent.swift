import Foundation

/// Tool 结果的 Provider 无关内容类型。
public enum BoneToolResultContent: Codable, Equatable, Sendable {
    case json(Data)
    case text(String)

    public var byteCount: Int {
        switch self {
        case let .json(data): data.count
        case let .text(value): value.lengthOfBytes(using: .utf8)
        }
    }

    func validated() throws -> Self {
        switch self {
        case let .json(data):
            guard (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil else {
                throw BoneInferenceError.invalidToolResult
            }
        case .text:
            break
        }
        return self
    }
}

/// 同一 Assistant Turn 的 Tool 结果批次，严格按 call ordinal 排列。
public struct BoneInferenceToolResultBatch: Codable, Equatable, Sendable {
    public static let maximumTotalResultByteCount = 4 * 1_048_576
    public let results: [BoneInferenceToolResult]

    public init(results: [BoneInferenceToolResult]) throws {
        guard !results.isEmpty,
              results.count <= BoneInferenceAssistantTurn.maximumToolCallCount else {
            throw BoneInferenceError.invalidToolResult
        }
        var callIDs = Set<String>()
        var expectedOrdinal = 0
        var totalBytes = 0
        for result in results {
            guard callIDs.insert(result.callID).inserted,
                  result.ordinal == expectedOrdinal else {
                throw BoneInferenceError.invalidToolResult
            }
            expectedOrdinal += 1
            let (next, overflow) = totalBytes.addingReportingOverflow(result.content.byteCount)
            guard !overflow else { throw BoneInferenceError.toolResultTooLarge }
            totalBytes = next
        }
        guard totalBytes <= Self.maximumTotalResultByteCount else {
            throw BoneInferenceError.toolResultTooLarge
        }
        self.results = results
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(results: container.decode([BoneInferenceToolResult].self, forKey: .results))
    }

    private enum CodingKeys: CodingKey { case results }
}
