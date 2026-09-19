import Foundation
import XCTest
@testable import BoneAgentKit

final class WorkflowRunIntegrationTests: XCTestCase {
    func testRejectedConcurrentWorkflowCallDoesNotFinishOwnedStep() async throws {
        let gate = WorkflowRunGate()
        let fixture = try fixture(engineGate: gate)
        let first = Task { try await fixture.agent.runWorkflowStep(modelID: "model", messages: [], controller: fixture.controller) }
        await gate.waitUntilEntered()
        do {
            _ = try await fixture.agent.runWorkflowStep(modelID: "model", messages: [], controller: fixture.controller)
            XCTFail("Concurrent call must be rejected")
        } catch { XCTAssertEqual(error as? BoneAgentError, .runAlreadyInProgress) }
        let state = await fixture.store.stored.state
        XCTAssertEqual(state, .running)
        await gate.open()
        do { let result = try await first.value; XCTAssertEqual(result.output, .text("done")) }
        catch { XCTFail("Owned run was damaged: \(error)") }
    }

    func testRunOwnershipIncludesWorkflowTerminalCommit() async throws {
        let gate = WorkflowRunGate()
        let fixture = try fixture(commitGate: gate)
        let first = Task { try await fixture.agent.runWorkflowStep(modelID: "model", messages: [], controller: fixture.controller) }
        await gate.waitUntilEntered()
        do {
            _ = try await fixture.agent.run(modelID: "model", messages: [])
            XCTFail("Terminal commit must still own the Agent")
        } catch { XCTAssertEqual(error as? BoneAgentError, .runAlreadyInProgress) }
        await gate.open()
        _ = try await first.value
    }

    func testFailedTerminalCommitDoesNotAttemptAnotherTerminalWrite() async throws {
        let fixture = try fixture(rejectTerminal: true)
        do {
            _ = try await fixture.agent.runWorkflowStep(modelID: "model", messages: [], controller: fixture.controller)
            XCTFail("Commit must fail")
        } catch { XCTAssertEqual(error as? BoneAgentError, .toolRecoveryRequired) }
        let terminalWrites = await fixture.store.terminalWrites
        XCTAssertEqual(terminalWrites, [.succeeded])
        let state = await fixture.store.stored.state
        XCTAssertEqual(state, .running)
    }

    func testRecoveryErrorsKeepUncertainCheckpointAndOriginalError() async throws {
        for failure in [BoneAgentError.toolOutcomeUnknown, .toolRecoveryRequired] {
            for rejectTerminal in [false, true] {
                let fixture = try fixture(rejectTerminal: rejectTerminal, progressFailure: failure)
                do {
                    _ = try await fixture.agent.runWorkflowStep(modelID: "model", messages: [], controller: fixture.controller)
                    XCTFail("Recovery error must escape")
                } catch { XCTAssertEqual(error as? BoneAgentError, failure) }
                let state = await fixture.store.stored.state
                XCTAssertEqual(state, rejectTerminal ? .running : .commitUncertain)
                let terminalWrites = await fixture.store.terminalWrites
                XCTAssertEqual(terminalWrites, [.commitUncertain])
            }
        }
    }

    func testSkippedStepCannotBeChangedIntoAnotherTerminalState() async throws {
        for terminal in [BoneWorkflowAgentStepTerminalState.succeeded, .failed, .cancelled] {
            let checkpoint = try checkpoint(state: .skipped)
            let store = WorkflowRunStore(checkpoint)
            let controller = try BoneWorkflowAgentStepController(restoring: checkpoint, persistence: store.adapter)
            do { try await controller.finish(terminal); XCTFail("Skipped is immutable") }
            catch { XCTAssertEqual(error as? BoneWorkflowAgentStepError, .terminalState) }
            let persisted = await store.stored
            XCTAssertEqual(persisted, checkpoint)
        }
    }

    func testConfirmedHostCancellationIsNotReportedAsRecoveryFailure() async throws {
        for cancelTask in [false, true] {
            let gate = WorkflowRunGate()
            let fixture = try fixture(engineGate: gate)
            let first = Task { try await fixture.agent.runWorkflowStep(modelID: "model", messages: [], controller: fixture.controller) }
            await gate.waitUntilEntered()
            try await fixture.controller.cancel()
            if cancelTask { first.cancel() }
            await gate.open()
            do { _ = try await first.value; XCTFail("Cancelled step must not succeed") }
            catch { XCTAssertTrue(error is CancellationError) }
            let writes = await fixture.store.terminalWrites
            XCTAssertEqual(writes, [.cancelled])
        }
    }

    func testUnconfirmedInferenceCheckpointDoesNotAttemptFollowupWrite() async throws {
        for failure in 0..<4 {
            let initial = try checkpoint()
            let probe = WorkflowRunStore(initial)
            let controller = try BoneWorkflowAgentStepController(restoring: initial, persistence: .init { n, revision, generation in
                await probe.recordAttempt()
                switch failure {
                case 0: throw BoneWorkflowAgentStepError.invalidState
                case 1:
                    _ = try await probe.commit(n, revision: revision, generation: generation)
                    throw BoneWorkflowAgentStepError.invalidState
                case 2: throw CancellationError()
                default: return n // Missing revision advancement: invalid receipt.
                }
            })
            let agent = BoneAgent(inferenceEngine: WorkflowRunEngine(gate: nil), toolRegistry: try .init(tools: []),
                toolContext: BoneAgentEmptyContext(), configuration: try .init(maximumSteps: 1), workflowController: controller)
            do {
                _ = try await agent.runWorkflowStep(modelID: "model", messages: [], controller: controller)
                XCTFail("Unconfirmed checkpoint must stop execution")
            } catch { XCTAssertEqual(error as? BoneAgentError, .toolRecoveryRequired) }
            let attempts = await probe.attempts
            XCTAssertEqual(attempts, 1, "Must not blindly write failed/cancelled/commitUncertain after unknown submission")
            do { try await controller.finish(.failed); XCTFail("Controller must be reloaded before further writes") }
            catch { XCTAssertEqual(error as? BoneWorkflowAgentStepError, .invalidState) }
            let finalAttempts = await probe.attempts
            XCTAssertEqual(finalAttempts, 1)
        }
    }

