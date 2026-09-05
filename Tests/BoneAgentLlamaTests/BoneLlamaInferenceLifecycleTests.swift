import BoneAgentKit
import BoneAgentLocalRuntime
import XCTest
@testable import BoneAgentLlama

final class BoneLlamaInferenceLifecycleTests: XCTestCase {
    func testSecondInferIsBusyAcrossWholePipelineWithoutDuplicateLoad() async throws {
        for phase in LifecycleRuntime.Stage.allCases {
            let runtime = LifecycleRuntime(blocking: phase)
            let engine = makeEngine(runtime)
            let first = Task { [request] in try await engine.infer(request: request) }
            await runtime.gate.waitForEntry()
            do {
                _ = try await engine.infer(request: request)
                XCTFail("Expected busy during \(phase)")
            } catch {
                XCTAssertEqual(error as? BoneLlamaAdapterError, .busy)
            }
            await runtime.gate.open()
            _ = try await first.value
            let snapshot = await runtime.snapshot()
            XCTAssertEqual(snapshot.loads, 1)
            XCTAssertEqual(snapshot.generations, 1)
        }
    }

    func testCancelDuringEveryStageRejectsLateResultsAndRetainsBusyUntilReturn() async throws {
        for phase in LifecycleRuntime.Stage.allCases {
            let runtime = LifecycleRuntime(blocking: phase)
            let engine = makeEngine(runtime)
            let first = Task { [request] in try await engine.infer(request: request) }
            await runtime.gate.waitForEntry()
            await engine.cancel() // Must return while the deliberately uncooperative call is gated.
            let cancelling = await engine.currentModelState()
            XCTAssertEqual(cancelling.phase, .cancelling)
            do {
                _ = try await engine.infer(request: request)
                XCTFail("Cancelled but still-running runtime must remain busy")
            } catch { XCTAssertEqual(error as? BoneLlamaAdapterError, .busy) }
            await runtime.gate.open()
            await assertCancelled(first)
            let snapshot = await runtime.snapshot()
            XCTAssertEqual(snapshot.generations, phase == .generate ? 1 : 0)
            XCTAssertEqual(snapshot.overlappingUnloads, 0)
            XCTAssertGreaterThanOrEqual(snapshot.cancels, 1)
            // A new request can run only after the old operation has drained.
            _ = try await engine.infer(request: request)
        }
    }

    func testUnloadDuringEveryStageDrainsRuntimeAndCannotPublishLateLoaded() async throws {
        for phase in LifecycleRuntime.Stage.allCases {
            let runtime = LifecycleRuntime(blocking: phase)
            let engine = makeEngine(runtime)
            let first = Task { [request] in try await engine.infer(request: request) }
            await runtime.gate.waitForEntry()
            var states = await engine.modelStateUpdates().makeAsyncIterator()
            _ = await states.next()
            let unload = Task { await engine.unload() }
            while let state = await states.next(), state.phase != .unloading {}
            await engine.cancel() // Actor round-trip; must not resurrect loaded during unload.
            let draining = await engine.currentModelState()
            XCTAssertTrue(draining.phase == .unloading || draining.phase == .cancelling)
            await runtime.gate.open()
            await assertCancelled(first)
            await unload.value
            let state = await engine.currentModelState()
            XCTAssertEqual(state.phase, .notLoaded)
            let snapshot = await runtime.snapshot()
            XCTAssertEqual(snapshot.overlappingUnloads, 0)
            XCTAssertEqual(snapshot.unloads, 1)
            XCTAssertEqual(snapshot.generations, phase == .generate ? 1 : 0)
            _ = try await engine.infer(request: request)
            let reused = await runtime.snapshot()
            XCTAssertEqual(reused.loads, 2)
        }
    }

