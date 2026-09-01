import XCTest
@testable import BoneAgentKit

final class BoneAgentTests: XCTestCase {
    /// 验证公共 Tool Result 工厂对非法调用标识返回稳定错误，而不是终止进程。
    func testToolResultFactoryRejectsInvalidCallID() {
        XCTAssertThrowsError(
            try BoneInferenceMessage.toolResult(
                callID: "",
                toolID: "echo",
                result: Data(#"{\"ok\":true}"#.utf8)
            )
        ) { error in
            XCTAssertEqual(error as? BoneInferenceError, .invalidToolResult)
        }
    }

    func testAfterFirstToolTurnBoundaryExecutesToolsAndStopsBeforeSecondInference() async throws {
        let arguments = try JSONEncoder().encode(ProbeEchoTool.Input(value: "candidate"))
        let turn = try BoneInferenceAssistantTurn(content: [
            .toolCall(.init(id: "call-1", toolID: ProbeEchoTool.definition.id, arguments: arguments)),
        ])
        let engine = RequestCapturingEngine(script: [
            .assistantTurn(turn: turn, finishReason: .toolCalls, usage: nil, refusal: nil, providerContinuation: nil),
            .finish(.init(text: "must-not-run")),
        ])
        let registry = try BoneAgentToolRegistry(tools: [BoneAnyAgentTool(ProbeEchoTool())])
        let agent = BoneAgent(
            inferenceEngine: engine,
            toolRegistry: registry,
            toolContext: BoneAgentEmptyContext(),
            configuration: try BoneAgentConfiguration(maximumSteps: 2)
        )

        let result = try await agent.runUntilBoundary(
            request: BoneInferenceRequest(modelID: "model", messages: [.init(role: .user, content: "scan")]),
            boundary: .afterFirstToolTurn
        )

        XCTAssertEqual(result, BoneAgentBoundaryResult(completion: .toolTurnCompleted, steps: 1))
        let inferenceCount = await engine.inferenceCount()
        XCTAssertEqual(inferenceCount, 1)
    }

    func testAfterFirstToolTurnBoundaryStillReturnsNormalModelFinishWithoutTools() async throws {
        let engine = RequestCapturingEngine(script: [.finish(.init(text: "done"))])
        let agent = BoneAgent(
            inferenceEngine: engine,
            toolRegistry: try BoneAgentToolRegistry(tools: []),
            toolContext: BoneAgentEmptyContext(),
            configuration: try BoneAgentConfiguration(maximumSteps: 1)
        )

        let result = try await agent.runUntilBoundary(
            request: BoneInferenceRequest(modelID: "model", messages: [.init(role: .user, content: "scan")]),
            boundary: .afterFirstToolTurn
        )

        XCTAssertEqual(result, BoneAgentBoundaryResult(completion: .modelFinished(.text("done")), steps: 1))
        let inferenceCount = await engine.inferenceCount()
        XCTAssertEqual(inferenceCount, 1)
    }

    func testAuthorizedPrivateLocalReadDoesNotRequireEffectStore() async throws {
        let arguments = try JSONEncoder().encode(ProbeEchoTool.Input(value: "private"))
        let turn = try BoneInferenceAssistantTurn(content: [
            .toolCall(.init(id: "call-1", toolID: PrivateReadProbeTool.definition.id, arguments: arguments)),
        ])
        let engine = RequestCapturingEngine(script: [
            .assistantTurn(turn: turn, finishReason: .toolCalls, usage: nil, refusal: nil, providerContinuation: nil),
            .finish(.init(text: "done")),
        ])
        let registry = try BoneAgentToolRegistry(tools: [BoneAnyAgentTool(PrivateReadProbeTool())])
        let policy = BoneToolImpactPolicy(maximumAllowed: PrivateReadProbeTool.definition.impact!)
        let agent = BoneAgent(
            inferenceEngine: engine,
            toolRegistry: registry,
            toolContext: BoneAgentEmptyContext(),
            configuration: try BoneAgentConfiguration(maximumSteps: 2, toolImpactPolicy: policy)
        )

        let result = try await agent.run(modelID: "model", messages: [.init(role: .user, content: "scan")])

        XCTAssertEqual(result.steps, 2)
    }

    func testInferenceFailurePublishesStableTransportDiagnosticWithoutPayload() async throws {
        let engine = StableFailureEngine(error: BoneInferenceTransportError.firstEventTimedOut)
        let recorder = ProgressRecorder()
        let agent = BoneAgent(
            inferenceEngine: engine,
            toolRegistry: try BoneAgentToolRegistry(tools: []),
            toolContext: BoneAgentEmptyContext(),
            configuration: try BoneAgentConfiguration(maximumSteps: 1),
            progressSink: recorder.sink()
        )

        do {
            _ = try await agent.run(modelID: "model", messages: [.init(role: .user, content: "scan")])
            XCTFail("transport failure must fail the run")
        } catch let error as BoneAgentError {
            XCTAssertEqual(error, .inferenceFailed)
        }
        let values = await recorder.values()
        XCTAssertTrue(values.contains(.inferenceFailed(.firstEventTimedOut)))
    }

    func testProtocolShapeFailurePublishesSafeShapeAndStableInvalidResponse() async throws {
        let diagnostic = BoneInferenceProtocolShapeDiagnostic.openAI(
            events: [BoneInferenceEventStreamEvent(data: "PRIVATE-NOT-JSON")],
            failureStage: .eventJSON
        )
        let engine = StableFailureEngine(error: BoneInferenceProtocolShapeError(diagnostic: diagnostic))
        let recorder = ProgressRecorder()
        let agent = BoneAgent(
            inferenceEngine: engine,
            toolRegistry: try BoneAgentToolRegistry(tools: []),
            toolContext: BoneAgentEmptyContext(),
            configuration: try BoneAgentConfiguration(maximumSteps: 1),
            progressSink: recorder.sink()
        )

        do {
            _ = try await agent.run(modelID: "model", messages: [.init(role: .user, content: "scan")])
            XCTFail("protocol failure must fail the run")
        } catch let error as BoneAgentError {
            XCTAssertEqual(error, .inferenceFailed)
        }
        let values = await recorder.values()
        XCTAssertTrue(values.contains(.inferenceProtocolShapeFailed(diagnostic)))
        XCTAssertTrue(values.contains(.inferenceFailed(.invalidResponse)))
        XCTAssertFalse(diagnostic.summary.contains("PRIVATE"))
    }

    func testRunRequestPreservesGenerationOptionsAndReasoningWhileInjectingRegistryTools() async throws {
        let engine = RequestCapturingEngine()
        let registry = try BoneAgentToolRegistry(tools: [BoneAnyAgentTool(ProbeEchoTool())])
        let agent = BoneAgent(
            inferenceEngine: engine,
            toolRegistry: registry,
            toolContext: BoneAgentEmptyContext(),
            configuration: try BoneAgentConfiguration(maximumSteps: 1)
        )
        let request = BoneInferenceRequest(
            modelID: "model",
            messages: [.init(role: .user, content: "scan")],
            generationOptions: .init(temperature: 0.2, maximumOutputTokens: 2_048),
            reasoningDisclosure: .hidden
        )

        _ = try await agent.run(request: request)

        let captured = await engine.lastRequest()
        let recorded = try XCTUnwrap(captured)
        XCTAssertEqual(recorded.modelID, "model")
        XCTAssertEqual(recorded.messages, request.messages)
        XCTAssertEqual(recorded.generationOptions, request.generationOptions)
        XCTAssertEqual(recorded.reasoningDisclosure, .hidden)
        XCTAssertEqual(recorded.responseFormat, .text)
        XCTAssertEqual(recorded.availableTools.map(\.id), registry.definitions.map(\.id))
    }
}

private actor ProgressRecorder {
    private var recorded = [BoneAgentProgress]()

    nonisolated func sink() -> BoneAgentProgressSink {
        BoneAgentProgressSink { [weak self] value in
            await self?.record(value)
        }
    }

    func record(_ value: BoneAgentProgress) { recorded.append(value) }
    func values() -> [BoneAgentProgress] { recorded }
}

private struct StableFailureEngine: BoneInferenceEngine {
    let nonImageCapabilities: Set<BoneInferenceCapability> = [.text]
    let imageGenerator: (any BoneInferenceImageGenerating)? = nil
    let error: any Error

