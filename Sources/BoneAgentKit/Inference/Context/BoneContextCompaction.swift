import Foundation

public enum BoneContextCompactionStrategy: String, Codable, Sendable {
    case none
    case toolResultClamp
    case slidingWindow
    case tiered
    case summary
}

/// Explicit policy for a Tool Result. Tool names are never guessed to be safe to discard.
public enum BoneContextToolResultPolicy: Equatable, Sendable {
    case retain
    case clamp(maximumBytes: Int)
}

public struct BoneContextCompactionReceipt: Codable, Equatable, Sendable {
    public let strategy: BoneContextCompactionStrategy
    public let sourceRevision: UInt64
    public let resultingRevision: UInt64
    public let removedTurnCount: Int
    public let removedToolExchangeCount: Int
    public let removedMessageCount: Int
    public let estimatedRequestTokenReduction: Int
    public let clampedToolResultCount: Int
    public let usedModelSummary: Bool
    public let fallbackUsed: Bool

    public init(
        strategy: BoneContextCompactionStrategy,
        sourceRevision: UInt64,
        resultingRevision: UInt64,
        removedTurnCount: Int,
        removedMessageCount: Int,
        estimatedRequestTokenReduction: Int,
        clampedToolResultCount: Int,
        usedModelSummary: Bool = false,
        fallbackUsed: Bool = false,
        removedToolExchangeCount: Int = 0
    ) {
        self.strategy = strategy
        self.sourceRevision = sourceRevision
        self.resultingRevision = resultingRevision
        self.removedTurnCount = removedTurnCount
        self.removedToolExchangeCount = removedToolExchangeCount
        self.removedMessageCount = removedMessageCount
        self.estimatedRequestTokenReduction = estimatedRequestTokenReduction
        self.clampedToolResultCount = clampedToolResultCount
        self.usedModelSummary = usedModelSummary
        self.fallbackUsed = fallbackUsed
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(strategy: try c.decode(BoneContextCompactionStrategy.self, forKey: .strategy),
            sourceRevision: try c.decode(UInt64.self, forKey: .sourceRevision),
            resultingRevision: try c.decode(UInt64.self, forKey: .resultingRevision),
            removedTurnCount: try c.decode(Int.self, forKey: .removedTurnCount),
            removedMessageCount: try c.decode(Int.self, forKey: .removedMessageCount),
            estimatedRequestTokenReduction: try c.decode(Int.self, forKey: .estimatedRequestTokenReduction),
            clampedToolResultCount: try c.decode(Int.self, forKey: .clampedToolResultCount),
            usedModelSummary: try c.decode(Bool.self, forKey: .usedModelSummary),
            fallbackUsed: try c.decode(Bool.self, forKey: .fallbackUsed),
            removedToolExchangeCount: try c.decodeIfPresent(Int.self, forKey: .removedToolExchangeCount) ?? 0)
    }

}

public struct BoneContextCompactionCandidate: Equatable, Sendable {
    public let messages: [BoneInferenceMessage]
    public let receipt: BoneContextCompactionReceipt

    public init(messages: [BoneInferenceMessage], receipt: BoneContextCompactionReceipt) {
        self.messages = messages
        self.receipt = receipt
    }
}

public enum BoneContextCompactionError: Error, Equatable, Sendable {
    case invalidConfiguration
    case mandatoryMessagesExceedBudget(estimated: Int, limit: Int)
    case noProgress
    case invalidHistory
    case revisionOverflow
    case continuationUnsupported
    case summaryUnavailable
    case tokenCountingFailed
}

