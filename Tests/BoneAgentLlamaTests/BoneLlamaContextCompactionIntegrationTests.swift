import Foundation
import XCTest
import BoneAgentKit
import BoneAgentLocalModels
@testable import BoneAgentLlama

final class BoneLlamaContextCompactionIntegrationTests: XCTestCase {
    private func engine(_ runtime: ContextRuntime, tools: Bool = false, context: Int = 512) -> BoneLlamaInferenceEngine {
        BoneLlamaInferenceEngine(modelID: "local", modelURL: URL(fileURLWithPath: "/synthetic/model.gguf"),
            plan: .init(contextTokens: context, maximumOutputTokens: 64, batchTokens: 32, threadCount: 1),
            toolEnvelope: tools ? BoneLlamaJSONToolEnvelopeCodec() : nil, runtimeFactory: { runtime })
    }
    func testRuntimeBudgetAndRealCounterPreventOversizeGeneration() async throws {
        let runtime = ContextRuntime()
        let local = engine(runtime)
        XCTAssertEqual(try local.contextBudget(for: "local")?.source, .runtime)
        XCTAssertEqual(try local.contextBudget(for: "local")?.contextWindowTokens, 512)
        let policy = try BoneContextManagementConfiguration(protocolReserveTokens: 0, safetyMarginTokens: 0)
        let agent = BoneAgent(inferenceEngine: local, toolRegistry: try .init(tools: []), toolContext: BoneAgentEmptyContext(),
            configuration: try .init(maximumSteps: 1, contextManagement: policy))
        let result = try await agent.run(modelID: "local", messages: [
            .init(role: .system, content: "rules"), .init(role: .user, content: "old"),
            .init(role: .assistant, content: String(repeating: "x", count: 5_000)), .init(role: .user, content: "now")
        ])
        XCTAssertEqual(result.output, .text("done"))
        let snapshot = await runtime.snapshot()
        XCTAssertEqual(snapshot.loads, 1)
        XCTAssertEqual(snapshot.generations, 1)
        XCTAssertGreaterThan(snapshot.counts, 1)
        XCTAssertFalse(snapshot.prompt.contains(String(repeating: "x", count: 100)))
        XCTAssertTrue(snapshot.prompt.contains("now"))
    }

    func testToolConfiguredEngineCanSummarizeWithNoToolEnvelope() async throws {
        let runtime = ContextRuntime()
        let local = engine(runtime, tools: true, context: 4_096)
        let response = try await local.infer(request: .init(modelID: "local", messages: [.init(role: .user, content: "Summarize historical data")]))
        XCTAssertEqual(response, .finish(.init(text: "done")))
        let snapshot = await runtime.snapshot()
        XCTAssertFalse(snapshot.prompt.contains("tool_calls"))
    }

    func testCounterDoesNotGenerateAndAcceptsNormalizedTextAssistantTurn() async throws {
        let runtime = ContextRuntime()
        let local = engine(runtime)
        let count = try await local.countContextTokens(request: .init(modelID: "local", messages: [
            .init(role: .user, content: "old"), .assistant(try .init(content: [.text("prior answer")])), .init(role: .user, content: "now")
        ]))
        XCTAssertGreaterThan(count, 0)
        let snapshot = await runtime.snapshot()
        XCTAssertEqual(snapshot.generations, 0)
    }

    func testLocalSummaryAndBusinessInferenceShareRuntimeSequentially() async throws {
        let runtime = ContextRuntime()
        let local = engine(runtime, context: 4_096)
        let binding = try BoneInferenceEngineContextSummarizer(engine: local, modelID: "local", budget: XCTUnwrap(local.contextBudget(for: "local")))
        let policy = try BoneContextManagementConfiguration(
            budgetProvider: { _ in try? .init(contextWindowTokens: 512, maximumOutputTokens: 64, source: .host) },
            summarizer: binding, protocolReserveTokens: 0, safetyMarginTokens: 0, maximumSummaryOutputTokens: 64)
        let agent = BoneAgent(inferenceEngine: local, toolRegistry: try .init(tools: []), toolContext: BoneAgentEmptyContext(),
            configuration: try .init(maximumSteps: 1, contextManagement: policy))
        _ = try await agent.run(modelID: "local", messages: [
            .init(role: .user, content: "old"), .init(role: .assistant, content: String(repeating: "old detail ", count: 250)), .init(role: .user, content: "now")
        ])
        let snapshot = await runtime.snapshot()
        XCTAssertEqual(snapshot.generations, 2)
        XCTAssertEqual(snapshot.loads, 1)
        XCTAssertTrue(snapshot.prompt.contains("Historical summary"))
    }
}

private actor ContextRuntime: BoneLlamaRuntime {
    nonisolated let runtimeVersion = 1
    private var loads = 0
    private var generations = 0
    private var counts = 0
    private var prompt = ""
    func load(modelURL: URL, configuration: BoneLlamaRuntimeConfiguration) async throws { loads += 1 }
    func tokenize(prompt: String) async throws -> BoneLlamaPromptTokenization {
        counts += 1
        return try .init(tokenCount: max(1, prompt.utf8.count / 4))
    }
    func generate(prompt: String, executionPlan: BoneLlamaPromptExecutionPlan, options: BoneLlamaGenerationOptions) async throws -> BoneLlamaGenerationResult {
        guard executionPlan.promptTokenCount + options.maximumOutputTokens <= executionPlan.contextTokens else { throw BoneLlamaRuntimeError.promptTooLong }
        generations += 1; self.prompt = prompt
        return .init(text: "done")
    }
    func verifyBasicGeneration() async throws {}
    func cancel() async {}
    func unload() async {}
    func snapshot() -> (loads: Int, generations: Int, counts: Int, prompt: String) { (loads, generations, counts, prompt) }
}
