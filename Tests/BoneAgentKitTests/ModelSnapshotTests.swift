import Foundation
import XCTest
@testable import BoneAgentKit

final class ModelSnapshotTests: XCTestCase {
    func testSnapshotArrivesBeforeResultAndCarriesModelFacts() async throws {
        let usage = BoneInferenceUsage(
            inputTokens: 7,
            outputTokens: 3,
            cachedInputTokens: 2,
            reasoningTokens: nil
        )
        let engine = SnapshotScriptedEngine(script: [try Self.assistantTurn(text: "hello", usage: usage)])
        let log = SnapshotLog()
        let agent = BoneAgent(
            inferenceEngine: engine,
            toolRegistry: try .init(tools: []),
            toolContext: BoneAgentEmptyContext(),
            configuration: try BoneAgentConfiguration(maximumSteps: 2),
            modelSnapshotSink: log.sink()
        )

        let result = try await agent.run(
            modelID: "model",
            messages: [.init(role: .user, content: "prompt")],
            snapshotContext: try Self.snapshotContext()
        )
        await log.append("result")

        XCTAssertEqual(result.output, .text("hello"))
        let sequence = await log.sequence()
        XCTAssertEqual(sequence, ["snapshot", "result"])
        let snapshots = await log.values()
        let snapshot = try XCTUnwrap(snapshots.first)
        XCTAssertEqual(snapshot.modelID, "model")
        XCTAssertEqual(snapshot.modelDisplayName, "GLM-5.3-Flash")
        XCTAssertEqual(snapshot.modelAlias, "fast")
        XCTAssertEqual(snapshot.serverReasoning, .providerDefault)
        XCTAssertEqual(snapshot.providerKind, .openAI)
        XCTAssertEqual(snapshot.invocation, .nonStreaming)
        XCTAssertEqual(snapshot.resolvedCapabilities, [.text])
        XCTAssertEqual(snapshot.capabilityProfileSource, .hostVerified)
        XCTAssertEqual(snapshot.capabilityProfileVerifiedAt, "2026-08-28")
        XCTAssertEqual(snapshot.contextLimits?.contextWindowTokens, 200_000)
        XCTAssertEqual(snapshot.catalogVersion, 7)
        XCTAssertEqual(snapshot.catalogVerifiedAt, "2026-08-28")
        XCTAssertEqual(snapshot.availableToolCount, 0)
        XCTAssertFalse(snapshot.usesOutputConstraint)
        XCTAssertEqual(snapshot.terminalState, .succeeded)
        XCTAssertEqual(snapshot.finishReason, .stop)
        XCTAssertEqual(snapshot.inferenceResponseCount, 1)
        XCTAssertEqual(snapshot.toolResultCount, 0)
        XCTAssertEqual(snapshot.usageByResponse, [usage])
        XCTAssertEqual(snapshot.totalUsage, usage)
        let wallClockSeconds = try XCTUnwrap(snapshot.wallClockSeconds)
        XCTAssertGreaterThanOrEqual(wallClockSeconds, 0)
        XCTAssertNotNil(
            snapshot.generatedAt.range(
                of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$"#,
                options: .regularExpression
            )
        )
    }

    func testSnapshotOmitsFactsHostDidNotProvide() async throws {
        let engine = SnapshotScriptedEngine(script: [.finish(.init(text: "hello"))])
        let log = SnapshotLog()
        let agent = BoneAgent(
            inferenceEngine: engine,
            toolRegistry: try .init(tools: []),
            toolContext: BoneAgentEmptyContext(),
            configuration: try BoneAgentConfiguration(maximumSteps: 2),
            modelSnapshotSink: log.sink()
        )

        _ = try await agent.run(modelID: "model", messages: [])

        let delivered = await log.values()
        let snapshot = try XCTUnwrap(delivered.first)
        XCTAssertNil(snapshot.modelDisplayName)
        XCTAssertNil(snapshot.modelAlias)
        XCTAssertNil(snapshot.serverReasoning)
        XCTAssertNil(snapshot.providerKind)
        XCTAssertNil(snapshot.capabilityProfileSource)
        XCTAssertNil(snapshot.capabilityProfileVerifiedAt)
        XCTAssertNil(snapshot.contextLimits)
        XCTAssertNil(snapshot.catalogVersion)
        XCTAssertNil(snapshot.catalogVerifiedAt)
        XCTAssertNil(snapshot.finishReason)
        XCTAssertTrue(snapshot.usageByResponse.isEmpty)
        XCTAssertNil(snapshot.totalUsage)
    }

