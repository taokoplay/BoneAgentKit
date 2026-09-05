import Foundation

/// 第一版严格串行 Agent Loop；并发或 sink 重入 Run 会在发布事件前稳定拒绝。
public actor BoneAgent {
    private let inferenceEngine: any BoneInferenceEngine
    private let toolRegistry: BoneAgentToolRegistry
    private let toolContext: any BoneAgentToolContext
    private let configuration: BoneAgentConfiguration
    private let eventSink: BoneAgentEventSink
    private let progressSink: BoneAgentProgressSink
    private let toolScheduler: BoneToolCallScheduler
    private let monotonicClock: @Sendable () -> TimeInterval
    private var isRunning = false

    /// monotonicClock 必须返回同一时基的单调 uptime 秒数；默认使用系统时钟。
    /// 自定义时钟主要用于确定性验证协作截止，不改变 Host 的执行/Receipt 生命周期。
    public init(
        inferenceEngine: any BoneInferenceEngine,
        toolRegistry: BoneAgentToolRegistry,
        toolContext: any BoneAgentToolContext,
        configuration: BoneAgentConfiguration,
        eventSink: BoneAgentEventSink = BoneAgentEventSink(),
        progressSink: BoneAgentProgressSink = BoneAgentProgressSink(),
        monotonicClock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {

        self.monotonicClock = monotonicClock
        self.inferenceEngine = inferenceEngine
        self.toolRegistry = toolRegistry
        self.toolContext = toolContext
        self.configuration = configuration
        self.eventSink = eventSink
        self.progressSink = progressSink
        toolScheduler = configuration.toolScheduler
    }

    /// 便捷装配：将同一 Workflow Agent Step controller 绑定为进度 checkpoint sink。
    public init(
        inferenceEngine: any BoneInferenceEngine,
        toolRegistry: BoneAgentToolRegistry,
        toolContext: any BoneAgentToolContext,
        configuration: BoneAgentConfiguration,
        workflowController: BoneWorkflowAgentStepController,
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

    public func run(modelID: String, messages: [BoneInferenceMessage]) async throws -> BoneAgentRunResult {
        try await run(request: BoneInferenceRequest(modelID: modelID, messages: messages))
    }

    /// 使用调用方的文本生成参数运行传统自治 Agent；保持现有模型终态输出契约。
    public func run(request initialRequest: BoneInferenceRequest) async throws -> BoneAgentRunResult {
        let result = try await runUntilBoundary(request: initialRequest, boundary: .untilModelFinish)
        guard case .modelFinished(let output) = result.completion else {
            throw BoneAgentError.inferenceFailed
        }
        return BoneAgentRunResult(output: output, steps: result.steps)
    }

    /// 将一次 Agent Run 的终态提交给 Workflow Agent Step；progressSink 应绑定同一 controller。
    public func runWorkflowStep(
        modelID: String,
        messages: [BoneInferenceMessage],
        controller: BoneWorkflowAgentStepController
    ) async throws -> BoneAgentRunResult {
        do {
            let result = try await run(modelID: modelID, messages: messages)
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

    /// 运行至调用方指定的通用边界；Tool 集合和 continuation 始终由 Runtime 管理。
    public func runUntilBoundary(
        request initialRequest: BoneInferenceRequest,
        boundary: BoneAgentRunBoundary
    ) async throws -> BoneAgentBoundaryResult {
        guard !isRunning else { throw BoneAgentError.runAlreadyInProgress }
        guard initialRequest.responseFormat == .text else { throw BoneAgentError.inferenceFailed }
        let preparedInitialRequest = BoneInferenceRequest(
            modelID: initialRequest.modelID,
            messages: initialRequest.messages,
            availableTools: toolRegistry.definitions,
            generationOptions: initialRequest.generationOptions,
            responseFormat: .text,
            outputConstraint: initialRequest.outputConstraint,
            reasoningDisclosure: initialRequest.reasoningDisclosure
        )
        do {
            let resolved = try inferenceEngine.resolvedCapabilities(
                for: preparedInitialRequest,
                invocation: .nonStreaming
            )
            try BoneInferenceCapabilityValidator.validate(
                request: preparedInitialRequest,
                capabilities: resolved.capabilities,
                invocation: resolved.invocation
            )
        } catch let BoneInferenceError.unsupportedCapability(capability) {
            throw BoneAgentError.unsupportedCapability(capability)
        } catch {
            throw BoneAgentError.inferenceFailed
        }
        isRunning = true
        defer { isRunning = false }

        await eventSink.receive(.runStarted)
        do {
            let budgetMeter = configuration.runBudget.map { BoneRunBudgetMeter(budget: $0, startedAtUptime: monotonicClock()) }
            var messages = preparedInitialRequest.messages
            var providerContinuation: BoneInferenceProviderContinuation?
            for step in 1...configuration.maximumSteps {
                try Task.checkCancellation()
                let response = try await infer(
                    template: preparedInitialRequest,
                    messages: messages,
                    providerContinuation: providerContinuation,
                    budgetMeter: budgetMeter
                )
                try await progressSink.receive(.inferenceResponsePrepared(
                    step: step,
                    kind: response.workflowCheckpointKind
                ))
                try Task.checkCancellation()

                switch response {
                case .finish(let finish):
                    return try await succeedBoundary(completion: .modelFinished(.text(finish.text)), steps: step, budgetMeter: budgetMeter)
                case .structured(let structured):
                    return try await succeedBoundary(completion: .modelFinished(.structured(structured.data)), steps: step, budgetMeter: budgetMeter)
                case .toolCall(let call):
                    try await executeLegacySingle(call, messages: &messages, budgetMeter: budgetMeter)
                    if boundary == .afterFirstToolTurn {
                        return try await succeedBoundary(completion: .toolTurnCompleted, steps: step, budgetMeter: budgetMeter)
                    }
                case let .assistantTurn(turn, finishReason, _, refusal, continuation):
                    guard refusal == nil else { throw BoneAgentError.inferenceFailed }
                    let calls = turn.toolCalls
                    switch finishReason {
                    case .stop:
                        guard calls.isEmpty else { throw BoneAgentError.inferenceFailed }
                        if let text = turn.text, turn.structuredOutputs.isEmpty {
                            return try await succeedBoundary(completion: .modelFinished(.text(text)), steps: step, budgetMeter: budgetMeter)
                        }
                        if turn.text == nil,
                           turn.structuredOutputs.count == 1,
                           let structured = turn.structuredOutputs.first {
                            return try await succeedBoundary(completion: .modelFinished(.structured(structured)), steps: step, budgetMeter: budgetMeter)
                        }
                        throw BoneAgentError.inferenceFailed
                    case .toolCalls:
                        guard !calls.isEmpty else { throw BoneAgentError.inferenceFailed }
                        providerContinuation = continuation
                        try await executeTurn(turn, messages: &messages, budgetMeter: budgetMeter)
                        if boundary == .afterFirstToolTurn {
                            return try await succeedBoundary(completion: .toolTurnCompleted, steps: step, budgetMeter: budgetMeter)
                        }
                    case .length, .contentFilter, .safety, .refusal, .other:
                        throw BoneAgentError.inferenceFailed
                    }
                }
            }
            throw BoneAgentError.stepLimitReached
        } catch is CancellationError {
            await eventSink.receive(.runFinished(.cancelled))
            throw CancellationError()
        } catch let error as BoneAgentError {
            await eventSink.receive(.runFinished(.failed(error)))
            throw error
        } catch is BoneRunBudgetError {
            await eventSink.receive(.runFinished(.failed(.budgetExceeded)))
            throw BoneAgentError.budgetExceeded
        } catch {
            await eventSink.receive(.runFinished(.failed(.inferenceFailed)))
            throw BoneAgentError.inferenceFailed
        }
    }

    private func infer(
        template: BoneInferenceRequest,
        messages: [BoneInferenceMessage],
        providerContinuation: BoneInferenceProviderContinuation?,
        budgetMeter: BoneRunBudgetMeter?
    ) async throws -> BoneInferenceResponse {
        do {
            let request = BoneInferenceRequest(
                modelID: template.modelID,
                messages: messages,
                availableTools: toolRegistry.definitions,
                generationOptions: template.generationOptions,
                responseFormat: .text,
                outputConstraint: template.outputConstraint,
                providerContinuation: providerContinuation,
                reasoningDisclosure: template.reasoningDisclosure
            )
            let inputBytes = try JSONEncoder().encode(request).count
            let estimatedCostMicrounits: Int64
            if budgetMeter != nil {
                guard let estimator = configuration.inferenceCostEstimator else {
                    throw BoneRunBudgetError.invalidBudget
                }
                estimatedCostMicrounits = try estimator(request)
                guard estimatedCostMicrounits >= 0 else {
                    throw BoneRunBudgetError.invalidBudget
                }
            } else {
                estimatedCostMicrounits = 0
            }
            try await budgetMeter?.reserveInferenceTurn(
                inputBytes: inputBytes,
                estimatedCostMicrounits: estimatedCostMicrounits,
                nowUptime: monotonicClock()
            )
            let response = try await inferenceEngine.infer(request: request)
            try Task.checkCancellation()
            try await budgetMeter?.checkWallClock(nowUptime: monotonicClock())
            try await budgetMeter?.commitInference(outputBytes: JSONEncoder().encode(response).count)
            return response
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as BoneRunBudgetError {
            throw error
        } catch {
            if let shapeError = error as? BoneInferenceProtocolShapeError {
                try await progressSink.receive(.inferenceProtocolShapeFailed(shapeError.diagnostic))
            }
            try await progressSink.receive(.inferenceFailed(Self.inferenceFailureDiagnostic(for: error)))
            throw BoneAgentError.inferenceFailed
        }
    }

    private static func inferenceFailureDiagnostic(
        for error: Error
    ) -> BoneAgentInferenceFailureDiagnostic {
        if let error = error as? BoneInferenceTransportError {
            switch error {
            case .invalidCredential: return .invalidCredential
            case .invalidConfiguration, .invalidEndpoint, .insecureEndpoint, .reservedHeader:
                return .invalidConfiguration
            case .httpStatus(let status): return .httpStatus(status)
            case .rateLimited: return .rateLimited
            case .quotaExceeded: return .quotaExceeded
            case .unsupportedModel: return .unsupportedModel
            case .safetyBlocked: return .safetyBlocked
            case .outputTruncated: return .outputTruncated
            case .firstEventTimedOut: return .firstEventTimedOut
            case .idleTimedOut: return .idleTimedOut
            case .network: return .network
            case .responseTooLarge, .invalidResponse: return .invalidResponse
            case .cancelled: return .unknown
            }
        }
        if error is BoneInferenceProtocolShapeError { return .invalidResponse }
        if error is BoneInferenceError { return .invalidResponse }
        return .unknown
    }

    private func executeLegacySingle(
        _ call: BoneInferenceToolCall,
        messages: inout [BoneInferenceMessage],
        budgetMeter: BoneRunBudgetMeter?
    ) async throws {
        guard call.arguments.count <= BoneInferenceToolCall.maximumArgumentsByteCount else {
            throw BoneAgentError.toolPayloadTooLarge
        }
        try Task.checkCancellation()
        guard let definition = toolRegistry.tool(id: call.toolID)?.definition else {
            throw BoneAgentError.toolNotFound
        }
        if let mismatch = try validate(call: call, definition: definition) {
            try await progressSink.receive(.toolArgumentsRejected(toolID: call.toolID, mismatch: mismatch))
            throw BoneAgentError.toolArgumentsInvalid
        }
        try await progressSink.receive(.toolExecutionPrepared(toolID: call.toolID))
        try await budgetMeter?.reserveToolExecution(argumentsBytes: call.arguments.count, nowUptime: monotonicClock())
        await eventSink.receive(.toolCallStarted)
        let output: Data
        do {
            try Task.checkCancellation()
            try await budgetMeter?.checkWallClock(nowUptime: monotonicClock())
            output = try await executeThroughPipeline(call, definition: definition, budgetMeter: budgetMeter)
        } catch {
            await budgetMeter?.releaseConcurrentTool()
            throw error
        }
        await budgetMeter?.releaseConcurrentTool()
        try Task.checkCancellation()
        try await budgetMeter?.checkWallClock(nowUptime: monotonicClock())
        guard output.count <= BoneInferenceToolResult.maximumResultByteCount else {
            throw BoneAgentError.toolPayloadTooLarge
        }
        try await budgetMeter?.commitTool(resultBytes: output.count)
        try await progressSink.receive(.toolResultPrepared(step: messages.count + 1, ordinal: 0))
        await eventSink.receive(.toolCallFinished)
        try Task.checkCancellation()
        try await budgetMeter?.checkWallClock(nowUptime: monotonicClock())
        messages.append(try .toolResult(callID: call.id, toolID: call.toolID, result: output))
    }

    private func executeTurn(
        _ turn: BoneInferenceAssistantTurn,
        messages: inout [BoneInferenceMessage],
        budgetMeter: BoneRunBudgetMeter?
    ) async throws {
        messages.append(.assistant(turn))
        let results: [BoneInferenceToolResult]
        let impactPolicy = configuration.toolImpactPolicy
        do {
            results = try await toolScheduler.execute(
                calls: turn.toolCalls,
                definitions: toolRegistry.definitions
            ) { [toolRegistry, toolContext, eventSink, progressSink, configuration, monotonicClock] call in
                guard call.arguments.count <= BoneInferenceToolCall.maximumArgumentsByteCount else {
                    throw BoneAgentError.toolPayloadTooLarge
                }
                try Task.checkCancellation()
                guard let definition = toolRegistry.tool(id: call.toolID)?.definition else {
                    throw BoneAgentError.toolNotFound
                }
                if let mismatch = try Self.validate(
                    call: call,
                    definition: definition,
                    impactPolicy: impactPolicy
                ) {
                    try await progressSink.receive(.toolArgumentsRejected(toolID: call.toolID, mismatch: mismatch))
                    throw BoneAgentError.toolArgumentsInvalid
                }
                try await progressSink.receive(.toolExecutionPrepared(toolID: call.toolID))
                try await budgetMeter?.reserveToolExecution(argumentsBytes: call.arguments.count, nowUptime: monotonicClock())
                await eventSink.receive(.toolCallStarted)
                let output: Data
                do {
                    try Task.checkCancellation()
                    try await budgetMeter?.checkWallClock(nowUptime: monotonicClock())
                    let executionContext = try await configuration.toolExecutionContextProvider?(call, definition)
                    try Task.checkCancellation()
                    try await budgetMeter?.checkWallClock(nowUptime: monotonicClock())
                    output = try await configuration.toolExecutionPipeline.execute(
                        arguments: call.arguments,
                        definition: definition,
                        context: executionContext
                    ) {
                        try await toolRegistry.execute(
                            id: call.toolID,
                            input: call.arguments,
                            context: toolContext
                        )
                    }
                } catch is CancellationError {
                    await budgetMeter?.releaseConcurrentTool()
                    throw CancellationError()
                } catch let error as BoneRunBudgetError {
                    await budgetMeter?.releaseConcurrentTool()
                    throw error
                } catch let error as BoneWorkflowToolExecutionError {
                    await budgetMeter?.releaseConcurrentTool()
                    switch error {
                    case .cancelledBeforeExecution: throw CancellationError()
                    case .toolExecutionFailed: throw BoneAgentError.toolExecutionFailed
                    case .outcomeUnknown: throw BoneAgentError.toolOutcomeUnknown
                    case .recoveryRequired: throw BoneAgentError.toolRecoveryRequired
                    case .invalidContext, .pipelineUnavailable, .authorizationRejected, .effectStoreRejected:
                        throw BoneToolBatchAbortError.controlPlaneFailure
                    }
                } catch let error as BoneAgentToolError {
                    await budgetMeter?.releaseConcurrentTool()
                    switch error.safeReason {
                    case .toolNotFound: throw BoneAgentError.toolNotFound
                    case .invalidArguments: throw BoneAgentError.toolExecutionFailed
                    case .invalidContext: throw BoneToolBatchAbortError.controlPlaneFailure
                    }
                } catch {
                    await budgetMeter?.releaseConcurrentTool()
                    throw BoneAgentError.toolExecutionFailed
                }
                await budgetMeter?.releaseConcurrentTool()
                try Task.checkCancellation()
                try await budgetMeter?.checkWallClock(nowUptime: monotonicClock())
                guard output.count <= BoneInferenceToolResult.maximumResultByteCount else {
                    throw BoneAgentError.toolPayloadTooLarge
                }
                try await budgetMeter?.commitTool(resultBytes: output.count)
                await eventSink.receive(.toolCallFinished)
                return .json(output)
            }
            for result in results {
                try Task.checkCancellation()
                try await budgetMeter?.checkWallClock(nowUptime: monotonicClock())
                try await progressSink.receive(.toolResultPrepared(
                    step: messages.count,
                    ordinal: result.ordinal
                ))
            }
            try Task.checkCancellation()
            try await budgetMeter?.checkWallClock(nowUptime: monotonicClock())
            messages.append(.toolResults(try .init(results: results)))
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as BoneAgentError {
            throw error
        } catch let error as BoneRunBudgetError {
            throw error
        } catch is BoneToolBatchAbortError {
            throw BoneAgentError.toolExecutionFailed
        } catch let error as BoneToolSchedulerError {
            switch error {
            case .missingToolDefinition: throw BoneAgentError.toolNotFound
            case .invalidConcurrencyLimit, .invalidCallOrder, .duplicateToolDefinition:
                throw BoneAgentError.toolExecutionFailed
            }
        } catch let error as BoneInferenceError {
            switch error {
            case .toolResultTooLarge: throw BoneAgentError.toolPayloadTooLarge
            default: throw BoneAgentError.toolExecutionFailed
            }
        } catch {
            throw BoneAgentError.toolExecutionFailed
        }
    }

    private func validate(
        call: BoneInferenceToolCall,
        definition: BoneAgentToolDefinition
    ) throws -> BoneToolSchemaMismatch? {
        do {
            return try Self.validate(
                call: call,
                definition: definition,
                impactPolicy: configuration.toolImpactPolicy
            )
        } catch is BoneToolBatchAbortError {
            throw BoneAgentError.toolExecutionFailed
        }
    }

    private static func validate(
        call: BoneInferenceToolCall,
        definition: BoneAgentToolDefinition,
        impactPolicy: BoneToolImpactPolicy?
    ) throws -> BoneToolSchemaMismatch? {
        do {
            let impact = try definition.requiredImpact()
            if let impactPolicy {
                try impactPolicy.authorize(impact)
            } else if impact.requiresHostAuthorization {
                throw BoneToolPolicyError.impactExceedsHostPolicy
            }
            guard let schema = definition.inputSchema else {
                throw BoneToolSchemaError.missingInputSchema
            }
            try BoneToolSchemaValidator.validateDefinition(schema)
            return BoneToolSchemaValidator.firstMismatch(arguments: call.arguments, against: schema)
        } catch is BoneToolPolicyError {
            throw BoneToolBatchAbortError.controlPlaneFailure
        } catch is BoneToolSchemaError {
            throw BoneToolBatchAbortError.controlPlaneFailure
        } catch {
            throw BoneToolBatchAbortError.controlPlaneFailure
        }
    }

    private func executeThroughPipeline(
        _ call: BoneInferenceToolCall,
        definition: BoneAgentToolDefinition,
        budgetMeter: BoneRunBudgetMeter?
    ) async throws -> Data {
        do {
            let executionContext = try await configuration.toolExecutionContextProvider?(call, definition)
            try Task.checkCancellation()
            try await budgetMeter?.checkWallClock(nowUptime: monotonicClock())
            return try await configuration.toolExecutionPipeline.execute(
                arguments: call.arguments,
                definition: definition,
                context: executionContext
            ) { [toolRegistry, toolContext] in
                try await toolRegistry.execute(id: call.toolID, input: call.arguments, context: toolContext)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as BoneRunBudgetError {
            throw error
        } catch let error as BoneWorkflowToolExecutionError {
            switch error {
            case .cancelledBeforeExecution:
                throw CancellationError()
            case .outcomeUnknown:
                throw BoneAgentError.toolOutcomeUnknown
            case .recoveryRequired:
                throw BoneAgentError.toolRecoveryRequired
            default:
                throw BoneAgentError.toolExecutionFailed
            }
        } catch let error as BoneAgentToolError {
            switch error.safeReason {
            case .toolNotFound:
                throw BoneAgentError.toolNotFound
            case .invalidArguments, .invalidContext:
                throw BoneAgentError.toolExecutionFailed
            }
        } catch {
            throw BoneAgentError.toolExecutionFailed
        }
    }

    /// runFinished delivery 的开始是成功 Run 的线性化点；此后不再读取取消/截止状态。
    private func succeedBoundary(
        completion: BoneAgentBoundaryCompletion,
        steps: Int,
        budgetMeter: BoneRunBudgetMeter?
    ) async throws -> BoneAgentBoundaryResult {
        try await budgetMeter?.checkWallClock(nowUptime: monotonicClock())
        try Task.checkCancellation()
        await eventSink.receive(.runFinished(.succeeded))
        return BoneAgentBoundaryResult(completion: completion, steps: steps)
    }
}

private extension BoneInferenceResponse {
    var workflowCheckpointKind: BoneAgentInferenceCheckpointKind {
        switch self {
        case .finish: return .finish
        case .structured: return .structured
        case .toolCall: return .toolCall
        case .assistantTurn: return .assistantTurn
        }
    }
}
