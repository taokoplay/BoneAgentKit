import Foundation

/// 第一版 Agent Runtime 配置；每次 infer 消耗一步，Tool 执行不额外消耗。
public typealias BoneInferenceCostEstimator = @Sendable (BoneInferenceRequest) throws -> Int64
public typealias BoneWorkflowToolExecutionContextProvider = @Sendable (
    BoneInferenceToolCall,
    BoneAgentToolDefinition
) async throws -> BoneWorkflowToolExecutionContext?

/// 流式只在完整结果返回后进入 Tool 执行；失败不自动回退。
public enum BoneAgentInferenceMode: Sendable {
    case nonStreaming
    case bufferedStreaming(BoneInferenceEventStreamOptions)
}

public struct BoneAgentConfiguration: Sendable {
    public let inferenceMode: BoneAgentInferenceMode
    public let maximumSteps: Int
    public let toolSchedulingMode: BoneToolSchedulingMode
    public let toolFailureStrategy: BoneToolFailureStrategy
    public let runBudget: BoneRunBudget?
    public let toolImpactPolicy: BoneToolImpactPolicy?
    public let inferenceCostEstimator: BoneInferenceCostEstimator?
    public let toolExecutionPipeline: BoneWorkflowToolExecutionPipeline
    public let toolExecutionContextProvider: BoneWorkflowToolExecutionContextProvider?
    public let logging: BoneAgentLoggerConfiguration
    /// 初始化时完成校验的 Tool 调度器，供 Agent 直接复用既有不变量。
    let toolScheduler: BoneToolCallScheduler

    public init(
        maximumSteps: Int,
        toolSchedulingMode: BoneToolSchedulingMode = .serial,
        toolFailureStrategy: BoneToolFailureStrategy = .failFast,
        runBudget: BoneRunBudget? = nil,
        toolImpactPolicy: BoneToolImpactPolicy? = nil,
        inferenceCostEstimator: BoneInferenceCostEstimator? = nil,
        toolExecutionPipeline: BoneWorkflowToolExecutionPipeline = .init(),
        toolExecutionContextProvider: BoneWorkflowToolExecutionContextProvider? = nil,
        logging: BoneAgentLoggerConfiguration = .init(),
        inferenceMode: BoneAgentInferenceMode = .nonStreaming
    ) throws {
        guard maximumSteps > 0 else {
            throw BoneAgentError.invalidMaximumSteps
        }
        let toolScheduler = try BoneToolCallScheduler(
            mode: toolSchedulingMode,
            failureStrategy: toolFailureStrategy
        )
        self.inferenceMode = inferenceMode
        self.maximumSteps = maximumSteps
        self.toolSchedulingMode = toolSchedulingMode
        self.toolFailureStrategy = toolFailureStrategy
        self.runBudget = runBudget
        self.toolImpactPolicy = toolImpactPolicy
        self.inferenceCostEstimator = inferenceCostEstimator
        self.toolExecutionPipeline = toolExecutionPipeline
        self.toolExecutionContextProvider = toolExecutionContextProvider
        self.logging = logging
        self.toolScheduler = toolScheduler
    }
}
