import Foundation

/// Tool 对调度器声明的执行安全性。未声明时一律串行。
public enum BoneToolExecutionPolicy: Codable, Equatable, Sendable {
    case serial
    case parallelSafe(resourceKeys: Set<String>)

    public static func parallelSafe(resourceKeys: [String]) -> Self {
        .parallelSafe(resourceKeys: Set(resourceKeys))
    }
}

/// Host 对同轮 Tool Calls 的调度选择；并发必须显式开启且有固定上限。
public enum BoneToolSchedulingMode: Codable, Equatable, Sendable {
    case serial
    case boundedParallel(maximumConcurrency: Int)
}

/// Tool 失败后的同轮行为。默认 fail-fast；collect-all 只回传固定安全错误分类。
public enum BoneToolFailureStrategy: String, Codable, Equatable, Sendable {
    case failFast
    case collectAll
}

public enum BoneToolSchedulerError: Error, Equatable, Sendable {
    case invalidConcurrencyLimit
    case invalidCallOrder
    case duplicateToolDefinition
    case missingToolDefinition
}