    func testSnapshotCountsToolsAndKeepsUnreportedUsageOutOfTotal() async throws {
        let call = BoneInferenceToolCall(
            id: "call-1",
            toolID: SnapshotEchoTool.definition.id,
            arguments: try JSONEncoder().encode(SnapshotEchoTool.Input(value: "ok"))
        )
        let usage = BoneInferenceUsage(
            inputTokens: 5,
            outputTokens: 2,
            cachedInputTokens: nil,
            reasoningTokens: 1
        )
        let engine = SnapshotScriptedEngine(
            capabilities: [.text, .toolCalling],
            script: [
                .toolCall(call),
                try Self.assistantTurn(text: "done", usage: usage),
            ]
        )
        let log = SnapshotLog()
        let agent = BoneAgent(
            inferenceEngine: engine,
            toolRegistry: try .init(tools: [BoneAnyAgentTool(SnapshotEchoTool())]),
            toolContext: BoneAgentEmptyContext(),
            configuration: try BoneAgentConfiguration(maximumSteps: 3),
            modelSnapshotSink: log.sink()
        )

        _ = try await agent.run(modelID: "model", messages: [])

        let delivered = await log.values()
        let snapshot = try XCTUnwrap(delivered.first)
        XCTAssertEqual(snapshot.availableToolCount, 1)
        XCTAssertEqual(snapshot.inferenceResponseCount, 2)
        XCTAssertEqual(snapshot.toolResultCount, 1)
        // legacy `.toolCall` 响应不报告用量，因此只产生一个明细条目。
        XCTAssertEqual(snapshot.usageByResponse, [usage])
        XCTAssertEqual(snapshot.totalUsage, usage)
        XCTAssertEqual(snapshot.finishReason, .stop)
    }

    func testUsageTotalKeepsUnknownOptionalFields() throws {
        let snapshot = BoneAgentRunModelSnapshot(
            modelID: "model",
            modelDisplayName: "  GLM-5.3-Flash  ",
            modelAlias: "   ",
            invocation: .nonStreaming,
            resolvedCapabilities: [.text],
            generationOptions: .init(),
            serverReasoning: .enabled,
            usesOutputConstraint: false,
            availableToolCount: 0,
            terminalState: .succeeded,
            inferenceResponseCount: 2,
            toolResultCount: 0,
            usageByResponse: [
                BoneInferenceUsage(
                    inputTokens: 1,
                    outputTokens: 2,
                    cachedInputTokens: 3,
                    reasoningTokens: nil
                ),
                BoneInferenceUsage(
                    inputTokens: 10,
                    outputTokens: 20,
                    cachedInputTokens: nil,
                    reasoningTokens: 4
                ),
            ],
            generatedAt: "2026-09-18T12:00:00.000Z"
        )

        XCTAssertEqual(snapshot.totalUsage?.inputTokens, 11)
        XCTAssertEqual(snapshot.totalUsage?.outputTokens, 22)
        // 任一报告者缺失该可选字段时合计保持未知，不把缺失当成 0。
        XCTAssertNil(snapshot.totalUsage?.cachedInputTokens)
        XCTAssertNil(snapshot.totalUsage?.reasoningTokens)
        // 显示名与别名只做空白归一，空串等于未提供。
        XCTAssertEqual(snapshot.modelDisplayName, "GLM-5.3-Flash")
        XCTAssertNil(snapshot.modelAlias)
        XCTAssertEqual(snapshot.serverReasoning, .enabled)
    }

