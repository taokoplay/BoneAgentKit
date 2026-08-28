import Foundation

public enum BoneCrashTestBoundary: String, CaseIterable, Equatable, Sendable {
    case beforePersistenceCommit
    case afterPersistenceCommitBeforeEvent
    case afterEventBeforeNextWork
}

public struct BoneCrashTestObservation: Equatable, Sendable {
    public let boundary: BoneCrashTestBoundary
    public let crashed: Bool

    public init(boundary: BoneCrashTestBoundary, crashed: Bool) {
        self.boundary = boundary
        self.crashed = crashed
    }
}

/// 在每个显式 commit 边界注入一次进程崩溃等价点；不执行真实 exit。
public struct BoneCrashTestHarness: Sendable {
    private let boundaries: [BoneCrashTestBoundary]

    public init(boundaries: [BoneCrashTestBoundary] = BoneCrashTestBoundary.allCases) {
        self.boundaries = boundaries
    }

    public func run(
        operation: @escaping @Sendable (BoneCrashTestBoundary) async throws -> String
    ) async throws -> [BoneCrashTestObservation] {
        var observations: [BoneCrashTestObservation] = []
        for boundary in boundaries {
            _ = try await operation(boundary)
            observations.append(.init(boundary: boundary, crashed: true))
        }
        return observations
    }
}
