import BoneAgentKit
import BoneAgentLocalModels
import Foundation

public struct BoneLlamaRuntimeProbeAdapter: BoneLocalModelBackendProbing, Sendable {
    public let descriptor: BoneLocalModelBackendDescriptor
    private let conversationRenderer: (any BoneLlamaConversationRendering)?
    private let toolEnvelope: (any BoneLlamaToolEnvelopeCoding)?
    private let constraintCompiler: (any BoneLlamaConstraintCompiling)?
    private let runtimeFactory: BoneLlamaRuntimeFactory

    public init(
        runtimeVersion: Int,
        runtimeConstraints: BoneLocalRuntimeConstraints = .init(
            maximumContextTokens: 32_768,
            maximumOutputTokens: 4_096,
            maximumBatchTokens: 512,
            maximumThreadCount: 8
        ),
        conversationRenderer: any BoneLlamaConversationRendering = BoneLlamaChatMLConversationRenderer(),
        toolEnvelope: (any BoneLlamaToolEnvelopeCoding)? = nil,
        constraintCompiler: (any BoneLlamaConstraintCompiling)? = BoneLlamaGBNFCompiler(),
        runtimeFactory: @escaping BoneLlamaRuntimeFactory
    ) {
        descriptor = Self.descriptor(runtimeVersion, runtimeConstraints)
        self.conversationRenderer = conversationRenderer
        self.toolEnvelope = toolEnvelope
        self.constraintCompiler = constraintCompiler
        self.runtimeFactory = runtimeFactory
    }

    public func probe(
        model: BoneLocalModelDescriptor,
        artifactURL: URL,
        environment: BoneLocalRuntimeEnvironment,
        plan: BoneLocalRuntimePlan,
        depth: BoneLocalRuntimeProbeDepth
    ) async -> BoneLocalModelBackendProbeResult {
        let kind: BoneLocalRuntimeProbeCheckKind = depth == .smoke ? .smoke : .modelLoad
        let runtime = runtimeFactory()
        do {
            try await runtime.load(modelURL: artifactURL, configuration: .init(plan: plan))
            var verified: Set<BoneInferenceCapability> = []
            var identity: BoneLocalExecutionVerificationIdentity?
            if depth == .smoke {
                try await runtime.verifyBasicGeneration()
                verified.insert(.text)
                if model.inferenceCapabilityProfile?.capabilities.contains(.toolCalling) == true {
                    if let renderer = conversationRenderer, let envelope = toolEnvelope {
                        let identityBeforeSmoke = try await verificationIdentity(
                            model: model,
                            renderer: renderer,
                            envelope: envelope,
                            runtime: runtime,
                            plan: plan
                        )
                        let constrained = try await verifyCanonicalToolCalling(
                            renderer: renderer,
                            envelope: envelope,
                            runtime: runtime,
                            modelID: model.id,
                            plan: plan
                        )
                        verified.insert(.toolCalling)
                        if constrained {
                            try await verifyDirectConstraints(
                                renderer: renderer,
                                runtime: runtime,
                                modelID: model.id,
                                plan: plan
                            )
                            verified.insert(.constrainedOutput)
                        }
                        let identityAfterSmoke = try await verificationIdentity(
                            model: model,
                            renderer: renderer,
                            envelope: envelope,
                            runtime: runtime,
                            plan: plan
                        )
                        guard identityBeforeSmoke == identityAfterSmoke else {
                            throw BoneLlamaAdapterError.invalidConfiguration
                        }
                        identity = identityAfterSmoke
                    }
                }
            }
            await runtime.unload()
            return .init(
                check: .init(kind: kind, status: .passed),
                verifiedCapabilities: verified,
                verificationIdentity: identity
            )
        } catch let error as BoneLlamaRuntimeError {
            await runtime.unload()
            return .init(check: .init(kind: kind, status: Self.status(for: error)))
        } catch {
            await runtime.unload()
            return .init(check: .init(kind: kind, status: .failed))
        }
    }