    func testSnapshotRoundTripsThroughCodableWithoutPersistingDerivedTotal() throws {
        let snapshot = BoneAgentRunModelSnapshot(
            modelID: "model",
            modelDisplayName: "GLM-5.3-Flash",
            modelAlias: "fast",
            providerKind: .custom,
            invocation: .streaming,
            resolvedCapabilities: [.text, .streaming],
            capabilityProfileSource: .official,
            capabilityProfileVerifiedAt: "2026-08-28",
            catalogVersion: 7,
            catalogVerifiedAt: "2026-08-28",
            generationOptions: .init(temperature: 0.2, maximumOutputTokens: 256),
            serverReasoning: .disabled,
            usesOutputConstraint: true,
            availableToolCount: 3,
            terminalState: .failed(.inferenceFailed),
            inferenceResponseCount: 1,
            toolResultCount: 0,
            usageByResponse: [
                BoneInferenceUsage(
                    inputTokens: 4,
                    outputTokens: 6,
                    cachedInputTokens: 1,
                    reasoningTokens: 2
                ),
            ],
            wallClockSeconds: 1.5,
            generatedAt: "2026-09-18T12:00:00.000Z"
        )

        let data = try JSONEncoder().encode(snapshot)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        // 派生合计不落盘；用解码后的键判定，避免字符串转义与键改名造成假通过。
        XCTAssertNil(object["totalUsage"])
        let decoded = try JSONDecoder().decode(BoneAgentRunModelSnapshot.self, from: data)
        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(decoded.totalUsage?.inputTokens, 4)
    }

