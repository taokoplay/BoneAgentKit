import BoneAgentKit
import BoneAgentLocalRuntime
import XCTest
@testable import BoneAgentLlama

final class BoneLlamaInferenceEngineTests: XCTestCase {
    func testDeclaresOnlyTextAndMapsGenerationResponse() async throws {
        let runtime = EngineRuntimeFixture(result: " Answer ")
        let engine = BoneLlamaInferenceEngine(
            modelID: "model",
            modelURL: URL(fileURLWithPath: "/tmp/model.gguf"),
            plan: .init(contextTokens: 512, maximumOutputTokens: 64, batchTokens: 32, threadCount: 2),
            runtimeFactory: { runtime }
        )
        XCTAssertEqual(engine.nonImageCapabilities, [.text])
        XCTAssertNil(engine.imageGenerator)

        let response = try await engine.infer(request: .init(
            modelID: "model",
            messages: [.init(role: .user, content: "Hello")],
            generationOptions: .init(temperature: 0.5, maximumOutputTokens: 100)
        ))

        XCTAssertEqual(response, .finish(.init(text: "Answer")))
        let snapshot = await runtime.snapshot()
        XCTAssertEqual(snapshot.loadCount, 1)
        XCTAssertEqual(snapshot.generateCount, 1)
        XCTAssertEqual(snapshot.maximumOutputTokens, 64)
    }

    func testToolCallingCodecEnablesCapabilityAndMapsResponse() async throws {
        let runtime = EngineRuntimeFixture(result: """
        {"tool_calls":[{"id":"call-1","name":"echo","arguments":{"value":"hello"}}]}
        """)
        let engine = BoneLlamaInferenceEngine(
            modelID: "model",
            modelURL: URL(fileURLWithPath: "/tmp/model.gguf"),
            plan: .init(contextTokens: 512, maximumOutputTokens: 64, batchTokens: 32, threadCount: 2),
            toolCalling: BoneLlamaJSONToolCallingCodec(),
            runtimeFactory: { runtime }
        )
        XCTAssertEqual(engine.nonImageCapabilities, [.text, .toolCalling])
        let request = BoneInferenceRequest(
            modelID: "model",
            messages: [.init(role: .user, content: "Echo hello")],
            availableTools: [Self.tool]
        )

        let resolved = try engine.resolvedCapabilities(for: request, invocation: .nonStreaming)
        XCTAssertEqual(resolved.capabilities, [.text, .toolCalling])
        let response = try await engine.infer(request: request)

        guard case let .assistantTurn(turn, reason, _, _, _) = response else {
            return XCTFail("Expected assistant turn")
        }
        XCTAssertEqual(reason, .toolCalls)
        XCTAssertEqual(turn.toolCalls.first?.toolID, "test.echo")
        let snapshot = await runtime.snapshot()
        XCTAssertTrue(snapshot.lastPrompt?.contains("\"name\":\"echo\"") == true)
    }

    func testUsesRealTokenCountToSlicePrefillAndClampOutput() async throws {
        let runtime = EngineRuntimeFixture(result: "ok", tokenCount: 450)
        let engine = BoneLlamaInferenceEngine(
            modelID: "model",
            modelURL: URL(fileURLWithPath: "/tmp/model.gguf"),
            plan: .init(contextTokens: 512, maximumOutputTokens: 128, batchTokens: 200, threadCount: 2),
            runtimeFactory: { runtime }
        )
        _ = try await engine.infer(request: .init(
            modelID: "model",
            messages: [.init(role: .user, content: "short characters do not determine token count")]
        ))

        let snapshot = await runtime.snapshot()
        XCTAssertEqual(snapshot.maximumOutputTokens, 62)
        XCTAssertEqual(snapshot.prefillRanges, [0..<200, 200..<400, 400..<450])
    }

    func testRejectsPromptAtContextLimitBeforeGenerate() async throws {
        let runtime = EngineRuntimeFixture(result: "unused", tokenCount: 512)
        let engine = BoneLlamaInferenceEngine(
            modelID: "model",
            modelURL: URL(fileURLWithPath: "/tmp/model.gguf"),
            plan: .init(contextTokens: 512, maximumOutputTokens: 64, batchTokens: 128, threadCount: 2),
            runtimeFactory: { runtime }
        )
        do {
            _ = try await engine.infer(request: .init(
                modelID: "model",
                messages: [.init(role: .user, content: "Hi")]
            ))
            XCTFail("Expected promptTooLong")
        } catch {
            XCTAssertEqual(error as? BoneLlamaAdapterError, .runtime(.promptTooLong))
        }
        let snapshot = await runtime.snapshot()
        XCTAssertEqual(snapshot.generateCount, 0)
    }

