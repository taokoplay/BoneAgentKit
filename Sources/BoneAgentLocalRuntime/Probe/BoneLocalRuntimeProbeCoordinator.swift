import BoneAgentKit
import Foundation

public struct BoneLocalRuntimeProbeCoordinator: Sendable {
    private let store: BoneLocalModelStore

    public init(store: BoneLocalModelStore) {
        self.store = store
    }

    public func probe(
        model: BoneLocalModelDescriptor,
        environment: BoneLocalRuntimeEnvironment,
        adapter: any BoneLocalRuntimeAdapterProbing,
        depth: BoneLocalRuntimeProbeDepth,
        verifyChecksum: Bool
    ) async -> BoneLocalRuntimeProbeReport {
        let inspection = BoneLocalModelArtifactInspector.inspect(
            model: model,
            store: store,
            verifyChecksum: verifyChecksum
        )
        var checks = inspection.checks
        guard let artifactURL = inspection.artifactURL else {
            return report(model: model, adapter: adapter, depth: depth, checks: checks)
        }

        let descriptor = adapter.descriptor
        guard descriptor.supportedFormats.contains(model.format) else {
            checks.append(.init(kind: .adapterFormatCompatibility, status: .incompatible))
            return report(model: model, adapter: adapter, depth: depth, checks: checks)
        }
        checks.append(.init(kind: .adapterFormatCompatibility, status: .passed))

        guard descriptor.runtimeVersion >= model.minimumRuntimeVersion else {
            checks.append(.init(kind: .runtimeVersion, status: .incompatible))
            return report(model: model, adapter: adapter, depth: depth, checks: checks)
        }
        checks.append(.init(kind: .runtimeVersion, status: .passed))

        guard environment.physicalMemoryBytes >= model.minimumMemoryBytes else {
            checks.append(.init(kind: .deviceMemory, status: .temporarilyUnavailable))
            return report(model: model, adapter: adapter, depth: depth, checks: checks)
        }
        checks.append(.init(kind: .deviceMemory, status: .passed))

        let plan: BoneLocalRuntimePlan
        do {
            plan = try BoneLocalRuntimePlanner.plan(
                model: model,
                environment: environment,
                runtimeConstraints: descriptor.runtimeConstraints
            )
            checks.append(.init(kind: .runtimePlan, status: .passed))
        } catch {
            checks.append(.init(kind: .runtimePlan, status: .failed))
            return report(model: model, adapter: adapter, depth: depth, checks: checks)
        }

        guard depth > .metadata else {
            return report(model: model, adapter: adapter, depth: depth, checks: checks)
        }
        guard descriptor.supports(depth) else {
            checks.append(.init(
                kind: depth == .smoke ? .smoke : .modelLoad,
                status: .unsupported
            ))
            return report(model: model, adapter: adapter, depth: depth, checks: checks)
        }

        let result = await adapter.probe(
            model: model,
            artifactURL: artifactURL,
            environment: environment,
            plan: plan,
            depth: depth
        )
        checks.append(result.check)
        return report(
            model: model,
            adapter: adapter,
            depth: depth,
            checks: checks,
            verifiedCapabilities: result.verifiedCapabilities
        )
    }

    private func report(
        model: BoneLocalModelDescriptor,
        adapter: any BoneLocalRuntimeAdapterProbing,
        depth: BoneLocalRuntimeProbeDepth,
        checks: [BoneLocalRuntimeProbeCheck],
        verifiedCapabilities: Set<BoneInferenceCapability> = []
    ) -> BoneLocalRuntimeProbeReport {
        BoneLocalRuntimeProbeReport(
            modelID: model.id,
            adapterID: adapter.descriptor.id,
            depth: depth,
            checks: checks,
            verifiedCapabilities: verifiedCapabilities
        )
    }
}
