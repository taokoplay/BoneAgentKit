import Foundation

/// 显式启用的 OpenAI/Anthropic 私有续接。仅在运行内使用，不是普通日志或业务输出。
enum BoneThinkingContinuation {
    struct Entry: Codable {
        let messageIndex: Int
        let turn: BoneInferenceAssistantTurn
        let userAnchorDigest: String
        let payload: Data
    }
    struct Envelope: Codable {
        let version: Int
        let modelID: String
        let identity: String
        let format: BoneInferenceReasoningProfile.Continuation
        let reasoningOptions: BoneInferenceReasoningOptions?
        let entries: [Entry]
    }

    static func identity(configuration: BoneInferenceProviderConfiguration, modelID: String,
                         profile: BoneInferenceReasoningProfile) -> String {
        // 不保存 URL、header、凭据原值；保守地将端点配置变化视为不兼容。
        let material = [configuration.kind.rawValue, configuration.baseURL.absoluteString,
                        configuration.endpointOverrides["chat"] ?? "", configuration.usesFullEndpointURL ? "full" : "relative",
                        configuration.authenticationMode.rawValue, modelID, profile.wireFormat.rawValue,
                        profile.continuation.rawValue].joined(separator: "\u{1F}")
        return BoneSHA256.hexDigest(Data(material.utf8))
    }

