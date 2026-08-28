import Foundation

/// 第一版 Agent Runtime 配置；每次 infer 消耗一步，Tool 执行不额外消耗。
public typealias BoneInferenceCostEstimator = @Sendable (BoneInferenceRequest) throws -> Int64
public typealias BoneWorkflowToolExecutionContextProvider = @Sendable (
    BoneInferenceToolCall,
    BoneAgentToolDefinition
) async throws -> BoneWorkflowToolExecutionContext?

public struct BoneAgentConfiguration: Sendable {
    public let maximumSteps: Int
    public let toolSchedulingMode: BoneToolSchedulingMode
    public let toolFailureStrategy: BoneToolFailureStrategy
    public let runBudget: BoneRunBudget?
    public let toolImpactPolicy: BoneToolImpactPolicy?
    public let inferenceCostEstimator: BoneInferenceCostEstimator?
    public let toolExecutionPipeline: BoneWorkflowToolExecutionPipeline
    public let toolExecutionContextProvider: BoneWorkflowToolExecutionContextProvider?

    public init(
        maximumSteps: Int,
        toolSchedulingMode: BoneToolSchedulingMode = .serial,
        toolFailureStrategy: BoneToolFailureStrategy = .failFast,
        runBudget: BoneRunBudget? = nil,
        toolImpactPolicy: BoneToolImpactPolicy? = nil,
        inferenceCostEstimator: BoneInferenceCostEstimator? = nil,
        toolExecutionPipeline: BoneWorkflowToolExecutionPipeline = .init(),
        toolExecutionContextProvider: BoneWorkflowToolExecutionContextProvider? = nil
    ) throws {
        guard maximumSteps > 0 else {
            throw BoneAgentError.invalidMaximumSteps
        }
        _ = try BoneToolCallScheduler(mode: toolSchedulingMode, failureStrategy: toolFailureStrategy)
        self.maximumSteps = maximumSteps
        self.toolSchedulingMode = toolSchedulingMode
        self.toolFailureStrategy = toolFailureStrategy
        self.runBudget = runBudget
        self.toolImpactPolicy = toolImpactPolicy
        self.inferenceCostEstimator = inferenceCostEstimator
        self.toolExecutionPipeline = toolExecutionPipeline
        self.toolExecutionContextProvider = toolExecutionContextProvider
    }
}