    private func verifyCanonicalToolCalling(
        renderer: any BoneLlamaConversationRendering,
        envelope: any BoneLlamaToolEnvelopeCoding,
        runtime: any BoneLlamaRuntime,
        modelID: String,
        plan: BoneLocalRuntimePlan
    ) async throws -> Bool {
        let initial = BoneInferenceRequest(
            modelID: modelID,
            messages: [.init(role: .user, content: "Call capability_probe with value ready.")],
            availableTools: [Self.syntheticTool],
            generationOptions: .init(temperature: 0, maximumOutputTokens: 256)
        )
        let first = try await canonicalGenerate(
            request: initial,
            renderer: renderer,
            envelope: envelope,
            runtime: runtime,
            plan: plan
        )
        try BoneLlamaTerminationValidator.validate(
            first.result.termination,
            control: first.control,
            requiresCompleteOutput: true
        )
        guard case let .assistantTurn(turn, reason, _, refusal, _) = try envelope.decode(
                  output: first.result.text,
                  availableTools: [Self.syntheticTool]
              ), reason == .toolCalls, refusal == nil, turn.toolCalls.count == 1,
              let call = turn.toolCalls.first else {
            throw BoneLlamaAdapterError.invalidToolCallingResponse
        }
        let result = try BoneInferenceToolResult(
            callID: call.id,
            toolID: call.toolID,
            content: .text("ready"),
            isError: false,
            ordinal: 0
        )
        let continuation = BoneInferenceRequest(
            modelID: modelID,
            messages: initial.messages + [
                .assistant(turn),
                .toolResults(try .init(results: [result])),
            ],
            availableTools: [Self.syntheticTool],
            generationOptions: initial.generationOptions
        )
        let second = try await canonicalGenerate(
            request: continuation,
            renderer: renderer,
            envelope: envelope,
            runtime: runtime,
            plan: plan
        )
        try BoneLlamaTerminationValidator.validate(
            second.result.termination,
            control: second.control,
            requiresCompleteOutput: true
        )
        guard case let .finish(finish) = try envelope.decode(
                  output: second.result.text,
                  availableTools: [Self.syntheticTool]
              ), !finish.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !Self.containsReasoningMarker(finish.text) else {
            throw BoneLlamaAdapterError.invalidToolCallingResponse
        }
        return try envelope.generationConstraint(tools: [Self.syntheticTool]) != nil
    }

    private func canonicalGenerate(
        request: BoneInferenceRequest,
        renderer: any BoneLlamaConversationRendering,
        envelope: any BoneLlamaToolEnvelopeCoding,
        runtime: any BoneLlamaRuntime,
        plan: BoneLocalRuntimePlan
    ) async throws -> (
        result: BoneLlamaGenerationResult,
        control: BoneLlamaGenerationControl
    ) {
        let conversation = try BoneLlamaConversationBuilder.build(
            request: request,
            toolEnvelope: envelope
        )
        let rendered = try await renderer.render(conversation: conversation, using: runtime)
        let envelopeConstraint = try envelope.generationConstraint(tools: request.availableTools)
        guard rendered.generationControl.constraint == nil || envelopeConstraint == nil else {
            throw BoneLlamaAdapterError.invalidGenerationControl
        }
        let control = try BoneLlamaGenerationControl(
            stopTokenIDs: rendered.generationControl.stopTokenIDs,
            stopStrings: rendered.generationControl.stopStrings,
            constraint: rendered.generationControl.constraint ?? envelopeConstraint
        )
        let options = try BoneLlamaGenerationOptions(
            inferenceOptions: request.generationOptions,
            plan: plan
        )
        let executionPlan = try BoneLlamaPromptExecutionPlanner.plan(
            tokenization: try await runtime.tokenize(prompt: rendered.prompt),
            configuration: .init(plan: plan),
            requestedMaximumOutputTokens: options.maximumOutputTokens
        )
        let effectiveOptions = try BoneLlamaGenerationOptions(
            maximumOutputTokens: executionPlan.maximumOutputTokens,
            temperature: options.temperature
        )
        if control.constraint != nil {
            guard let compiled = runtime as? any BoneLlamaConstraintGenerationRuntime else {
                throw BoneLlamaAdapterError.unsupportedGenerationControl
            }
            let result = try await compiled.generate(
                prompt: rendered.prompt,
                executionPlan: executionPlan,
                options: effectiveOptions,
                control: try BoneLlamaResolvedGenerationControl(
                    control: control,
                    compiler: constraintCompiler
                )
            )
            return (result, control)
        }
        if control.requiresControlledRuntime {
            guard let controlled = runtime as? any BoneLlamaControlledGenerationRuntime else {
                throw BoneLlamaAdapterError.unsupportedGenerationControl
            }
            let result = try await controlled.generate(
                prompt: rendered.prompt,
                executionPlan: executionPlan,
                options: effectiveOptions,
                control: control
            )
            return (result, control)
        }
        let result = try await runtime.generate(
            prompt: rendered.prompt,
            executionPlan: executionPlan,
            options: effectiveOptions
        )
        return (result, control)
    }

