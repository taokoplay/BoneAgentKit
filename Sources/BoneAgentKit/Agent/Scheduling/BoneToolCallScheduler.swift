import Foundation

/// 按 Provider ordinal 确定性调度同轮 Tool Calls。
public struct BoneToolCallScheduler: Sendable {
    public typealias Operation = @Sendable (BoneInferenceToolCall) async throws -> BoneToolResultContent

    public let mode: BoneToolSchedulingMode
    public let failureStrategy: BoneToolFailureStrategy

    public init(
        mode: BoneToolSchedulingMode = .serial,
        failureStrategy: BoneToolFailureStrategy = .failFast
    ) throws {
        if case let .boundedParallel(maximumConcurrency) = mode,
           !(1...BoneInferenceAssistantTurn.maximumToolCallCount).contains(maximumConcurrency) {
            throw BoneToolSchedulerError.invalidConcurrencyLimit
        }
        self.mode = mode
        self.failureStrategy = failureStrategy
    }

    public func execute(
        calls: [BoneInferenceToolCall],
        definitions: [BoneAgentToolDefinition],
        operation: @escaping Operation
    ) async throws -> [BoneInferenceToolResult] {
        guard calls.indices.allSatisfy({ calls[$0].ordinal == $0 }) else {
            throw BoneToolSchedulerError.invalidCallOrder
        }
        let indexed = try index(definitions)
        guard calls.allSatisfy({ indexed[$0.toolID] != nil }) else {
            throw BoneToolSchedulerError.missingToolDefinition
        }

        var results: [BoneInferenceToolResult] = []
        results.reserveCapacity(calls.count)
        for batch in batches(calls: calls, definitions: indexed) {
            try Task.checkCancellation()
            let batchResults: [BoneInferenceToolResult]
            if batch.count == 1 {
                batchResults = try await executeSerial(batch, operation: operation)
            } else {
                batchResults = try await executeParallel(batch, operation: operation)
            }
            try Task.checkCancellation()
            results.append(contentsOf: batchResults)
        }
        return results.sorted { $0.ordinal < $1.ordinal }
    }
}

private extension BoneToolCallScheduler {
    func index(_ definitions: [BoneAgentToolDefinition]) throws -> [String: BoneAgentToolDefinition] {
        var result: [String: BoneAgentToolDefinition] = [:]
        for definition in definitions {
            guard result.updateValue(definition, forKey: definition.id) == nil else {
                throw BoneToolSchedulerError.duplicateToolDefinition
            }
        }
        return result
    }

    func batches(
        calls: [BoneInferenceToolCall],
        definitions: [String: BoneAgentToolDefinition]
    ) -> [[BoneInferenceToolCall]] {
        guard case let .boundedParallel(limit) = mode, limit > 1 else {
            return calls.map { [$0] }
        }
        var batches: [[BoneInferenceToolCall]] = []
        var current: [BoneInferenceToolCall] = []
        var resourceKeys = Set<String>()

        func flush() {
            if !current.isEmpty { batches.append(current) }
            current = []
            resourceKeys = []
        }

        for call in calls {
            guard let definition = definitions[call.toolID],
                  definition.impact?.isOrdinaryReadOnly == true,
                  case let .parallelSafe(keys)? = definition.executionPolicy else {
                flush()
                batches.append([call])
                continue
            }
            if current.count >= limit || !resourceKeys.isDisjoint(with: keys) {
                flush()
            }
            current.append(call)
            resourceKeys.formUnion(keys)
        }
        flush()
        return batches
    }

    func executeSerial(
        _ calls: [BoneInferenceToolCall],
        operation: @escaping Operation
    ) async throws -> [BoneInferenceToolResult] {
        var results: [BoneInferenceToolResult] = []
        for call in calls {
            do {
                let content = try await operation(call)
                try Task.checkCancellation()
                results.append(try makeResult(call: call, content: content, isError: false))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if failureStrategy == .failFast { throw error }
                results.append(try makeResult(call: call, content: .text("tool_execution_failed"), isError: true))
            }
        }
        return results
    }

    func executeParallel(
        _ calls: [BoneInferenceToolCall],
        operation: @escaping Operation
    ) async throws -> [BoneInferenceToolResult] {
        let strategy = failureStrategy
        return try await withThrowingTaskGroup(of: BoneInferenceToolResult.self) { group in
            for call in calls {
                group.addTask {
                    do {
                        let content = try await operation(call)
                        try Task.checkCancellation()
                        return try makeResult(call: call, content: content, isError: false)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        if strategy == .failFast { throw error }
                        return try makeResult(
                            call: call,
                            content: .text("tool_execution_failed"),
                            isError: true
                        )
                    }
                }
            }
            var results: [BoneInferenceToolResult] = []
            do {
                for try await result in group {
                    try Task.checkCancellation()
                    results.append(result)
                }
            } catch {
                group.cancelAll()
                throw error
            }
            try Task.checkCancellation()
            return results.sorted { $0.ordinal < $1.ordinal }
        }
    }

    func makeResult(
        call: BoneInferenceToolCall,
        content: BoneToolResultContent,
        isError: Bool
    ) throws -> BoneInferenceToolResult {
        try .init(
            callID: call.id,
            toolID: call.toolID,
            content: content,
            isError: isError,
            ordinal: call.ordinal
        )
    }
}
