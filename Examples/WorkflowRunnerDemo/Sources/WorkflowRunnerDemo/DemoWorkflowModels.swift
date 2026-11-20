import Foundation
import BoneAgentKit

// Example-local prototypes. None of the Demo* types are SDK API.
enum DemoWorkflowError: Error, Equatable {
    case invalidPlan, duplicateExecutor, unsupportedExecutor, invalidScope
    case inputChanged, configurationChanged, invalidCheckpoint, invalidReceipt
    case alreadyDriving, takeoverDenied, lostAcknowledgement, assertionFailed(String)
}

enum DemoRunMode: String, Codable, Sendable { case planning, executing }
enum DemoTerminalPolicy: String, Codable, Sendable { case automatic, hostDecided }
enum DemoPhase: String, Codable, Sendable { case prepared, dispatchPrepared, settled }
enum DemoOutcome: String, Sendable { case completed, failed, cancelled, awaitingHostDecision, requiresRecovery }

struct DemoInputReference: Codable, Equatable, Sendable {
    let id: String
    let revision: UInt64
}

struct DemoCapabilities: Codable, Equatable, Sendable {
    let policyID: String
    let revision: UInt64
    let allowedToolIDs: [String]
    let maximumImpact: BoneToolImpact

    init(policyID: String = "demo.policy", revision: UInt64 = 1,
         allowedToolIDs: [String], maximumImpact: BoneToolImpact = .ordinaryPublicRead) throws {
        guard !policyID.isEmpty, revision > 0, Set(allowedToolIDs).count == allowedToolIDs.count else {
            throw DemoWorkflowError.invalidScope
        }
        self.policyID = policyID
        self.revision = revision
        self.allowedToolIDs = allowedToolIDs.sorted()
        self.maximumImpact = maximumImpact
    }

    func select(_ tools: [BoneAnyAgentTool], mode: DemoRunMode,
                hostPolicy: BoneToolImpactPolicy?) throws -> BoneAgentToolRegistry {
        _ = try BoneAgentToolRegistry(tools: tools) // Reject duplicate IDs before filtering.
        let scopePolicy = BoneToolImpactPolicy(maximumAllowed: maximumImpact)
        let hostPolicy = hostPolicy ?? BoneToolImpactPolicy(maximumAllowed: .ordinaryPublicRead)
        let selected = try tools.filter { tool in
            guard allowedToolIDs.contains(tool.definition.id) else { return false }
            let impact = try tool.definition.requiredImpact()
            guard mode != .planning || impact.isOrdinaryReadOnly else { return false }
            do {
                try scopePolicy.authorize(impact)
                try hostPolicy.authorize(impact)
            } catch is BoneToolPolicyError { return false }
            _ = try tool.definition.validatedForModelExposure()
            return true
        }
        return try BoneAgentToolRegistry(tools: selected)
    }
}

struct DemoPreparation: Sendable {
    let mode: DemoRunMode
    let capabilities: DemoCapabilities
    let input: DemoInputReference
}

struct DemoExecution: Sendable {
    let snapshot: BoneWorkflowRunSnapshot
    let controller: BoneWorkflowAgentStepController
}

struct DemoPreparedStep: Sendable {
    let tools: [BoneAgentToolDefinition]
    let execute: @Sendable (DemoExecution) async throws -> BoneAgentRunOutput?
}

struct DemoStepExecutor: Sendable {
    let kind: String
    let revision: UInt64
    let prepare: @Sendable (DemoPreparation) throws -> DemoPreparedStep

    static func agent(engine: any BoneInferenceEngine, tools: [BoneAnyAgentTool],
                      messages: [BoneInferenceMessage], input: DemoInputReference,
                      configuration: BoneAgentConfiguration) -> Self {
        Self(kind: "agent", revision: 1) { preparation in
            guard preparation.input == input else { throw DemoWorkflowError.inputChanged }
            let registry = try preparation.capabilities.select(tools, mode: preparation.mode,
                                                               hostPolicy: configuration.toolImpactPolicy)
            let request = BoneInferenceRequest(modelID: "synthetic-model", messages: messages,
                                               availableTools: registry.definitions)
            let resolved = try engine.resolvedCapabilities(for: request, invocation: .nonStreaming)
            try BoneInferenceCapabilityValidator.validate(request: request, capabilities: resolved.capabilities,
                                                          invocation: resolved.invocation)
            return DemoPreparedStep(tools: registry.definitions) { context in
                let agent = BoneAgent(inferenceEngine: engine, toolRegistry: registry,
                                      toolContext: BoneAgentEmptyContext(), configuration: configuration,
                                      workflowController: context.controller)
                let result = try await agent.runWorkflowStep(modelID: request.modelID,
                                                            messages: request.messages,
                                                            controller: context.controller)
                return result.output
            }
        }
    }
}

struct DemoStepExecutors: Sendable {
    private let entries: [String: DemoStepExecutor]