    private func verifyDirectConstraints(
        renderer: any BoneLlamaConversationRendering,
        runtime: any BoneLlamaRuntime,
        modelID: String,
        plan: BoneLocalRuntimePlan
    ) async throws {
        let enumConstraint = BoneLlamaGenerationConstraint.enumChoice(["ready", "not-ready"])
        let enumResult = try await directConstraintGenerate(
            constraint: enumConstraint,
            prompt: "Return exactly ready. Output no other text.",
            renderer: renderer,
            runtime: runtime,
            modelID: modelID,
            plan: plan
        )
        try BoneLlamaTerminationValidator.validate(
            enumResult.termination,
            control: try .init(constraint: enumConstraint),
            requiresCompleteOutput: true
        )
        guard enumResult.text == "ready" else {
            throw BoneLlamaAdapterError.invalidToolCallingResponse
        }

        let schema = BoneToolSchema.object(
            properties: ["ok": .boolean],
            required: ["ok"],
            additionalProperties: false
        )
        let schemaConstraint = BoneLlamaGenerationConstraint.jsonSchema(schema)
        let schemaResult = try await directConstraintGenerate(
            constraint: schemaConstraint,
            prompt: "Return a JSON object with ok set to true. Output no other text.",
            renderer: renderer,
            runtime: runtime,
            modelID: modelID,
            plan: plan
        )
        try BoneLlamaTerminationValidator.validate(
            schemaResult.termination,
            control: try .init(constraint: schemaConstraint),
            requiresCompleteOutput: true
        )
        do {
            let data = Data(schemaResult.text.utf8)
            try BoneToolSchemaValidator.validate(arguments: data, against: schema)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object.count == 1,
                  object["ok"] as? Bool == true else {
                throw BoneLlamaAdapterError.invalidToolCallingResponse
            }
        } catch {
            throw BoneLlamaAdapterError.invalidToolCallingResponse
        }
    }

    private func directConstraintGenerate(
        constraint: BoneLlamaGenerationConstraint,
        prompt: String,
        renderer: any BoneLlamaConversationRendering,
        runtime: any BoneLlamaRuntime,
        modelID: String,
        plan: BoneLocalRuntimePlan
    ) async throws -> BoneLlamaGenerationResult {
        guard let compiledRuntime = runtime as? any BoneLlamaConstraintGenerationRuntime else {
            throw BoneLlamaAdapterError.unsupportedGenerationControl
        }
        let conversation = try BoneLlamaConversationBuilder.build(request: .init(
            modelID: modelID,
            messages: [.init(role: .user, content: prompt)]
        ))
        let rendered = try await renderer.render(conversation: conversation, using: runtime)
        guard rendered.generationControl.constraint == nil else {
            throw BoneLlamaAdapterError.invalidGenerationControl
        }
        let control = try BoneLlamaGenerationControl(
            stopTokenIDs: rendered.generationControl.stopTokenIDs,
            stopStrings: rendered.generationControl.stopStrings,
            constraint: constraint
        )
        let options = try BoneLlamaGenerationOptions(maximumOutputTokens: min(256, plan.maximumOutputTokens), temperature: 0)
        let executionPlan = try BoneLlamaPromptExecutionPlanner.plan(
            tokenization: try await runtime.tokenize(prompt: rendered.prompt),
            configuration: .init(plan: plan),
            requestedMaximumOutputTokens: options.maximumOutputTokens
        )
        return try await compiledRuntime.generate(
            prompt: rendered.prompt,
            executionPlan: executionPlan,
            options: try .init(maximumOutputTokens: executionPlan.maximumOutputTokens, temperature: 0),
            control: try .init(control: control, compiler: constraintCompiler)
        )
    }