    func testFailureAndCancellationStillDeliverSnapshot() async throws {
        let failureLog = SnapshotLog()
        let failingAgent = BoneAgent(
            inferenceEngine: SnapshotScriptedEngine(failure: BoneInferenceError.invalidResponse),
            toolRegistry: try .init(tools: []),
            toolContext: BoneAgentEmptyContext(),
            configuration: try BoneAgentConfiguration(maximumSteps: 2),
            modelSnapshotSink: failureLog.sink()
        )
        do {
            _ = try await failingAgent.run(modelID: "model", messages: [])
            XCTFail("expected inference failure")
        } catch {
            XCTAssertEqual(error as? BoneAgentError, .inferenceFailed)
        }
        let failedSnapshots = await failureLog.values()
        let failedSnapshot = try XCTUnwrap(failedSnapshots.first)
        XCTAssertEqual(failedSnapshots.count, 1)
        XCTAssertEqual(failedSnapshot.terminalState, .failed(.inferenceFailed))
        XCTAssertEqual(failedSnapshot.inferenceResponseCount, 0)

        let cancelLog = SnapshotLog()
        let slowAgent = BoneAgent(
            inferenceEngine: SnapshotScriptedEngine(delay: 5),
            toolRegistry: try .init(tools: []),
            toolContext: BoneAgentEmptyContext(),
            configuration: try BoneAgentConfiguration(maximumSteps: 2),
            modelSnapshotSink: cancelLog.sink()
        )
        let task = Task { try await slowAgent.run(modelID: "model", messages: []) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let cancelledSnapshots = await cancelLog.values()
        let cancelledSnapshot = try XCTUnwrap(cancelledSnapshots.first)
        XCTAssertEqual(cancelledSnapshots.count, 1)
        XCTAssertEqual(cancelledSnapshot.terminalState, .cancelled)
    }

    func testSnapshotNeverCarriesPromptToolArgumentsOrCredentialText() async throws {
        let call = BoneInferenceToolCall(
            id: "call-1",
            toolID: SnapshotEchoTool.definition.id,
            arguments: try JSONEncoder().encode(SnapshotEchoTool.Input(value: "SECRET-TOOL-ARGUMENT"))
        )
        let engine = SnapshotScriptedEngine(
            capabilities: [.text, .toolCalling],
            script: [.toolCall(call), .finish(.init(text: "done"))]
        )
        let log = SnapshotLog()
        let agent = BoneAgent(
            inferenceEngine: engine,
            toolRegistry: try .init(tools: [BoneAnyAgentTool(SnapshotEchoTool())]),
            toolContext: BoneAgentEmptyContext(),
            configuration: try BoneAgentConfiguration(maximumSteps: 3),
            modelSnapshotSink: log.sink()
        )

        _ = try await agent.run(
            modelID: "model",
            messages: [.init(role: .user, content: "SECRET-PROMPT-TEXT")]
        )

        let recorded = await log.values()
        let snapshot = try XCTUnwrap(recorded.first)
        let json = try XCTUnwrap(String(data: try JSONEncoder().encode(snapshot), encoding: .utf8))
        XCTAssertFalse(json.contains("SECRET-PROMPT-TEXT"))
        XCTAssertFalse(json.contains("SECRET-TOOL-ARGUMENT"))
        XCTAssertEqual(snapshot.toolResultCount, 1)
    }

    func testCapabilityGateRejectionDeliversNoSnapshot() async throws {
        let log = SnapshotLog()
        let agent = BoneAgent(
            inferenceEngine: SnapshotScriptedEngine(capabilities: [.text], script: [.finish(.init(text: "done"))]),
            toolRegistry: try .init(tools: [BoneAnyAgentTool(SnapshotEchoTool())]),
            toolContext: BoneAgentEmptyContext(),
            configuration: try BoneAgentConfiguration(maximumSteps: 2),
            modelSnapshotSink: log.sink()
        )

        do {
            _ = try await agent.run(modelID: "model", messages: [])
            XCTFail("expected capability rejection")
        } catch {
            XCTAssertEqual(error as? BoneAgentError, .unsupportedCapability(.toolCalling))
        }
        let rejected = await log.values()
        XCTAssertTrue(rejected.isEmpty)
    }

    func testMixedResponseShapesDoNotReportStaleFinishReason() async throws {
        let usage = BoneInferenceUsage(
            inputTokens: 12,
            outputTokens: 4,
            cachedInputTokens: nil,
            reasoningTokens: nil
        )
        let call = BoneInferenceToolCall(
            id: "call-1",
            toolID: SnapshotEchoTool.definition.id,
            arguments: try JSONEncoder().encode(SnapshotEchoTool.Input(value: "ok"))
        )
        // 本地 Tool Envelope 会先出 assistantTurn（tool_calls），final 阶段出 legacy finish。
        let engine = SnapshotScriptedEngine(
            capabilities: [.text, .toolCalling],
            script: [
                .assistantTurn(
                    turn: try .init(content: [.toolCall(call)]),
                    finishReason: .toolCalls,
                    usage: usage,
                    refusal: nil,
                    providerContinuation: nil
                ),
                .finish(.init(text: "done")),
            ]
        )
        let log = SnapshotLog()
        let agent = BoneAgent(
            inferenceEngine: engine,
            toolRegistry: try .init(tools: [BoneAnyAgentTool(SnapshotEchoTool())]),
            toolContext: BoneAgentEmptyContext(),
            configuration: try BoneAgentConfiguration(maximumSteps: 3),
            modelSnapshotSink: log.sink()
        )

        _ = try await agent.run(modelID: "model", messages: [])

        let mixedSnapshots = await log.values()
        let snapshot = try XCTUnwrap(mixedSnapshots.first)
        XCTAssertEqual(snapshot.terminalState, .succeeded)
        XCTAssertEqual(snapshot.inferenceResponseCount, 2)
        XCTAssertEqual(snapshot.toolResultCount, 1)
        // 最后一次响应是 legacy finish，形态本身不携带原因，不得保留上一轮的 .toolCalls。
        XCTAssertNil(snapshot.finishReason)
        XCTAssertEqual(snapshot.usageByResponse, [usage])
    }

    func testDeliveredResponseSurvivesCheckpointFailure() async throws {
        let usage = BoneInferenceUsage(
            inputTokens: 9,
            outputTokens: 5,
            cachedInputTokens: nil,
            reasoningTokens: nil
        )
        let engine = SnapshotScriptedEngine(script: [try Self.assistantTurn(text: "hello", usage: usage)])
        let log = SnapshotLog()
        let agent = BoneAgent(
            inferenceEngine: engine,
            toolRegistry: try .init(tools: []),
            toolContext: BoneAgentEmptyContext(),
            configuration: try BoneAgentConfiguration(maximumSteps: 2),
            progressSink: .init { _ in throw SnapshotSinkError.denied },
            modelSnapshotSink: log.sink()
        )

        do {
            _ = try await agent.run(modelID: "model", messages: [])
            XCTFail("expected checkpoint failure")
        } catch {
            XCTAssertEqual(error as? BoneAgentError, .inferenceFailed)
        }

        let delivered = await log.values()
        let snapshot = try XCTUnwrap(delivered.first)
        XCTAssertEqual(snapshot.terminalState, .failed(.inferenceFailed))
        // Provider 调用已经发生，checkpoint 失败不能把这次响应记成 0。
        XCTAssertEqual(snapshot.inferenceResponseCount, 1)
        XCTAssertEqual(snapshot.finishReason, .stop)
        XCTAssertEqual(snapshot.usageByResponse, [usage])
    }

    func testToolResultsReceivedAreCountedWhenPublishingFails() async throws {
        let calls = try ["call-1", "call-2"].map { id in
            BoneInferenceToolCall(
                id: id,
                toolID: SnapshotEchoTool.definition.id,
                arguments: try JSONEncoder().encode(SnapshotEchoTool.Input(value: id))
            )
        }
        let engine = SnapshotScriptedEngine(
            capabilities: [.text, .toolCalling],
            script: [
                .assistantTurn(
                    turn: try .init(content: calls.map { .toolCall($0) }),
                    finishReason: .toolCalls,
                    usage: nil,
                    refusal: nil,
                    providerContinuation: nil
                ),
            ]
        )
        let log = SnapshotLog()
        let progress = SnapshotProgressRecorder(failOnToolResultOrdinal: 2)
        let agent = BoneAgent(
            inferenceEngine: engine,
            toolRegistry: try .init(tools: [BoneAnyAgentTool(SnapshotEchoTool())]),
            toolContext: BoneAgentEmptyContext(),
            configuration: try BoneAgentConfiguration(maximumSteps: 2),
            progressSink: progress.sink(),
            modelSnapshotSink: log.sink()
        )

        do {
            _ = try await agent.run(modelID: "model", messages: [])
            XCTFail("expected publish failure")
        } catch {
            // executeTurn 将未识别的进度错误归为 Tool 执行失败（现有行为，未在本次改动范围内）。
            XCTAssertEqual(error as? BoneAgentError, .toolExecutionFailed)
        }

        let published = await log.values()
        let snapshot = try XCTUnwrap(published.first)
        XCTAssertEqual(snapshot.terminalState, .failed(.toolExecutionFailed))
        // 两个 Tool 都已执行，第二个结果发布失败不能把第一个丢掉。
        XCTAssertEqual(snapshot.toolResultCount, 2)
        XCTAssertEqual(snapshot.inferenceResponseCount, 1)
    }

    func testCancellationAfterDeliveredResponseKeepsItCounted() async throws {
        let usage = BoneInferenceUsage(
            inputTokens: 21,
            outputTokens: 7,
            cachedInputTokens: nil,
            reasoningTokens: nil
        )
        let gate = SnapshotInferenceGate()
        let engine = SnapshotScriptedEngine(
            script: [try Self.assistantTurn(text: "hello", usage: usage)],
            gate: gate
        )
        let log = SnapshotLog()
        let agent = BoneAgent(
            inferenceEngine: engine,
            toolRegistry: try .init(tools: []),
            toolContext: BoneAgentEmptyContext(),
            configuration: try BoneAgentConfiguration(maximumSteps: 2),
            modelSnapshotSink: log.sink()
        )

        let task = Task { try await agent.run(modelID: "model", messages: []) }
        await gate.waitUntilEntered()
        task.cancel()
        await gate.release()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        let snapshots = await log.values()
        let snapshot = try XCTUnwrap(snapshots.first)
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshot.terminalState, .cancelled)
        // 响应已在取消判定之前交付，仍是已计费的一次调用。
        XCTAssertEqual(snapshot.inferenceResponseCount, 1)
        XCTAssertEqual(snapshot.usageByResponse, [usage])
    }