    func infer(request: BoneInferenceRequest) async throws -> BoneInferenceResponse {
        throw error
    }
}

private actor RequestCapturingEngine: BoneInferenceEngine {
    nonisolated let nonImageCapabilities: Set<BoneInferenceCapability> = [.text, .toolCalling]
    nonisolated let imageGenerator: (any BoneInferenceImageGenerating)? = nil
    private var request: BoneInferenceRequest?
    private var script: [BoneInferenceResponse]
    private var inferenceCallCount = 0

    init(script: [BoneInferenceResponse] = [.finish(.init(text: "done"))]) {
        self.script = script
    }

    func infer(request: BoneInferenceRequest) async throws -> BoneInferenceResponse {
        self.request = request
        inferenceCallCount += 1
        guard !script.isEmpty else { throw BoneInferenceError.invalidResponse }
        return script.removeFirst()
    }

    func lastRequest() -> BoneInferenceRequest? { request }
    func inferenceCount() -> Int { inferenceCallCount }
}

private struct PrivateReadProbeTool: BoneAgentTool {
    typealias Input = ProbeEchoTool.Input
    typealias Output = ProbeEchoTool.Output
    typealias Context = BoneAgentEmptyContext

    static let definition = BoneAgentToolDefinition(
        id: "test.private-read",
        version: "1",
        title: "Private Read",
        summary: "Read already-authorized local private context",
        wireName: "private_read",
        schemaVersion: 1,
        inputSchema: ProbeEchoTool.definition.inputSchema!,
        impact: BoneToolImpact(
            dataAccess: .userPrivate,
            externalTransmission: .none,
            stateChange: .none,
            economic: .none,
            userVisible: .none,
            permissionChange: .none
        )
    )

    func execute(input: Input, context: Context) async throws -> Output {
        Output(value: input.value)
    }
}

private struct ProbeEchoTool: BoneAgentTool {
    struct Input: Codable, Sendable { let value: String }
    struct Output: Codable, Sendable { let value: String }
    typealias Context = BoneAgentEmptyContext

    static let definition = BoneAgentToolDefinition(
        id: "test.probe-echo",
        version: "1",
        title: "Probe Echo",
        summary: "Echo probe input",
        wireName: "probe_echo",
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