/// Deterministic compaction that can run before either a remote or local inference call.
public enum BoneContextCompactor {
    public static func compact(
        messages: [BoneInferenceMessage],
        budget: BoneContextWindowBudget,
        configuredOutputTokens: Int? = nil,
        preferredOutputTokens: Int? = nil,
        minimumRecentTurnCount: Int = 1,
        sourceRevision: UInt64 = 0,
        protocolReserveTokens: Int = BoneContextWindowPlanner.defaultProtocolReserveTokens,
        safetyMarginTokens: Int? = nil,
        toolResultPolicy: @Sendable (String) -> BoneContextToolResultPolicy = { _ in .retain }
    ) throws -> BoneContextCompactionCandidate {
        guard !messages.isEmpty,
              minimumRecentTurnCount > 0 else {
            throw BoneContextCompactionError.invalidConfiguration
        }
        let clamped = try clampToolResults(in: messages, policy: toolResultPolicy)
        _ = try BoneContextTurn.split(messages)
        let segmented = try BoneContextTurn.split(clamped.messages)
        let systemMessages = segmented.head
        let turns = segmented.turns
        guard !turns.isEmpty else {
            throw BoneContextCompactionError.noProgress
        }

        let capacity: (maximumOutputTokens: Int, availableInputTokens: Int)
        do {
            capacity = try budget.availableInputTokens(
                configuredOutputTokens: configuredOutputTokens,
                preferredOutputTokens: preferredOutputTokens,
                protocolReserveTokens: protocolReserveTokens,
                safetyMarginTokens: safetyMarginTokens
            )
        } catch {
            throw BoneContextCompactionError.invalidConfiguration
        }

        let systemTokens = BoneTokenEstimator.estimateMessages(systemMessages)
        let protectedCount = min(minimumRecentTurnCount, turns.count)
        let protectedTurns = Array(turns.suffix(protectedCount))
        let protectedMessages = protectedTurns.flatMap(\.messages)
        let mandatoryTokens = systemTokens + BoneTokenEstimator.estimateMessages(protectedMessages)
        guard mandatoryTokens <= capacity.availableInputTokens else {
            throw BoneContextCompactionError.mandatoryMessagesExceedBudget(
                estimated: mandatoryTokens,
                limit: capacity.availableInputTokens
            )
        }

        var keptOlder: [BoneContextTurn] = []
        var remainingTokens = capacity.availableInputTokens - mandatoryTokens
        if turns.count > protectedCount {
            for turn in turns.dropLast(protectedCount).reversed() {
                guard turn.estimatedTokenCount <= remainingTokens else { break }
                keptOlder.append(turn)
                remainingTokens -= turn.estimatedTokenCount
            }
        }
        keptOlder.reverse()
        let keptTurns = keptOlder + protectedTurns
        let resultMessages = systemMessages + keptTurns.flatMap(\.messages)
        let removedTurns = turns.count - keptTurns.count
        let removedMessages = turns.dropLast(keptTurns.count).flatMap(\.messages)
        let removedTokens = max(0, BoneTokenEstimator.estimateMessages(messages) - BoneTokenEstimator.estimateMessages(resultMessages))
        let didClamp = clamped.clampedToolResultCount > 0
        let strategy: BoneContextCompactionStrategy = removedTurns > 0
            ? (didClamp ? .tiered : .slidingWindow)
            : (didClamp ? .toolResultClamp : .none)
        guard resultMessages != messages || didClamp else {
            throw BoneContextCompactionError.noProgress
        }
        guard sourceRevision < UInt64.max else { throw BoneContextCompactionError.revisionOverflow }
        return BoneContextCompactionCandidate(
            messages: resultMessages,
            receipt: BoneContextCompactionReceipt(
                strategy: strategy,
                sourceRevision: sourceRevision,
                resultingRevision: sourceRevision + 1,
                removedTurnCount: removedTurns,
                removedMessageCount: removedMessages.count,
                estimatedRequestTokenReduction: removedTokens,
                clampedToolResultCount: clamped.clampedToolResultCount
            )
        )
    }

    struct ClampResult {
        let messages: [BoneInferenceMessage]
        let clampedToolResultCount: Int
    }

    static func clampToolResults(
        in messages: [BoneInferenceMessage],
        policy: @Sendable (String) -> BoneContextToolResultPolicy
    ) throws -> ClampResult {
        var count = 0
        let output = try messages.map { message -> BoneInferenceMessage in
            guard message.role == .tool else { return message }
            guard let batch = try? message.requiredToolResults() else { return message }
            let results = try batch.results.map { result -> BoneInferenceToolResult in
                guard case let .clamp(maximumBytes) = policy(result.toolID) else { return result }
                guard maximumBytes >= "[context-compacted]".utf8.count else { throw BoneContextCompactionError.invalidConfiguration }
                guard result.content.byteCount > maximumBytes else { return result }
                count += 1
                let content = clampedContent(result.content, maximumBytes: maximumBytes)
                return (try? BoneInferenceToolResult(
                    callID: result.callID,
                    toolID: result.toolID,
                    content: content,
                    isError: result.isError,
                    ordinal: result.ordinal
                )) ?? result
            }
            guard let rebuilt = try? BoneInferenceToolResultBatch(results: results) else {
                return message
            }
            if message.toolResult != nil, let result = rebuilt.results.first, rebuilt.results.count == 1 {
                return .toolResult(result)
            }
            return .toolResults(rebuilt)
        }
        return ClampResult(messages: output, clampedToolResultCount: count)
    }

    private static func clampedContent(_ content: BoneToolResultContent, maximumBytes: Int) -> BoneToolResultContent {
        let marker = "[context-compacted]"
        // 保证最小标记完整；过小配置不允许静默截掉披露信息。
        guard maximumBytes >= marker.utf8.count else { return content }
        let value: String
        switch content {
        case let .text(text): value = text
        case let .json(data): value = String(decoding: data, as: UTF8.self)
        }
        let space = maximumBytes - marker.utf8.count
        let head = utf8Prefix(value, limit: space / 2)
        let tail = String(utf8Prefix(String(value.reversed()), limit: space - head.utf8.count).reversed())
        return .text(head + marker + tail)
    }

    private static func utf8Prefix(_ value: String, limit: Int) -> String {
        var result = ""
        var bytes = 0
        for character in value {
            let size = String(character).utf8.count
            guard size <= limit - bytes else { break }
            result.append(character)
            bytes += size
        }
        return result
    }
}
