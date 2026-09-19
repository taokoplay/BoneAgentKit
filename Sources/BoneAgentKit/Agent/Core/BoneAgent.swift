import Foundation

/// 第一版严格串行 Agent Loop；并发或 sink 重入 Run 会在发布事件前稳定拒绝。
public actor BoneAgent {
    private let inferenceEngine: any BoneInferenceEngine
    private let toolRegistry: BoneAgentToolRegistry
    private let toolContext: any BoneAgentToolContext
    private let configuration: BoneAgentConfiguration
    private let eventSink: BoneAgentEventSink
    private let progressSink: BoneAgentProgressSink
    private let modelSnapshotSink: BoneAgentModelSnapshotSink
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
        monotonicClock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        modelSnapshotSink: BoneAgentModelSnapshotSink = BoneAgentModelSnapshotSink()
    ) {

        self.monotonicClock = monotonicClock
        self.modelSnapshotSink = modelSnapshotSink
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
        eventSink: BoneAgentEventSink = BoneAgentEventSink(),
        modelSnapshotSink: BoneAgentModelSnapshotSink = BoneAgentModelSnapshotSink()
    ) {
        self.init(
            inferenceEngine: inferenceEngine,
            toolRegistry: toolRegistry,
            toolContext: toolContext,
            configuration: configuration,
            eventSink: eventSink,
            progressSink: workflowController.progressSink(),
            modelSnapshotSink: modelSnapshotSink
        )
    }

    public func run(
        modelID: String,
        messages: [BoneInferenceMessage],
        snapshotContext: BoneAgentModelSnapshotContext? = nil
    ) async throws -> BoneAgentRunResult {
        try await run(
            request: BoneInferenceRequest(modelID: modelID, messages: messages),
            snapshotContext: snapshotContext
        )
    }

    /// 使用调用方的文本生成参数运行传统自治 Agent；保持现有模型终态输出契约。
    public func run(
        request initialRequest: BoneInferenceRequest,
        snapshotContext: BoneAgentModelSnapshotContext? = nil
    ) async throws -> BoneAgentRunResult {
        let result = try await runUntilBoundary(
            request: initialRequest,
            boundary: .untilModelFinish,
            snapshotContext: snapshotContext
        )
        guard case .modelFinished(let output) = result.completion else {
            throw BoneAgentError.inferenceFailed
        }
        return BoneAgentRunResult(output: output, steps: result.steps)
    }

    /// 将一次 Agent Run 的终态提交给 Workflow Agent Step；progressSink 应绑定同一 controller。
    public func runWorkflowStep(
        modelID: String,
        messages: [BoneInferenceMessage],
        controller: BoneWorkflowAgentStepController,
        snapshotContext: BoneAgentModelSnapshotContext? = nil
    ) async throws -> BoneAgentRunResult {
        do {
            let result = try await run(
                modelID: modelID,
                messages: messages,
                snapshotContext: snapshotContext
            )
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
    /// 快照覆盖能力门禁之后的完整生命周期：门禁本身拒绝时不产出快照。
    public func runUntilBoundary(
        request initialRequest: BoneInferenceRequest,
        boundary: BoneAgentRunBoundary,
        snapshotContext: BoneAgentModelSnapshotContext? = nil
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
        let invocation: BoneInferenceInvocationMode
        switch configuration.inferenceMode {
        case .nonStreaming: invocation = .nonStreaming
        case .bufferedStreaming(let options):
            guard options.totalTimeout.map({ $0.isFinite && $0 > 0 }) != false,
                  options.deadlineUptime.map({ $0.isFinite }) != false,
                  options.totalTimeout != nil || options.deadlineUptime != nil || configuration.runBudget != nil else {
                throw BoneAgentError.inferenceFailed
            }
            guard inferenceEngine is any BoneInferenceBufferedStreaming else {
                throw BoneAgentError.unsupportedCapability(.streaming)
            }
            invocation = .streaming
        }
        let resolved: BoneResolvedInferenceCapabilities
        do {
            resolved = try inferenceEngine.resolvedCapabilities(
                for: preparedInitialRequest,
                invocation: invocation
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
        configuration.logging.write(.info, "run.started", context: BoneAgentLogContext(["modelID": preparedInitialRequest.modelID, "messageCount": "\(preparedInitialRequest.messages.count)"]))
        let runStartedAt = monotonicClock()
        var runSnapshot = BoneAgentRunSnapshotBuilder(
            request: preparedInitialRequest,
            resolved: resolved,
            context: snapshotContext,
            startedAt: runStartedAt
        )
        do {
            let runDeadline = configuration.runBudget.map { runStartedAt + $0.maximumWallClockSeconds }
            let budgetMeter = configuration.runBudget.map { BoneRunBudgetMeter(budget: $0, startedAtUptime: runStartedAt) }
            var messages = preparedInitialRequest.messages
            var providerContinuation: BoneInferenceProviderContinuation?
            for step in 1...configuration.maximumSteps {
                try Task.checkCancellation()
                configuration.logging.write(.debug, "inference.step.started", context: BoneAgentLogContext(["step": "\(step)", "messageCount": "\(messages.count)"]))
                let response = try await infer(
                    template: preparedInitialRequest,
                    messages: messages,
                    providerContinuation: providerContinuation,
                    budgetMeter: budgetMeter,
                    runDeadline: runDeadline,
                    onResponseDelivered: { runSnapshot.record(response: $0) }
                )
                try await progressSink.receive(.inferenceResponsePrepared(
                    step: step,
                    kind: response.workflowCheckpointKind
                ))
                try Task.checkCancellation()

                switch response {
                case .finish(let finish):
                    return try await succeedBoundary(completion: .modelFinished(.text(finish.text)), steps: step, budgetMeter: budgetMeter, snapshot: runSnapshot)
                case .structured(let structured):
                    return try await succeedBoundary(completion: .modelFinished(.structured(structured.data)), steps: step, budgetMeter: budgetMeter, snapshot: runSnapshot)
                case .toolCall(let call):
                    try await executeLegacySingle(call, messages: &messages, budgetMeter: budgetMeter)
                    runSnapshot.toolResultCount += 1
                    if boundary == .afterFirstToolTurn {
                        return try await succeedBoundary(completion: .toolTurnCompleted, steps: step, budgetMeter: budgetMeter, snapshot: runSnapshot)
                    }
                case let .assistantTurn(turn, finishReason, _, refusal, continuation):
                    guard refusal == nil else { throw BoneAgentError.inferenceFailed }
                    let calls = turn.toolCalls
                    switch finishReason {
                    case .stop:
                        guard calls.isEmpty else { throw BoneAgentError.inferenceFailed }
                        if let text = turn.text, turn.structuredOutputs.isEmpty {
                            return try await succeedBoundary(completion: .modelFinished(.text(text)), steps: step, budgetMeter: budgetMeter, snapshot: runSnapshot)
                        }
                        if turn.text == nil,
                           turn.structuredOutputs.count == 1,
                           let structured = turn.structuredOutputs.first {
                            return try await succeedBoundary(completion: .modelFinished(.structured(structured)), steps: step, budgetMeter: budgetMeter, snapshot: runSnapshot)
                        }
                        throw BoneAgentError.inferenceFailed
                    case .toolCalls:
                        guard !calls.isEmpty else { throw BoneAgentError.inferenceFailed }
                        providerContinuation = continuation
                        try await executeTurn(
                            turn,
                            messages: &messages,
                            budgetMeter: budgetMeter,
                            onResultsReceived: { runSnapshot.toolResultCount += $0 }
                        )
                        if boundary == .afterFirstToolTurn {
                            return try await succeedBoundary(completion: .toolTurnCompleted, steps: step, budgetMeter: budgetMeter, snapshot: runSnapshot)
                        }
                    case .length, .contentFilter, .safety, .refusal, .other:
                        throw BoneAgentError.inferenceFailed
                    }
                }
            }
            throw BoneAgentError.stepLimitReached
        } catch is CancellationError {
            configuration.logging.write(.warning, "run.cancelled", context: BoneAgentLogContext(["modelID": preparedInitialRequest.modelID]))
            await eventSink.receive(.runFinished(.cancelled))
            await deliverSnapshot(runSnapshot, terminalState: .cancelled)
            throw CancellationError()
        } catch let error as BoneAgentError {
            configuration.logging.write(.error, "run.failed", context: BoneAgentLogContext(["modelID": preparedInitialRequest.modelID, "error": String(describing: error)]))
            await eventSink.receive(.runFinished(.failed(error)))
            await deliverSnapshot(runSnapshot, terminalState: .failed(error))
            throw error
        } catch is BoneRunBudgetError {
            await eventSink.receive(.runFinished(.failed(.budgetExceeded)))
            await deliverSnapshot(runSnapshot, terminalState: .failed(.budgetExceeded))
            throw BoneAgentError.budgetExceeded
        } catch {
            await eventSink.receive(.runFinished(.failed(.inferenceFailed)))
            await deliverSnapshot(runSnapshot, terminalState: .failed(.inferenceFailed))
            throw BoneAgentError.inferenceFailed
        }
    }

    private func infer(
        template: BoneInferenceRequest,
        messages: [BoneInferenceMessage],
        providerContinuation: BoneInferenceProviderContinuation?,
        budgetMeter: BoneRunBudgetMeter?,
        runDeadline: TimeInterval?,
        onResponseDelivered: (BoneInferenceResponse) -> Void
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
            let inputData = try JSONEncoder().encode(request)
            let inputBytes = inputData.count
            configuration.logging.write(.debug, "inference.request", context: BoneAgentLogContext(["modelID": request.modelID, "requestBytes": "\(inputBytes)", "request": configuration.logging.includesSensitivePayloads ? String(decoding: inputData, as: UTF8.self) : "[omitted]"]))
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
            let response: BoneInferenceResponse
            switch configuration.inferenceMode {
            case .nonStreaming:
                response = try await inferenceEngine.infer(request: request)
            case .bufferedStreaming(let options):
                guard let streaming = inferenceEngine as? any BoneInferenceBufferedStreaming else {
                    throw BoneAgentError.unsupportedCapability(.streaming)
                }
                // 将测试可注入时钟的剩余额度转换为真实 uptime，不逐步重置 Run 预算。
                let remaining = runDeadline.map { $0 - monotonicClock() }
                let budgetDeadline = remaining.map { ProcessInfo.processInfo.systemUptime + $0 }
                let deadline = [options.deadlineUptime, budgetDeadline].compactMap { $0 }.min()
                if let remaining, remaining <= 0 { throw BoneRunBudgetError.wallClockLimitReached }
                if let deadline, deadline <= ProcessInfo.processInfo.systemUptime { throw BoneInferenceStreamDeadlineExceeded() }
                response = try await streaming.inferUsingStream(request: request, options: .init(
                    firstEventTimeout: options.firstEventTimeout, idleTimeout: options.idleTimeout,
                    maximumBytes: options.maximumBytes, totalTimeout: options.totalTimeout,
                    deadlineUptime: deadline
                ))
            }
            // Engine 已交付该响应，Provider 调用已经发生；先记录事实，再做取消、预算与
            // checkpoint 判定，之后任何失败都不能把已计费的响应从记录里抹掉。
            onResponseDelivered(response)
            configuration.logging.write(.debug, "inference.result.validated", context: BoneAgentLogContext(["modelID": request.modelID, "messageCount": "\(request.messages.count)", "responseBytes": (try? JSONEncoder().encode(response)).map { String($0.count) } ?? "unknown"]))
            try Task.checkCancellation()
            try await budgetMeter?.checkWallClock(nowUptime: monotonicClock())
            try await budgetMeter?.commitInference(outputBytes: JSONEncoder().encode(response).count)
            return response
        } catch BoneInferenceTransportError.cancelled {
            throw CancellationError()
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
        configuration.logging.write(.info, "tool.started", context: BoneAgentLogContext(["toolID": call.toolID, "callID": call.id, "argumentBytes": "\(call.arguments.count)"]))
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
        do {
            try Task.checkCancellation()
            try await budgetMeter?.checkWallClock(nowUptime: monotonicClock())
            guard output.count <= BoneInferenceToolResult.maximumResultByteCount else {
                throw BoneAgentError.toolPayloadTooLarge
            }
            try await budgetMeter?.commitTool(resultBytes: output.count)
            try await progressSink.receive(.toolResultPrepared(step: messages.count + 1, ordinal: 0))
            await eventSink.receive(.toolCallFinished)
            configuration.logging.write(.info, "tool.finished", context: BoneAgentLogContext(["toolID": call.toolID, "callID": call.id, "resultBytes": "\(output.count)"]))
            try Task.checkCancellation()
            try await budgetMeter?.checkWallClock(nowUptime: monotonicClock())
            messages.append(try .toolResult(callID: call.id, toolID: call.toolID, result: output))
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as BoneAgentError {
            throw error
        } catch let error as BoneRunBudgetError {
            throw error
        } catch {
            // Tool 已执行并返回结果；Agent Step 结果提交或组装失败必须走恢复语义，
            // 不得归为 Tool 执行失败，也不允许 Host 直接重试 Tool。
            throw BoneAgentError.toolRecoveryRequired
        }
    }

    /// 执行一个完整 Assistant Tool Turn；已受理的结果数通过 `onResultsReceived` 立即上报，
    /// 因此结果发布中途失败时，已经执行的 Tool 仍然计入快照。
    private func executeTurn(
        _ turn: BoneInferenceAssistantTurn,
        messages: inout [BoneInferenceMessage],
        budgetMeter: BoneRunBudgetMeter?,
        onResultsReceived: (Int) -> Void
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
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as BoneAgentError {
            throw error
        } catch let error as BoneRunBudgetError {
            throw error
        } catch is BoneToolBatchAbortError {
            // 预执行控制面拒绝（授权、Schema 或 Effect Intent 未持久化）：Tool 未运行，
            // 归类为 Tool 失败是安全的；不得声称“已返回、禁止重试”。
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
        // Tool 已执行、结果已受理；此后失败属于结果提交或组装，走恢复语义。
        onResultsReceived(results.count)
        do {
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
        } catch let error as BoneRunBudgetError {
            throw error
        } catch {
            // Tool 已执行、结果已受理；Agent Step 结果提交或组装失败必须走恢复语义，
            // 不得归为 Tool 执行失败，也不允许 Host 直接重试 Tool。
            throw BoneAgentError.toolRecoveryRequired
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
    /// 快照在同一个线性化点之后、返回值之前投递，因此调用方拿到结果时快照已交付。
    private func succeedBoundary(
        completion: BoneAgentBoundaryCompletion,
        steps: Int,
        budgetMeter: BoneRunBudgetMeter?,
        snapshot: BoneAgentRunSnapshotBuilder
    ) async throws -> BoneAgentBoundaryResult {
        try await budgetMeter?.checkWallClock(nowUptime: monotonicClock())
        try Task.checkCancellation()
        await eventSink.receive(.runFinished(.succeeded))
        await deliverSnapshot(snapshot, terminalState: .succeeded)
        return BoneAgentBoundaryResult(completion: completion, steps: steps)
    }

    /// 终态快照的唯一投递点：必须在返回结果或抛出错误之前 await。
    private func deliverSnapshot(
        _ builder: BoneAgentRunSnapshotBuilder,
        terminalState: BoneAgentRunTerminalState
    ) async {
        await modelSnapshotSink.receive(
            builder.snapshot(
                terminalState: terminalState,
                wallClockSeconds: max(0, monotonicClock() - builder.startedAt)
            )
        )
    }
}

/// Run 期间的模型事实累加器；只保存白名单事实，不保存 Prompt、响应正文或 Tool 内容。
private struct BoneAgentRunSnapshotBuilder {
    let request: BoneInferenceRequest
    let resolved: BoneResolvedInferenceCapabilities
    let context: BoneAgentModelSnapshotContext?
    let startedAt: TimeInterval
    var inferenceResponseCount = 0
    var toolResultCount = 0
    var finishReason: BoneInferenceFinishReason?
    var usageByResponse: [BoneInferenceUsage] = []

    /// 记录一次 Engine 已交付响应的可读事实；在取消、预算与 checkpoint 判定之前调用。
    ///
    /// `finishReason` 始终跟随最后一次响应：legacy 单结果形态不携带终止原因，
    /// 因此该次记录会把它重置为 nil（未知），而不是保留上一次 Assistant Turn 的值。
    /// 未报告用量的响应不产生条目，也不按 0 计入合计。
    mutating func record(response: BoneInferenceResponse) {
        inferenceResponseCount += 1
        switch response {
        case .finish, .structured, .toolCall:
            finishReason = nil
        case let .assistantTurn(_, finishReason, usage, _, _):
            self.finishReason = finishReason
            if let usage { usageByResponse.append(usage) }
        }
    }

    func snapshot(
        terminalState: BoneAgentRunTerminalState,
        wallClockSeconds: TimeInterval?
    ) -> BoneAgentRunModelSnapshot {
        BoneAgentRunModelSnapshot(
            modelID: request.modelID,
            modelDisplayName: context?.modelDisplayName,
            modelAlias: context?.modelAlias,
            providerKind: context?.providerKind,
            invocation: resolved.invocation,
            resolvedCapabilities: resolved.capabilities,
            capabilityProfileSource: context?.capabilityProfile?.source,
            capabilityProfileVerifiedAt: context?.capabilityProfile?.verifiedAt,
            contextLimits: context?.contextLimits,
            catalogVersion: context?.catalogVersion,
            catalogVerifiedAt: context?.catalogVerifiedAt,
            generationOptions: request.generationOptions,
            serverReasoning: context?.serverReasoning,
            usesOutputConstraint: request.outputConstraint != nil,
            availableToolCount: request.availableTools.count,
            terminalState: terminalState,
            finishReason: finishReason,
            inferenceResponseCount: inferenceResponseCount,
            toolResultCount: toolResultCount,
            usageByResponse: usageByResponse,
            wallClockSeconds: wallClockSeconds,
            generatedAt: BoneAgentRunModelSnapshot.currentUTCTimestamp()
        )
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