    static func decode(_ value: BoneInferenceProviderContinuation,
                       configuration: BoneInferenceProviderConfiguration,
                       profiles: [String: BoneInferenceReasoningProfile]) throws -> Envelope {
        try value.validate(for: configuration.kind)
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: value.data),
              envelope.version == 1, !envelope.entries.isEmpty,
              let profile = profiles[envelope.modelID], profile.continuation != .none,
              profile.continuation == envelope.format,
              envelope.identity == identity(configuration: configuration, modelID: envelope.modelID, profile: profile) else {
            throw BoneInferenceError.invalidProviderContinuation
        }
        return envelope
    }

    static func validatedEntries(_ envelope: Envelope, messages: [BoneInferenceMessage]) throws -> [Int: Entry] {
        var result: [Int: Entry] = [:]
        for entry in envelope.entries {
            guard messages.indices.contains(entry.messageIndex), result[entry.messageIndex] == nil,
                  messages[entry.messageIndex].assistantTurn == entry.turn,
                  entry.userAnchorDigest == anchorDigest(before: entry.messageIndex, in: messages),
                  !entry.payload.isEmpty else { throw BoneInferenceError.invalidProviderContinuation }
            result[entry.messageIndex] = entry
        }
        return result
    }

    static func payloads(request: BoneInferenceRequest, configuration: BoneInferenceProviderConfiguration,
                         profiles: [String: BoneInferenceReasoningProfile]) throws -> [Int: Data] {
        if request.providerContinuation != nil,
           request.responseFormat.isStructured || request.outputConstraint != nil {
            // 必须在构造 URLRequest/调用 transport 前拒绝；不能发送后才在 attach 阶段丢弃响应。
            throw BoneInferenceError.invalidProviderContinuation
        }
        guard let value = request.providerContinuation else { return [:] }
        let envelope = try decode(value, configuration: configuration, profiles: profiles)
        // Provider 的私有思考块只对普通文本/Tool assistant turn 有意义；结构化输出或
        // outputConstraint 会由另一条 public turn 语义承载，不能把旧私有 payload 带入网络请求。
        guard !request.responseFormat.isStructured, request.outputConstraint == nil,
              envelope.modelID == request.modelID,
              envelope.reasoningOptions == request.generationOptions.reasoning else {
            throw BoneInferenceError.invalidProviderContinuation
        }
        return try validatedEntries(envelope, messages: request.messages.filter { $0.role != .system }).mapValues(\.payload)
    }

    static func attach(response: BoneInferenceResponse, payload: Data?, request: BoneInferenceRequest,
                       configuration: BoneInferenceProviderConfiguration,
                       profiles: [String: BoneInferenceReasoningProfile]) throws -> BoneInferenceResponse {
        guard let profile = profiles[request.modelID], profile.continuation != .none else {
            guard request.providerContinuation == nil else { throw BoneInferenceError.invalidProviderContinuation }
            return response
        }
        // Structured/fallback outputs use a different public turn; do not bind private wire content to it.
        guard !request.responseFormat.isStructured, request.outputConstraint == nil else {
            guard payload == nil, request.providerContinuation == nil else {
                throw BoneInferenceError.invalidProviderContinuation
            }
            return response
        }
        let messages = request.messages.filter { $0.role != .system }
        var entries: [Int: Entry] = [:]
        if let previous = request.providerContinuation {
            let envelope = try decode(previous, configuration: configuration, profiles: profiles)
            guard envelope.modelID == request.modelID else { throw BoneInferenceError.invalidProviderContinuation }
            entries = try validatedEntries(envelope, messages: messages)
        }
        guard let turn = response.terminalAssistantTurn else { return response }
        if let payload {
            guard let anchor = anchorDigest(before: messages.count, in: messages) else {
                throw BoneInferenceError.invalidProviderContinuation
            }
            entries[messages.count] = .init(messageIndex: messages.count, turn: turn, userAnchorDigest: anchor, payload: payload)
        }
        guard !entries.isEmpty else { return response }
        let envelope = Envelope(version: 1, modelID: request.modelID,
                                identity: identity(configuration: configuration, modelID: request.modelID, profile: profile),
                                format: profile.continuation, reasoningOptions: request.generationOptions.reasoning,
                                entries: entries.keys.sorted().map { entries[$0]! })
        let continuation = try encode(envelope, provider: configuration.kind)
        if case let .assistantTurn(_, reason, usage, refusal, _) = response {
            return .init(assistantTurn: turn, finishReason: reason, usage: usage, refusal: refusal, providerContinuation: continuation)
        }
        return .init(assistantTurn: turn, finishReason: .stop, usage: response.usage, refusal: nil, providerContinuation: continuation)
    }

    static func rebind(_ value: BoneInferenceProviderContinuation,
                       configuration: BoneInferenceProviderConfiguration,
                       profiles: [String: BoneInferenceReasoningProfile],
                       from original: [BoneInferenceMessage], to compacted: [BoneInferenceMessage]) throws -> BoneInferenceProviderContinuation? {
        let envelope = try decode(value, configuration: configuration, profiles: profiles)
        let old = original.filter { $0.role != .system }; let new = compacted.filter { $0.role != .system }
        let entries = try validatedEntries(envelope, messages: old)
        if old == new { return value }
        var rebound: [Entry] = []
        for (oldIndex, entry) in entries.sorted(by: { $0.key < $1.key }) {
            guard let anchor = precedingUser(oldIndex, in: old) else { throw BoneInferenceError.invalidProviderContinuation }
            let oldMatches = old.indices.filter { old[$0].assistantTurn == entry.turn && precedingUser($0, in: old) == anchor }
            let newMatches = new.indices.filter { new[$0].assistantTurn == entry.turn && precedingUser($0, in: new) == anchor }
            guard oldMatches.count == 1, newMatches.count <= 1 else { throw BoneInferenceError.invalidProviderContinuation }
            if let index = newMatches.first {
                rebound.append(.init(messageIndex: index, turn: entry.turn, userAnchorDigest: entry.userAnchorDigest, payload: entry.payload))
            } else {
                // Only whole user turns may be removed. Keeping their user but changing/dropping signed turns is unsafe.
                guard !new.contains(where: { $0.role == .user && $0.content == anchor }),
                      Set(entry.turn.toolCalls.map(\.id)).isDisjoint(with: new.flatMap { $0.assistantTurn?.toolCalls.map(\.id) ?? [] }) else {
                    throw BoneInferenceError.invalidProviderContinuation
                }
            }
        }
        guard !rebound.isEmpty else { return nil }
        return try encode(.init(version: 1, modelID: envelope.modelID, identity: envelope.identity,
                                format: envelope.format, reasoningOptions: envelope.reasoningOptions,
                                entries: rebound), provider: configuration.kind)
    }

    private static func anchorDigest(before index: Int, in messages: [BoneInferenceMessage]) -> String? {
        precedingUser(index, in: messages).map { BoneSHA256.hexDigest(Data($0.utf8)) }
    }

    private static func precedingUser(_ index: Int, in messages: [BoneInferenceMessage]) -> String? {
        guard index > 0 else { return nil }
        return messages[..<index].last { $0.role == .user }?.content
    }
    private static func encode(_ envelope: Envelope, provider: BoneInferenceProviderKind) throws -> BoneInferenceProviderContinuation {
        try .init(provider: provider, data: JSONEncoder().encode(envelope))
    }

    static func openAIPayload(json: [String: Any]) throws -> Data? {
        guard let message = (json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any],
              let reasoning = message["reasoning_content"] as? String else { return nil }
        return try boundedJSON(["reasoning_content": reasoning])
    }
    static func openAIPayload(events: [BoneInferenceEventStreamEvent]) throws -> Data? {
        var text: String? = nil
        for event in events where event.data != "[DONE]" {
            guard let json = try? JSONSerialization.jsonObject(with: Data(event.data.utf8)) as? [String: Any],
                  let delta = (json["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any],
                  let fragment = delta["reasoning_content"] as? String else { continue }
            text = (text ?? "") + fragment
            guard text!.utf8.count <= BoneInferenceProviderContinuation.maximumByteCount else { throw BoneInferenceError.providerContinuationTooLarge }
        }
        return try text.map { try boundedJSON(["reasoning_content": $0]) }
    }
    static func anthropicPayload(json: [String: Any]) throws -> Data? {
        guard let blocks = json["content"] as? [[String: Any]],
              blocks.contains(where: { ["thinking", "redacted_thinking"].contains($0["type"] as? String ?? "") }) else { return nil }
        for block in blocks {
            switch block["type"] as? String {
            case "thinking":
                guard block["thinking"] is String, let signature = block["signature"] as? String, !signature.isEmpty else { throw BoneInferenceError.invalidProviderContinuation }
            case "redacted_thinking":
                guard let data = block["data"] as? String, !data.isEmpty else { throw BoneInferenceError.invalidProviderContinuation }
            case "text", "tool_use": break
            default: throw BoneInferenceError.invalidProviderContinuation
            }
        }
        return try boundedJSON(blocks)
    }
    /// Called only after the strict SSE aggregator has validated ordering and terminal state.
    static func anthropicPayload(events: [BoneInferenceEventStreamEvent]) throws -> Data? {
        var blocks: [Int: [String: Any]] = [:]; var arguments: [Int: String] = [:]
        for event in events {
            guard let json = try? JSONSerialization.jsonObject(with: Data(event.data.utf8)) as? [String: Any],
                  let index = json["index"] as? Int else { continue }
            if json["type"] as? String == "content_block_start", let block = json["content_block"] as? [String: Any] { blocks[index] = block }
            if json["type"] as? String == "content_block_delta", let delta = json["delta"] as? [String: Any], var block = blocks[index] {
                let key: String?
                switch delta["type"] as? String {
                case "thinking_delta": key = "thinking"
                case "signature_delta": key = "signature"
                case "text_delta": key = "text"
                case "input_json_delta":
                    guard let fragment = delta["partial_json"] as? String else { throw BoneInferenceError.invalidProviderContinuation }
                    arguments[index, default: ""] += fragment; key = nil
                default: throw BoneInferenceError.invalidProviderContinuation
                }
                if let key {
                    guard let fragment = delta[key] as? String else { throw BoneInferenceError.invalidProviderContinuation }
                    block[key] = (block[key] as? String ?? "") + fragment
                }
                blocks[index] = block
            }
        }
        for (index, json) in arguments {
            guard let input = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { throw BoneInferenceError.invalidProviderContinuation }
            blocks[index]?["input"] = input
        }
        return try anthropicPayload(json: ["content": blocks.keys.sorted().map { blocks[$0]! }])
    }
    private static func boundedJSON(_ value: Any) throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        guard data.count <= BoneInferenceProviderContinuation.maximumByteCount else { throw BoneInferenceError.providerContinuationTooLarge }
        return data
    }
}
