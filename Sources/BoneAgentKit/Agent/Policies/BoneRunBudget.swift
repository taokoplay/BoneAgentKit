import Foundation

/// 单次 Run 的操作额度与协作截止预算；wall-clock 使用单调 uptime 秒数，兼容 iOS 13。
/// 截止在操作边界检查，不强行终止 Host 代码，也不打断必要的副作用 Receipt 提交。
public struct BoneRunBudget: Codable, Equatable, Sendable {
    public let maximumInferenceCalls: Int
    public let maximumToolCalls: Int
    public let maximumInputBytes: Int
    public let maximumOutputBytes: Int
    public let maximumTurns: Int
    public let maximumWallClockSeconds: TimeInterval
    public let maximumConcurrentToolCalls: Int
    public let maximumEstimatedCostMicrounits: Int64

    public init(
        maximumInferenceCalls: Int,
        maximumToolCalls: Int,
        maximumInputBytes: Int,
        maximumOutputBytes: Int,
        maximumTurns: Int,
        maximumWallClockSeconds: TimeInterval,
        maximumConcurrentToolCalls: Int,
        maximumEstimatedCostMicrounits: Int64
    ) throws {
        guard maximumInferenceCalls > 0,
              maximumToolCalls > 0,
              maximumInputBytes >= 0,
              maximumOutputBytes >= 0,
              maximumTurns > 0,
              maximumWallClockSeconds.isFinite,
              maximumWallClockSeconds > 0,
              maximumConcurrentToolCalls > 0,
              maximumEstimatedCostMicrounits >= 0 else {
            throw BoneRunBudgetError.invalidBudget
        }
        self.maximumInferenceCalls = maximumInferenceCalls
        self.maximumToolCalls = maximumToolCalls
        self.maximumInputBytes = maximumInputBytes
        self.maximumOutputBytes = maximumOutputBytes
        self.maximumTurns = maximumTurns
        self.maximumWallClockSeconds = maximumWallClockSeconds
        self.maximumConcurrentToolCalls = maximumConcurrentToolCalls
        self.maximumEstimatedCostMicrounits = maximumEstimatedCostMicrounits
    }
}

/// 对调用方公开的稳定预算错误；只包含类别与配置上限，不含实际 payload、费用明细或时间。
public enum BoneRunBudgetError: Error, Codable, Equatable, Sendable {
    case invalidBudget
    case inferenceCallLimitReached(limit: Int)
    case toolCallLimitReached(limit: Int)
    case inputByteLimitReached(limit: Int)
    case outputByteLimitReached(limit: Int)
    case turnLimitReached(limit: Int)
    case wallClockLimitReached
    case concurrencyLimitReached(limit: Int)
    case estimatedCostLimitReached(limit: Int64)
}

