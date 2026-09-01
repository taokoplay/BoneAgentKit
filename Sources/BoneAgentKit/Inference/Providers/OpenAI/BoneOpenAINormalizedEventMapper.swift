import Foundation

struct BoneOpenAINormalizedEventMapper {
    private let disclosure: BoneInferenceReasoningDisclosure
    private let toolIDsByWireName: [String: String]
    private var callIDs: [Int: String] = [:]
    private var startedCalls = Set<Int>()
    private var reasoningStarted = false

    init(disclosure: BoneInferenceReasoningDisclosure, definitions: [BoneAgentToolDefinition]) {
        self.disclosure = disclosure
        toolIDsByWireName = Dictionary(uniqueKeysWithValues: definitions.compactMap { definition in
            guard let name = definition.wireName else { return nil }
            return (name, definition.id)
        })
    }

    mutating func consume(_ event: BoneInferenceEventStreamEvent) throws -> [BoneInferenceStreamEvent] {
        guard event.data != "[DONE]" else { return [] }
        guard let object = try? JSONSerialization.jsonObject(with: Data(event.data.utf8)),
              let json = object as? [String: Any], json["error"] == nil else {
            throw BoneInferenceTransportError.invalidResponse
        }
        var result: [BoneInferenceStreamEvent] = []
        if let usage = try usage(json["usage"] as? [String: Any]) { result.append(.usage(usage)) }
        guard let choices = json["choices"] as? [[String: Any]], choices.count <= 1,
              let delta = choices.first?["delta"] as? [String: Any] else { return result }
        let readable = delta["reasoning_content"] as? String
        let summary = delta["reasoning_summary"] as? String
        let selected: (BoneInferenceReasoning.Kind, String)?
        switch disclosure {
        case .hidden: selected = nil
        case .summary: selected = summary.map { (.summary, $0) }
        case .providerReadable:
            selected = readable.map { (.providerReadable, $0) } ?? summary.map { (.summary, $0) }
        }
        if let (kind, text) = selected, !text.isEmpty {
            if !reasoningStarted { result.append(.reasoningStarted(kind: kind)); reasoningStarted = true }
            result.append(.reasoningDelta(text))
        }
        if let text = delta["content"] as? String, !text.isEmpty { result.append(.textDelta(text)) }
        for fragment in delta["tool_calls"] as? [[String: Any]] ?? [] {
            guard let index = fragment["index"] as? Int else { throw BoneInferenceTransportError.invalidResponse }
            if let id = fragment["id"] as? String { callIDs[index] = id }
            guard let id = callIDs[index] else { continue }
            if !startedCalls.contains(index),
               let function = fragment["function"] as? [String: Any],
               let name = function["name"] as? String,
               let toolID = toolIDsByWireName[name] {
                startedCalls.insert(index)
                result.append(.toolCallStarted(id: id, toolID: toolID))
            }
            if let function = fragment["function"] as? [String: Any],
               let arguments = function["arguments"] as? String,
               !arguments.isEmpty {
                result.append(.toolArgumentsDelta(id: id, data: Data(arguments.utf8)))
            }
        }
        if reasoningStarted, choices.first?["finish_reason"] != nil {
            result.append(.reasoningCompleted)
            reasoningStarted = false
        }
        if choices.first?["finish_reason"] != nil {
            for index in startedCalls.sorted() {
                if let id = callIDs[index] { result.append(.toolCallCompleted(id: id)) }
            }
            startedCalls.removeAll()
        }
        return result
    }

    private func usage(_ raw: [String: Any]?) throws -> BoneInferenceUsage? {
        guard let raw else { return nil }
        guard let input = raw["prompt_tokens"] as? Int,
              let output = raw["completion_tokens"] as? Int else { throw BoneInferenceTransportError.invalidResponse }
        return try BoneInferenceUsage(
            inputTokens: input,
            outputTokens: output,
            cachedInputTokens: (raw["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int,
            reasoningTokens: (raw["completion_tokens_details"] as? [String: Any])?["reasoning_tokens"] as? Int
        ).validated()
    }
}
