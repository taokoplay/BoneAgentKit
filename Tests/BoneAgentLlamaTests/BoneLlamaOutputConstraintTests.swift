import BoneAgentKit
import BoneAgentLocalRuntime
import XCTest
@testable import BoneAgentLlama

final class BoneLlamaOutputConstraintTests: XCTestCase {
    func testEnumConstraintUsesCompilerAndCompiledRuntimeThenReturnsExactFinish() async throws {
        let runtime = ConstraintRuntimeFixture(result: "ready", termination: .eog)
        let engine = makeEngine(runtime: runtime, compiler: BoneLlamaGBNFCompiler())
        let request = BoneInferenceRequest(
            modelID: "model",
            messages: [.init(role: .user, content: "Status")],
            outputConstraint: .enumChoice(["ready", "not-ready"])
        )

        let response = try await engine.infer(request: request)

        XCTAssertEqual(response, .finish(.init(text: "ready")))
        let recorded = await runtime.recordedControl()
        XCTAssertEqual(recorded?.sourceConstraint, .enumChoice(["ready", "not-ready"]))
        XCTAssertEqual(recorded?.compiledConstraint?.compilerIdentity, BoneLlamaGBNFCompiler().identity)
    }

    func testSchemaConstraintReturnsStructuredJSONValueAndRevalidates() async throws {
        let schema = BoneToolSchema.object(
            properties: ["ok": .boolean],
            required: ["ok"],
            additionalProperties: false
        )
        let runtime = ConstraintRuntimeFixture(result: #"{"ok":true}"#, termination: .eog)
        let engine = makeEngine(runtime: runtime, compiler: BoneLlamaGBNFCompiler())

        let response = try await engine.infer(request: .init(
            modelID: "model",
            messages: [.init(role: .user, content: "Status")],
            outputConstraint: .jsonSchema(schema)
        ))

        XCTAssertEqual(response, .structured(.init(data: Data(#"{"ok":true}"#.utf8))))
    }

    func testConstraintFailsBeforeGenerationWithoutCompilerOrV2Runtime() async throws {
        let plainRuntime = PlainConstraintRuntimeFixture()
        let noCompiler = BoneLlamaInferenceEngine(
            modelID: "model",
            modelURL: URL(fileURLWithPath: "/tmp/model.gguf"),
            plan: Self.plan,
            conversationRenderer: BoneLlamaChatMLConversationRenderer(),
            constraintCompiler: nil,
            runtimeFactory: { plainRuntime }
        )
        await assertThrows(try await noCompiler.infer(request: request()))

        let withCompiler = BoneLlamaInferenceEngine(
            modelID: "model",
            modelURL: URL(fileURLWithPath: "/tmp/model.gguf"),
            plan: Self.plan,
            conversationRenderer: BoneLlamaChatMLConversationRenderer(),
            constraintCompiler: BoneLlamaGBNFCompiler(),
            runtimeFactory: { plainRuntime }
        )
        await assertThrows(try await withCompiler.infer(request: request()))
        let generateCount = await plainRuntime.generateCount()
        XCTAssertEqual(generateCount, 0)
    }

    func testConstraintCapabilityRequiresMatchingRuntimeSmokeProfile() throws {
        let runtime = ConstraintRuntimeFixture(result: "ready", termination: .eog)
        let unverified = makeEngine(runtime: runtime, compiler: BoneLlamaGBNFCompiler())
        XCTAssertEqual(unverified.nonImageCapabilities, [.text])

        let identity = try Self.identity()
        let profile = try BoneModelCapabilityProfile(
            capabilities: [.text, .constrainedOutput],
            source: .runtimeSmoke,
            verifiedAt: "2026-09-04",
            verificationIdentity: identity
        )
        let verified = BoneLlamaInferenceEngine(
            modelID: "model",
            modelURL: URL(fileURLWithPath: "/tmp/model.gguf"),
            plan: Self.plan,
            conversationRenderer: BoneLlamaChatMLConversationRenderer(),
            verifiedCapabilityProfile: profile,
            currentVerificationIdentity: identity,
            constraintCompiler: BoneLlamaGBNFCompiler(),
            runtimeFactory: { runtime }
        )
        XCTAssertEqual(verified.nonImageCapabilities, [.text, .constrainedOutput])
    }

    func testRejectsEnumDriftSchemaMismatchAndIncompleteTermination() async throws {
        for (result, termination) in [
            ("ready ", BoneLlamaGenerationTermination.eog),
            ("READY", .eog),
            ("ready", .maximumTokens),
            ("ready", .runtimeCompleted),
        ] {
            let runtime = ConstraintRuntimeFixture(result: result, termination: termination)
            await assertThrows(try await makeEngine(runtime: runtime, compiler: BoneLlamaGBNFCompiler()).infer(request: request()))
        }

        let schema = BoneToolSchema.object(properties: ["ok": .boolean], required: ["ok"], additionalProperties: false)
        let runtime = ConstraintRuntimeFixture(result: #"{"ok":"true"}"#, termination: .eog)
        await assertThrows(try await makeEngine(runtime: runtime, compiler: BoneLlamaGBNFCompiler()).infer(request: .init(
            modelID: "model",
            messages: [.init(role: .user, content: "Status")],
            outputConstraint: .jsonSchema(schema)
        )))
    }

    private func makeEngine(
        runtime: ConstraintRuntimeFixture,
        compiler: (any BoneLlamaConstraintCompiling)?
    ) -> BoneLlamaInferenceEngine {
        BoneLlamaInferenceEngine(
            modelID: "model",
            modelURL: URL(fileURLWithPath: "/tmp/model.gguf"),
            plan: Self.plan,
            conversationRenderer: BoneLlamaChatMLConversationRenderer(),
            constraintCompiler: compiler,
            runtimeFactory: { runtime }
        )
    }

    private func request() -> BoneInferenceRequest {
        .init(
            modelID: "model",
            messages: [.init(role: .user, content: "Status")],
            outputConstraint: .enumChoice(["ready"])
        )
    }

    private func assertThrows<T>(_ expression: @autoclosure () async throws -> T) async {
        do { _ = try await expression(); XCTFail("Expected error") }
        catch { XCTAssertNotNil(error as? BoneLlamaAdapterError) }
    }

    private static let plan = BoneLocalRuntimePlan(
        contextTokens: 512,
        maximumOutputTokens: 64,
        batchTokens: 32,
        threadCount: 2
    )

    private static func identity() throws -> BoneCapabilityVerificationIdentity {
        try .init(
            artifactSHA256: String(repeating: "a", count: 64),
            runtimeID: "llama.cpp",
            runtimeVersion: 3,
            tokenizerID: "fixture",
            tokenizerVersion: "1",
            templateDigest: String(repeating: "b", count: 64),
            rendererID: "bone.chatml",
            rendererVersion: "1",
            reasoningMode: "disabled",
            generationControlDigest: String(repeating: "c", count: 64),
            toolEnvelopeID: nil,
            toolEnvelopeVersion: nil,
            constraintDecoderID: "fixture.gbnf",
            constraintDecoderVersion: "1",
            contextTokens: 512,
            batchTokens: 32,
            addGenerationPrompt: true,
            maximumOutputTokens: 64
        )
    }
}

private actor ConstraintRuntimeFixture: BoneLlamaCompiledConstraintRuntime {
    nonisolated let runtimeVersion = 3
    let result: String
    let termination: BoneLlamaGenerationTermination
    var control: BoneLlamaCompiledGenerationControl?

    init(result: String, termination: BoneLlamaGenerationTermination) {
        self.result = result
        self.termination = termination
    }

    func load(modelURL: URL, configuration: BoneLlamaRuntimeConfiguration) async throws {}
    func tokenize(prompt: String) async throws -> BoneLlamaPromptTokenization { try .init(tokenCount: 8) }
    func generate(prompt: String, executionPlan: BoneLlamaPromptExecutionPlan, options: BoneLlamaGenerationOptions) async throws -> BoneLlamaGenerationResult {
        throw BoneLlamaRuntimeError.generationFailed
    }
    func generate(prompt: String, executionPlan: BoneLlamaPromptExecutionPlan, options: BoneLlamaGenerationOptions, control: BoneLlamaCompiledGenerationControl) async throws -> BoneLlamaGenerationResult {
        self.control = control
        return .init(text: result, termination: termination)
    }
    func smokeTest() async throws {}
    func cancel() async {}
    func unload() async {}
    func recordedControl() -> BoneLlamaCompiledGenerationControl? { control }
}

private actor PlainConstraintRuntimeFixture: BoneLlamaRuntime {
    nonisolated let runtimeVersion = 1
    var count = 0
    func load(modelURL: URL, configuration: BoneLlamaRuntimeConfiguration) async throws {}
    func tokenize(prompt: String) async throws -> BoneLlamaPromptTokenization { try .init(tokenCount: 8) }
    func generate(prompt: String, executionPlan: BoneLlamaPromptExecutionPlan, options: BoneLlamaGenerationOptions) async throws -> BoneLlamaGenerationResult {
        count += 1
        return .init(text: "ready", termination: .eog)
    }
    func smokeTest() async throws {}
    func cancel() async {}
    func unload() async {}
    func generateCount() -> Int { count }
}