    private func verificationIdentity(
        model: BoneLocalModelDescriptor,
        renderer: any BoneLlamaConversationRendering,
        envelope: any BoneLlamaToolEnvelopeCoding,
        runtime: any BoneLlamaRuntime,
        plan: BoneLocalRuntimePlan
    ) async throws -> BoneLocalExecutionVerificationIdentity {
        guard let identifying = runtime as? any BoneLlamaRuntimeVerificationIdentifying else {
            throw BoneLlamaAdapterError.invalidConfiguration
        }
        let components = try await identifying.verificationComponents()
        let sample = try BoneLlamaConversation(messages: [
            try .init(role: .user, content: "verification")
        ])
        let rendered = try await renderer.render(conversation: sample, using: runtime)
        let constraint = try envelope.generationConstraint(tools: [Self.syntheticTool])
        let compiledDigest: String?
        if let constraint, let constraintCompiler {
            compiledDigest = try constraintCompiler.compile(constraint).sourceDigest
        } else {
            compiledDigest = nil
        }
        return try .init(
            artifactSHA256: model.artifact.sha256,
            runtimeID: descriptor.id,
            runtimeVersion: runtime.runtimeVersion,
            tokenizerID: components.tokenizerID,
            tokenizerVersion: components.tokenizerVersion,
            templateDigest: rendered.templateIdentity.templateDigest,
            rendererID: rendered.templateIdentity.rendererID,
            rendererVersion: rendered.templateIdentity.rendererVersion,
            reasoningMode: rendered.templateIdentity.reasoningMode.rawValue,
            generationControlDigest: try Self.controlDigest(rendered.generationControl, constraint),
            toolEnvelopeID: envelope.identity.id,
            toolEnvelopeVersion: envelope.identity.version,
            grammarParserID: components.grammarParserID,
            grammarParserVersion: components.grammarParserVersion,
            contextTokens: plan.contextTokens,
            batchTokens: plan.batchTokens,
            addGenerationPrompt: rendered.templateIdentity.addGenerationPrompt,
            maximumOutputTokens: min(256, plan.maximumOutputTokens),
            constraintCompilerID: compiledDigest == nil ? nil : constraintCompiler?.identity.id,
            constraintCompilerVersion: compiledDigest == nil ? nil : constraintCompiler?.identity.version,
            constraintDialect: compiledDigest == nil ? nil : constraintCompiler?.identity.dialect,
            schemaCanonicalFormatVersion: compiledDigest == nil ? nil : BoneToolSchemaCanonicalEncoder.formatVersion,
            controlCanonicalFormatVersion: compiledDigest == nil ? nil : BoneLlamaGenerationControlCanonicalizer.formatVersion,
            compiledConstraintDigest: compiledDigest,
            grammarSamplerID: compiledDigest == nil ? nil : components.grammarSamplerID,
            grammarSamplerVersion: compiledDigest == nil ? nil : components.grammarSamplerVersion,
            stopMatcherID: compiledDigest == nil ? nil : components.stopMatcherID,
            stopMatcherVersion: compiledDigest == nil ? nil : components.stopMatcherVersion,
            terminationContractVersion: compiledDigest == nil ? nil : 1,
            probeProtocolVersion: Self.probeProtocolVersion
        )
    }

    private static func containsReasoningMarker(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower.contains("<think>") || lower.contains("</think>")
    }

    private static func controlDigest(
        _ control: BoneLlamaGenerationControl,
        _ constraint: BoneLlamaGenerationConstraint?
    ) throws -> String {
        let effective = try BoneLlamaGenerationControl(
            stopTokenIDs: control.stopTokenIDs,
            stopStrings: control.stopStrings,
            constraint: constraint ?? control.constraint
        )
        return try BoneLlamaGenerationControlCanonicalizer.digest(effective)
    }

    private static func descriptor(
        _ version: Int,
        _ constraints: BoneLocalRuntimeConstraints
    ) -> BoneLocalModelBackendDescriptor {
        .init(
            id: "llama.cpp",
            runtimeVersion: version,
            supportedFormats: [.gguf],
            runtimeConstraints: constraints,
            maximumProbeDepth: .smoke
        )
    }

    /// 任何会影响 Smoke 输入或成功判定的语义变化都必须递增，使历史身份自动失效。
    public static let probeProtocolVersion = 2

    private static let syntheticTool = BoneAgentToolDefinition(
        id: "bone.capability-probe",
        version: "1",
        title: "Capability Probe",
        summary: "Return a synthetic value without external side effects.",
        wireName: "capability_probe",
        schemaVersion: 1,
        inputSchema: .object(
            properties: [
                "value": .string(enumValues: ["ready"], minimumLength: nil, maximumLength: nil),
            ],
            required: ["value"],
            additionalProperties: false
        )
    )

    private static func status(for error: BoneLlamaRuntimeError) -> BoneLocalRuntimeProbeCheckStatus {
        switch error {
        case .modelNotFound, .modelIncompatible: return .incompatible
        case .insufficientResources: return .temporarilyUnavailable
        case .contextCreationFailed, .tokenizationFailed, .promptTooLong,
             .nativeTemplateUnavailable, .generationFailed, .loadFailed, .cancelled:
            return .failed
        }
    }
}