    func testStepLimitAndToolTurnBoundaryReportTerminalState() async throws {
        let call = BoneInferenceToolCall(
            id: "call-1",
            toolID: SnapshotEchoTool.definition.id,
            arguments: try JSONEncoder().encode(SnapshotEchoTool.Input(value: "ok"))
        )
        let limitEngine = SnapshotScriptedEngine(capabilities: [.text, .toolCalling], script: [.toolCall(call)])
        let limitLog = SnapshotLog()
        let limitAgent = BoneAgent(
            inferenceEngine: limitEngine,
            toolRegistry: try .init(tools: [BoneAnyAgentTool(SnapshotEchoTool())]),
            toolContext: BoneAgentEmptyContext(),
            configuration: try BoneAgentConfiguration(maximumSteps: 1),
            modelSnapshotSink: limitLog.sink()
        )

        do {
            _ = try await limitAgent.run(modelID: "model", messages: [])
            XCTFail("expected step limit")
        } catch {
            XCTAssertEqual(error as? BoneAgentError, .stepLimitReached)
        }
        let limitSnapshots = await limitLog.values()
        let limitSnapshot = try XCTUnwrap(limitSnapshots.first)
        XCTAssertEqual(limitSnapshot.terminalState, .failed(.stepLimitReached))
        XCTAssertEqual(limitSnapshot.toolResultCount, 1)
        XCTAssertEqual(limitSnapshot.inferenceResponseCount, 1)
        XCTAssertNil(limitSnapshot.finishReason)

        let boundaryEngine = SnapshotScriptedEngine(capabilities: [.text, .toolCalling], script: [.toolCall(call)])
        let boundaryLog = SnapshotLog()
        let boundaryAgent = BoneAgent(
            inferenceEngine: boundaryEngine,
            toolRegistry: try .init(tools: [BoneAnyAgentTool(SnapshotEchoTool())]),
            toolContext: BoneAgentEmptyContext(),
            configuration: try BoneAgentConfiguration(maximumSteps: 2),
            modelSnapshotSink: boundaryLog.sink()
        )

        let result = try await boundaryAgent.runUntilBoundary(
            request: .init(modelID: "model", messages: []),
            boundary: .afterFirstToolTurn
        )
        XCTAssertEqual(result.completion, .toolTurnCompleted)
        let boundarySnapshots = await boundaryLog.values()
        let boundarySnapshot = try XCTUnwrap(boundarySnapshots.first)
        XCTAssertEqual(boundarySnapshot.terminalState, .succeeded)
        XCTAssertEqual(boundarySnapshot.toolResultCount, 1)
    }

