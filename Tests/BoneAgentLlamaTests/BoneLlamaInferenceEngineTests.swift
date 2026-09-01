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

    func generate(prompt: String, options: BoneLlamaGenerationOptions) async throws -> BoneLlamaGenerationResult {
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
    private var loaded = false
    private var loadCount = 0
    private var generateCount = 0
    private var maximumOutputTokens: Int?

    init(result: String) { self.result = result }

    func load(modelURL: URL, configuration: BoneLlamaRuntimeConfiguration) async throws {
        loaded = true
        loadCount += 1
    }
    func generate(prompt: String, options: BoneLlamaGenerationOptions) async throws -> BoneLlamaGenerationResult {
        generateCount += 1
        maximumOutputTokens = options.maximumOutputTokens
        return .init(text: result)
    }
    func smokeTest() async throws {}
    func cancel() async {}
    func unload() async { loaded = false }

    func snapshot() -> (loadCount: Int, generateCount: Int, maximumOutputTokens: Int?) {
        (loadCount, generateCount, maximumOutputTokens)
    }
}
