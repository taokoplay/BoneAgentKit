import Foundation

/// 固定映射，不接受任意 body/header 注入；声明只能缩小已有能力。
enum BoneInferenceReasoningRequestSupport {
    enum Wire { case openAI, anthropic, gemini }

    private struct ResolvedOptions: Sendable {
        let mode: BoneInferenceReasoningMode
        let effort: String?
        let budgetTokens: Int?

        var isActive: Bool { mode != .disabled }
    }

    static func resolved(
        _ capabilities: Set<BoneInferenceCapability>,
        request: BoneInferenceRequest,
        metadata: BoneModelMetadata?,
        profile: BoneInferenceReasoningProfile?,
        wire: Wire
    ) throws -> Set<BoneInferenceCapability> {
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
                result.remove(.structuredOutput)
                result.remove(.constrainedOutput)
            }
            if let output = declared.modalities?.output, !output.contains("text") {
                result.remove(.text)
            }
            if declared.temperature == false, request.generationOptions.temperature != nil {
                throw BoneInferenceReasoningConfigurationError.temperatureUnsupported
            }
            if let rawOptions = request.generationOptions.reasoning,
               let options = try normalizedOptions(rawOptions, profile: profile) {
                if declared.reasoning == false {
                    throw BoneInferenceReasoningConfigurationError.unsupportedMode
                }
                if let controls = declared.reasoningOptions {
                    if let effort = options.effort,
                       let control = controls.first(where: { $0.type == "effort" }),
                       let values = control.values,
                       !values.contains(where: { $0 == effort }) {
                        throw BoneInferenceReasoningConfigurationError.unsupportedEffort
                    }
                    if let budget = options.budgetTokens,
                       let control = controls.first(where: { $0.type == "budget_tokens" }),
                       (control.min.map { budget < $0 } == true || control.max.map { budget > $0 } == true) {
                        throw BoneInferenceReasoningConfigurationError.unsupportedBudget
                    }
                }
            }
        }
        if let rawOptions = request.generationOptions.reasoning {
            _ = try rawOptions.validated()
            if try normalizedOptions(rawOptions, profile: profile) != nil {
                _ = try fields(
                    request: request,
                    profile: profile,
                    wire: wire,
                    forcedTool: wire == .anthropic && request.responseFormat.isStructured
                )
            }
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

    private static func mappedEffort(
        _ level: BoneInferenceThinkingLevel,
        profile: BoneInferenceReasoningProfile
    ) -> String? {
        profile.levelMap[level] ?? (profile.effortValues.contains(level.rawValue) ? level.rawValue : nil)
    }

    private static func clampedLevel(
        _ requested: BoneInferenceThinkingLevel,
        profile: BoneInferenceReasoningProfile
    ) throws -> BoneInferenceThinkingLevel {
        guard !profile.supportedLevels.isEmpty,
              !profile.supportedLevels.contains(requested),
              let requestedIndex = BoneInferenceThinkingLevel.allCases.firstIndex(of: requested) else {
            return requested
        }
        let levels = BoneInferenceThinkingLevel.allCases
        for index in requestedIndex..<levels.count where profile.supportedLevels.contains(levels[index]) {
            return levels[index]
        }
        for index in stride(from: requestedIndex - 1, through: 0, by: -1)
            where profile.supportedLevels.contains(levels[index]) {
            return levels[index]
        }
        throw BoneInferenceReasoningConfigurationError.unsupportedMode
    }

    private static func normalizedOptions(
        _ options: BoneInferenceReasoningOptions,
        profile: BoneInferenceReasoningProfile?
    ) throws -> ResolvedOptions? {
        switch options.selection {
        case .providerDefault:
            return nil
        case .disabled:
            return .init(mode: .disabled, effort: nil, budgetTokens: nil)
        case .level(let requestedLevel):
            guard let profile else { throw BoneInferenceReasoningConfigurationError.missingProfile }
            let level = try clampedLevel(requestedLevel, profile: profile)
            if level == .off {
                return .init(mode: .disabled, effort: nil, budgetTokens: nil)
            }
            switch profile.wireFormat {
            case .anthropicBudget, .enableThinking, .geminiBudget:
                guard let budget = profile.budgetByLevel[level] else {
                    throw BoneInferenceReasoningConfigurationError.unsupportedBudget
                }
                return .init(mode: .enabled, effort: nil, budgetTokens: budget)
            case .anthropicAdaptive:
                guard let effort = mappedEffort(level, profile: profile) else {
                    throw BoneInferenceReasoningConfigurationError.unsupportedEffort
                }
                return .init(mode: .adaptive, effort: effort, budgetTokens: nil)
            case .geminiLevel:
                guard let effort = mappedEffort(level, profile: profile) else {
                    throw BoneInferenceReasoningConfigurationError.unsupportedEffort
                }
                return .init(mode: .enabled, effort: effort, budgetTokens: nil)
            case .openAIChat, .thinkingType, .anthropicCompatible:
                guard let effort = mappedEffort(level, profile: profile) else {
                    throw BoneInferenceReasoningConfigurationError.unsupportedEffort
                }
                return .init(mode: .enabled, effort: effort, budgetTokens: nil)
            }
        }
    }

    static func fields(
        request: BoneInferenceRequest,
        profile: BoneInferenceReasoningProfile?,
        wire: Wire,
        forcedTool: Bool = false
    ) throws -> [String: Any] {
        guard let rawOptions = request.generationOptions.reasoning else { return [:] }
        _ = try rawOptions.validated()
        guard let options = try normalizedOptions(rawOptions, profile: profile) else { return [:] }
        guard let profile else {
            // Anthropic 兼容入口可以在无模型 profile 时明确关闭思考；开启/自适应仍必须有 Host 验证的 profile。
            guard options.mode == .disabled, wire == .anthropic else {
                throw BoneInferenceReasoningConfigurationError.missingProfile
            }
            return ["thinking": ["type": "disabled"]]
        }
        try profile.validated(for: requestWire(wire))
        guard profile.modes.contains(options.mode) else {
            throw BoneInferenceReasoningConfigurationError.unsupportedMode
        }
        if let effort = options.effort, !profile.effortValues.contains(effort) {
            throw BoneInferenceReasoningConfigurationError.unsupportedEffort
        }
        if let budget = options.budgetTokens, profile.budgetRange?.contains(budget) != true {
            throw BoneInferenceReasoningConfigurationError.unsupportedBudget
        }
        if request.generationOptions.temperature != nil,
           options.isActive, !profile.allowsTemperature {
            throw BoneInferenceReasoningConfigurationError.temperatureUnsupported
        }
        switch profile.wireFormat {
        case .openAIChat:
            guard wire == .openAI, options.budgetTokens == nil, options.mode != .adaptive else {
                throw BoneInferenceReasoningConfigurationError.incompatibleProtocol
            }
            if options.mode == .disabled {
                guard profile.effortValues.contains("none") else {
                    throw BoneInferenceReasoningConfigurationError.unsupportedMode
                }
                return ["reasoning_effort": "none"]
            }
            guard let effort = options.effort else {
                throw BoneInferenceReasoningConfigurationError.unsupportedEffort
            }
            guard effort != "none" else {
                throw BoneInferenceReasoningConfigurationError.incompatibleOptions
            }
            return ["reasoning_effort": effort]
        case .thinkingType:
            guard wire == .openAI, options.mode != .adaptive, options.budgetTokens == nil else {
                throw BoneInferenceReasoningConfigurationError.incompatibleProtocol
            }
            var fields: [String: Any] = ["thinking": ["type": options.mode.rawValue]]
            if let effort = options.effort { fields["reasoning_effort"] = effort }
            return fields
        case .enableThinking:
            guard wire == .openAI, options.mode != .adaptive, options.effort == nil else {
                throw BoneInferenceReasoningConfigurationError.incompatibleProtocol
            }
            var fields: [String: Any] = ["enable_thinking": options.isActive]
            if let budget = options.budgetTokens {
                guard budget >= 0 else { throw BoneInferenceReasoningConfigurationError.unsupportedBudget }
                fields["thinking_budget"] = budget
            }
            return fields
        case .anthropicBudget:
            guard wire == .anthropic, options.mode != .adaptive, options.effort == nil else {
                throw BoneInferenceReasoningConfigurationError.incompatibleProtocol
            }
            if !options.isActive { return ["thinking": ["type": "disabled"]] }
            guard let budget = options.budgetTokens, budget >= 1024,
                  budget < (request.generationOptions.maximumOutputTokens ?? 4096) else {
                throw BoneInferenceReasoningConfigurationError.unsupportedBudget
            }
            guard !forcedTool else { throw BoneInferenceReasoningConfigurationError.incompatibleOptions }
            return ["thinking": ["type": "enabled", "budget_tokens": budget]]
        case .anthropicAdaptive:
            guard wire == .anthropic, options.budgetTokens == nil, options.mode != .enabled else {
                throw BoneInferenceReasoningConfigurationError.incompatibleProtocol
            }
            if !options.isActive { return ["thinking": ["type": "disabled"]] }
            var fields: [String: Any] = ["thinking": ["type": "adaptive"]]
            if let effort = options.effort { fields["output_config"] = ["effort": effort] }
            return fields
        case .anthropicCompatible:
            guard wire == .anthropic, options.budgetTokens == nil, options.mode != .adaptive else {
                throw BoneInferenceReasoningConfigurationError.incompatibleProtocol
            }
            var fields: [String: Any] = ["thinking": ["type": options.mode.rawValue]]
            if let effort = options.effort { fields["output_config"] = ["effort": effort] }
            return fields
        case .geminiBudget:
            guard wire == .gemini, options.effort == nil, options.mode != .adaptive else {
                throw BoneInferenceReasoningConfigurationError.incompatibleProtocol
            }
            let budget = options.isActive ? (options.budgetTokens ?? -1) : 0
            return ["thinkingConfig": ["thinkingBudget": budget]]
        case .geminiLevel:
            guard wire == .gemini, options.budgetTokens == nil,
                  let effort = options.effort,
                  ["minimal", "low", "medium", "high"].contains(effort) else {
                throw BoneInferenceReasoningConfigurationError.incompatibleProtocol
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
                object.merge(addition) { old, _ in old }
                body[key] = object
            } else {
                body[key] = value
            }
        }
    }
}
