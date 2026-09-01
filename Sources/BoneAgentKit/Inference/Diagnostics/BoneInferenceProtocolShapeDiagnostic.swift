import Foundation

/// 只包含协议形态白名单元数据的诊断，不保留正文、推理、Tool 参数或 signature。
public struct BoneInferenceProtocolShapeError: Error, Equatable, Sendable {
    public let diagnostic: BoneInferenceProtocolShapeDiagnostic

    public init(diagnostic: BoneInferenceProtocolShapeDiagnostic) {
        self.diagnostic = diagnostic
    }
}

public struct BoneInferenceStructuredValidationDiagnostic: Equatable, Sendable {
    public let failure: BoneInferenceStructuredValidationFailure?
    public let schemaMismatch: BoneToolSchemaMismatch?

    public init(
        failure: BoneInferenceStructuredValidationFailure?,
        schemaMismatch: BoneToolSchemaMismatch?
    ) {
        self.failure = failure
        self.schemaMismatch = schemaMismatch
    }
}

public enum BoneInferenceStructuredValidationFailure: String, Equatable, Sendable {
    case invalidJSON
    case rootNotObject
    case schemaMismatch

    static func diagnose(
        text: String,
        schema: BoneToolSchema?
    ) -> BoneInferenceStructuredValidationDiagnostic {
        guard let normalized = BoneStructuredJSONObjectNormalizer.normalize(text) else {
            let data = Data(text.utf8)
            return .init(failure: classify(data: data, schema: schema), schemaMismatch: nil)
        }
        guard let schema else { return .init(failure: nil, schemaMismatch: nil) }
        let mismatch = BoneToolSchemaValidator.firstMismatch(arguments: normalized.data, against: schema)
        return .init(
            failure: mismatch == nil ? nil : .schemaMismatch,
            schemaMismatch: mismatch
        )
    }

    public static func classify(data: Data, schema: BoneToolSchema?) -> Self? {
        let value: Any
        do { value = try JSONSerialization.jsonObject(with: data) }
        catch { return .invalidJSON }
        guard value is [String: Any] else { return .rootNotObject }
        guard let schema else { return nil }
        do { try BoneToolSchemaValidator.validate(arguments: data, against: schema) }
        catch { return .schemaMismatch }
        return nil
    }
}

public enum BoneInferenceAnthropicFailureStage: String, Equatable, Sendable {
    case responseJSON = "response_json"
    case providerError = "provider_error"
    case contentShape = "content_shape"
    case blockShape = "block_shape"
    case toolIdentity = "tool_identity"
    case toolInputShape = "tool_input_shape"
    case stopReason = "stop_reason"
    case usageShape = "usage_shape"
    case assistantTurn = "assistant_turn"
}

public enum BoneInferenceOpenAIFailureStage: String, Equatable, Sendable {
    case eventJSON = "event_json"
    case eventError = "event_error"
    case choicesShape = "choices_shape"
    case choiceIndex = "choice_index"
    case deltaShape = "delta_shape"
    case toolFragment = "tool_fragment"
    case toolIdentity = "tool_identity"
    case toolArgumentsJSON = "tool_arguments_json"
    case finishReason = "finish_reason"
    case streamCompletion = "stream_completion"
    case usageShape = "usage_shape"
    case assistantTurn = "assistant_turn"
}

public struct BoneInferenceProtocolShapeDiagnostic: Equatable, Sendable {
    public let summary: String

    public static func openAI(
        events: [BoneInferenceEventStreamEvent],
        failureStage: BoneInferenceOpenAIFailureStage? = nil
    ) -> Self {
        var invalidJSONEvents = 0
        var errorEvents = 0
        var choicesAbsent = 0
        var choicesEmpty = 0
        var choiceCountMismatch = 0
        var nonzeroChoiceIndexes = 0
        var deltaAbsent = 0
        var toolFragments = 0
        var usageEvents = 0
        var finishReasons: [String: Int] = [:]
        var doneSeen = false

        for event in events {
            if event.data == "[DONE]" {
                doneSeen = true
                continue
            }
            guard let object = try? JSONSerialization.jsonObject(with: Data(event.data.utf8)),
                  let json = object as? [String: Any] else {
                invalidJSONEvents += 1
                continue
            }
            if event.event == "error" || json["error"] != nil { errorEvents += 1 }
            if json["usage"] != nil { usageEvents += 1 }
            guard let choices = json["choices"] as? [[String: Any]] else {
                choicesAbsent += 1
                continue
            }
            if choices.isEmpty { choicesEmpty += 1 }
            if choices.count > 1 { choiceCountMismatch += 1 }
            for choice in choices {
                if let index = choice["index"] as? Int, index != 0 { nonzeroChoiceIndexes += 1 }
                if let reason = allowlisted(choice["finish_reason"] as? String) {
                    finishReasons[reason, default: 0] += 1
                }
                guard let delta = choice["delta"] as? [String: Any] else {
                    deltaAbsent += 1
                    continue
                }
                toolFragments += (delta["tool_calls"] as? [[String: Any]])?.count ?? 0
            }
        }
        var components = [
            "protocol=openai",
            "events=\(events.count)",
            "doneSeen=\(doneSeen)",
            "invalidJSONEvents=\(invalidJSONEvents)",
            "errorEvents=\(errorEvents)",
            "choicesAbsent=\(choicesAbsent)",
            "choicesEmpty=\(choicesEmpty)",
            "choiceCountMismatch=\(choiceCountMismatch)",
            "nonzeroChoiceIndexes=\(nonzeroChoiceIndexes)",
            "finishReason=\(format(finishReasons, empty: "absent"))",
            "deltaAbsent=\(deltaAbsent)",
            "toolFragments=\(toolFragments)",
            "usageEvents=\(usageEvents)",
        ]
        if let failureStage { components.append("failureStage=\(failureStage.rawValue)") }
        return .init(summary: components.joined(separator: " "))
    }