    func testReusesLoadedRuntimeAndFailsClosed() async throws {
        let runtime = EngineRuntimeFixture(result: "ok")
        let engine = BoneLlamaInferenceEngine(
            modelID: "model",
            modelURL: URL(fileURLWithPath: "/tmp/model.gguf"),
            plan: .init(contextTokens: 512, maximumOutputTokens: 64, batchTokens: 32, threadCount: 2),
            runtimeFactory: { runtime }
        )
        let request = BoneInferenceRequest(modelID: "model", messages: [.init(role: .user, content: "Hi")])
        _ = try await engine.infer(request: request)
        _ = try await engine.infer(request: request)
        let snapshot = await runtime.snapshot()
        XCTAssertEqual(snapshot.loadCount, 1)

        do {
            _ = try await engine.infer(request: .init(modelID: "other", messages: [.init(role: .user, content: "Hi")]))
            XCTFail("Expected model mismatch")
        } catch {
            XCTAssertEqual(error as? BoneLlamaAdapterError, .modelMismatch)
        }
    }

    func testRejectsUnsupportedAndEmptyResponses() async throws {
        let emptyRuntime = EngineRuntimeFixture(result: "  ")
        let engine = BoneLlamaInferenceEngine(
            modelID: "model", modelURL: URL(fileURLWithPath: "/tmp/model.gguf"),
            plan: .init(contextTokens: 512, maximumOutputTokens: 64, batchTokens: 32, threadCount: 2),
            runtimeFactory: { emptyRuntime }
        )
        do {
            _ = try await engine.infer(request: .init(modelID: "model", messages: [.init(role: .user, content: "Hi")]))
            XCTFail("Expected empty response")
        } catch {
            XCTAssertEqual(error as? BoneLlamaAdapterError, .emptyResponse)
        }
    }

    func testStateStreamReplaysCurrentAndReportsOperationCompletion() async throws {
        let runtime = ControlledEngineRuntimeFixture()
        let engine = makeControlledEngine(runtime)
        let stream = await engine.modelStateUpdates()
        var iterator = stream.makeAsyncIterator()
        let initial = await iterator.next()
        XCTAssertEqual(initial?.phase, .notLoaded)

        let localRequest = BoneInferenceRequest(modelID: "model", messages: [.init(role: .user, content: "Hi")])
        let inference = Task { try await engine.infer(request: localRequest) }
        await runtime.waitUntilLoadStarts()
        let loading = await iterator.next()
        XCTAssertEqual(loading?.phase, .loading)

        await runtime.finishLoad()
        await runtime.waitUntilGenerateStarts()
        let current = await engine.currentModelState()
        XCTAssertEqual(current.phase, .generating)
        let generating = await iterator.next()
        XCTAssertEqual(generating?.phase, .generating)

        await runtime.finishGenerate()
        _ = try await inference.value
        let completed = await iterator.next()
        XCTAssertEqual(completed?.phase, .loaded)
        XCTAssertGreaterThan(completed?.revision ?? 0, 0)

        let unload = Task { await engine.unload() }
        let unloading = await iterator.next()
        XCTAssertEqual(unloading?.phase, .unloading)
        await unload.value
        let unloaded = await iterator.next()
        XCTAssertEqual(unloaded?.phase, .notLoaded)
    }

    func testStateStreamMulticastsAndReportsTypedFailure() async {
        let runtime = ControlledEngineRuntimeFixture(loadError: .modelIncompatible)
        let engine = makeControlledEngine(runtime)
        var first = await engine.modelStateUpdates().makeAsyncIterator()
        var second = await engine.modelStateUpdates().makeAsyncIterator()
        let firstInitial = await first.next()
        XCTAssertEqual(firstInitial?.phase, .notLoaded)
        let secondInitial = await second.next()
        XCTAssertEqual(secondInitial?.phase, .notLoaded)

        let localRequest = BoneInferenceRequest(modelID: "model", messages: [.init(role: .user, content: "Hi")])
        let inference = Task { try await engine.infer(request: localRequest) }
        await runtime.waitUntilLoadStarts()
        let firstLoading = await first.next()
        XCTAssertEqual(firstLoading?.phase, .loading)
        let secondLoading = await second.next()
        XCTAssertEqual(secondLoading?.phase, .loading)
        await runtime.finishLoad()
        _ = try? await inference.value

        let firstFailure = await first.next()
        let secondFailure = await second.next()
        XCTAssertEqual(firstFailure?.phase, .failed)
        XCTAssertEqual(firstFailure?.failure, .modelIncompatible)
        XCTAssertEqual(secondFailure, firstFailure)
    }

