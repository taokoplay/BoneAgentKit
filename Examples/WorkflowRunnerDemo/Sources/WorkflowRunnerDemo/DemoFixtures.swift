import Foundation
import BoneAgentKit
import BoneAgentTesting

/// A process-local forwarding store with deterministic acknowledgement-loss injection.
actor DemoPersistence: BoneWorkflowPersistence {
    enum Fault: Sendable { case none, dispatchAcknowledgement, responseAcknowledgement, stepAcknowledgement, runAcknowledgement }
    private let storage = BoneInMemoryWorkflowPersistence()
    private var fault: Fault
    private(set) var writes = 0
    private(set) var creates = 0
    private(set) var trace: [String] = []

    init(fault: Fault = .none) { self.fault = fault }

    func create(run: BoneWorkflowRunRecord, checkpoint: BoneWorkflowCheckpoint) async throws -> BoneWorkflowRunSnapshot {
        let saved = try await storage.create(run: run, checkpoint: checkpoint)
        creates += 1
        record(saved)
        return saved
    }

    func load(runID: BoneRunID) async throws -> BoneWorkflowRunSnapshot { try await storage.load(runID: runID) }

    func commit(run: BoneWorkflowRunRecord, checkpoint: BoneWorkflowCheckpoint,
                expectedRevision: UInt64, leaseGeneration: UInt64) async throws -> BoneWorkflowRunSnapshot {
        let saved = try await storage.commit(run: run, checkpoint: checkpoint,
                                             expectedRevision: expectedRevision, leaseGeneration: leaseGeneration)
        record(saved)
        let payload = try DemoCheckpoint.decode(saved)
        let lose: Bool
        switch fault {
        case .none: lose = false
        case .dispatchAcknowledgement: lose = payload.phase == .dispatchPrepared
        case .responseAcknowledgement: lose = payload.step.inferenceResponseCount > 0
        case .stepAcknowledgement: lose = payload.phase == .settled
        case .runAcknowledgement: lose = saved.run.state == .completed
        }
        if lose {
            fault = .none
            throw DemoWorkflowError.lostAcknowledgement // The actual commit above succeeded.
        }
        return saved
    }

    func acquireLease(runID: BoneRunID, expectedRevision: UInt64) async throws -> BoneWorkflowRunSnapshot {
        let saved = try await storage.acquireLease(runID: runID, expectedRevision: expectedRevision)
        record(saved)
        return saved
    }

    private func record(_ snapshot: BoneWorkflowRunSnapshot) {
        writes += 1
        trace.append("revision=\(snapshot.run.revision) generation=\(snapshot.run.leaseGeneration) run=\(snapshot.run.state.rawValue)")
    }
}

actor DemoToolCounter {
    private(set) var reads = 0
    private(set) var writes = 0
    func read() { reads += 1 }
    func write() { writes += 1 }
}

struct DemoPayload: Codable, Sendable {}

struct DemoReadTool: BoneAgentTool {
    typealias Input = DemoPayload
    struct Output: Codable, Sendable { let count: Int }
    typealias Context = BoneAgentEmptyContext
    static let definition = BoneAgentToolDefinition(
        id: "demo.read", version: "1", title: "Read", summary: "Read synthetic public metadata",
        wireName: "demo_read", schemaVersion: 1,
        inputSchema: .object(properties: [:], required: [], additionalProperties: false), impact: .ordinaryPublicRead)
    let counter: DemoToolCounter
    func execute(input: Input, context: Context) async throws -> Output {
        await counter.read()
        return .init(count: 7)
    }
}

struct DemoWriteTool: BoneAgentTool {
    typealias Input = DemoPayload
    typealias Output = DemoPayload
    typealias Context = BoneAgentEmptyContext
    static let impact = BoneToolImpact(dataAccess: .public, externalTransmission: .none,
                                       stateChange: .reversible, economic: .none,
                                       userVisible: .none, permissionChange: .none)
    static let definition = BoneAgentToolDefinition(
        id: "demo.write", version: "1", title: "Write", summary: "Mutate a synthetic memory counter",
        wireName: "demo_write", schemaVersion: 1,
        inputSchema: .object(properties: [:], required: [], additionalProperties: false), impact: impact)
    let counter: DemoToolCounter
    func execute(input: Input, context: Context) async throws -> Output {
        await counter.write()
        return .init()
    }
}

struct DemoFixture: Sendable {
    static let input = DemoInputReference(id: "synthetic.input", revision: 1)
    let engine: BoneScriptedInferenceEngine
    let counter: DemoToolCounter
    let persistence: DemoPersistence
    let executor: DemoStepExecutor
    let capabilities: DemoCapabilities

    init(script: [BoneInferenceResponse], fault: DemoPersistence.Fault = .none,
         messages: [BoneInferenceMessage] = [.init(role: .user, content: "Read the public count")]) throws {
        let engine = BoneScriptedInferenceEngine(script: script)
        let counter = DemoToolCounter()
        self.engine = engine
        self.counter = counter
        persistence = DemoPersistence(fault: fault)
        capabilities = try .init(allowedToolIDs: ["demo.read", "demo.write"], maximumImpact: DemoWriteTool.impact)
        executor = .agent(engine: engine,
                          tools: [BoneAnyAgentTool(DemoReadTool(counter: counter)), BoneAnyAgentTool(DemoWriteTool(counter: counter))],
                          messages: messages, input: Self.input,
                          configuration: try .init(maximumSteps: 4, toolImpactPolicy: .init(maximumAllowed: DemoWriteTool.impact)))
    }

    func runner(terminalPolicy: DemoTerminalPolicy = .automatic) throws -> DemoWorkflowRunner {
        DemoWorkflowRunner(persistence: persistence, executors: try .init([executor]),
                           capabilities: capabilities, terminalPolicy: terminalPolicy)
    }

    static func call(_ tool: String = "demo.read") -> BoneInferenceResponse {
        .toolCall(.init(id: "call-1", toolID: tool, arguments: Data("{}".utf8)))
    }
    static func finish(_ text: String = "Public count: 7") -> BoneInferenceResponse { .finish(.init(text: text)) }
}

func demoCheck(_ condition: Bool, _ message: String) throws {
    guard condition else { throw DemoWorkflowError.assertionFailed(message) }
}