    func testEncodedKeySetMatchesDocumentedWhitelist() async throws {
        let usage = BoneInferenceUsage(
            inputTokens: 3,
            outputTokens: 1,
            cachedInputTokens: nil,
            reasoningTokens: nil
        )
        let engine = SnapshotScriptedEngine(script: [try Self.assistantTurn(text: "hello", usage: usage)])
        let log = SnapshotLog()
        let agent = BoneAgent(
            inferenceEngine: engine,
            toolRegistry: try .init(tools: []),
            toolContext: BoneAgentEmptyContext(),
            configuration: try BoneAgentConfiguration(maximumSteps: 2),
            modelSnapshotSink: log.sink()
        )

        _ = try await agent.run(
            modelID: "model",
            messages: [.init(role: .user, content: "SECRET-PROMPT-TEXT")],
            snapshotContext: try Self.snapshotContext()
        )

        let whitelisted = await log.values()
        let snapshot = try XCTUnwrap(whitelisted.first)
        let data = try JSONEncoder().encode(snapshot)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        // 白名单是硬约束：新增字段必须先改这里和文档，不能默默出现在可落盘记录里。
        XCTAssertEqual(Set(object.keys), Self.documentedSnapshotKeys)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("SECRET-PROMPT-TEXT"))
        // 唯一的 URL 例外是 Host 声明的公开文档地址；对解码后的值断言，避免 JSON 转义造成假判定。
        let limits = try XCTUnwrap(object["contextLimits"] as? [String: Any])
        XCTAssertEqual(limits["documentationURL"] as? String, "https://example.com/models")
    }

    private static let documentedSnapshotKeys: Set<String> = [
        "modelID", "modelDisplayName", "modelAlias", "providerKind", "invocation",
        "resolvedCapabilities", "capabilityProfileSource", "capabilityProfileVerifiedAt",
        "contextLimits", "catalogVersion", "catalogVerifiedAt", "generationOptions",
        "serverReasoning", "usesOutputConstraint", "availableToolCount", "terminalState",
        "finishReason", "inferenceResponseCount", "toolResultCount", "usageByResponse",
        "wallClockSeconds", "generatedAt",
    ]

    private static func assistantTurn(
        text: String,
        usage: BoneInferenceUsage?
    ) throws -> BoneInferenceResponse {
        .assistantTurn(
            turn: try .init(content: [.text(text)]),
            finishReason: .stop,
            usage: usage,
            refusal: nil,
            providerContinuation: nil
        )
    }

    private static func snapshotContext() throws -> BoneAgentModelSnapshotContext {
        BoneAgentModelSnapshotContext(
            providerKind: .openAI,
            modelDisplayName: "GLM-5.3-Flash",
            modelAlias: "fast",
            serverReasoning: .providerDefault,
            capabilityProfile: try BoneModelCapabilityProfile(
                capabilities: [.text, .toolCalling],
                source: .hostVerified,
                verifiedAt: "2026-08-28"
            ),
            contextLimits: try BoneModelContextLimits(
                contextWindowTokens: 200_000,
                maximumInputTokens: 180_000,
                maximumOutputTokens: 8_192,
                source: .official,
                verifiedAt: "2026-08-28",
                documentationURL: URL(string: "https://example.com/models")!
            ),
            catalogVersion: 7,
            catalogVerifiedAt: "2026-08-28"
        )
    }
}

