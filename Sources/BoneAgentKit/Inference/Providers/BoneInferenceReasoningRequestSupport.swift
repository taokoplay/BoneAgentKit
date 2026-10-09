import Foundation

/// 固定映射，不接受任意 body/header 注入；声明只能缩小已有能力。
enum BoneInferenceReasoningRequestSupport {
    enum Wire { case openAI, anthropic, gemini }

    static func resolved(_ capabilities: Set<BoneInferenceCapability>, request: BoneInferenceRequest,
                         metadata: BoneModelMetadata?, profile: BoneInferenceReasoningProfile?,
                         wire: Wire) throws -> Set<BoneInferenceCapability> {
        var result = capabilities
        if let profile {
            try profile.validated(for: requestWire(wire))
        }
        if let metadata {
            guard metadata.declaration.id == request.modelID else {
                throw BoneInferenceReasoningConfigurationError.metadataMismatch
            }
            let declared = metadata.declaration
            if declared.toolCalling == false { result.remove(.toolCalling) }
            if declared.structuredOutput == false {
                result.remove(.structuredOutput); result.remove(.constrainedOutput)
            }
            if let output = declared.modalities?.output, !output.contains("text") { result.remove(.text) }
            if declared.temperature == false, request.generationOptions.temperature != nil {
                throw BoneInferenceReasoningConfigurationError.temperatureUnsupported
            }
            if declared.reasoning == false, request.generationOptions.reasoning != nil {
                throw BoneInferenceReasoningConfigurationError.unsupportedMode
            }
            if let requested = request.generationOptions.reasoning, let controls = declared.reasoningOptions {
                if let effort = requested.effort,
                   let options = controls.first(where: { $0.type == "effort" }),
                   let values = options.values,
                   !values.contains(where: { $0 == effort }) {
                    throw BoneInferenceReasoningConfigurationError.unsupportedEffort
                }
                if let budget = requested.budgetTokens,
                   let options = controls.first(where: { $0.type == "budget_tokens" }),
                   (options.min.map { budget < $0 } == true || options.max.map { budget > $0 } == true) {
                    throw BoneInferenceReasoningConfigurationError.unsupportedBudget
                }
            }
        }
        if request.generationOptions.reasoning != nil {
            _ = try fields(request: request, profile: profile, wire: wire,
                           forcedTool: wire == .anthropic && request.responseFormat.isStructured)
        }
        return result
    }

    private static func requestWire(_ wire: Wire) -> BoneInferenceReasoningRequestWire {
        switch wire {
        case .openAI: return .openAI
        case .anthropic: return .anthropic
        case .gemini: return .gemini
        }
    }

