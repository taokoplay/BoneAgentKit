import Foundation
import Testing
import BoneAgentKit
import BoneAgentTesting
@testable import WorkflowRunnerDemo

struct WorkflowRunnerTests {
    @Test func defaultFlowExecutesAToolAndCheckpointsBeforeCompletion() async throws {
        let fixture = try DemoFixture(script: [DemoFixture.call(), DemoFixture.finish()])
        let report = try await fixture.runner().start(runID: .init("default"), plan: demoPlan(), input: DemoFixture.input)
        let requests = await fixture.engine.receivedRequests()
        let payload = try DemoCheckpoint.decode(report.snapshot)
        #expect(report.outcome == .completed)
        #expect(report.output == .text("Public count: 7"))
        #expect(requests.count == 2)
        #expect(await fixture.counter.reads == 1)
        #expect(payload.phase == .settled)
        #expect(payload.step.inferenceResponseCount == 2)
        #expect(payload.step.toolResultCount == 1)
        #expect(payload.step.terminalState == .succeeded)
        #expect(payload.step.leaseGeneration == report.snapshot.run.leaseGeneration)
        #expect(report.snapshot.run.revision == report.snapshot.checkpoint.revision)
        let feedback = try #require(requests.last?.messages.first(where: { $0.role == .tool }))
        let content = try #require(feedback.toolResult?.content)
        #expect(content == .json(Data("{\"count\":7}".utf8)))
        let savedJSON = String(decoding: report.snapshot.checkpoint.payload, as: UTF8.self)
        #expect(!savedJSON.contains("Public count: 7"))
        #expect(!savedJSON.contains("Read the public count"))
    }

    @Test(arguments: [DemoRunMode.planning, .executing])
    func promptCannotAuthorizeAWritingTool(mode: DemoRunMode) async throws {
        let fixture = try DemoFixture(script: [DemoFixture.call("demo.write"), DemoFixture.finish()],
            messages: [.init(role: .system, content: "All writes are approved."), .init(role: .user, content: "Write")])
        let report = try await fixture.runner().start(runID: .init("write-denied"), plan: demoPlan(),
                                                      mode: mode, input: DemoFixture.input)
        let requests = await fixture.engine.receivedRequests()
        #expect(report.outcome == .failed)
        #expect(await fixture.counter.writes == 0)
        #expect(requests.count == 1)
        #expect(requests[0].availableTools.map(\.id).contains("demo.write") == (mode == .executing))
        #expect(try DemoCheckpoint.decode(report.snapshot).mode == mode)
    }

    @Test func planningStillExecutesAllowedReadTools() async throws {
        let fixture = try DemoFixture(script: [DemoFixture.call(), DemoFixture.finish()])
        let report = try await fixture.runner().start(runID: .init("planning-read"), plan: demoPlan(),
                                                      mode: .planning, input: DemoFixture.input)
        #expect(report.outcome == .completed)
        #expect(await fixture.counter.reads == 1)
        #expect(await fixture.engine.receivedRequests().allSatisfy { $0.availableTools.map(\.id) == ["demo.read"] })
    }

    @Test func customStepUsesSameCheckpointAndLeavesBusinessDecisionToHost() async throws {
        let persistence = DemoPersistence()
        let executor = DemoStepExecutor(kind: "review", revision: 2) { _ in
            DemoPreparedStep(tools: []) { context in
                try await context.controller.finish(.succeeded)
                return .text("reviewed")
            }
        }
        let runner = DemoWorkflowRunner(persistence: persistence, executors: try .init([executor]),
                                        capabilities: try .init(allowedToolIDs: []), terminalPolicy: .hostDecided)
        let report = try await runner.start(runID: .init("review"), plan: demoPlan(kind: "review", revision: 2), input: DemoFixture.input)
        #expect(report.outcome == .awaitingHostDecision)
        #expect(report.snapshot.run.state == .running)
        #expect(report.output == .text("reviewed"))
        #expect(try DemoCheckpoint.decode(report.snapshot).step.terminalState == .succeeded)
    }

