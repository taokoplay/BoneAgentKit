import BoneAgentKit
import BoneAgentLocalRuntime
import Foundation

public struct BoneLlamaRuntimeProbeAdapter: BoneLocalRuntimeAdapterProbing, Sendable {
    public let descriptor: BoneLocalRuntimeAdapterDescriptor
    private let toolCalling: (any BoneLlamaToolCalling)?
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
        descriptor = .init(
            id: "llama.cpp",
            runtimeVersion: runtimeVersion,
            supportedFormats: [.gguf],
            runtimeConstraints: runtimeConstraints,
            maximumProbeDepth: .smoke
        )
        self.toolCalling = toolCalling
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
            try await runtime.load(
                modelURL: artifactURL,
                configuration: .init(plan: plan)
            )
            var verified: Set<BoneInferenceCapability> = []
            if depth == .smoke {
                try await runtime.smokeTest()
                verified.insert(.text)
                if model.inferenceCapabilityProfile?.capabilities.contains(.toolCalling) == true,
                   let toolCalling {
                    try await verifyToolCalling(
                        codec: toolCalling,
                        runtime: runtime,
                        modelID: model.id,
                        plan: plan
                    )
                    verified.insert(.toolCalling)
                }
            }
            await runtime.unload()
            return .init(
                check: .init(kind: kind, status: .passed),
                verifiedCapabilities: verified
            )
        } catch let error as BoneLlamaRuntimeError {
            await runtime.unload()
            return .init(check: .init(kind: kind, status: Self.status(for: error)))
        } catch {
            await runtime.unload()
            return .init(check: .init(kind: kind, status: .failed))
        }
    }

    private func verifyToolCalling(
        codec: any BoneLlamaToolCalling,
        runtime: any BoneLlamaRuntime,
        modelID: String,
        plan: BoneLocalRuntimePlan
    ) async throws {
        let tool = Self.syntheticTool
        let initial = BoneInferenceRequest(
            modelID: modelID,
            messages: [.init(role: .user, content: "Call capability_probe with value ready.")],
            availableTools: [tool],
            generationOptions: .init(temperature: 0, maximumOutputTokens: 256)
        )
        let options = try BoneLlamaGenerationOptions(
            inferenceOptions: initial.generationOptions,
            plan: plan
        )
        let first = try await runtime.generate(
            prompt: try codec.encode(request: initial),
            options: options
        )
        guard case let .assistantTurn(turn, reason, _, refusal, _) = try codec.decode(
            output: first.text,
            availableTools: [tool]
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
            availableTools: [tool],
            generationOptions: initial.generationOptions
        )
        let second = try await runtime.generate(
            prompt: try codec.encode(request: continuation),
            options: options
        )
        guard case let .finish(finish) = try codec.decode(
            output: second.text,
            availableTools: [tool]
        ), !finish.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BoneLlamaAdapterError.invalidToolCallingResponse
        }
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

    private static func status(
        for error: BoneLlamaRuntimeError
    ) -> BoneLocalRuntimeProbeCheckStatus {
        switch error {
        case .modelNotFound, .modelIncompatible:
            return .incompatible
        case .insufficientResources:
            return .temporarilyUnavailable
        case .contextCreationFailed, .tokenizationFailed, .promptTooLong,
             .generationFailed, .loadFailed, .cancelled:
            return .failed
        }
    }
}
