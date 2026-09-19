import Foundation

/// Gemini 原始 model parts 的有界 opaque envelope；只在运行内按轮次重放，不进入安全日志。
enum BoneGeminiContinuation {
    static func make(parts: [[String: Any]]) throws -> BoneInferenceProviderContinuation? {
        guard parts.contains(where: { $0["thoughtSignature"] != nil }) else { return nil }
        return try envelope(["modelParts": parts])
    }

    /// 接受旧单轮 envelope，并将新版历史逐项绑定到非 system 消息索引和精确 assistant turn。
    /// 已绑定的 assistant turn 被裁剪、移动或修改时 fail closed；不认证 user/tool 内容。
    static func partsByMessage(
        from continuation: BoneInferenceProviderContinuation?,
        messages: [BoneInferenceMessage]
    ) throws -> [Int: [[String: Any]]] {
        guard let continuation else { return [:] }
        let object = try object(from: continuation)
        if let parts = object["modelParts"] as? [[String: Any]], object.count == 1 {
            guard !parts.isEmpty, let index = messages.lastIndex(where: { $0.assistantTurn != nil }) else {
                throw BoneInferenceError.invalidProviderContinuation
            }
            return [index: parts]
        }
        guard let version = object["version"] as? Int, version == 1,
              let entries = object["turns"] as? [[String: Any]], !entries.isEmpty else {
            throw BoneInferenceError.invalidProviderContinuation
        }
        var result: [Int: [[String: Any]]] = [:]
        for entry in entries {
            guard let index = entry["messageIndex"] as? Int,
                  messages.indices.contains(index), result[index] == nil,
                  let turn = messages[index].assistantTurn,
                  let encoded = entry["turn"] as? String,
                  let data = Data(base64Encoded: encoded),
                  let expected = try? JSONDecoder().decode(BoneInferenceAssistantTurn.self, from: data),
                  expected == turn,
                  let parts = entry["modelParts"] as? [[String: Any]], !parts.isEmpty else {
                throw BoneInferenceError.invalidProviderContinuation
            }
            result[index] = parts
        }
        return result
    }

    /// 每次 Provider 返回时累积已验证的历史，Agent 仍只需传递一个不透明 continuation。
    /// 本轮没有新签名也不能清空旧轮次；256 KiB 上限沿用公共 envelope 契约。
    static func accumulating(
        _ response: BoneInferenceResponse,
        after request: BoneInferenceRequest
    ) throws -> BoneInferenceResponse {
        guard case let .assistantTurn(turn, reason, usage, refusal, continuation) = response,
              reason == .toolCalls || reason == .stop else { return response }
        let messages = request.messages.filter { $0.role != .system }
        var history = try partsByMessage(from: request.providerContinuation, messages: messages)
        if let continuation {
            let object = try object(from: continuation)
            guard let parts = object["modelParts"] as? [[String: Any]], !parts.isEmpty else {
                throw BoneInferenceError.invalidProviderContinuation
            }
            history[messages.count] = parts
        }
        guard !history.isEmpty else { return response }
        let entries: [[String: Any]] = try history.keys.sorted().map { index in
            let boundTurn = index == messages.count ? turn : messages[index].assistantTurn!
            return ["messageIndex": index,
                    "turn": try JSONEncoder().encode(boundTurn).base64EncodedString(),
                    "modelParts": history[index]!]
        }
        return .assistantTurn(turn: turn, finishReason: reason, usage: usage, refusal: refusal,
            providerContinuation: try envelope(["version": 1, "turns": entries]))
    }

    private static func object(from continuation: BoneInferenceProviderContinuation) throws -> [String: Any] {
        try continuation.validate(for: .google)
        guard let object = try? JSONSerialization.jsonObject(with: continuation.data) as? [String: Any] else {
            throw BoneInferenceError.invalidProviderContinuation
        }
        return object
    }

    private static func envelope(_ object: [String: Any]) throws -> BoneInferenceProviderContinuation {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw BoneInferenceTransportError.invalidResponse
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try .init(provider: .google, data: data)
    }
}