    func testTaskCancellationDoesNotAcceptUncooperativeRuntimeResult() async {
        for phase in LifecycleRuntime.Stage.allCases {
            let runtime = LifecycleRuntime(blocking: phase)
            let engine = makeEngine(runtime)
            let first = Task { [request] in try await engine.infer(request: request) }
            await runtime.gate.waitForEntry()
            first.cancel()
            await runtime.gate.open()
            await assertCancelled(first)
            let snapshot = await runtime.snapshot()
            XCTAssertEqual(snapshot.generations, phase == .generate ? 1 : 0)
        }
    }

    func testLateCancelCallbackKeepsAdmissionClosedUntilControlDrains() async throws {
        let runtime = LifecycleRuntime(blocking: .generate, blockCancel: true)
        let engine = makeEngine(runtime)
        let first = Task { [request] in try await engine.infer(request: request) }
        await runtime.gate.waitForEntry()
        let cancel = Task { await engine.cancel() }
        await runtime.cancelGate.waitForEntry()
        await runtime.gate.open()
        do {
            _ = try await engine.infer(request: request)
            XCTFail("Control callback still owns old operation")
        } catch { XCTAssertEqual(error as? BoneLlamaAdapterError, .busy) }
        await runtime.cancelGate.open()
        await cancel.value
        await assertCancelled(first)
        _ = try await engine.infer(request: request)
        let snapshot = await runtime.snapshot()
        XCTAssertEqual(snapshot.cancels, 1)
    }

    func testConcurrentUnloadJoinsAndRejectsInferenceUntilReleaseCompletes() async throws {
        let runtime = LifecycleRuntime(blocking: .generate, blockUnload: true)
        let engine = makeEngine(runtime)
        await runtime.gate.open()
        _ = try await engine.infer(request: request)
        let first = Task { await engine.unload() }
        await runtime.unloadGate.waitForEntry()
        let second = Task { await engine.unload() }
        await engine.cancel()
        do {
            _ = try await engine.infer(request: request)
            XCTFail("Unload still owns runtime")
        } catch { XCTAssertEqual(error as? BoneLlamaAdapterError, .busy) }
        await runtime.unloadGate.open()
        await first.value
        await second.value
        let snapshot = await runtime.snapshot()
        XCTAssertEqual(snapshot.unloads, 1)
        let state = await engine.currentModelState()
        XCTAssertEqual(state.phase, .notLoaded)
    }

    func testTaskCancellationSignalsRuntimeBeforeBlockedGenerateReturns() async {
        let runtime = LifecycleRuntime(blocking: .generate, blockCancel: true)
        let engine = makeEngine(runtime)
        let first = Task { [request] in try await engine.infer(request: request) }
        await runtime.gate.waitForEntry()
        first.cancel()
        await runtime.cancelGate.waitForEntry()
        let state = await engine.currentModelState()
        XCTAssertEqual(state.phase, .cancelling)
        await runtime.cancelGate.open()
        await runtime.gate.open()
        await assertCancelled(first)
    }

    func testPartialLoadFailureDrainsBeforeReleasingAdmission() async throws {
        let runtime = PartialLoadFailureRuntime()
        let engine = makeEngine(runtime)
        let first = Task { [request] in
            do {
                _ = try await engine.infer(request: request)
                XCTFail("Expected load failure")
            } catch { XCTAssertEqual(error as? BoneLlamaAdapterError, .runtime(.loadFailed)) }
            await runtime.cleanupOrCompletion.open()
            await runtime.cleanupOrCompletion.enterOnce()
        }
        await runtime.cleanupOrCompletion.waitForEntry()
        let cleaning = await runtime.snapshot()
        XCTAssertEqual(cleaning.unloads, 1, "Partial load allocation must be unloaded before infer returns")
        guard cleaning.unloads == 1 else { await first.value; return }
        do {
            _ = try await engine.infer(request: request)
            XCTFail("Cleanup must retain admission")
        } catch { XCTAssertEqual(error as? BoneLlamaAdapterError, .busy) }
        let blocked = await runtime.snapshot()
        XCTAssertEqual(blocked.loads, 1)
        await runtime.unloadGate.open()
        await first.value
        _ = try await engine.infer(request: request)
        let retried = await runtime.snapshot()
        XCTAssertEqual(retried.loads, 2)
        XCTAssertEqual(retried.dirtyReloads, 0)
        XCTAssertEqual(retried.unloads, 1)
    }

