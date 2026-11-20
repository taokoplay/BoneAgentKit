import Foundation
import BoneAgentKit

/// Bridges step progress into the same Run+Checkpoint CAS used by the workflow.
private actor DemoStepBridge {
    let persistence: any BoneWorkflowPersistence
    let runID: BoneRunID
    let generation: UInt64
    let attemptID: BoneAttemptID
    private var committing = false

    init(persistence: any BoneWorkflowPersistence, payload: DemoCheckpoint) {
        self.persistence = persistence
        runID = payload.step.runID
        generation = payload.step.leaseGeneration
        attemptID = payload.step.attemptID
    }

    func commit(_ next: BoneWorkflowAgentStepCheckpoint, expectedRevision: UInt64,
                leaseGeneration: UInt64) async throws -> BoneWorkflowAgentStepCheckpoint {
        guard !committing else { throw BoneWorkflowFailure.revisionConflict }
        committing = true
        defer { committing = false }
        let current = try await persistence.load(runID: runID)
        var payload = try DemoCheckpoint.decode(current)
        guard current.run.state == .running,
              generation > 0, current.run.leaseGeneration == generation, leaseGeneration == generation,
              payload.step.leaseGeneration == generation, next.leaseGeneration == generation,
              next.runID == runID, next.stepID == payload.step.stepID,
              next.attemptID == attemptID, payload.step.attemptID == attemptID else {
            throw BoneWorkflowFailure.leaseConflict
        }
        guard payload.phase == .dispatchPrepared, payload.step.persistenceRevision == expectedRevision,
              next.persistenceRevision == expectedRevision else { throw BoneWorkflowFailure.revisionConflict }
        if next.state != payload.step.state { _ = try payload.step.state.transitioned(to: next.state) }
        payload.step = try demoStepCopy(next, revision: demoIncrement(expectedRevision))
        if next.terminalState != nil { payload.phase = .settled }
        let saved = try await demoCommit(persistence, current: current, payload: payload)
        return try DemoCheckpoint.decode(saved).step
    }
}

