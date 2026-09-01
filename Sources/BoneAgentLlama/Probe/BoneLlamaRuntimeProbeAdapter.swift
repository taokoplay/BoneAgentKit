import BoneAgentLocalRuntime
import Foundation

public struct BoneLlamaRuntimeProbeAdapter: BoneLocalRuntimeAdapterProbing, Sendable {
    public let descriptor: BoneLocalRuntimeAdapterDescriptor
    private let runtimeFactory: BoneLlamaRuntimeFactory

    public init(
        runtimeVersion: Int,
        runtimeConstraints: BoneLocalRuntimeConstraints = .init(
            maximumContextTokens: 32_768,
            maximumOutputTokens: 4_096,
            maximumBatchTokens: 512,
            maximumThreadCount: 8
        ),
        runtimeFactory: @escaping BoneLlamaRuntimeFactory
    ) {
        descriptor = .init(
            id: "llama.cpp",
            runtimeVersion: runtimeVersion,
            supportedFormats: [.gguf],
            runtimeConstraints: runtimeConstraints,
            maximumProbeDepth: .smoke
        )
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
            if depth == .smoke { try await runtime.smokeTest() }
            await runtime.unload()
            return .init(check: .init(kind: kind, status: .passed))
        } catch let error as BoneLlamaRuntimeError {
            await runtime.unload()
            return .init(check: .init(kind: kind, status: Self.status(for: error)))
        } catch {
            await runtime.unload()
            return .init(check: .init(kind: kind, status: .failed))
        }
    }

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
