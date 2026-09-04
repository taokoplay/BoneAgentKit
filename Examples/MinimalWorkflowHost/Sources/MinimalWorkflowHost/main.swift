import Foundation
import BoneAgentKit
import BoneAgentTesting

private struct PublicReadTool {
    static let definition = BoneAgentToolDefinition(
        id: "example.public-read",
        version: "1.0.0",
        title: "Public Read",
        summary: "Returns synthetic public metadata",
        executionPolicy: .parallelSafe(resourceKeys: ["synthetic-public"]),
        impact: .ordinaryPublicRead
    )
}

private struct AuthorizedWriteTool {
    static let impact = BoneToolImpact(
        dataAccess: .userPrivate,
        externalTransmission: .none,
        stateChange: .reversible,
        economic: .none,
        userVisible: .none,
        permissionChange: .none
    )
    static let definition = BoneAgentToolDefinition(
        id: "example.authorized-write",
        version: "1.0.0",
        title: "Authorized Write",
        summary: "Mutates synthetic in-memory state after approval",
        impact: impact
    )
}

private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw ExampleError.failed(message) }
}
private enum ExampleError: Error { case failed(String) }

@main
enum MinimalWorkflowHost {
    static func main() async throws {
        let readImpact = try PublicReadTool.definition.requiredImpact()
        let writeImpact = try AuthorizedWriteTool.definition.requiredImpact()
        try check(readImpact.isOrdinaryReadOnly, "read impact")
        try check(writeImpact.requiresHostAuthorization, "write authorization")

        let runID = try BoneRunID("example-run")
        let stepID = try BoneStepID("agent-step")
        let attemptID = try BoneAttemptID("attempt-1")
        let plan = try BoneWorkflowPlan(
            identity: "minimal-workflow-host",
            revision: 1,
            steps: [.init(id: stepID, kind: "agent", revision: 1)]
        )
        let payload = Data("{\"phase\":\"created\"}".utf8)
        let checkpoint = try BoneWorkflowCheckpoint(
            descriptor: .init(formatVersion: 1, workflowIdentity: plan.identity, workflowRevision: plan.revision),
            payload: payload,
            dataClassification: .safeState
        )
        let persistence = BoneInMemoryWorkflowPersistence()
        let created = try await persistence.create(
            run: .init(id: runID, plan: plan, state: .running, revision: 0, leaseGeneration: 0),
            checkpoint: checkpoint
        )
        let leased = try await persistence.acquireLease(runID: runID, expectedRevision: created.run.revision)
        let loaded = try await persistence.load(runID: runID)
        try check(loaded == leased, "in-memory recovery")

        let canonical = try BoneCanonicalToolCall(
            toolID: AuthorizedWriteTool.definition.id,
            toolVersion: AuthorizedWriteTool.definition.version,
            schemaVersion: 1,
            arguments: Data("{\"value\":1}".utf8)
        )
        let ticketID = try BoneAuthorizationTicketID("ticket-1")
        let callID = try BoneToolCallID("call-1")
        let handler = BoneInMemoryAuthorizationHandler()
        let grant = try BoneAuthorizationGrant(
            ticketID: ticketID,
            runID: runID,
            stepID: stepID,
            attemptID: attemptID,
            toolCallID: callID,
            canonicalCall: canonical,
            principal: "example-user",
            resourceScope: "synthetic-state",
            resourceRevision: 1,
            impact: AuthorizedWriteTool.impact,
            grantedAtUptime: 10,
            expiresAtUptime: 20,
            nonce: "nonce-1"
        )
        try await handler.store(grant)
        try await handler.consume(.init(
            ticketID: ticketID,
            runID: runID,
            stepID: stepID,
            attemptID: attemptID,
            toolCallID: callID,
            canonicalCall: canonical,
            principal: "example-user",
            resourceScope: "synthetic-state",
            resourceRevision: 1,
            impact: AuthorizedWriteTool.impact,
            nowUptime: 15
        ))

        let engine = BoneScriptedInferenceEngine(script: [.finish(.init(text: "synthetic-ok"))])
        let response = try await engine.infer(request: .init(
            modelID: "synthetic-model",
            messages: [.init(role: .user, content: "synthetic")]
        ))
        try check(response == .finish(.init(text: "synthetic-ok")), "synthetic inference")
        print("PASS: MinimalWorkflowHost recovery + authorization")
    }
}
