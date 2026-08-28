import Foundation

/// 调用方一体化 Facade；封装推理引擎、Tool Registry、Context 与 Runtime 配置。
public struct BoneAgentKit: Sendable {
    private let agent: BoneAgent

    public init(
        inferenceEngine: any BoneInferenceEngine,
        toolRegistry: BoneAgentToolRegistry,
        toolContext: any BoneAgentToolContext,
        configuration: BoneAgentConfiguration,
        eventSink: BoneAgentEventSink = BoneAgentEventSink(),
        progressSink: BoneAgentProgressSink = BoneAgentProgressSink()
    ) {
        agent = BoneAgent(
            inferenceEngine: inferenceEngine,
            toolRegistry: toolRegistry,
            toolContext: toolContext,
            configuration: configuration,
            eventSink: eventSink,
            progressSink: progressSink
        )
    }

    /// 便捷装配：将同一 Workflow controller 绑定为进度 checkpoint sink。
    public init(
        inferenceEngine: any BoneInferenceEngine,
        toolRegistry: BoneAgentToolRegistry,
        toolContext: any BoneAgentToolContext,
        configuration: BoneAgentConfiguration,
        workflowController: BoneAgentWorkflowStepController,
        eventSink: BoneAgentEventSink = BoneAgentEventSink()
    ) {
        self.init(
            inferenceEngine: inferenceEngine,
            toolRegistry: toolRegistry,
            toolContext: toolContext,
            configuration: configuration,
            eventSink: eventSink,
            progressSink: workflowController.progressSink()
        )
    }

    public func run(
        modelID: String,
        messages: [BoneInferenceMessage]
    ) async throws -> BoneAgentRunResult {
        try await agent.run(modelID: modelID, messages: messages)
    }

    /// 将一次 Agent Run 的终态提交给 Workflow Step；progressSink 应绑定同一 controller。
    public func runWorkflowStep(
        modelID: String,
        messages: [BoneInferenceMessage],
        controller: BoneAgentWorkflowStepController
    ) async throws -> BoneAgentRunResult {
        do {
            let result = try await agent.run(modelID: modelID, messages: messages)
            try await controller.finish(.succeeded)
            return result
        } catch is CancellationError {
            try await controller.finish(.cancelled)
            throw CancellationError()
        } catch {
            try await controller.finish(.failed)
            throw error
        }
    }
}
