import Foundation
import XCTest
@testable import BoneAgentKit

final class AgentStreamingModeTests: XCTestCase {
    func testAgentUsesOnlyBufferedStream() async throws {
        let engine = ModeEngine()
        let agent = BoneAgent(inferenceEngine: engine, toolRegistry: try .init(tools: []), toolContext: BoneAgentEmptyContext(), configuration: try .init(maximumSteps: 1, inferenceMode: .bufferedStreaming(.init(totalTimeout: 10))))
        _ = try await agent.run(modelID: "fixture", messages: [.init(role: .user, content: "hi")])
        let counts = await engine.counts()
        XCTAssertEqual(counts.0, 0)
        XCTAssertEqual(counts.1, 1)
        let options = await engine.options
        XCTAssertEqual(options?.totalTimeout, 10)
    }

    func testStreamFailureDoesNotRetryOrFallback() async throws {
        let engine = ModeEngine(fails: true)
        let agent = BoneAgent(inferenceEngine: engine, toolRegistry: try .init(tools: []), toolContext: BoneAgentEmptyContext(), configuration: try .init(maximumSteps: 3, inferenceMode: .bufferedStreaming(.init(totalTimeout: 10))))
        do {
            _ = try await agent.run(modelID: "fixture", messages: [.init(role: .user, content: "hi")])
            XCTFail("Expected failure")
        } catch { XCTAssertEqual(error as? BoneAgentError, .inferenceFailed) }
        let counts = await engine.counts()
        XCTAssertEqual(counts.0, 0)
        XCTAssertEqual(counts.1, 1)
    }

    func testRunBudgetIsPassedToStreamAsDeadline() async throws {
        let engine = ModeEngine()
        let budget = try BoneRunBudget(maximumInferenceCalls: 1, maximumToolCalls: 1, maximumInputBytes: 100_000, maximumOutputBytes: 100_000, maximumTurns: 1, maximumWallClockSeconds: 5, maximumConcurrentToolCalls: 1, maximumEstimatedCostMicrounits: 10)
        let before = ProcessInfo.processInfo.systemUptime
        let agent = BoneAgent(inferenceEngine: engine, toolRegistry: try .init(tools: []), toolContext: BoneAgentEmptyContext(), configuration: try .init(maximumSteps: 1, runBudget: budget, inferenceCostEstimator: { _ in 0 }, inferenceMode: .bufferedStreaming(.init(totalTimeout: 100))))
        _ = try await agent.run(modelID: "fixture", messages: [.init(role: .user, content: "hi")])
        let options = await engine.options
        let deadline = try XCTUnwrap(options?.deadlineUptime)
        XCTAssertGreaterThan(deadline, before)
        XCTAssertLessThanOrEqual(deadline, ProcessInfo.processInfo.systemUptime + 5)
    }
}

private actor ModeEngine: BoneInferenceEngine, BoneInferenceBufferedStreaming {
    nonisolated let nonImageCapabilities: Set<BoneInferenceCapability> = [.text, .streaming]
    nonisolated let imageGenerator: (any BoneInferenceImageGenerating)? = nil
    var nonstream = 0
    var stream = 0
    var options: BoneInferenceEventStreamOptions?
    let fails: Bool
    init(fails: Bool = false) { self.fails = fails }
    func infer(request: BoneInferenceRequest) async throws -> BoneInferenceResponse { nonstream += 1; return .finish(.init(text: "ok")) }
    func inferUsingStream(request: BoneInferenceRequest, options: BoneInferenceEventStreamOptions) async throws -> BoneInferenceResponse {
        stream += 1
        self.options = options
        if fails { throw BoneInferenceTransportError.outputTruncated }
        return .finish(.init(text: "ok"))
    }
    func counts() -> (Int, Int) { (nonstream, stream) }
}