    func testAsyncRenderCancellationAndUnloadDiscardLatePrompt() async throws {
        for shouldUnload in [false, true] {
            let runtime = LifecycleRuntime(blocking: .generate)
            await runtime.gate.open()
            let renderer = GatedLifecycleRenderer()
            let engine = BoneLlamaInferenceEngine(
                modelID: "model", modelURL: URL(fileURLWithPath: "/tmp/model.gguf"),
                plan: .init(contextTokens: 512, maximumOutputTokens: 64, batchTokens: 32, threadCount: 2),
                conversationRenderer: renderer, runtimeFactory: { runtime })
            let first = Task { [request] in try await engine.infer(request: request) }
            await renderer.gate.waitForEntry()
            var unload: Task<Void, Never>?
            if shouldUnload {
                var states = await engine.modelStateUpdates().makeAsyncIterator()
                _ = await states.next()
                unload = Task { await engine.unload() }
                while let state = await states.next(), state.phase != .unloading {}
            } else {
                await engine.cancel()
            }
            do {
                _ = try await engine.infer(request: request)
                XCTFail("Rendering still owns session")
            } catch { XCTAssertEqual(error as? BoneLlamaAdapterError, .busy) }
            let before = await runtime.snapshot()
            XCTAssertEqual(before.unloads, 0, "Renderer may still be using runtime")
            await renderer.gate.open()
            await assertCancelled(first)
            await unload?.value
            let after = await runtime.snapshot()
            XCTAssertEqual(after.generations, 0)
            XCTAssertEqual(after.unloads, 1)
            let state = await engine.currentModelState()
            XCTAssertEqual(state.phase, .notLoaded)
        }
    }

    func testOutputValidationFailureDoesNotUnloadHealthyLoadedRuntime() async {
        let runtime = LifecycleRuntime(blocking: .generate, output: " ")
        await runtime.gate.open()
        let engine = makeEngine(runtime)
        for _ in 0..<2 {
            do {
                _ = try await engine.infer(request: request)
                XCTFail("Expected empty response")
            } catch { XCTAssertEqual(error as? BoneLlamaAdapterError, .emptyResponse) }
        }
        let snapshot = await runtime.snapshot()
        XCTAssertEqual(snapshot.loads, 1)
        XCTAssertEqual(snapshot.unloads, 0)
        XCTAssertEqual(snapshot.generations, 2)
    }

    private var request: BoneInferenceRequest {
        .init(modelID: "model", messages: [.init(role: .user, content: "Hi")])
    }

    private func makeEngine(_ runtime: any BoneLlamaRuntime) -> BoneLlamaInferenceEngine {
        .init(modelID: "model", modelURL: URL(fileURLWithPath: "/tmp/model.gguf"),
              plan: .init(contextTokens: 512, maximumOutputTokens: 64, batchTokens: 32, threadCount: 2),
              runtimeFactory: { runtime })
    }

    private func assertCancelled(_ task: Task<BoneInferenceResponse, Error>) async {
        do {
            _ = try await task.value
            XCTFail("Expected cancellation, not a late success")
        } catch {
            XCTAssertEqual(error as? BoneLlamaAdapterError, .runtime(.cancelled))
        }
    }
}

private actor LifecycleGate {
    private var entered = false
    private var opened = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var blocked: CheckedContinuation<Void, Never>?

    func enterOnce() async {
        guard !entered else { return }
        entered = true
        entryWaiters.forEach { $0.resume() }
        entryWaiters.removeAll()
        if !opened { await withCheckedContinuation { blocked = $0 } }
    }
    func waitForEntry() async {
        if entered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }
    func open() {
        opened = true
        blocked?.resume()
        blocked = nil
    }
}