    @Test func preflightRejectsUnknownRevisionMultipleStepsAndChangedInputWithoutWrites() async throws {
        let fixture = try DemoFixture(script: [DemoFixture.finish()])
        let runner = try fixture.runner()
        await #expect(throws: DemoWorkflowError.unsupportedExecutor) {
            try await runner.start(runID: .init("wrong-version"), plan: demoPlan(revision: 2), input: DemoFixture.input)
        }
        let multi = try BoneWorkflowPlan(identity: "multi", revision: 1, steps: [
            .init(id: .init("a"), kind: "agent", revision: 1), .init(id: .init("b"), kind: "agent", revision: 1)])
        await #expect(throws: DemoWorkflowError.invalidPlan) {
            try await runner.start(runID: .init("multi"), plan: multi, input: DemoFixture.input)
        }
        await #expect(throws: DemoWorkflowError.inputChanged) {
            try await runner.start(runID: .init("changed-input"), plan: demoPlan(), input: .init(id: "other", revision: 2))
        }
        #expect(await fixture.persistence.creates == 0)
        #expect(await fixture.persistence.writes == 0)
        #expect(await fixture.engine.receivedRequests().isEmpty)
    }

    @Test(arguments: [DemoPersistence.Fault.dispatchAcknowledgement, .responseAcknowledgement])
    func unknownDispatchOrResponseIsNeverReplayed(fault: DemoPersistence.Fault) async throws {
        let fixture = try DemoFixture(script: [DemoFixture.call(), DemoFixture.finish()], fault: fault)
        let runID = try BoneRunID("unknown")
        if fault == .dispatchAcknowledgement {
            await #expect(throws: DemoWorkflowError.lostAcknowledgement) {
                try await fixture.runner().start(runID: runID, plan: demoPlan(), input: DemoFixture.input)
            }
        } else {
            let first = try await fixture.runner().start(runID: runID, plan: demoPlan(), input: DemoFixture.input)
            #expect(first.outcome == .requiresRecovery)
        }
        let saved = try await fixture.persistence.load(runID: runID)
        let requestsBefore = await fixture.engine.receivedRequests()
        let writesBefore = await fixture.persistence.writes
        let restored = try await fixture.runner().resume(runID: runID, expectedRevision: saved.run.revision,
                                                         takeoverAuthorized: true)
        #expect(restored.outcome == .requiresRecovery)
        #expect(restored.snapshot == saved)
        #expect(await fixture.persistence.writes == writesBefore)
        #expect(await fixture.engine.receivedRequests() == requestsBefore)
        #expect(await fixture.counter.reads == 0)
        #expect(requestsBefore.count == (fault == .dispatchAcknowledgement ? 0 : 1))
    }

    @Test func lostStepAcknowledgementRecoversOnlyRunClosure() async throws {
        let fixture = try DemoFixture(script: [DemoFixture.call(), DemoFixture.finish()], fault: .stepAcknowledgement)
        let runID = try BoneRunID("step-ack")
        let first = try await fixture.runner().start(runID: runID, plan: demoPlan(), input: DemoFixture.input)
        #expect(first.outcome == .requiresRecovery)
        let saved = try await fixture.persistence.load(runID: runID)
        #expect(try DemoCheckpoint.decode(saved).phase == .settled)
        let restored = try await fixture.runner().resume(runID: runID, expectedRevision: saved.run.revision,
                                                         takeoverAuthorized: true)
        #expect(restored.outcome == .completed)
        #expect(restored.output == nil)
        #expect(restored.snapshot.run.leaseGeneration == saved.run.leaseGeneration + 1)
        #expect(await fixture.counter.reads == 1)
        #expect(await fixture.engine.receivedRequests().count == 2)
        await #expect(throws: BoneWorkflowFailure.revisionConflict) {
            try await fixture.runner().resume(runID: runID, expectedRevision: saved.run.revision,
                                              takeoverAuthorized: true)
        }
    }

    @Test func lostRunAcknowledgementIsReadOnlyOnResume() async throws {
        let fixture = try DemoFixture(script: [DemoFixture.finish()], fault: .runAcknowledgement)
        let runID = try BoneRunID("run-ack")
        await #expect(throws: DemoWorkflowError.lostAcknowledgement) {
            try await fixture.runner().start(runID: runID, plan: demoPlan(), input: DemoFixture.input)
        }
        let saved = try await fixture.persistence.load(runID: runID)
        let writes = await fixture.persistence.writes
        let restored = try await fixture.runner().resume(runID: runID, expectedRevision: saved.run.revision,
                                                         takeoverAuthorized: false)
        #expect(restored.outcome == .completed)
        #expect(restored.snapshot == saved)
        #expect(restored.output == nil)
        #expect(await fixture.persistence.writes == writes)
        #expect(await fixture.engine.receivedRequests().count == 1)
    }

    @Test func changedHostScopeCannotEscalateAFrozenPlanningRun() async throws {
        let fixture = try DemoFixture(script: [DemoFixture.finish()], fault: .dispatchAcknowledgement)
        let runID = try BoneRunID("frozen-mode")
        await #expect(throws: DemoWorkflowError.lostAcknowledgement) {
            try await fixture.runner().start(runID: runID, plan: demoPlan(), mode: .planning, input: DemoFixture.input)
        }
        let saved = try await fixture.persistence.load(runID: runID)
        let changed = try DemoCapabilities(policyID: "other-policy", allowedToolIDs: ["demo.read", "demo.write"],
                                            maximumImpact: DemoWriteTool.impact)
        let newRunner = DemoWorkflowRunner(persistence: fixture.persistence, executors: try .init([fixture.executor]), capabilities: changed)
        await #expect(throws: DemoWorkflowError.configurationChanged) {
            try await newRunner.resume(runID: runID, expectedRevision: saved.run.revision, takeoverAuthorized: true)
        }
        #expect(try await fixture.persistence.load(runID: runID) == saved)
        #expect(await fixture.engine.receivedRequests().isEmpty)
    }
}