    public static func openAI(
        responseJSON json: [String: Any],
        failureStage: BoneInferenceOpenAIFailureStage? = nil
    ) -> Self {
        let choices = json["choices"] as? [[String: Any]]
        var finishReasons: [String: Int] = [:]
        var toolCallCount = 0
        var messageAbsent = 0
        for choice in choices ?? [] {
            if let reason = allowlisted(choice["finish_reason"] as? String) {
                finishReasons[reason, default: 0] += 1
            }
            guard let message = choice["message"] as? [String: Any] else {
                messageAbsent += 1
                continue
            }
            toolCallCount += (message["tool_calls"] as? [[String: Any]])?.count ?? 0
        }
        var components = [
            "protocol=openai",
            "transport=nonstream",
            "choices=\(choices?.count ?? 0)",
            "choicesPresent=\(choices != nil)",
            "messageAbsent=\(messageAbsent)",
            "finishReason=\(format(finishReasons, empty: "absent"))",
            "toolCallCount=\(toolCallCount)",
            "usagePresent=\(json["usage"] != nil)",
            "errorPresent=\(json["error"] != nil)",
        ]
        if let failureStage { components.append("failureStage=\(failureStage.rawValue)") }
        return .init(summary: components.joined(separator: " "))
    }

    public static func anthropic(
        responseJSON json: [String: Any],
        failureStage: BoneInferenceAnthropicFailureStage? = nil
    ) -> Self {
        let blocks = json["content"] as? [[String: Any]]
        var blockTypes: [String: Int] = [:]
        var toolUseBlocks = 0
        for block in blocks ?? [] {
            if let type = allowlisted(block["type"] as? String) {
                blockTypes[type, default: 0] += 1
                if type == "tool_use" { toolUseBlocks += 1 }
            } else {
                blockTypes["invalid", default: 0] += 1
            }
        }
        var components = [
            "protocol=anthropic",
            "transport=nonstream",
            "errorPresent=\(json["error"] != nil)",
            "contentPresent=\(json["content"] != nil)",
            "contentIsArray=\(blocks != nil)",
            "contentBlockCount=\(blocks?.count ?? 0)",
            "blockTypes=\(format(blockTypes, empty: "none"))",
            "toolUseBlocks=\(toolUseBlocks)",
            "stopReason=\(allowlisted(json["stop_reason"] as? String) ?? "absent")",
            "usagePresent=\(json["usage"] != nil)",
        ]
        if let failureStage { components.append("failureStage=\(failureStage.rawValue)") }
        return .init(summary: components.joined(separator: " "))
    }

    public static func anthropic(
        events: [BoneInferenceEventStreamEvent],
        structuredFailure: BoneInferenceStructuredValidationFailure? = nil,
        schemaMismatch: BoneToolSchemaMismatch? = nil
    ) -> Self {
        var types: [String: Int] = [:]
        var blocks: [String: Int] = [:]
        var deltas: [String: Int] = [:]
        var stopReasons: [String: Int] = [:]
        for event in events {
            guard let object = try? JSONSerialization.jsonObject(with: Data(event.data.utf8)),
                  let json = object as? [String: Any],
                  let type = allowlisted(json["type"] as? String) else {
                types["invalid_json", default: 0] += 1
                continue
            }
            types[type, default: 0] += 1
            if type == "content_block_start",
               let raw = json["content_block"] as? [String: Any],
               let value = allowlisted(raw["type"] as? String) {
                blocks[value, default: 0] += 1
            }
            if type == "content_block_delta",
               let raw = json["delta"] as? [String: Any],
               let value = allowlisted(raw["type"] as? String) {
                deltas[value, default: 0] += 1
            }
            if type == "message_delta", let raw = json["delta"] as? [String: Any] {
                if raw.keys.contains("stop_reason") {
                    let value = allowlisted(raw["stop_reason"] as? String) ?? "null"
                    stopReasons[value, default: 0] += 1
                }
            }
        }
        var components = [
            "protocol=anthropic",
            "events=\(events.count)",
            "types=\(format(types, empty: "none"))",
            "blocks=\(format(blocks, empty: "none"))",
            "deltas=\(format(deltas, empty: "none"))",
            "stopReason=\(format(stopReasons, empty: "absent"))",
        ]
        if let structuredFailure {
            components.append("structuredFailure=\(structuredFailure.rawValue)")
        }
        if let schemaMismatch {
            components.append("schemaPath=\(schemaMismatch.path)")
            components.append("schemaRule=\(schemaMismatch.rule.rawValue)")
        }
        return .init(summary: components.joined(separator: " "))
    }

    private static func allowlisted(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.count <= 64,
              value.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).contains($0)
              }) else { return nil }
        return value
    }

    private static func format(_ values: [String: Int], empty: String) -> String {
        guard !values.isEmpty else { return empty }
        return values.keys.sorted().map { "\($0):\(values[$0]!)" }.joined(separator: ",")
    }
}