/// Run 内存预算计量器。reserve 在开始下一次操作前原子检查并占用预算。
public actor BoneRunBudgetMeter {
    private let budget: BoneRunBudget
    private let startedAtUptime: TimeInterval
    private var inferenceCalls = 0
    private var toolCalls = 0
    private var inputBytes = 0
    private var outputBytes = 0
    private var turns = 0
    private var concurrentToolCalls = 0
    private var estimatedCostMicrounits: Int64 = 0

    public init(
        budget: BoneRunBudget,
        startedAtUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        self.budget = budget
        self.startedAtUptime = startedAtUptime
    }

    public func reserveInference(
        inputBytes newInputBytes: Int,
        estimatedCostMicrounits newCost: Int64,
        nowUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) throws {
        try checkWallClock(nowUptime: nowUptime)
        guard newInputBytes >= 0, newCost >= 0 else { throw BoneRunBudgetError.invalidBudget }
        guard inferenceCalls < budget.maximumInferenceCalls else {
            throw BoneRunBudgetError.inferenceCallLimitReached(limit: budget.maximumInferenceCalls)
        }
        guard adding(inputBytes, newInputBytes) <= budget.maximumInputBytes else {
            throw BoneRunBudgetError.inputByteLimitReached(limit: budget.maximumInputBytes)
        }
        guard adding(estimatedCostMicrounits, newCost) <= budget.maximumEstimatedCostMicrounits else {
            throw BoneRunBudgetError.estimatedCostLimitReached(limit: budget.maximumEstimatedCostMicrounits)
        }
        inferenceCalls += 1
        inputBytes += newInputBytes
        estimatedCostMicrounits += newCost
    }

    /// Agent 在调用引擎前原子预留轮次及推理额度；拒绝时所有计数保持不变。
    /// 已接受的尝试（包括随后抛错/取消）消耗额度，不在完成时重复计轮次。
    func reserveInferenceTurn(
        inputBytes: Int,
        estimatedCostMicrounits: Int64,
        nowUptime: TimeInterval
    ) throws {
        guard turns < budget.maximumTurns else {
            throw BoneRunBudgetError.turnLimitReached(limit: budget.maximumTurns)
        }
        try reserveInference(inputBytes: inputBytes, estimatedCostMicrounits: estimatedCostMicrounits,
            nowUptime: nowUptime)
        turns += 1
    }

    public func commitInference(outputBytes newOutputBytes: Int) throws {
        try reserveOutputBytes(newOutputBytes)
    }

    public func reserveTool(
        argumentsBytes: Int,
        nowUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) throws {
        try checkWallClock(nowUptime: nowUptime)
        guard argumentsBytes >= 0 else { throw BoneRunBudgetError.invalidBudget }
        guard toolCalls < budget.maximumToolCalls else {
            throw BoneRunBudgetError.toolCallLimitReached(limit: budget.maximumToolCalls)
        }
        guard adding(inputBytes, argumentsBytes) <= budget.maximumInputBytes else {
            throw BoneRunBudgetError.inputByteLimitReached(limit: budget.maximumInputBytes)
        }
        toolCalls += 1
        inputBytes += argumentsBytes
    }

    /// 原子预留一次 Tool 尝试的累计额度与在途槽位。失败不改变任何计数；
    /// 成功后累计调用/输入额度不退款，只有在途槽位需由调用方释放。
    func reserveToolExecution(
        argumentsBytes: Int,
        nowUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) throws {
        try checkWallClock(nowUptime: nowUptime)
        guard concurrentToolCalls < budget.maximumConcurrentToolCalls else {
            throw BoneRunBudgetError.concurrencyLimitReached(limit: budget.maximumConcurrentToolCalls)
        }
        try reserveTool(argumentsBytes: argumentsBytes, nowUptime: nowUptime)
        concurrentToolCalls += 1
    }

    public func commitTool(resultBytes: Int) throws {
        try reserveOutputBytes(resultBytes)
    }

    public func commitTurn() throws {
        guard turns < budget.maximumTurns else {
            throw BoneRunBudgetError.turnLimitReached(limit: budget.maximumTurns)
        }
        turns += 1
    }

    public func checkWallClock(
        nowUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) throws {
        guard nowUptime.isFinite,
              nowUptime >= startedAtUptime,
              nowUptime - startedAtUptime <= budget.maximumWallClockSeconds else {
            throw BoneRunBudgetError.wallClockLimitReached
        }
    }

    public func reserveConcurrentTool(
        nowUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) throws {
        try checkWallClock(nowUptime: nowUptime)
        guard concurrentToolCalls < budget.maximumConcurrentToolCalls else {
            throw BoneRunBudgetError.concurrencyLimitReached(limit: budget.maximumConcurrentToolCalls)
        }
        concurrentToolCalls += 1
    }

    public func releaseConcurrentTool() {
        concurrentToolCalls = max(0, concurrentToolCalls - 1)
    }
}

private extension BoneRunBudgetMeter {
    func reserveOutputBytes(_ newOutputBytes: Int) throws {
        guard newOutputBytes >= 0 else { throw BoneRunBudgetError.invalidBudget }
        guard adding(outputBytes, newOutputBytes) <= budget.maximumOutputBytes else {
            throw BoneRunBudgetError.outputByteLimitReached(limit: budget.maximumOutputBytes)
        }
        outputBytes += newOutputBytes
    }

    func adding<T: FixedWidthInteger>(_ lhs: T, _ rhs: T) -> T {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? T.max : value
    }
}
