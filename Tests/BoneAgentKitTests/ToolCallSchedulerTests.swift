import Foundation
import XCTest
@testable import BoneAgentKit

/// 调度器测试使用的普通 Tool 执行失败。
private enum SchedulerSyntheticFailure: Error {
    case failed
}

/// 记录 Tool 执行并发度与开始、结束顺序。
private actor SchedulerExecutionProbe {
    /// 当前正在执行的 Tool 数量。
    private var activeCount = 0
    /// 观测到的最大并发 Tool 数量。
    private var maximumActiveCount = 0
    /// Tool 开始执行的顺序。
    private var startedIDs: [String] = []

    /// 记录一个 Tool 开始执行。
    /// - Parameter id: Tool 调用标识。
    func begin(id: String) {
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
        startedIDs.append(id)
    }

    /// 记录一个 Tool 结束执行。
    func end() {
        activeCount -= 1
    }

    /// 返回调度观测快照。
    /// - Returns: 最大并发数与开始顺序。
    func snapshot() -> (maximumActiveCount: Int, startedIDs: [String]) {
        (maximumActiveCount, startedIDs)
    }
}

final class ToolCallSchedulerTests: XCTestCase {
    /// 验证未声明并行安全的 Tool 即使开启并行模式仍保持串行。
    func testUndeclaredParallelSafetyRemainsSerial() async throws {
        let scheduler = try BoneToolCallScheduler(mode: .boundedParallel(maximumConcurrency: 4))
        let calls = [makeCall(id: "a", ordinal: 0), makeCall(id: "b", ordinal: 1)]
        let definitions = calls.map { makeDefinition(id: $0.toolID) }
        let probe = SchedulerExecutionProbe()

        let results = try await scheduler.execute(calls: calls, definitions: definitions) { call in
            await probe.begin(id: call.id)
            try await Task.sleep(for: .milliseconds(5))
            await probe.end()
            return .json(Data(#"{}"#.utf8))
        }

        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.maximumActiveCount, 1)
        XCTAssertEqual(snapshot.startedIDs, ["a", "b"])
        XCTAssertEqual(results.map(\.ordinal), [0, 1])
    }

    /// 验证显式并行安全 Tool 遵守固定并发上限，结果仍按 Provider ordinal 排序。
    func testParallelSafeToolsRespectBoundAndDeterministicOrder() async throws {
        let scheduler = try BoneToolCallScheduler(mode: .boundedParallel(maximumConcurrency: 2))
        let calls = [
            makeCall(id: "a", ordinal: 0),
            makeCall(id: "b", ordinal: 1),
            makeCall(id: "c", ordinal: 2),
        ]
        let definitions = calls.map {
            makeDefinition(
                id: $0.toolID,
                policy: .parallelSafe(resourceKeys: [$0.toolID]),
                impact: .ordinaryPublicRead
            )
        }
        let probe = SchedulerExecutionProbe()

        let results = try await scheduler.execute(calls: calls, definitions: definitions) { call in
            await probe.begin(id: call.id)
            try await Task.sleep(for: .milliseconds(call.ordinal == 0 ? 8 : 2))
            await probe.end()
            return .json(Data(#"{}"#.utf8))
        }

        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.maximumActiveCount, 2)
        XCTAssertEqual(results.map(\.callID), ["a", "b", "c"])
    }

    /// 验证资源键冲突的 Tool 即使声明并行安全也必须串行。
    func testConflictingResourcesRemainSerial() async throws {
        let scheduler = try BoneToolCallScheduler(mode: .boundedParallel(maximumConcurrency: 2))
        let calls = [makeCall(id: "a", ordinal: 0), makeCall(id: "b", ordinal: 1)]
        let definitions = calls.map {
            makeDefinition(
                id: $0.toolID,
                policy: .parallelSafe(resourceKeys: ["shared"]),
                impact: .ordinaryPublicRead
            )
        }
        let probe = SchedulerExecutionProbe()

        _ = try await scheduler.execute(calls: calls, definitions: definitions) { call in
            await probe.begin(id: call.id)
            try await Task.sleep(for: .milliseconds(5))
            await probe.end()
            return .json(Data(#"{}"#.utf8))
        }

        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.maximumActiveCount, 1)
    }

    /// 验证 collectAll 把普通执行失败转换为固定安全结果，并继续后续调用。
    func testCollectAllContinuesAfterOrdinaryExecutionFailure() async throws {
        let scheduler = try BoneToolCallScheduler(failureStrategy: .collectAll)
        let calls = [makeCall(id: "a", ordinal: 0), makeCall(id: "b", ordinal: 1)]
        let definitions = calls.map { makeDefinition(id: $0.toolID) }

        let results = try await scheduler.execute(calls: calls, definitions: definitions) { call in
            if call.id == "a" { throw SchedulerSyntheticFailure.failed }
            return .json(Data(#"{}"#.utf8))
        }

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].content, .text("tool_execution_failed"))
        XCTAssertTrue(results[0].isError)
        XCTAssertFalse(results[1].isError)
    }

    /// 验证 collectAll 仍然传播预算耗尽，不把控制面失败伪装成普通 Tool 结果。
    func testCollectAllDoesNotCollectBudgetFailure() async throws {
        let scheduler = try BoneToolCallScheduler(failureStrategy: .collectAll)
        let call = makeCall(id: "a", ordinal: 0)

        do {
            _ = try await scheduler.execute(calls: [call], definitions: [makeDefinition(id: call.toolID)]) { _ in
                throw BoneAgentError.budgetExceeded
            }
            XCTFail("预算耗尽必须中断批次")
        } catch let error as BoneAgentError {
            XCTAssertEqual(error, .budgetExceeded)
        }
    }

    /// 验证 collectAll 不收集授权、持久化等控制面失败的内部中断标记。
    func testCollectAllDoesNotCollectControlPlaneFailure() async throws {
        let scheduler = try BoneToolCallScheduler(failureStrategy: .collectAll)
        let call = makeCall(id: "a", ordinal: 0)

        do {
            _ = try await scheduler.execute(calls: [call], definitions: [makeDefinition(id: call.toolID)]) { _ in
                throw BoneToolBatchAbortError.controlPlaneFailure
            }
            XCTFail("控制面失败必须中断批次")
        } catch is BoneToolBatchAbortError {
            // 中断标记必须原样传播给 Agent 边界映射。
        }
    }

    /// 验证 collectAll 仍然传播任务取消。
    func testCollectAllDoesNotCollectCancellation() async throws {
        let scheduler = try BoneToolCallScheduler(failureStrategy: .collectAll)
        let call = makeCall(id: "a", ordinal: 0)

        do {
            _ = try await scheduler.execute(calls: [call], definitions: [makeDefinition(id: call.toolID)]) { _ in
                throw CancellationError()
            }
            XCTFail("任务取消必须中断批次")
        } catch is CancellationError {
            // 取消按控制流传播，不生成 Tool 结果。
        }
    }

    /// 验证取消后即使 Operation 非协作地返回结果，调度器也不会交付迟到成功。
    func testCancellationDiscardsLateResults() async throws {
        let scheduler = try BoneToolCallScheduler(mode: .boundedParallel(maximumConcurrency: 2))
        let calls = [makeCall(id: "a", ordinal: 0), makeCall(id: "b", ordinal: 1)]
        let definitions = calls.map {
            makeDefinition(
                id: $0.toolID,
                policy: .parallelSafe(resourceKeys: [$0.toolID]),
                impact: .ordinaryPublicRead
            )
        }
        let task = Task {
            try await scheduler.execute(calls: calls, definitions: definitions) { _ in
                do { try await Task.sleep(for: .seconds(1)) } catch { /* 模拟非协作的迟到返回。 */ }
                return .json(Data(#"{}"#.utf8))
            }
        }

        try await Task.sleep(for: .milliseconds(10))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("取消后的迟到结果不得成功聚合")
        } catch is CancellationError {
            // 取消必须覆盖 Operation 的迟到成功。
        }
    }

    /// 创建测试 Tool 调用。
    /// - Parameters:
    ///   - id: 调用及 Tool 的稳定标识。
    ///   - ordinal: Provider 返回顺序。
    /// - Returns: 无参数的测试调用。
    private func makeCall(id: String, ordinal: Int) -> BoneInferenceToolCall {
        BoneInferenceToolCall(id: id, toolID: id, arguments: Data(#"{}"#.utf8), ordinal: ordinal)
    }

    /// 创建与测试调用匹配的 Tool 定义。
    /// - Parameter id: Tool 的稳定标识。
    /// - Returns: 默认串行执行的 Tool 定义。
    private func makeDefinition(
        id: String,
        policy: BoneToolExecutionPolicy? = nil,
        impact: BoneToolImpact = .ordinaryPublicRead
    ) -> BoneAgentToolDefinition {
        BoneAgentToolDefinition(
            id: id,
            version: "1",
            title: id,
            summary: "test",
            executionPolicy: policy,
            impact: impact
        )
    }
}
