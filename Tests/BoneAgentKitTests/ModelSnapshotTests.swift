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
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("totalUsage"))
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

private actor SnapshotScriptedEngine: BoneInferenceEngine {
    nonisolated let nonImageCapabilities: Set<BoneInferenceCapability>
    nonisolated let imageGenerator: (any BoneInferenceImageGenerating)? = nil

    private var script: [BoneInferenceResponse]
    private let delaySeconds: TimeInterval?
    private let failure: (any Error)?

    init(
        capabilities: Set<BoneInferenceCapability> = [.text],
        script: [BoneInferenceResponse] = [],
        delay: TimeInterval? = nil,
        failure: (any Error)? = nil
    ) {
        nonImageCapabilities = capabilities
        self.script = script
        delaySeconds = delay
        self.failure = failure
    }

    func infer(request: BoneInferenceRequest) async throws -> BoneInferenceResponse {
        if let delaySeconds {
            try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
        }
        if let failure { throw failure }
        guard !script.isEmpty else { throw BoneInferenceError.invalidResponse }
        return script.removeFirst()
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
