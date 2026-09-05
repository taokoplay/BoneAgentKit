import BoneAgentKit
import BoneAgentLocalModels
import XCTest
@testable import BoneAgentLlama

final class BoneLlamaRuntimeProbeAdapterTests: XCTestCase {
    func testLoadProbeLoadsThenUnloadsIsolatedRuntime() async throws {
        let runtime = LlamaRuntimeFixture()
        let adapter = BoneLlamaRuntimeProbeAdapter(
            runtimeVersion: 2,
            runtimeFactory: { runtime }
        )

        let result = await adapter.probe(
            model: try model(),
            artifactURL: URL(fileURLWithPath: "/tmp/model.gguf"),
            environment: environment(),
            plan: plan(),
            depth: .load
        )

        let events = await runtime.events()
        XCTAssertEqual(result.check, .init(kind: .modelLoad, status: .passed))
        XCTAssertTrue(result.verifiedCapabilities.isEmpty)
        XCTAssertEqual(events, [.load, .unload])
    }

    func testSmokeProbeVerifiesTextCapability() async throws {
        let runtime = LlamaRuntimeFixture()
        let adapter = BoneLlamaRuntimeProbeAdapter(runtimeVersion: 1, runtimeFactory: { runtime })
        let result = await adapter.probe(
            model: try model(), artifactURL: URL(fileURLWithPath: "/tmp/model.gguf"),
            environment: environment(), plan: plan(), depth: .smoke
        )
        XCTAssertEqual(result.verifiedCapabilities, [.text])
        let events = await runtime.events()
        XCTAssertEqual(events, [.load, .smoke, .unload])
    }