/// Ignores task cancellation and cancel(); only the test-owned gate releases native work.
private actor LifecycleRuntime: BoneLlamaRuntime {
    enum Stage: CaseIterable { case load, tokenize, generate }
    nonisolated let runtimeVersion = 1
    nonisolated let gate = LifecycleGate()
    nonisolated let cancelGate = LifecycleGate()
    nonisolated let unloadGate = LifecycleGate()
    private let output: String
    private let blockCancel: Bool
    private let blockUnload: Bool
    private let blocking: Stage
    private var activeCalls = 0
    private var loads = 0
    private var generations = 0
    private var cancels = 0
    private var unloads = 0
    private var overlappingUnloads = 0

    init(blocking: Stage, blockCancel: Bool = false, blockUnload: Bool = false, output: String = "late answer") {
        self.output = output
        self.blocking = blocking
        self.blockCancel = blockCancel
        self.blockUnload = blockUnload
    }
    private func work(_ stage: Stage) async {
        activeCalls += 1
        if stage == blocking { await gate.enterOnce() }
        activeCalls -= 1
    }
    func load(modelURL: URL, configuration: BoneLlamaRuntimeConfiguration) async throws {
        loads += 1
        await work(.load)
    }
    func tokenize(prompt: String) async throws -> BoneLlamaPromptTokenization {
        await work(.tokenize)
        return try .init(tokenCount: 8)
    }
    func generate(prompt: String, executionPlan: BoneLlamaPromptExecutionPlan,
                  options: BoneLlamaGenerationOptions) async throws -> BoneLlamaGenerationResult {
        generations += 1
        await work(.generate)
        return .init(text: output, termination: .eog)
    }
    func smokeTest() async throws {}
    func cancel() async {
        cancels += 1
        if blockCancel { await cancelGate.enterOnce() }
    }
    func unload() async {
        unloads += 1
        if activeCalls > 0 { overlappingUnloads += 1 }
        if blockUnload { await unloadGate.enterOnce() }
    }
    func snapshot() -> (loads: Int, generations: Int, cancels: Int, unloads: Int, overlappingUnloads: Int) {
        (loads, generations, cancels, unloads, overlappingUnloads)
    }
}

private actor PartialLoadFailureRuntime: BoneLlamaRuntime {
    nonisolated let runtimeVersion = 1
    nonisolated let cleanupOrCompletion = LifecycleGate()
    nonisolated let unloadGate = LifecycleGate()
    private var allocated = false
    private var loads = 0
    private var unloads = 0
    private var dirtyReloads = 0
    func load(modelURL: URL, configuration: BoneLlamaRuntimeConfiguration) async throws {
        loads += 1
        if allocated { dirtyReloads += 1 }
        allocated = true
        if loads == 1 { throw BoneLlamaRuntimeError.loadFailed }
    }
    func tokenize(prompt: String) async throws -> BoneLlamaPromptTokenization { try .init(tokenCount: 8) }
    func generate(prompt: String, executionPlan: BoneLlamaPromptExecutionPlan,
                  options: BoneLlamaGenerationOptions) async throws -> BoneLlamaGenerationResult {
        .init(text: "ok", termination: .eog)
    }
    func smokeTest() async throws {}
    func cancel() async {}
    func unload() async {
        unloads += 1
        await cleanupOrCompletion.open()
        await cleanupOrCompletion.enterOnce()
        await unloadGate.enterOnce()
        allocated = false
    }
    func snapshot() -> (loads: Int, unloads: Int, dirtyReloads: Int) {
        (loads, unloads, dirtyReloads)
    }
}

private struct GatedLifecycleRenderer: BoneLlamaConversationRendering {
    let gate = LifecycleGate()
    func render(conversation: BoneLlamaConversation,
                using runtime: any BoneLlamaRuntime) async throws -> BoneLlamaRenderedPrompt {
        await gate.enterOnce()
        return try await BoneLlamaChatMLConversationRenderer().render(conversation: conversation, using: runtime)
    }
}
