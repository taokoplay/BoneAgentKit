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
    private var isRunning = false

    public init(
        inferenceEngine: any BoneInferenceEngine,
        toolRegistry: BoneAgentToolRegistry,
        toolContext: any BoneAgentToolContext,
        configuration: BoneAgentConfiguration,
        eventSink: BoneAgentEventSink = BoneAgentEventSink(),
        progressSink: BoneAgentProgressSink = BoneAgentProgressSink()
    ) {

        self.inferenceEngine = inferenceEngine
        self.toolRegistry = toolRegistry
        self.toolContext = toolContext
        self.configuration = configuration
        self.eventSink = eventSink
        self.progressSink = progressSink
        toolScheduler = try! BoneToolCallScheduler(
            mode: configuration.toolSchedulingMode,
            failureStrategy: configuration.toolFailureStrategy
        )
    }

    public func run(modelID: String, messages initialMessages: [BoneInferenceMessage]) async throws -> BoneAgentRunResult {
        guard !isRunning else { throw BoneAgentError.runAlreadyInProgress }
        isRunning = true
        defer { isRunning = false }

        await eventSink.receive(.runStarted)
        do {
            let budgetMeter = configuration.runBudget.map { BoneRunBudgetMeter(budget: $0) }
            var messages = initialMessages
            var providerContinuation: BoneInferenceProviderContinuation?
            for step in 1...configuration.maximumSteps {
                try Task.checkCancellation()
                let response = try await infer(
                    modelID: modelID,
                    messages: messages,
                    providerContinuation: providerContinuation,
                    budgetMeter: budgetMeter
                )
                try await budgetMeter?.commitTurn()
                try await progressSink.receive(.inferenceResponsePrepared(
                    step: step,
                    kind: response.workflowCheckpointKind
                ))
                try Task.checkCancellation()

                switch response {
                case .finish(let finish):
                    return await succeed(output: .text(finish.text), steps: step)
                case .structured(let structured):
                    return await succeed(output: .structured(structured.data), steps: step)
                case .toolCall(let call):
                    try await executeLegacySingle(call, messages: &messages, budgetMeter: budgetMeter)
                case let .assistantTurn(turn, finishReason, _, refusal, continuation):
                    guard refusal == nil else { throw BoneAgentError.inferenceFailed }
                    let calls = turn.toolCalls
                    switch finishReason {
                    case .stop:
                        guard calls.isEmpty else { throw BoneAgentError.inferenceFailed }
                        if let text = turn.text, turn.structuredOutputs.isEmpty {
                            return await succeed(output: .text(text), steps: step)
                        }
                        if turn.text == nil,
                           turn.structuredOutputs.count == 1,
                           let structured = turn.structuredOutputs.first {
                            return await succeed(output: .structured(structured), steps: step)
                        }
                        throw BoneAgentError.inferenceFailed
                    case .toolCalls:
                        guard !calls.isEmpty else { throw BoneAgentError.inferenceFailed }
                        providerContinuation = continuation
                        try await executeTurn(turn, messages: &messages, budgetMeter: budgetMeter)
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
        modelID: String,
        messages: [BoneInferenceMessage],
        providerContinuation: BoneInferenceProviderContinuation?,
        budgetMeter: BoneRunBudgetMeter?
    ) async throws -> BoneInferenceResponse {
        do {
            let request = BoneInferenceRequest(
                modelID: modelID,
                messages: messages,
                availableTools: toolRegistry.definitions,
                providerContinuation: providerContinuation
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
            try await budgetMeter?.reserveInference(
                inputBytes: inputBytes,
                estimatedCostMicrounits: estimatedCostMicrounits
            )
            let response = try await inferenceEngine.infer(request: request)
            try await budgetMeter?.checkWallClock()
            try await budgetMeter?.commitInference(outputBytes: JSONEncoder().encode(response).count)
            return response
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as BoneRunBudgetError {
            throw error
        } catch {
            throw BoneAgentError.inferenceFailed
        }
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
        try validate(call: call, definition: definition)
        try await budgetMeter?.reserveTool(argumentsBytes: call.arguments.count)
        try await budgetMeter?.reserveConcurrentTool()
        await eventSink.receive(.toolCallStarted)
        let output: Data
        do {
            output = try await executeThroughPipeline(call, definition: definition)
        } catch {
            await budgetMeter?.releaseConcurrentTool()
            throw error
        }
        await budgetMeter?.releaseConcurrentTool()
        guard output.count <= BoneInferenceToolResult.maximumResultByteCount else {
            throw BoneAgentError.toolPayloadTooLarge
        }
        try await budgetMeter?.commitTool(resultBytes: output.count)
        try await progressSink.receive(.toolResultPrepared(step: messages.count + 1, ordinal: 0))
        await eventSink.receive(.toolCallFinished)
        messages.append(.toolResult(callID: call.id, toolID: call.toolID, result: output))
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
            ) { [toolRegistry, toolContext, eventSink, configuration] call in
                guard call.arguments.count <= BoneInferenceToolCall.maximumArgumentsByteCount else {
                    throw BoneAgentError.toolPayloadTooLarge
                }
                try Task.checkCancellation()
                guard let definition = toolRegistry.tool(id: call.toolID)?.definition else {
                    throw BoneAgentError.toolNotFound
                }
                try Self.validate(
                    call: call,
                    definition: definition,
                    impactPolicy: impactPolicy
                )
                try await budgetMeter?.reserveTool(argumentsBytes: call.arguments.count)
                try await budgetMeter?.reserveConcurrentTool()
                await eventSink.receive(.toolCallStarted)
                let output: Data
                do {
                    let executionContext = try await configuration.toolExecutionContextProvider?(call, definition)
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
                } catch let error as BoneWorkflowToolExecutionError {
                    await budgetMeter?.releaseConcurrentTool()
                    switch error {
                    case .cancelledBeforeExecution: throw CancellationError()
                    default: throw BoneAgentError.toolExecutionFailed
                    }
                } catch let error as BoneAgentToolError {
                    await budgetMeter?.releaseConcurrentTool()
                    switch error.safeReason {
                    case .toolNotFound: throw BoneAgentError.toolNotFound
                    case .invalidArguments, .invalidContext: throw BoneAgentError.toolExecutionFailed
                    }
                } catch {
                    await budgetMeter?.releaseConcurrentTool()
                    throw BoneAgentError.toolExecutionFailed
                }
                await budgetMeter?.releaseConcurrentTool()
                guard output.count <= BoneInferenceToolResult.maximumResultByteCount else {
                    throw BoneAgentError.toolPayloadTooLarge
                }
                try await budgetMeter?.commitTool(resultBytes: output.count)
                await eventSink.receive(.toolCallFinished)
                return .json(output)
            }
            for result in results {
                try await progressSink.receive(.toolResultPrepared(
                    step: messages.count,
                    ordinal: result.ordinal
                ))
            }
            messages.append(.toolResults(try .init(results: results)))
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as BoneAgentError {
            throw error
        } catch let error as BoneRunBudgetError {
            throw error
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
    ) throws {
        try Self.validate(
            call: call,
            definition: definition,
            impactPolicy: configuration.toolImpactPolicy
        )
    }

    private static func validate(
        call: BoneInferenceToolCall,
        definition: BoneAgentToolDefinition,
        impactPolicy: BoneToolImpactPolicy?
    ) throws {
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
            try BoneToolSchemaValidator.validate(arguments: call.arguments, against: schema)
        } catch {
            throw BoneAgentError.toolExecutionFailed
        }
    }

    private func executeThroughPipeline(
        _ call: BoneInferenceToolCall,
        definition: BoneAgentToolDefinition
    ) async throws -> Data {
        do {
            let executionContext = try await configuration.toolExecutionContextProvider?(call, definition)
            return try await configuration.toolExecutionPipeline.execute(
                arguments: call.arguments,
                definition: definition,
                context: executionContext
            ) { [toolRegistry, toolContext] in
                try await toolRegistry.execute(id: call.toolID, input: call.arguments, context: toolContext)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as BoneWorkflowToolExecutionError {
            switch error {
            case .cancelledBeforeExecution:
                throw CancellationError()
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

    /// runFinished delivery 的开始是成功 Run 的线性化点；此后不再读取取消状态。
    private func succeed(output: BoneAgentRunOutput, steps: Int) async -> BoneAgentRunResult {
        await eventSink.receive(.runFinished(.succeeded))
        return BoneAgentRunResult(output: output, steps: steps)
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