private enum SnapshotSinkError: Error { case denied }

private actor SnapshotScriptedEngine: BoneInferenceEngine {
    nonisolated let nonImageCapabilities: Set<BoneInferenceCapability>
    nonisolated let imageGenerator: (any BoneInferenceImageGenerating)? = nil

    private var script: [BoneInferenceResponse]
    private let delaySeconds: TimeInterval?
    private let failure: (any Error)?
    private let gate: SnapshotInferenceGate?

    init(
        capabilities: Set<BoneInferenceCapability> = [.text],
        script: [BoneInferenceResponse] = [],
        delay: TimeInterval? = nil,
        failure: (any Error)? = nil,
        gate: SnapshotInferenceGate? = nil
    ) {
        nonImageCapabilities = capabilities
        self.script = script
        delaySeconds = delay
        self.failure = failure
        self.gate = gate
    }

    func infer(request: BoneInferenceRequest) async throws -> BoneInferenceResponse {
        if let delaySeconds {
            try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
        }
        if let failure { throw failure }
        if let gate { await gate.suspend() }
        guard !script.isEmpty else { throw BoneInferenceError.invalidResponse }
        return script.removeFirst()
    }
}

/// 在响应交付前挂起 Engine，让测试能确定性地在推理进行中取消 Run。
private actor SnapshotInferenceGate {
    private var entered = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func suspend() async {
        entered = true
        entryWaiter?.resume()
        entryWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiter = $0 }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

/// 可选在第 N 个 Tool 结果发布时抛错的进度记录器。
private actor SnapshotProgressRecorder {
    private let failOnToolResultOrdinal: Int
    private var toolResultCount = 0

    init(failOnToolResultOrdinal: Int) {
        self.failOnToolResultOrdinal = failOnToolResultOrdinal
    }

    nonisolated func sink() -> BoneAgentProgressSink {
        BoneAgentProgressSink { [weak self] progress in
            try await self?.record(progress)
        }
    }

    private func record(_ progress: BoneAgentProgress) throws {
        guard case .toolResultPrepared = progress else { return }
        toolResultCount += 1
        guard toolResultCount < failOnToolResultOrdinal else {
            throw SnapshotSinkError.denied
        }
    }
}

private actor SnapshotLog {
    private var snapshots = [BoneAgentRunModelSnapshot]()
    private var order = [String]()

    nonisolated func sink() -> BoneAgentModelSnapshotSink {
        BoneAgentModelSnapshotSink { [weak self] snapshot in
            await self?.record(snapshot)
        }
    }

    func record(_ snapshot: BoneAgentRunModelSnapshot) {
        snapshots.append(snapshot)
        order.append("snapshot")
    }

    func append(_ value: String) { order.append(value) }
    func values() -> [BoneAgentRunModelSnapshot] { snapshots }
    func sequence() -> [String] { order }
}

private struct SnapshotEchoTool: BoneAgentTool {
    struct Input: Codable, Sendable { let value: String }
    struct Output: Codable, Sendable { let value: String }
    typealias Context = BoneAgentEmptyContext

    static let definition = BoneAgentToolDefinition(
        id: "test.snapshot-echo",
        version: "1",
        title: "Snapshot Echo",
        summary: "Echo snapshot probe input",
        wireName: "snapshot_echo",
        schemaVersion: 1,
        inputSchema: .object(
            properties: [
                "value": .string(enumValues: [], minimumLength: 1, maximumLength: 64),
            ],
            required: ["value"],
            additionalProperties: false
        ),
        impact: .ordinaryPublicRead
    )

    func execute(input: Input, context: BoneAgentEmptyContext) async throws -> Output {
        Output(value: input.value)
    }
}