    static func fields(request: BoneInferenceRequest, profile: BoneInferenceReasoningProfile?,
                       wire: Wire, forcedTool: Bool = false) throws -> [String: Any] {
        guard let options = request.generationOptions.reasoning else { return [:] }
        _ = try options.validated()
        guard let profile else { throw BoneInferenceReasoningConfigurationError.missingProfile }
        try profile.validated(for: requestWire(wire))
        if let mode = options.mode, !profile.modes.contains(mode) {
            throw BoneInferenceReasoningConfigurationError.unsupportedMode
        }
        if let effort = options.effort, !profile.effortValues.contains(effort) {
            throw BoneInferenceReasoningConfigurationError.unsupportedEffort
        }
        if let budget = options.budgetTokens, profile.budgetRange?.contains(budget) != true {
            throw BoneInferenceReasoningConfigurationError.unsupportedBudget
        }
        if request.generationOptions.temperature != nil,
           options.mode != .disabled, !profile.allowsTemperature {
            throw BoneInferenceReasoningConfigurationError.temperatureUnsupported
        }
        let active = options.mode != .disabled
        switch profile.wireFormat {
        case .openAIChat:
            guard wire == .openAI else { throw BoneInferenceReasoningConfigurationError.incompatibleProtocol }
            guard options.budgetTokens == nil, options.mode != .adaptive else {
                throw BoneInferenceReasoningConfigurationError.incompatibleOptions
            }
            if options.mode == .disabled {
                guard profile.effortValues.contains("none") else { throw BoneInferenceReasoningConfigurationError.unsupportedMode }
                return ["reasoning_effort": "none"]
            }
            guard let effort = options.effort else { throw BoneInferenceReasoningConfigurationError.unsupportedEffort }
            guard options.mode != .enabled || effort != "none" else { throw BoneInferenceReasoningConfigurationError.incompatibleOptions }
            return ["reasoning_effort": effort]
        case .thinkingType:
            guard wire == .openAI else { throw BoneInferenceReasoningConfigurationError.incompatibleProtocol }
            guard options.mode != .adaptive, options.budgetTokens == nil else { throw BoneInferenceReasoningConfigurationError.incompatibleOptions }
            var fields: [String: Any] = [:]
            if let mode = options.mode { fields["thinking"] = ["type": mode.rawValue] }
            if let effort = options.effort { fields["reasoning_effort"] = effort }
            return fields
        case .enableThinking:
            guard wire == .openAI else { throw BoneInferenceReasoningConfigurationError.incompatibleProtocol }
            guard options.mode != .adaptive, options.effort == nil else { throw BoneInferenceReasoningConfigurationError.incompatibleOptions }
            var fields: [String: Any] = [:]
            if let mode = options.mode { fields["enable_thinking"] = mode == .enabled }
            if let budget = options.budgetTokens {
                guard budget >= 0 else { throw BoneInferenceReasoningConfigurationError.unsupportedBudget }
                fields["thinking_budget"] = budget
            }
            return fields
        case .anthropicBudget:
            guard wire == .anthropic else { throw BoneInferenceReasoningConfigurationError.incompatibleProtocol }
            guard options.mode != .adaptive, options.effort == nil else { throw BoneInferenceReasoningConfigurationError.incompatibleOptions }
            if !active { return ["thinking": ["type": "disabled"]] }
            guard profile.modes.contains(.enabled) else { throw BoneInferenceReasoningConfigurationError.unsupportedMode }
            guard let budget = options.budgetTokens, budget >= 1024,
                  budget < (request.generationOptions.maximumOutputTokens ?? 4096) else {
                throw BoneInferenceReasoningConfigurationError.unsupportedBudget
            }
            guard !forcedTool else { throw BoneInferenceReasoningConfigurationError.incompatibleOptions }
            return ["thinking": ["type": "enabled", "budget_tokens": budget]]
        case .anthropicAdaptive:
            guard wire == .anthropic else { throw BoneInferenceReasoningConfigurationError.incompatibleProtocol }
            guard options.budgetTokens == nil, options.mode != .enabled else { throw BoneInferenceReasoningConfigurationError.incompatibleOptions }
            if !active { return ["thinking": ["type": "disabled"]] }
            guard profile.modes.contains(.adaptive) else { throw BoneInferenceReasoningConfigurationError.unsupportedMode }
            var fields: [String: Any] = ["thinking": ["type": "adaptive"]]
            if let effort = options.effort { fields["output_config"] = ["effort": effort] }
            return fields
        case .anthropicCompatible:
            guard wire == .anthropic else { throw BoneInferenceReasoningConfigurationError.incompatibleProtocol }
            guard options.budgetTokens == nil, options.mode != .adaptive else { throw BoneInferenceReasoningConfigurationError.incompatibleOptions }
            var fields: [String: Any] = [:]
            if let mode = options.mode { fields["thinking"] = ["type": mode.rawValue] }
            if let effort = options.effort { fields["output_config"] = ["effort": effort] }
            return fields
        case .geminiBudget:
            guard wire == .gemini else { throw BoneInferenceReasoningConfigurationError.incompatibleProtocol }
            guard options.effort == nil, options.mode != .adaptive else { throw BoneInferenceReasoningConfigurationError.incompatibleOptions }
            let budget: Int
            if !active { budget = 0 }
            else if let value = options.budgetTokens { budget = value }
            else { budget = -1 }
            guard profile.budgetRange?.contains(budget) == true else { throw BoneInferenceReasoningConfigurationError.unsupportedBudget }
            guard options.mode != .enabled || budget != 0 else { throw BoneInferenceReasoningConfigurationError.incompatibleOptions }
            return ["thinkingConfig": ["thinkingBudget": budget]]
        case .geminiLevel:
            guard wire == .gemini else { throw BoneInferenceReasoningConfigurationError.incompatibleProtocol }
            guard options.budgetTokens == nil, options.mode == nil,
                  let effort = options.effort,
                  ["minimal", "low", "medium", "high"].contains(effort) else {
                throw BoneInferenceReasoningConfigurationError.incompatibleOptions
            }
            return ["thinkingConfig": ["thinkingLevel": effort.uppercased()]]
        }
    }

    static func merge(_ fields: [String: Any], into body: inout [String: Any]) throws {
        for (key, value) in fields {
            if let existing = body[key] {
                // Anthropic effort and constrained JSON schema both use output_config.
                guard key == "output_config", var object = existing as? [String: Any],
                      let addition = value as? [String: Any], Set(object.keys).isDisjoint(with: addition.keys) else {
                    throw BoneInferenceReasoningConfigurationError.incompatibleOptions
                }
                object.merge(addition) { old, _ in old }; body[key] = object
            } else { body[key] = value }
        }
    }
}
