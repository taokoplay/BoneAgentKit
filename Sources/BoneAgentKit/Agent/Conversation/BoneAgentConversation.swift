import Foundation

/// Safe lifecycle only. A conversation is not a Workflow checkpoint or a durable lease.
public enum BoneAgentConversationPhase: String, Sendable { case ready, running, recoveryRequired }

public enum BoneAgentConversationError: Error, Equatable, Sendable {
    case invalidState, unsupportedVersion, bindingMismatch, toolsChanged, stateTooLarge
    case busy, recoveryRequired, contextPolicyRequired, revisionOverflow, invalidUserMessage
}

/// Explicit private conversation storage. Only successful, completed user turns are
/// publishable. Host owns encryption, authenticity, CAS, in-flight markers and recovery.
public actor BoneAgentConversation {
    public static let maximumPrivateStateBytes = 8 * 1_048_576
    public static let maximumUserMessageBytes = 1_048_576
    private let agent: BoneAgent
    private var state: BoneAgentConversationState
    public private(set) var phase: BoneAgentConversationPhase = .ready
    public var revision: UInt64 { state.revision }
    public var id: UUID { state.id }

    init(agent: BoneAgent, state: BoneAgentConversationState) {
        self.agent = agent
        self.state = state
    }

    /// Starts a NEW Run with the current Agent configuration and Run budget.
    /// Any execution error locks this instance; it is never an implicit retry permit.
    public func send(_ userMessage: String, snapshotContext: BoneAgentModelSnapshotContext? = nil) async throws -> BoneAgentRunResult {
        guard phase != .running else { throw BoneAgentConversationError.busy }
        guard phase == .ready else { throw BoneAgentConversationError.recoveryRequired }
        guard !userMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              userMessage.utf8.count <= Self.maximumUserMessageBytes else { throw BoneAgentConversationError.invalidUserMessage }
        guard state.revision < UInt64.max else { throw BoneAgentConversationError.revisionOverflow }
        try Task.checkCancellation()
        phase = .running
        do {
            let completed = try await agent.runConversation(state: state, userMessage: userMessage, snapshotContext: snapshotContext)
            // Agent already crossed its success linearization point; a late cancellation
            // must not discard the committed result and invite a duplicate request.
            state = completed.state
            phase = .ready
            return completed.result
        } catch let error as BoneAgentError where error == .runAlreadyInProgress {
            // Another public Run owns the Agent, but this conversation has not
            // crossed its own execution boundary; the Host may try later.
            phase = .ready
            throw error
        } catch {
            phase = .recoveryRequired
            throw error
        }
    }

    /// Contains prompts, tool payloads, summaries and provider signatures. Never send
    /// this blob to logs, normal checkpoints or another connection/model.
    public func exportPrivateState() throws -> Data {
        guard phase != .running else { throw BoneAgentConversationError.busy }
        guard phase == .ready else { throw BoneAgentConversationError.recoveryRequired }
        return try state.encoded()
    }
}

/// Deliberately internal Codable: persistence requires the explicitly named private API.
struct BoneAgentConversationState: Codable, Sendable {
    let schemaVersion: Int
    let id: UUID
    let bindingID: String
    let modelID: String
    let tools: [BoneAgentToolDefinition]
    let generationOptions: BoneInferenceGenerationOptions
    let outputConstraint: BoneInferenceOutputConstraint?
    let reasoningDisclosure: BoneInferenceReasoningDisclosure
    var revision: UInt64
    var messages: [BoneInferenceMessage]
    var summary: String?
    var contextRevision: UInt64
    var providerContinuation: BoneInferenceProviderContinuation?

    func validate() throws {
        guard schemaVersion == 1 else { throw BoneAgentConversationError.unsupportedVersion }
        guard Self.validBinding(bindingID), !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              modelID.utf8.count <= 256, messages.count <= 10_000,
              summary.map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 65_536 }) != false,
              summary == nil || contextRevision > 0 else { throw BoneAgentConversationError.invalidState }
        do {
            _ = try generationOptions.validated()
            let segmented = try BoneContextTurn.split(messages)
            guard segmented.turns.allSatisfy({ $0.messages.first?.role == .user && $0.messages.last?.role == .assistant }) else {
                throw BoneAgentConversationError.invalidState
            }
            if let outputConstraint { _ = try outputConstraint.validated() }
            let toolIDs = Set(tools.map(\.id))
            for tool in tools { _ = try tool.validatedForModelExposure() }
            for message in messages {
                if let turn = message.assistantTurn {
                    guard turn.toolCalls.allSatisfy({ toolIDs.contains($0.toolID) }) else {
                        throw BoneAgentConversationError.invalidState
                    }
                }
                if message.role == .tool {
                    let batch = try message.requiredToolResults()
                    guard batch.results.allSatisfy({ toolIDs.contains($0.toolID) }) else {
                        throw BoneAgentConversationError.invalidState
                    }
                }
            }
        } catch { throw BoneAgentConversationError.invalidState }
        guard tools == tools.sorted(by: { $0.id < $1.id }), Set(tools.map(\.id)).count == tools.count else {
            throw BoneAgentConversationError.invalidState
        }
        if revision == 0 {
            guard messages.allSatisfy({ $0.role == .system }), summary == nil, contextRevision == 0,
                  providerContinuation == nil else { throw BoneAgentConversationError.invalidState }
        } else {
            guard messages.contains(where: { $0.role == .user }), let last = messages.last, last.role == .assistant,
                  last.assistantTurn?.toolCalls.isEmpty ?? true else { throw BoneAgentConversationError.invalidState }
        }
    }

    func encoded() throws -> Data {
        try validate()
        let data = try JSONEncoder().encode(self)
        guard data.count <= BoneAgentConversation.maximumPrivateStateBytes else { throw BoneAgentConversationError.stateTooLarge }
        return data
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= BoneAgentConversation.maximumPrivateStateBytes else { throw BoneAgentConversationError.stateTooLarge }
        let value: Self
        do { value = try JSONDecoder().decode(Self.self, from: data) }
        catch { throw BoneAgentConversationError.invalidState }
        try value.validate()
        return value
    }

    static func validBinding(_ value: String) -> Bool {
        (1...128).contains(value.utf8.count) && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0)
        }
    }
}

struct BoneAgentConversationCompletion: Sendable {
    let state: BoneAgentConversationState
    let result: BoneAgentRunResult
}
