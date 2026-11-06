import Foundation

struct BoneOpenAINormalizedEventMapper {
    private let disclosure: BoneInferenceReasoningDisclosure
    private let toolIDsByWireName: [String: String]
    private var callIDs: [Int: String] = [:]
    private var startedCalls = Set<Int>()
    private var reasoningStarted = false
    private(set) var activities: [BoneInferenceActivity] = []
    private var lastActivity: BoneInferenceActivity?
    private(set) var hasOutputToken = false

    init(disclosure: BoneInferenceReasoningDisclosure, definitions: [BoneAgentToolDefinition]) {
        self.disclosure = disclosure
        toolIDsByWireName = Dictionary(uniqueKeysWithValues: definitions.compactMap { definition in
            guard let name = definition.wireName else { return nil }
            return (name, definition.id)
        })
    }

    mutating func consume(_ event: BoneInferenceEventStreamEvent) throws -> [BoneInferenceStreamEvent] {
        activities.removeAll(keepingCapacity: true)
        guard event.data != "[DONE]" else {
            recordActivity(.validatingResponse)
            return []
        }
        guard let object = try? JSONSerialization.jsonObject(with: Data(event.data.utf8)),
              let json = object as? [String: Any], json["error"] == nil else {
            throw BoneInferenceTransportError.invalidResponse
        }
        var result: [BoneInferenceStreamEvent] = []
        if let usage = try BoneProviderUsage.read(json, wire: .openAI) { result.append(.usage(usage)) }
        guard let choices = json["choices"] as? [[String: Any]], choices.count <= 1 else { return result }
        let finished = (choices.first?["finish_reason"] as? String).map { !$0.isEmpty } ?? false
        guard let delta = choices.first?["delta"] as? [String: Any] else {
            if finished { recordActivity(.validatingResponse) }
            return result
        }
        let readable = delta["reasoning_content"] as? String
        let summary = delta["reasoning_summary"] as? String
        if readable?.isEmpty == false || summary?.isEmpty == false {
            hasOutputToken = true
            recordActivity(.reasoning)
        }
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
        if let text = delta["content"] as? String, !text.isEmpty {
            hasOutputToken = true
            recordActivity(.generatingResponse)
            result.append(.textDelta(text))
        }
        for fragment in delta["tool_calls"] as? [[String: Any]] ?? [] {
            guard let index = fragment["index"] as? Int else { throw BoneInferenceTransportError.invalidResponse }
            recordActivity(.generatingToolCall)
            if let arguments = (fragment["function"] as? [String: Any])?["arguments"] as? String,
               !arguments.isEmpty { hasOutputToken = true }
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
        if reasoningStarted, finished {
            result.append(.reasoningCompleted)
            reasoningStarted = false
        }
        if finished {
            recordActivity(.validatingResponse)
            for index in startedCalls.sorted() {
                if let id = callIDs[index] { result.append(.toolCallCompleted(id: id)) }
            }
            startedCalls.removeAll()
        }
        return result
    }

    mutating func finish() {
        activities.removeAll(keepingCapacity: true)
        recordActivity(.validatingResponse)
    }

    private mutating func recordActivity(_ activity: BoneInferenceActivity) {
        guard lastActivity != activity else { return }
        lastActivity = activity
        activities.append(activity)
    }
}
