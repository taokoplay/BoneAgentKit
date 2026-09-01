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
