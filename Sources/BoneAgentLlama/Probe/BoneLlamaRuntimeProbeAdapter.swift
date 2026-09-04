import BoneAgentKit
import BoneAgentLocalRuntime
import Foundation

public struct BoneLlamaRuntimeProbeAdapter: BoneLocalRuntimeAdapterProbing, Sendable {
    public let descriptor: BoneLocalRuntimeAdapterDescriptor
    private let legacyToolCalling: (any BoneLlamaToolCalling)?
    private let conversationRenderer: (any BoneLlamaConversationRendering)?
    private let toolEnvelope: (any BoneLlamaToolEnvelopeCoding)?
    private let runtimeFactory: BoneLlamaRuntimeFactory

    public init(
        runtimeVersion: Int,
        runtimeConstraints: BoneLocalRuntimeConstraints = .init(
            maximumContextTokens: 32_768,
            maximumOutputTokens: 4_096,
            maximumBatchTokens: 512,
            maximumThreadCount: 8
        ),
        toolCalling: (any BoneLlamaToolCalling)? = nil,
        runtimeFactory: @escaping BoneLlamaRuntimeFactory
    ) {
        descriptor = Self.descriptor(runtimeVersion, runtimeConstraints)
        legacyToolCalling = toolCalling
        conversationRenderer = nil
        toolEnvelope = nil
        self.runtimeFactory = runtimeFactory
    }

    public init(
        runtimeVersion: Int,
        runtimeConstraints: BoneLocalRuntimeConstraints = .init(
            maximumContextTokens: 32_768,
            maximumOutputTokens: 4_096,
            maximumBatchTokens: 512,
            maximumThreadCount: 8
        ),
        conversationRenderer: any BoneLlamaConversationRendering,
        toolEnvelope: (any BoneLlamaToolEnvelopeCoding)? = nil,
        runtimeFactory: @escaping BoneLlamaRuntimeFactory
    ) {
        descriptor = Self.descriptor(runtimeVersion, runtimeConstraints)
        legacyToolCalling = nil
        self.conversationRenderer = conversationRenderer
        self.toolEnvelope = toolEnvelope
        self.runtimeFactory = runtimeFactory
    }

