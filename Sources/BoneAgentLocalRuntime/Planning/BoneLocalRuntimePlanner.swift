import Foundation

public struct BoneLocalRuntimeConstraints: Equatable, Sendable {
    public let maximumContextTokens: Int
    public let maximumOutputTokens: Int
    public let maximumBatchTokens: Int
    public let maximumThreadCount: Int

    public init(
        maximumContextTokens: Int,
        maximumOutputTokens: Int,
        maximumBatchTokens: Int,
        maximumThreadCount: Int
    ) {
        self.maximumContextTokens = maximumContextTokens
        self.maximumOutputTokens = maximumOutputTokens
        self.maximumBatchTokens = maximumBatchTokens
        self.maximumThreadCount = maximumThreadCount
    }
}

public struct BoneLocalRuntimePlanRequest: Equatable, Sendable {
    public let requestedContextTokens: Int?
    public let requestedOutputTokens: Int?
    public let requestedBatchTokens: Int?
    public let requestedThreadCount: Int?
    public let hostMaximumContextTokens: Int?

    public init(
        requestedContextTokens: Int? = nil,
        requestedOutputTokens: Int? = nil,
        requestedBatchTokens: Int? = nil,
        requestedThreadCount: Int? = nil,
        hostMaximumContextTokens: Int? = nil
    ) {
        self.requestedContextTokens = requestedContextTokens
        self.requestedOutputTokens = requestedOutputTokens
        self.requestedBatchTokens = requestedBatchTokens
        self.requestedThreadCount = requestedThreadCount
        self.hostMaximumContextTokens = hostMaximumContextTokens
    }
}

public struct BoneLocalRuntimePlan: Equatable, Sendable {
    public let contextTokens: Int
    public let maximumOutputTokens: Int
    public let batchTokens: Int
    public let threadCount: Int
}

public enum BoneLocalRuntimePlanningError: Error, Equatable, Sendable {
    case invalidConstraints
    case insufficientMemory(required: UInt64, available: UInt64)
}

public enum BoneLocalRuntimePlanner {
    public static func plan(
        model: BoneLocalModelDescriptor,
        environment: BoneLocalRuntimeEnvironment,
        runtimeConstraints: BoneLocalRuntimeConstraints,
        request: BoneLocalRuntimePlanRequest = .init()
    ) throws -> BoneLocalRuntimePlan {
        guard runtimeConstraints.maximumContextTokens >= 512,
              runtimeConstraints.maximumOutputTokens > 0,
              runtimeConstraints.maximumBatchTokens > 0,
              runtimeConstraints.maximumThreadCount > 0 else {
            throw BoneLocalRuntimePlanningError.invalidConstraints
        }
        guard environment.physicalMemoryBytes >= model.minimumMemoryBytes else {
            throw BoneLocalRuntimePlanningError.insufficientMemory(
                required: model.minimumMemoryBytes,
                available: environment.physicalMemoryBytes
            )
        }

        let desiredContext = positive(request.requestedContextTokens)
            ?? model.recommendedContextTokens
        let hostLimit = positive(request.hostMaximumContextTokens) ?? Int.max
        let contextTokens = max(512, min(
            desiredContext,
            model.contextLimits.contextWindowTokens,
            runtimeConstraints.maximumContextTokens,
            hostLimit
        ))

        let modelOutput = model.contextLimits.maximumOutputTokens ?? Int.max
        let requestedOutput = positive(request.requestedOutputTokens)
            ?? runtimeConstraints.maximumOutputTokens
        let maximumOutputTokens = min(
            requestedOutput,
            runtimeConstraints.maximumOutputTokens,
            modelOutput,
            max(1, contextTokens / 2)
        )

        let conservative = environment.isLowPowerModeEnabled || environment.thermalState >= .serious
        let defaultBatch = conservative ? 128 : 256
        let defaultThreads = conservative ? 2 : max(1, environment.activeProcessorCount - 2)
        let batchTokens = min(
            positive(request.requestedBatchTokens) ?? defaultBatch,
            runtimeConstraints.maximumBatchTokens,
            contextTokens
        )
        let threadCount = min(
            positive(request.requestedThreadCount) ?? defaultThreads,
            runtimeConstraints.maximumThreadCount,
            environment.activeProcessorCount
        )

        return BoneLocalRuntimePlan(
            contextTokens: contextTokens,
            maximumOutputTokens: maximumOutputTokens,
            batchTokens: max(1, batchTokens),
            threadCount: max(1, threadCount)
        )
    }

    private static func positive(_ value: Int?) -> Int? {
        value.flatMap { $0 > 0 ? $0 : nil }
    }
}