    func testConstrainedSmokeVerifiesToolContinuationAndReturnsIdentity() async throws {
        let runtime = ControlledLlamaRuntimeFixture(outputs: [
            (#"{"type":"tool_calls","tool_calls":[{"id":"probe-1","name":"capability_probe","arguments":{"value":"ready"}}]}"#, .eog),
            (#"{"type":"final","content":"Capability verified."}"#, .eog),
        ])
        let renderer = ProbeRendererFixture()
        let envelope = BoneLlamaConstrainedJSONToolEnvelopeCodec()
        let adapter = BoneLlamaRuntimeProbeAdapter(
            runtimeVersion: 2,
            conversationRenderer: renderer,
            toolEnvelope: envelope,
            runtimeFactory: { runtime }
        )
        let result = await adapter.probe(
            model: try model(profile: try BoneModelCapabilityProfile(
                capabilities: [.text, .toolCalling, .constrainedOutput],
                source: .official,
                verifiedAt: "2026-09-03"
            )),
            artifactURL: URL(fileURLWithPath: "/tmp/model.gguf"),
            environment: environment(),
            plan: plan(),
            depth: .smoke
        )

        XCTAssertEqual(result.check.status, .passed)
        XCTAssertEqual(result.verifiedCapabilities, [.text, .toolCalling, .constrainedOutput])
        XCTAssertEqual(result.verificationIdentity?.toolEnvelopeVersion, "2")
        XCTAssertEqual(result.verificationIdentity?.artifactSHA256, String(repeating: "a", count: 64))
        XCTAssertEqual(result.verificationIdentity?.constraintCompilerID, "bone.gbnf")
        XCTAssertEqual(result.verificationIdentity?.constraintDialect, "bone-gbnf-v1")
        XCTAssertEqual(result.verificationIdentity?.grammarSamplerID, "fixture-gbnf-sampler")
        XCTAssertEqual(result.verificationIdentity?.stopMatcherID, "fixture-stop")
        XCTAssertEqual(result.verificationIdentity?.terminationContractVersion, 1)
        XCTAssertEqual(
            result.verificationIdentity?.probeProtocolVersion,
            BoneLlamaRuntimeProbeAdapter.probeProtocolVersion
        )
        XCTAssertTrue(result.verificationIdentity?.hasConstraintRuntimeIdentity == true)
        let directPrompts = await runtime.directPrompts()
        XCTAssertEqual(directPrompts.count, 2)
        XCTAssertTrue(directPrompts.first?.contains("Return exactly ready. Output no other text.") == true)
        XCTAssertTrue(directPrompts.last?.contains("Return a JSON object with ok set to true. Output no other text.") == true)
        let controls = await runtime.controls()
        XCTAssertEqual(controls.count, 4)
        XCTAssertTrue(controls.allSatisfy { $0.constraint != nil })
        let sawMultipleRanges = await runtime.sawMultiplePrefillRanges()
        XCTAssertTrue(sawMultipleRanges)
    }

    func testConstrainedSmokeFailsClosedWhenModelChoosesAllowedButUnrequestedEnumBranch() async throws {
        let runtime = ControlledLlamaRuntimeFixture(
            outputs: [
                (#"{"type":"tool_calls","tool_calls":[{"id":"probe-1","name":"capability_probe","arguments":{"value":"ready"}}]}"#, .eog),
                (#"{"type":"final","content":"Capability verified."}"#, .eog),
            ],
            directConstraintOutputs: [("not-ready", .eog), (#"{"ok":true}"#, .eog)]
        )
        let adapter = BoneLlamaRuntimeProbeAdapter(
            runtimeVersion: 2,
            conversationRenderer: ProbeRendererFixture(),
            toolEnvelope: BoneLlamaConstrainedJSONToolEnvelopeCodec(),
            runtimeFactory: { runtime }
        )
        let result = await adapter.probe(
            model: try model(profile: try BoneModelCapabilityProfile(
                capabilities: [.text, .toolCalling, .constrainedOutput],
                source: .official,
                verifiedAt: "2026-09-03"
            )),
            artifactURL: URL(fileURLWithPath: "/tmp/model.gguf"),
            environment: environment(), plan: plan(), depth: .smoke
        )

        XCTAssertEqual(result.check.status, .failed)
        XCTAssertTrue(result.verifiedCapabilities.isEmpty)
        XCTAssertNil(result.verificationIdentity)
        let directPrompts = await runtime.directPrompts()
        XCTAssertEqual(directPrompts.count, 1)
        XCTAssertTrue(directPrompts.first?.contains("Return exactly ready. Output no other text.") == true)
    }

    func testConstrainedSmokeFailsClosedWhenDirectConstraintOutputIsInvalid() async throws {
        let runtime = ControlledLlamaRuntimeFixture(
            outputs: [
                (#"{"type":"tool_calls","tool_calls":[{"id":"probe-1","name":"capability_probe","arguments":{"value":"ready"}}]}"#, .eog),
                (#"{"type":"final","content":"Capability verified."}"#, .eog),
            ],
            directConstraintOutputs: [("READY", .eog)]
        )
        let adapter = BoneLlamaRuntimeProbeAdapter(
            runtimeVersion: 2,
            conversationRenderer: ProbeRendererFixture(),
            toolEnvelope: BoneLlamaConstrainedJSONToolEnvelopeCodec(),
            runtimeFactory: { runtime }
        )
        let result = await adapter.probe(
            model: try model(profile: try BoneModelCapabilityProfile(
                capabilities: [.text, .toolCalling, .constrainedOutput],
                source: .official,
                verifiedAt: "2026-09-03"
            )),
            artifactURL: URL(fileURLWithPath: "/tmp/model.gguf"),
            environment: environment(), plan: plan(), depth: .smoke
        )

        XCTAssertEqual(result.check.status, .failed)
        XCTAssertTrue(result.verifiedCapabilities.isEmpty)
        XCTAssertNil(result.verificationIdentity)
    }

    func testConstrainedSmokeFailsClosedOnInvalidTermination() async throws {
        let runtime = ControlledLlamaRuntimeFixture(outputs: [
            (#"{"type":"tool_calls","tool_calls":[{"id":"probe-1","name":"capability_probe","arguments":{"value":"ready"}}]}"#, .maximumTokens),
        ])
        let adapter = BoneLlamaRuntimeProbeAdapter(
            runtimeVersion: 2,
            conversationRenderer: ProbeRendererFixture(),
            toolEnvelope: BoneLlamaConstrainedJSONToolEnvelopeCodec(),
            runtimeFactory: { runtime }
        )
        let result = await adapter.probe(
            model: try model(profile: try BoneModelCapabilityProfile(
                capabilities: [.text, .toolCalling, .constrainedOutput],
                source: .official,
                verifiedAt: "2026-09-03"
            )),
            artifactURL: URL(fileURLWithPath: "/tmp/model.gguf"),
            environment: environment(), plan: plan(), depth: .smoke
        )

        XCTAssertEqual(result.check.status, .failed)
        XCTAssertTrue(result.verifiedCapabilities.isEmpty)
        XCTAssertNil(result.verificationIdentity)
    }

    func testSmokeProbeRunsSmokeAndMapsRuntimeErrors() async throws {
        for (error, expected) in [
            (BoneLlamaRuntimeError.modelIncompatible, BoneLocalRuntimeProbeCheckStatus.incompatible),
            (.insufficientResources, .temporarilyUnavailable),
            (.loadFailed, .failed),
        ] {
            let runtime = LlamaRuntimeFixture(error: error)
            let adapter = BoneLlamaRuntimeProbeAdapter(runtimeVersion: 1, runtimeFactory: { runtime })
            let result = await adapter.probe(
                model: try model(), artifactURL: URL(fileURLWithPath: "/tmp/model.gguf"),
                environment: environment(), plan: plan(), depth: .smoke
            )
            let events = await runtime.events()
            XCTAssertEqual(result.check, .init(kind: .smoke, status: expected))
            XCTAssertEqual(events.last, .unload)
        }
    }

    private func plan() -> BoneLocalRuntimePlan {
        .init(contextTokens: 512, maximumOutputTokens: 128, batchTokens: 32, threadCount: 2)
    }

    private func environment() -> BoneLocalRuntimeEnvironment {
        .init(physicalMemoryBytes: 10_000, availableDiskBytes: 10_000, activeProcessorCount: 4, isSimulator: false, isLowPowerModeEnabled: false, thermalState: .nominal)
    }

    private func model(
        profile: BoneModelCapabilityProfile? = nil
    ) throws -> BoneLocalModelDescriptor {
        .init(
            id: "model", displayName: "Model", family: "Test", format: .gguf,
            parameterCount: 1, quantization: "Q4", minimumMemoryBytes: 1,
            recommendedContextTokens: 512, minimumRuntimeVersion: 1,
            contextLimits: try .init(contextWindowTokens: 1_024, maximumInputTokens: 768, maximumOutputTokens: 256, source: .official, verifiedAt: "2026-09-01", documentationURL: URL(string: "https://example.com")!),
            inferenceCapabilityProfile: profile,
            artifact: .init(fileName: "model.gguf", expectedByteCount: 4, sha256: String(repeating: "a", count: 64), sources: []),
            license: .init(name: "Test", url: URL(string: "https://example.com")!, modelCardURL: URL(string: "https://example.com")!)
        )
    }
}

private struct ProbeRendererFixture: BoneLlamaConversationRendering {
    func render(
        conversation: BoneLlamaConversation,
        using runtime: any BoneLlamaRuntime
    ) async throws -> BoneLlamaRenderedPrompt {
        try .init(
            prompt: conversation.messages.map(\.content).joined(separator: "\n") + String(repeating: " x", count: 200),
            templateIdentity: .init(
                source: .ggufMetadata,
                templateDigest: String(repeating: "b", count: 64),
                rendererID: "fixture.native",
                rendererVersion: "1",
                reasoningMode: .disabled,
                addGenerationPrompt: true
            )
        )
    }
}

private actor ControlledLlamaRuntimeFixture: BoneLlamaControlledGenerationRuntime, BoneLlamaConstraintGenerationRuntime, BoneLlamaRuntimeVerificationIdentifying {
    nonisolated let runtimeVersion = 2
    private var outputs: [(String, BoneLlamaGenerationTermination)]
    private var directConstraintOutputs: [(String, BoneLlamaGenerationTermination)]
    private var recordedControls: [BoneLlamaGenerationControl] = []
    private var recordedDirectPrompts: [String] = []
    private var multiplePrefillRanges = false

    init(
        outputs: [(String, BoneLlamaGenerationTermination)],
        directConstraintOutputs: [(String, BoneLlamaGenerationTermination)] = [
            ("ready", .eog),
            (#"{"ok":true}"#, .eog),
        ]
    ) {
        self.outputs = outputs
        self.directConstraintOutputs = directConstraintOutputs
    }

    func load(modelURL: URL, configuration: BoneLlamaRuntimeConfiguration) async throws {}
    func tokenize(prompt: String) async throws -> BoneLlamaPromptTokenization { try .init(tokenCount: 96) }
    func generate(prompt: String, executionPlan: BoneLlamaPromptExecutionPlan, options: BoneLlamaGenerationOptions) async throws -> BoneLlamaGenerationResult {
        throw BoneLlamaRuntimeError.generationFailed
    }
    func generate(
        prompt: String,
        executionPlan: BoneLlamaPromptExecutionPlan,
        options: BoneLlamaGenerationOptions,
        control: BoneLlamaGenerationControl
    ) async throws -> BoneLlamaGenerationResult {
        recordedControls.append(control)
        multiplePrefillRanges = multiplePrefillRanges || executionPlan.prefillRanges.count > 1
        guard !outputs.isEmpty else { throw BoneLlamaRuntimeError.generationFailed }
        let next = outputs.removeFirst()
        return .init(text: next.0, termination: next.1)
    }
    func generate(
        prompt: String,
        executionPlan: BoneLlamaPromptExecutionPlan,
        options: BoneLlamaGenerationOptions,
        control: BoneLlamaResolvedGenerationControl
    ) async throws -> BoneLlamaGenerationResult {
        recordedControls.append(try .init(
            stopTokenIDs: control.stopTokenIDs,
            stopStrings: control.stopStrings,
            constraint: control.sourceConstraint
        ))
        multiplePrefillRanges = multiplePrefillRanges || executionPlan.prefillRanges.count > 1
        if !outputs.isEmpty {
            let next = outputs.removeFirst()
            return .init(text: next.0, termination: next.1)
        }
        guard !directConstraintOutputs.isEmpty else { throw BoneLlamaRuntimeError.generationFailed }
        recordedDirectPrompts.append(prompt)
        let next = directConstraintOutputs.removeFirst()
        return .init(text: next.0, termination: next.1)
    }
    func verificationComponents() async throws -> BoneLlamaRuntimeVerificationComponents {
        .init(
            tokenizerID: "fixture-tokenizer",
            tokenizerVersion: "1",
            grammarParserID: "fixture-grammar",
            grammarParserVersion: "1",
            grammarSamplerID: "fixture-gbnf-sampler",
            grammarSamplerVersion: "1",
            stopMatcherID: "fixture-stop",
            stopMatcherVersion: "1"
        )
    }
    func verifyBasicGeneration() async throws {}
    func cancel() async {}
    func unload() async {}
    func controls() -> [BoneLlamaGenerationControl] { recordedControls }
    func directPrompts() -> [String] { recordedDirectPrompts }
    func sawMultiplePrefillRanges() -> Bool { multiplePrefillRanges }
}

private enum LlamaRuntimeEvent: Equatable, Sendable { case load, smoke, generate, unload }

private actor LlamaRuntimeFixture: BoneLlamaRuntime {
    nonisolated let runtimeVersion = 1
    private let error: BoneLlamaRuntimeError?
    private var outputs: [String]
    private var recorded: [LlamaRuntimeEvent] = []

    init(error: BoneLlamaRuntimeError? = nil, outputs: [String] = []) {
        self.error = error
        self.outputs = outputs
    }

    func load(modelURL: URL, configuration: BoneLlamaRuntimeConfiguration) async throws {
        recorded.append(.load)
        if let error { throw error }
    }
    func tokenize(prompt: String) async throws -> BoneLlamaPromptTokenization {
        try .init(tokenCount: max(1, prompt.utf8.count / 4))
    }

    func generate(
        prompt: String,
        executionPlan: BoneLlamaPromptExecutionPlan,
        options: BoneLlamaGenerationOptions
    ) async throws -> BoneLlamaGenerationResult {
        recorded.append(.generate)
        guard !outputs.isEmpty else { return .init(text: "ok") }
        return .init(text: outputs.removeFirst())
    }
    func verifyBasicGeneration() async throws { recorded.append(.smoke) }
    func cancel() async {}
    func unload() async { recorded.append(.unload) }
    func events() -> [LlamaRuntimeEvent] { recorded }
}