    public func probe(
        model: BoneLocalModelDescriptor,
        artifactURL: URL,
        environment: BoneLocalRuntimeEnvironment,
        plan: BoneLocalRuntimePlan,
        depth: BoneLocalRuntimeProbeDepth
    ) async -> BoneLocalRuntimeAdapterProbeResult {
        let kind: BoneLocalRuntimeProbeCheckKind = depth == .smoke ? .smoke : .modelLoad
        let runtime = runtimeFactory()
        do {
            try await runtime.load(modelURL: artifactURL, configuration: .init(plan: plan))
            var verified: Set<BoneInferenceCapability> = []
            var identity: BoneCapabilityVerificationIdentity?
            if depth == .smoke {
                try await runtime.smokeTest()
                verified.insert(.text)
                if model.inferenceCapabilityProfile?.capabilities.contains(.toolCalling) == true {
                    if let renderer = conversationRenderer, let envelope = toolEnvelope {
                        let constrained = try await verifyCanonicalToolCalling(
                            renderer: renderer,
                            envelope: envelope,
                            runtime: runtime,
                            modelID: model.id,
                            plan: plan
                        )
                        verified.insert(.toolCalling)
                        if constrained { verified.insert(.constrainedOutput) }
                        identity = try await verificationIdentity(
                            model: model,
                            renderer: renderer,
                            envelope: envelope,
                            runtime: runtime,
                            plan: plan
                        )
                    } else if let legacyToolCalling {
                        try await verifyLegacyToolCalling(
                            codec: legacyToolCalling,
                            runtime: runtime,
                            modelID: model.id,
                            plan: plan
                        )
                        verified.insert(.toolCalling)
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

    private func verificationIdentity(
        model: BoneLocalModelDescriptor,
        renderer: any BoneLlamaConversationRendering,
        envelope: any BoneLlamaToolEnvelopeCoding,
        runtime: any BoneLlamaRuntime,
        plan: BoneLocalRuntimePlan
    ) async throws -> BoneCapabilityVerificationIdentity {
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
        if let constraint {
            compiledDigest = try BoneLlamaGBNFCompiler().compile(constraint).sourceDigest
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
            constraintDecoderID: components.constraintDecoderID,
            constraintDecoderVersion: components.constraintDecoderVersion,
            contextTokens: plan.contextTokens,
            batchTokens: plan.batchTokens,
            addGenerationPrompt: rendered.templateIdentity.addGenerationPrompt,
            maximumOutputTokens: min(256, plan.maximumOutputTokens),
            constraintCompilerID: compiledDigest == nil ? nil : BoneLlamaGBNFCompiler().identity.id,
            constraintCompilerVersion: compiledDigest == nil ? nil : BoneLlamaGBNFCompiler().identity.version,
            constraintDialect: compiledDigest == nil ? nil : BoneLlamaGBNFCompiler().identity.dialect,
            schemaCanonicalFormatVersion: compiledDigest == nil ? nil : BoneToolSchemaCanonicalEncoder.formatVersion,
            controlCanonicalFormatVersion: compiledDigest == nil ? nil : BoneLlamaGenerationControlCanonicalizer.formatVersion,
            compiledConstraintDigest: compiledDigest,
            grammarRuntimeID: compiledDigest == nil ? nil : components.grammarRuntimeID,
            grammarRuntimeVersion: compiledDigest == nil ? nil : components.grammarRuntimeVersion,
            stopMatcherID: compiledDigest == nil ? nil : "bone.utf8-stop",
            stopMatcherVersion: compiledDigest == nil ? nil : "1",
            terminationContractVersion: compiledDigest == nil ? nil : 1
        )
    }

    private func verifyLegacyToolCalling(
        codec: any BoneLlamaToolCalling,
        runtime: any BoneLlamaRuntime,
        modelID: String,
        plan: BoneLocalRuntimePlan
    ) async throws {
        let initial = BoneInferenceRequest(
            modelID: modelID,
            messages: [.init(role: .user, content: "Call capability_probe with value ready.")],
            availableTools: [Self.syntheticTool],
            generationOptions: .init(temperature: 0, maximumOutputTokens: 256)
        )
        let options = try BoneLlamaGenerationOptions(inferenceOptions: initial.generationOptions, plan: plan)
        let first = try await legacyGenerate(prompt: codec.encode(request: initial), options: options, runtime: runtime, plan: plan)
        guard case let .assistantTurn(turn, reason, _, refusal, _) = try codec.decode(
            output: first.text, availableTools: [Self.syntheticTool]
        ), reason == .toolCalls, refusal == nil, turn.toolCalls.count == 1,
              let call = turn.toolCalls.first else {
            throw BoneLlamaAdapterError.invalidToolCallingResponse
        }
        let result = try BoneInferenceToolResult(
            callID: call.id, toolID: call.toolID, content: .text("ready"), isError: false, ordinal: 0
        )
        let continuation = BoneInferenceRequest(
            modelID: modelID,
            messages: initial.messages + [.assistant(turn), .toolResults(try .init(results: [result]))],
            availableTools: [Self.syntheticTool],
            generationOptions: initial.generationOptions
        )
        let second = try await legacyGenerate(prompt: codec.encode(request: continuation), options: options, runtime: runtime, plan: plan)
        guard case let .finish(finish) = try codec.decode(output: second.text, availableTools: [Self.syntheticTool]),
              !finish.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BoneLlamaAdapterError.invalidToolCallingResponse
        }
    }

    private func legacyGenerate(
        prompt: String,
        options: BoneLlamaGenerationOptions,
        runtime: any BoneLlamaRuntime,
        plan: BoneLocalRuntimePlan
    ) async throws -> BoneLlamaGenerationResult {
        let executionPlan = try BoneLlamaPromptExecutionPlanner.plan(
            tokenization: try await runtime.tokenize(prompt: prompt),
            configuration: .init(plan: plan),
            requestedMaximumOutputTokens: options.maximumOutputTokens
        )
        return try await runtime.generate(
            prompt: prompt,
            executionPlan: executionPlan,
            options: try .init(
                maximumOutputTokens: executionPlan.maximumOutputTokens,
                temperature: options.temperature
            )
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
    ) -> BoneLocalRuntimeAdapterDescriptor {
        .init(
            id: "llama.cpp",
            runtimeVersion: version,
            supportedFormats: [.gguf],
            runtimeConstraints: constraints,
            maximumProbeDepth: .smoke
        )
    }

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