actor DemoWorkflowRunner {
    private let persistence: any BoneWorkflowPersistence
    private let executors: DemoStepExecutors
    private let capabilities: DemoCapabilities
    private let terminalPolicy: DemoTerminalPolicy
    private var activeRuns = Set<BoneRunID>()

    init(persistence: any BoneWorkflowPersistence, executors: DemoStepExecutors,
         capabilities: DemoCapabilities, terminalPolicy: DemoTerminalPolicy = .automatic) {
        self.persistence = persistence
        self.executors = executors
        self.capabilities = capabilities
        self.terminalPolicy = terminalPolicy
    }

    func start(runID: BoneRunID, plan: BoneWorkflowPlan, mode: DemoRunMode = .executing,
               input: DemoInputReference) async throws -> DemoRunReport {
        guard activeRuns.insert(runID).inserted else { throw DemoWorkflowError.alreadyDriving }
        defer { activeRuns.remove(runID) }
        try Task.checkCancellation()
        guard !input.id.isEmpty, input.revision > 0 else { throw DemoWorkflowError.inputChanged }
        let executor = try executors.executor(for: plan)
        let prepared = try executor.prepare(.init(mode: mode, capabilities: capabilities, input: input))
        let step = try BoneWorkflowAgentStepCheckpoint(
            runID: runID, stepID: plan.steps[0].id, attemptID: .init("attempt-\(UUID().uuidString)"), state: .pending)
        let payload = DemoCheckpoint(schemaVersion: 1, mode: mode, capabilities: capabilities,
                                     terminalPolicy: terminalPolicy, input: input, tools: prepared.tools,
                                     phase: .prepared, step: step)
        let control = BoneWorkflowRunController(persistence: persistence)
        let created = try await control.createRun(runID: runID, plan: plan, checkpoint: payload.envelope(plan: plan))
        let running = try await control.beginExecution(runID: runID, expectedRevision: created.run.revision)
        return try await dispatch(running, prepared: prepared)
    }

    /// The caller asserts takeover permission for this isolated in-memory fixture.
    /// It is not a replacement for real Host ownership authentication.
    func resume(runID: BoneRunID, expectedRevision: UInt64,
                takeoverAuthorized: Bool) async throws -> DemoRunReport {
        guard activeRuns.insert(runID).inserted else { throw DemoWorkflowError.alreadyDriving }
        defer { activeRuns.remove(runID) }
        let current = try await persistence.load(runID: runID)
        guard current.run.revision == expectedRevision else { throw BoneWorkflowFailure.revisionConflict }
        let payload = try DemoCheckpoint.decode(current)
        // A confirmed terminal Run can be read even when its old executor is unavailable.
        if let report = terminalReport(current) { return report }
        guard payload.capabilities == capabilities, payload.terminalPolicy == terminalPolicy else {
            throw DemoWorkflowError.configurationChanged
        }
        let executor = try executors.executor(for: current.run.plan)
        let prepared = try executor.prepare(.init(mode: payload.mode, capabilities: capabilities, input: payload.input))
        guard prepared.tools == payload.tools else { throw DemoWorkflowError.configurationChanged }
        guard current.run.state == .pending || current.run.state == .running,
              payload.step.state != .commitUncertain,
              payload.step.pendingAuthorizationTicketID == nil else { return recoveryReport(current) }
        if payload.phase == .dispatchPrepared { return recoveryReport(current) }
        guard takeoverAuthorized else { throw DemoWorkflowError.takeoverDenied }
        try Task.checkCancellation()
        let control = BoneWorkflowRunController(persistence: persistence)
        let leased: BoneWorkflowRunSnapshot
        if current.run.state == .pending {
            leased = try await control.beginExecution(runID: runID, expectedRevision: expectedRevision)
        } else {
            leased = try await control.recover(runID: runID, expectedRevision: expectedRevision)
        }
        if payload.phase == .settled {
            // Recover only the Run closure, never the model output or tool execution.
            return try await close(leased, generation: leased.run.leaseGeneration, output: nil)
        }
        guard payload.step.inferenceResponseCount == 0, payload.step.toolResultCount == 0 else {
            return recoveryReport(leased)
        }
        return try await dispatch(leased, prepared: prepared)
    }

    private func dispatch(_ running: BoneWorkflowRunSnapshot,
                          prepared: DemoPreparedStep) async throws -> DemoRunReport {
        var current = running
        var payload = try DemoCheckpoint.decode(current)
        let generation = running.run.leaseGeneration
        guard generation > 0, running.run.state == .running, payload.phase == .prepared else {
            throw DemoWorkflowError.invalidCheckpoint
        }
        if payload.step.state == .pending {
            payload.step = try demoStepCopy(payload.step, state: .ready,
                                           revision: demoIncrement(payload.step.persistenceRevision), generation: generation)
            current = try await demoCommit(persistence, current: current, payload: payload)
        }
        payload.step = try demoStepCopy(payload.step, state: .running,
                                       revision: demoIncrement(payload.step.persistenceRevision), generation: generation)
        current = try await demoCommit(persistence, current: current, payload: payload)
        payload.phase = .dispatchPrepared
        try Task.checkCancellation()
        current = try await demoCommit(persistence, current: current, payload: payload)
        let bridge = DemoStepBridge(persistence: persistence, payload: payload)
        let controller = try BoneWorkflowAgentStepController(restoring: payload.step, persistence: .init {
            try await bridge.commit($0, expectedRevision: $1, leaseGeneration: $2)
        })
        let output: BoneAgentRunOutput?
        do {
            output = try await prepared.execute(.init(snapshot: current, controller: controller))
        } catch {
            let saved = try await persistence.load(runID: running.run.id)
            let state = try DemoCheckpoint.decode(saved)
            if let agentError = error as? BoneAgentError,
               agentError == .toolOutcomeUnknown || agentError == .toolRecoveryRequired {
                return recoveryReport(saved)
            }
            if state.step.state == .commitUncertain { return recoveryReport(saved) }
            // runWorkflowStep may already have committed failed/cancelled. Do not finish twice.
            guard state.step.terminalState != nil else { throw error }
            return try await close(saved, generation: generation, output: nil)
        }
        let saved = try await persistence.load(runID: running.run.id)
        return try await close(saved, generation: generation, output: output)
    }

    private func close(_ current: BoneWorkflowRunSnapshot, generation: UInt64,
                       output: BoneAgentRunOutput?) async throws -> DemoRunReport {
        let payload = try DemoCheckpoint.decode(current)
        guard current.run.leaseGeneration == generation else { throw BoneWorkflowFailure.leaseConflict }
        guard payload.phase == .settled, let terminal = payload.step.terminalState else {
            return recoveryReport(current)
        }
        if payload.terminalPolicy == .hostDecided {
            return .init(outcome: .awaitingHostDecision, snapshot: current, output: output)
        }
        let control = BoneWorkflowRunController(persistence: persistence)
        var current = current
        let target: BoneWorkflowRunState
        switch terminal {
        case .succeeded: target = .completed
        case .failed: target = .failed
        case .cancelled:
            if current.run.state != .cancelling {
                current = try await control.requestCancellation(runID: current.run.id,
                                                                expectedRevision: current.run.revision)
            }
            target = .cancelled
        }
        let saved = try await control.reconcileTerminal(runID: current.run.id, state: target,
                                                        expectedRevision: current.run.revision,
                                                        leaseGeneration: generation)
        guard let report = terminalReport(saved, output: output) else { throw DemoWorkflowError.invalidReceipt }
        return report
    }

    private func terminalReport(_ snapshot: BoneWorkflowRunSnapshot,
                                output: BoneAgentRunOutput? = nil) -> DemoRunReport? {
        let outcome: DemoOutcome
        switch snapshot.run.state {
        case .completed: outcome = .completed
        case .failed: outcome = .failed
        case .cancelled: outcome = .cancelled
        case .recoveryRequired: outcome = .requiresRecovery
        default: return nil
        }
        return .init(outcome: outcome, snapshot: snapshot, output: output)
    }

    private func recoveryReport(_ snapshot: BoneWorkflowRunSnapshot) -> DemoRunReport {
        .init(outcome: .requiresRecovery, snapshot: snapshot, output: nil)
    }
}
