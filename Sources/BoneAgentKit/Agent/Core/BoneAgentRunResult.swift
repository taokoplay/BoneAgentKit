import Foundation

/// 一次成功 Agent Run 的强类型输出。
public enum BoneAgentRunOutput: Codable, Equatable, Sendable {
    case text(String)
    case structured(Data)
}

/// 单次 Agent Run 可选择的通用停止边界。
public enum BoneAgentRunBoundary: Codable, Equatable, Sendable {
    /// 保持传统自治 Loop 语义，持续运行直到模型产生正式输出。
    case untilModelFinish
    /// 执行完首个完整 Tool Turn 后由 Host 接管，不再发起下一次推理。
    case afterFirstToolTurn
}

/// 到达指定运行边界时的强类型完成形态。
public enum BoneAgentBoundaryCompletion: Codable, Equatable, Sendable {
    case modelFinished(BoneAgentRunOutput)
    case toolTurnCompleted
}

/// 不改变传统 Run 输出契约的边界运行结果。
public struct BoneAgentBoundaryResult: Codable, Equatable, Sendable {
    public let completion: BoneAgentBoundaryCompletion
    public let steps: Int

    public init(completion: BoneAgentBoundaryCompletion, steps: Int) {
        self.completion = completion
        self.steps = steps
    }
}

/// 一次成功 Agent Run 的最小结果。
public struct BoneAgentRunResult: Codable, Equatable, Sendable {
    public let output: BoneAgentRunOutput
    public let steps: Int

    public init(output: BoneAgentRunOutput, steps: Int) {
        self.output = output
        self.steps = steps
    }
}
