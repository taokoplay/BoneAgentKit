import Foundation

/// OpenAI Tool SSE 的严格状态机；只在语义终态与 `[DONE]` 均完整时交付。
enum BoneOpenAIToolStreamAggregator {
    static func aggregate(
        events: [BoneInferenceEventStreamEvent],
        definitions: [BoneAgentToolDefinition]
    ) throws -> BoneInferenceResponse {
        let definitions = try definitions.map { try $0.validatedForModelExposure() }
        let stableIDs = Dictionary(uniqueKeysWithValues: definitions.map { ($0.wireName!, $0.id) })
        guard stableIDs.count == definitions.count else { throw BoneInferenceTransportError.invalidResponse }

        var text = ""
        var calls: [Int: PartialCall] = [:]
        var finishReason: String?
        var usage: BoneInferenceUsage?
        var done = false

        for event in events {
            if event.data == "[DONE]" {
                guard !done, finishReason != nil else { throw BoneInferenceTransportError.invalidResponse }
                done = true
                continue
            }
            guard !done, event.event != "error",
                  let object = try? JSONSerialization.jsonObject(with: Data(event.data.utf8)),
                  let json = object as? [String: Any], json["error"] == nil else {
                throw BoneInferenceTransportError.invalidResponse
            }
            if let parsedUsage = try parseUsage(json["usage"] as? [String: Any]) {
                usage = parsedUsage
            }
            guard let choices = json["choices"] as? [[String: Any]], choices.count <= 1 else {
                throw BoneInferenceTransportError.invalidResponse
            }
            guard let choice = choices.first else { continue }
            guard (choice["index"] as? Int ?? 0) == 0 else {
                throw BoneInferenceTransportError.invalidResponse
            }
            if let reason = choice["finish_reason"] as? String {
                guard finishReason == nil else { throw BoneInferenceTransportError.invalidResponse }
                finishReason = reason
            }
            guard let delta = choice["delta"] as? [String: Any] else {
                throw BoneInferenceTransportError.invalidResponse
            }
            if let fragment = delta["content"] as? String { text += fragment }
            for fragment in delta["tool_calls"] as? [[String: Any]] ?? [] {
                guard let index = fragment["index"] as? Int, index >= 0 else {
                    throw BoneInferenceTransportError.invalidResponse
                }
                var call = calls[index] ?? PartialCall()
                if let id = fragment["id"] as? String {
                    guard call.id == nil || call.id == id else { throw BoneInferenceTransportError.invalidResponse }
                    call.id = id
                }
                if let type = fragment["type"] as? String, type != "function" {
                    throw BoneInferenceTransportError.invalidResponse
                }
                if let function = fragment["function"] as? [String: Any] {
                    if let name = function["name"] as? String {
                        guard call.wireName == nil || call.wireName == name else {
                            throw BoneInferenceTransportError.invalidResponse
                        }
                        call.wireName = name
                    }
                    if let arguments = function["arguments"] as? String {
                        call.arguments += arguments
                    }
                }
                calls[index] = call
            }
        }

        guard done, let finishReason else { throw BoneInferenceTransportError.invalidResponse }
        if !calls.isEmpty {
            guard finishReason == "tool_calls" || finishReason == "function_call" else {
                throw BoneInferenceTransportError.invalidResponse
            }
            let indices = calls.keys.sorted()
            guard indices == Array(0..<indices.count) else { throw BoneInferenceTransportError.invalidResponse }
            var content: [BoneInferenceAssistantContent] = []
            if !text.isEmpty { content.append(.text(text)) }
            var callIDs = Set<String>()
            for index in indices {
                guard let partial = calls[index],
                      let id = partial.id,
                      callIDs.insert(id).inserted,
                      let wireName = partial.wireName,
                      let stableID = stableIDs[wireName] else {
                    throw BoneInferenceTransportError.invalidResponse
                }
                let arguments = Data(partial.arguments.utf8)
                guard (try? JSONSerialization.jsonObject(with: arguments)) is [String: Any] else {
                    throw BoneInferenceTransportError.invalidResponse
                }
                content.append(.toolCall(.init(id: id, toolID: stableID, arguments: arguments)))
            }
            let turn: BoneInferenceAssistantTurn
            do { turn = try .init(content: content) }
            catch { throw BoneInferenceTransportError.invalidResponse }
            return .init(
                assistantTurn: turn,
                finishReason: .toolCalls,
                usage: usage,
                refusal: nil,
                providerContinuation: nil
            )
        }

        guard !text.isEmpty, finishReason == "stop" else {
            throw BoneInferenceTransportError.invalidResponse
        }
        return .init(
            assistantTurn: try BoneInferenceAssistantTurn(content: [.text(text)]),
            finishReason: .stop,
            usage: usage,
            refusal: nil,
            providerContinuation: nil
        )
    }
}

private extension BoneOpenAIToolStreamAggregator {
    struct PartialCall {
        var id: String?
        var wireName: String?
        var arguments = ""
    }

    static func parseUsage(_ raw: [String: Any]?) throws -> BoneInferenceUsage? {
        guard let raw else { return nil }
        guard let input = raw["prompt_tokens"] as? Int,
              let output = raw["completion_tokens"] as? Int else {
            throw BoneInferenceTransportError.invalidResponse
        }
        do {
            return try BoneInferenceUsage(
                inputTokens: input,
                outputTokens: output,
                cachedInputTokens: (raw["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int,
                reasoningTokens: (raw["completion_tokens_details"] as? [String: Any])?["reasoning_tokens"] as? Int
            ).validated()
        } catch {
            throw BoneInferenceTransportError.invalidResponse
        }
    }
}
