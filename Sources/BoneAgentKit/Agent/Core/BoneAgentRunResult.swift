import Foundation

/// 一次成功 Agent Run 的强类型输出。
public enum BoneAgentRunOutput: Codable, Equatable, Sendable {
    case text(String)
    case structured(Data)
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
