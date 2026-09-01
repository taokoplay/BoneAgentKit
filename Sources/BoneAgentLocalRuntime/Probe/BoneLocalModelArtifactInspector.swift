import Foundation

public struct BoneLocalModelArtifactInspection: Equatable, Sendable {
    public let artifactURL: URL?
    public let checks: [BoneLocalRuntimeProbeCheck]
}

public enum BoneLocalModelArtifactInspector {
    public static func inspect(
        model: BoneLocalModelDescriptor,
        store: BoneLocalModelStore,
        verifyChecksum: Bool
    ) -> BoneLocalModelArtifactInspection {
        let state = store.installationState(for: model, verifyChecksum: verifyChecksum)
        switch state {
        case .notInstalled:
            return .init(
                artifactURL: nil,
                checks: [.init(kind: .installation, status: .corrupted)]
            )
        case .invalid:
            return .init(
                artifactURL: nil,
                checks: [
                    .init(kind: .installation, status: .passed),
                    .init(kind: .artifactIntegrity, status: .corrupted),
                ]
            )
        case .installed(let url):
            var checks = [
                BoneLocalRuntimeProbeCheck(kind: .installation, status: .passed),
                BoneLocalRuntimeProbeCheck(kind: .artifactIntegrity, status: .passed),
            ]
            guard hasExpectedSignature(at: url, format: model.format) else {
                checks.append(.init(kind: .formatSignature, status: .corrupted))
                return .init(artifactURL: nil, checks: checks)
            }
            checks.append(.init(kind: .formatSignature, status: .passed))
            return .init(artifactURL: url, checks: checks)
        }
    }

    private static func hasExpectedSignature(at url: URL, format: BoneLocalModelFormat) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4), data.count == 4 else { return false }
        switch format {
        case .gguf:
            return data == Data("GGUF".utf8)
        }
    }
}