    private static let tool = BoneAgentToolDefinition(
        id: "test.echo",
        version: "1",
        title: "Echo",
        summary: "Echo a value",
        wireName: "echo",
        schemaVersion: 1,
        inputSchema: .object(
            properties: ["value": .string(enumValues: [], minimumLength: nil, maximumLength: nil)],
            required: ["value"],
            additionalProperties: false
        )
    )

    private func makeControlledEngine(_ runtime: ControlledEngineRuntimeFixture) -> BoneLlamaInferenceEngine {
        BoneLlamaInferenceEngine(
            modelID: "model",
            modelURL: URL(fileURLWithPath: "/tmp/model.gguf"),
            plan: .init(contextTokens: 512, maximumOutputTokens: 64, batchTokens: 32, threadCount: 2),
            runtimeFactory: { runtime }
        )
    }
}

private actor ControlledEngineRuntimeFixture: BoneLlamaRuntime {
    nonisolated let runtimeVersion = 1
    private let loadError: BoneLlamaRuntimeError?
    private var loadStarted: CheckedContinuation<Void, Never>?
    private var loadStartWaiter: CheckedContinuation<Void, Never>?
    private var loadFinish: CheckedContinuation<Void, Never>?
    private var generateStarted: CheckedContinuation<Void, Never>?
    private var generateStartWaiter: CheckedContinuation<Void, Never>?
    private var generateFinish: CheckedContinuation<Void, Never>?

    init(loadError: BoneLlamaRuntimeError? = nil) { self.loadError = loadError }

    func load(modelURL: URL, configuration: BoneLlamaRuntimeConfiguration) async throws {
        signal(&loadStarted, waiter: &loadStartWaiter)
        await withCheckedContinuation { loadFinish = $0 }
        if let loadError { throw loadError }
    }

    func tokenize(prompt: String) async throws -> BoneLlamaPromptTokenization {
        try .init(tokenCount: 8)
    }

    func generate(
        prompt: String,
        executionPlan: BoneLlamaPromptExecutionPlan,
        options: BoneLlamaGenerationOptions
    ) async throws -> BoneLlamaGenerationResult {
        signal(&generateStarted, waiter: &generateStartWaiter)
        await withCheckedContinuation { generateFinish = $0 }
        return .init(text: "ok")
    }

    func smokeTest() async throws {}
    func cancel() async {}
    func unload() async {}

    func waitUntilLoadStarts() async {
        if loadStarted != nil { return }
        await withCheckedContinuation { loadStartWaiter = $0 }
    }

    func finishLoad() { loadFinish?.resume(); loadFinish = nil }

    func waitUntilGenerateStarts() async {
        if generateStarted != nil { return }
        await withCheckedContinuation { generateStartWaiter = $0 }
    }

    func finishGenerate() { generateFinish?.resume(); generateFinish = nil }

    private func signal(
        _ marker: inout CheckedContinuation<Void, Never>?,
        waiter: inout CheckedContinuation<Void, Never>?
    ) {
        marker = waiter
        waiter?.resume()
        waiter = nil
    }
}

private actor EngineRuntimeFixture: BoneLlamaRuntime {
    nonisolated let runtimeVersion = 1
    private let result: String
    private let tokenCount: Int?
    private var loaded = false
    private var loadCount = 0
    private var generateCount = 0
    private var maximumOutputTokens: Int?
    private var lastPrompt: String?
    private var prefillRanges: [Range<Int>]?

    init(result: String, tokenCount: Int? = nil) {
        self.result = result
        self.tokenCount = tokenCount
    }

    func load(modelURL: URL, configuration: BoneLlamaRuntimeConfiguration) async throws {
        loaded = true
        loadCount += 1
    }
    func tokenize(prompt: String) async throws -> BoneLlamaPromptTokenization {
        try .init(tokenCount: tokenCount ?? max(1, prompt.utf8.count / 4))
    }

    func generate(
        prompt: String,
        executionPlan: BoneLlamaPromptExecutionPlan,
        options: BoneLlamaGenerationOptions
    ) async throws -> BoneLlamaGenerationResult {
        generateCount += 1
        maximumOutputTokens = options.maximumOutputTokens
        lastPrompt = prompt
        prefillRanges = executionPlan.prefillRanges
        return .init(text: result)
    }
    func smokeTest() async throws {}
    func cancel() async {}
    func unload() async { loaded = false }

    func snapshot() -> (
        loadCount: Int,
        generateCount: Int,
        maximumOutputTokens: Int?,
        lastPrompt: String?,
        prefillRanges: [Range<Int>]?
    ) {
        (loadCount, generateCount, maximumOutputTokens, lastPrompt, prefillRanges)
    }
}
