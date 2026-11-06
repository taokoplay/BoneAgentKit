import Foundation

struct BoneGeminiNormalizedEventMapper {
    private let disclosure: BoneInferenceReasoningDisclosure
    private let toolIDsByWireName: [String: String]
    private var reasoningActive = false
    private var localCallIndex = 0
    private let localCallNamespace: String
    private(set) var activities: [BoneInferenceActivity] = []
    private var lastActivity: BoneInferenceActivity?
    private(set) var hasOutputToken = false

    init(disclosure: BoneInferenceReasoningDisclosure, definitions: [BoneAgentToolDefinition], localCallNamespace: String = UUID().uuidString) {
        self.localCallNamespace = localCallNamespace
        self.disclosure = disclosure
        toolIDsByWireName = Dictionary(uniqueKeysWithValues: definitions.compactMap { definition in
            guard let name = definition.wireName else { return nil }
            return (name, definition.id)
        })
    }

    mutating func consume(_ event: BoneInferenceEventStreamEvent) throws -> [BoneInferenceStreamEvent] {
        activities.removeAll(keepingCapacity: true)
        guard let object = try? JSONSerialization.jsonObject(with: Data(event.data.utf8)),
              let json = object as? [String: Any], json["error"] == nil,
              let candidates = json["candidates"] as? [[String: Any]], candidates.count == 1,
              let candidate = candidates.first else { throw BoneInferenceTransportError.invalidResponse }
        var result: [BoneInferenceStreamEvent] = []
        if let content = candidate["content"] as? [String: Any],
           let parts = content["parts"] as? [[String: Any]] {
            for part in parts {
                try BoneGeminiToolWire.validatePartShape(part)
                if let text = part["text"] as? String, !text.isEmpty { hasOutputToken = true }
                if part["thought"] as? Bool == true {
                    recordActivity(.reasoning)
                    if disclosure == .providerReadable,
                       let text = part["text"] as? String, !text.isEmpty {
                        if !reasoningActive {
                            result.append(.reasoningStarted(kind: .providerReadable))
                            reasoningActive = true
                        }
                        result.append(.reasoningDelta(text))
                    }
                    continue
                }
                if reasoningActive { result.append(.reasoningCompleted); reasoningActive = false }
                if let text = part["text"] as? String, !text.isEmpty {
                    recordActivity(.generatingResponse)
                    result.append(.textDelta(text))
                }
                if part["functionCall"] != nil { recordActivity(.generatingToolCall) }
                if let function = part["functionCall"] as? [String: Any],
                   let name = function["name"] as? String,
                   let toolID = toolIDsByWireName[name],
                   let args = function["args"] as? [String: Any] {
                    hasOutputToken = true
                    let id = function["id"] as? String ?? "gemini-local-\(localCallNamespace)-\(localCallIndex)"
                    localCallIndex += 1
                    result.append(.toolCallStarted(id: id, toolID: toolID))
                    result.append(.toolArgumentsDelta(
                        id: id,
                        data: try JSONSerialization.data(withJSONObject: args, options: [.sortedKeys])
                    ))
                    result.append(.toolCallCompleted(id: id))
                }
            }
        }
        if candidate["finishReason"] != nil, reasoningActive {
            result.append(.reasoningCompleted)
            reasoningActive = false
        }
        if candidate["finishReason"] != nil { recordActivity(.validatingResponse) }
        if let usage = try BoneProviderUsage.read(json, wire: .gemini) { result.append(.usage(usage)) }
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