    init(_ executors: [DemoStepExecutor]) throws {
        var entries: [String: DemoStepExecutor] = [:]
        for executor in executors {
            guard !executor.kind.isEmpty, executor.revision > 0 else { throw DemoWorkflowError.invalidPlan }
            guard entries[executor.kind] == nil else { throw DemoWorkflowError.duplicateExecutor }
            entries[executor.kind] = executor
        }
        self.entries = entries
    }

    func executor(for plan: BoneWorkflowPlan) throws -> DemoStepExecutor {
        guard plan.steps.count == 1 else { throw DemoWorkflowError.invalidPlan }
        guard let executor = entries[plan.steps[0].kind], executor.revision == plan.steps[0].revision else {
            throw DemoWorkflowError.unsupportedExecutor
        }
        return executor
    }
}

struct DemoCheckpoint: Codable, Equatable, Sendable {
    let schemaVersion: UInt64
    let mode: DemoRunMode
    let capabilities: DemoCapabilities
    let terminalPolicy: DemoTerminalPolicy
    let input: DemoInputReference
    let tools: [BoneAgentToolDefinition]
    var phase: DemoPhase
    var step: BoneWorkflowAgentStepCheckpoint

    static func decode(_ snapshot: BoneWorkflowRunSnapshot) throws -> Self {
        let value: Self
        do { value = try JSONDecoder().decode(Self.self, from: snapshot.checkpoint.payload) }
        catch { throw DemoWorkflowError.invalidCheckpoint }
        guard value.schemaVersion == 1, snapshot.run.plan.steps.count == 1,
              snapshot.run.revision == snapshot.checkpoint.revision,
              snapshot.checkpoint.descriptor.formatVersion == 1,
              snapshot.checkpoint.descriptor.workflowIdentity == snapshot.run.plan.identity,
              snapshot.checkpoint.descriptor.workflowRevision == snapshot.run.plan.revision,
              value.step.runID == snapshot.run.id, value.step.stepID == snapshot.run.plan.steps[0].id,
              value.phase == .settled ? value.step.terminalState != nil : value.step.terminalState == nil else {
            throw DemoWorkflowError.invalidCheckpoint
        }
        return value
    }

    func envelope(plan: BoneWorkflowPlan, revision: UInt64 = 0) throws -> BoneWorkflowCheckpoint {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try .init(descriptor: .init(formatVersion: 1, workflowIdentity: plan.identity,
                                          workflowRevision: plan.revision),
                         payload: encoder.encode(self), dataClassification: .opaqueReference,
                         revision: revision)
    }
}

struct DemoRunReport: Sendable {
    let outcome: DemoOutcome
    let snapshot: BoneWorkflowRunSnapshot
    let output: BoneAgentRunOutput?
}

func demoPlan(kind: String = "agent", revision: UInt64 = 1) throws -> BoneWorkflowPlan {
    try .init(identity: "demo.workflow.\(kind)", revision: 1,
              steps: [.init(id: .init("main"), kind: kind, revision: revision)])
}

func demoStepCopy(_ step: BoneWorkflowAgentStepCheckpoint, state: BoneWorkflowStepState? = nil,
                  revision: UInt64? = nil, generation: UInt64? = nil) throws -> BoneWorkflowAgentStepCheckpoint {
    if let state, state != step.state { _ = try step.state.transitioned(to: state) }
    return .init(runID: step.runID, stepID: step.stepID, attemptID: step.attemptID,
                 state: state ?? step.state, inferenceResponseCount: step.inferenceResponseCount,
                 toolResultCount: step.toolResultCount, pendingAuthorizationTicketID: step.pendingAuthorizationTicketID,
                 cancellationPersisted: step.cancellationPersisted, terminalState: step.terminalState,
                 persistenceRevision: revision ?? step.persistenceRevision,
                 leaseGeneration: generation ?? step.leaseGeneration,
                 executionSnapshotReference: step.executionSnapshotReference)
}

func demoIncrement(_ value: UInt64) throws -> UInt64 {
    let (next, overflow) = value.addingReportingOverflow(1)
    guard !overflow else { throw BoneWorkflowFailure.revisionConflict }
    return next
}

func demoCommit(_ persistence: any BoneWorkflowPersistence, current: BoneWorkflowRunSnapshot,
                payload: DemoCheckpoint) async throws -> BoneWorkflowRunSnapshot {
    let envelope = try payload.envelope(plan: current.run.plan, revision: current.run.revision)
    let saved = try await persistence.commit(run: current.run, checkpoint: envelope,
                                            expectedRevision: current.run.revision,
                                            leaseGeneration: current.run.leaseGeneration)
    guard saved.run.id == current.run.id, saved.run.plan == current.run.plan,
          saved.run.state == current.run.state, saved.run.leaseGeneration == current.run.leaseGeneration,
          saved.run.revision == (try demoIncrement(current.run.revision)),
          saved.checkpoint.revision == saved.run.revision,
          saved.checkpoint.payload == envelope.payload,
          saved.checkpoint.descriptor == envelope.descriptor,
          saved.checkpoint.dataClassification == envelope.dataClassification,
          saved.checkpoint.retention == envelope.retention else { throw DemoWorkflowError.invalidReceipt }
    return saved
}