    func testInFlightCheckpointLosingToConfirmedCancellationStaysCancelled() async throws {
        let initial = try checkpoint()
        let store = WorkflowRunStore(initial)
        let gate = WorkflowRunGate()
        let controller = try BoneWorkflowAgentStepController(restoring: initial, persistence: .init { n, revision, generation in
            if n.inferenceResponseCount == 1 { await gate.block() }
            return try await store.commit(n, revision: revision, generation: generation)
        })
        let agent = BoneAgent(inferenceEngine: WorkflowRunEngine(gate: nil), toolRegistry: try .init(tools: []),
            toolContext: BoneAgentEmptyContext(), configuration: try .init(maximumSteps: 1), workflowController: controller)
        let run = Task { try await agent.runWorkflowStep(modelID: "model", messages: [], controller: controller) }
        await gate.waitUntilEntered()
        try await controller.cancel()
        await gate.open()
        do { _ = try await run.value; XCTFail("Cancelled step must not succeed") }
        catch { XCTAssertTrue(error is CancellationError) }
        let state = await controller.checkpoint.state
        XCTAssertEqual(state, .cancelled)
        let writes = await store.terminalWrites
        XCTAssertEqual(writes, [.cancelled])
    }

    private func checkpoint(state: BoneWorkflowStepState = .running) throws -> BoneWorkflowAgentStepCheckpoint {
        .init(runID: try .init("run"), stepID: try .init("step"), attemptID: try .init("attempt"), state: state)
    }

    private func fixture(
        engineGate: WorkflowRunGate? = nil,
        commitGate: WorkflowRunGate? = nil,
        rejectTerminal: Bool = false,
        progressFailure: BoneAgentError? = nil
    ) throws -> (agent: BoneAgent, controller: BoneWorkflowAgentStepController, store: WorkflowRunStore) {
        let initial = try checkpoint()
        let store = WorkflowRunStore(initial, gate: commitGate, rejectTerminal: rejectTerminal)
        let controller = try BoneWorkflowAgentStepController(restoring: initial, persistence: store.adapter)
        let agent = BoneAgent(inferenceEngine: WorkflowRunEngine(gate: engineGate),
            toolRegistry: try .init(tools: []), toolContext: BoneAgentEmptyContext(),
            configuration: try .init(maximumSteps: 1), progressSink: .init { progress in
                if let progressFailure { throw progressFailure }
                try await controller.receive(progress)
            })
        return (agent, controller, store)
    }
}

private actor WorkflowRunGate {
    private var entered = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    func block() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            release = continuation; entered = true; waiter?.resume(); waiter = nil
        }
    }
    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { waiter = $0 } }
    }
    func open() { release?.resume(); release = nil }
}

private struct WorkflowRunEngine: BoneInferenceEngine {
    let gate: WorkflowRunGate?
    var nonImageCapabilities: Set<BoneInferenceCapability> { [.text] }
    var imageGenerator: (any BoneInferenceImageGenerating)? { nil }
    func infer(request: BoneInferenceRequest) async throws -> BoneInferenceResponse {
        await gate?.block()
        return .finish(.init(text: "done"))
    }
}

private actor WorkflowRunStore {
    var stored: BoneWorkflowAgentStepCheckpoint
    var terminalWrites: [BoneWorkflowStepState] = []
    var attempts = 0
    func recordAttempt() { attempts += 1 }
    let gate: WorkflowRunGate?
    let rejectTerminal: Bool
    init(_ initial: BoneWorkflowAgentStepCheckpoint, gate: WorkflowRunGate? = nil, rejectTerminal: Bool = false) {
        stored = initial; self.gate = gate; self.rejectTerminal = rejectTerminal
    }
    nonisolated var adapter: BoneWorkflowAgentStepCheckpointStore {
        .init { next, revision, generation in try await self.commit(next, revision: revision, generation: generation) }
    }
    func commit(_ n: BoneWorkflowAgentStepCheckpoint, revision: UInt64, generation: UInt64) async throws -> BoneWorkflowAgentStepCheckpoint {
        if n.terminalState != nil || n.state == .commitUncertain {
            terminalWrites.append(n.state)
            await gate?.block()
            if rejectTerminal { throw BoneWorkflowAgentStepError.invalidState }
        }
        guard revision == stored.persistenceRevision, generation == stored.leaseGeneration else {
            throw BoneWorkflowAgentStepError.invalidState
        }
        stored = .init(runID: n.runID, stepID: n.stepID, attemptID: n.attemptID, state: n.state,
            inferenceResponseCount: n.inferenceResponseCount, toolResultCount: n.toolResultCount,
            pendingAuthorizationTicketID: n.pendingAuthorizationTicketID, cancellationPersisted: n.cancellationPersisted,
            terminalState: n.terminalState, persistenceRevision: revision + 1, leaseGeneration: generation)
        return stored
    }
}
