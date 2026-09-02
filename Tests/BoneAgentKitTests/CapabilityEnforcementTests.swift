import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import BoneAgentKit

final class CapabilityEnforcementTests: XCTestCase {
    func testModelCapabilityProfileIntersectsEngineCapabilitiesAndRejectsInvalidMetadata() throws {
        let profile = try BoneModelCapabilityProfile(
            capabilities: [.text, .toolCalling],
            source: .hostVerified,
            verifiedAt: "2026-09-02"
        )
        XCTAssertEqual(
            profile.resolved(engineCapabilities: [.text, .toolCalling, .streaming]),
            [.text, .toolCalling]
        )
        XCTAssertThrowsError(try BoneModelCapabilityProfile(
            capabilities: [.imageGeneration],
            source: .official,
            verifiedAt: "2026-09-02"
        ))
        XCTAssertThrowsError(try BoneModelCapabilityProfile(
            capabilities: [.text],
            source: .official,
            verifiedAt: "2026-02-30"
        ))
    }

    func testRequirementsInferTextAndToolCallingFromRequest() throws {
        let request = BoneInferenceRequest(
            modelID: "model",
            messages: [.init(role: .user, content: "private-prompt")],
            availableTools: [Self.toolDefinition]
        )

        let requirements = try BoneInferenceRequirements(request: request)

        XCTAssertEqual(requirements.requiredCapabilities, [.text, .toolCalling])
    }

    func testValidatorRejectsMissingToolCallingBeforeExecution() throws {
        let request = BoneInferenceRequest(
            modelID: "model",
            messages: [.init(role: .user, content: "private-prompt")],
            availableTools: [Self.toolDefinition]
        )

        XCTAssertThrowsError(
            try BoneInferenceCapabilityValidator.validate(
                request: request,
                capabilities: [.text],
                invocation: .nonStreaming
            )
        ) { error in
            XCTAssertEqual(error as? BoneInferenceError, .unsupportedCapability(.toolCalling))
            XCTAssertFalse(String(describing: error).contains("private-prompt"))
        }
    }

    func testValidatorRejectsStreamingWithoutStreamingCapability() throws {
        let request = BoneInferenceRequest(
            modelID: "model",
            messages: [.init(role: .user, content: "hello")]
        )

        XCTAssertThrowsError(
            try BoneInferenceCapabilityValidator.validate(
                request: request,
                capabilities: [.text],
                invocation: .streaming
            )
        ) { error in
            XCTAssertEqual(error as? BoneInferenceError, .unsupportedCapability(.streaming))
        }
    }

    func testProviderBoundaryRejectsMissingToolCapabilityBeforeTransport() async throws {
        let transport = CapabilityCapturingTransport()
        let engine = CapabilityGuardedEngine(capabilities: [.text], transport: transport)
        let request = BoneInferenceRequest(
            modelID: "model",
            messages: [.init(role: .user, content: "private-prompt")],
            availableTools: [Self.toolDefinition]
        )

        do {
            _ = try await engine.infer(request: request)
            XCTFail("Provider 边界缺少 Tool Calling 能力时必须失败")
        } catch let error as BoneInferenceError {
            XCTAssertEqual(error, .unsupportedCapability(.toolCalling))
        }
        let sends = await transport.sendCount()
        XCTAssertEqual(sends, 0)
    }

    func testProviderBoundaryRejectsStreamingBeforeTransport() async throws {
        let transport = CapabilityCapturingTransport()
        let engine = CapabilityGuardedEngine(capabilities: [.text], transport: transport)
        let request = BoneInferenceRequest(
            modelID: "model",
            messages: [.init(role: .user, content: "private-prompt")]
        )

        do {
            _ = try await engine.streamInference(request: request, options: .init())
            XCTFail("缺少 Streaming 能力时必须失败")
        } catch let error as BoneInferenceError {
            XCTAssertEqual(error, .unsupportedCapability(.streaming))
        }
        let sends = await transport.sendCount()
        XCTAssertEqual(sends, 0)
    }

    func testRequireNativeStructuredOutputRejectsMissingCapability() throws {
        let request = BoneInferenceRequest(
            modelID: "model",
            messages: [.init(role: .user, content: "private-prompt")],
            responseFormat: .jsonObject(fallback: .requireNative)
        )

        XCTAssertThrowsError(try BoneInferenceCapabilityValidator.validate(
            request: request,
            capabilities: [.text, .toolCalling],
            invocation: .nonStreaming
        )) { error in
            XCTAssertEqual(error as? BoneInferenceError, .unsupportedStructuredOutput)
        }
    }

    func testStructuredOutputAllowsExplicitToolFallback() throws {
        let request = BoneInferenceRequest(
            modelID: "model",
            messages: [.init(role: .user, content: "private-prompt")],
            responseFormat: .jsonObject(fallback: .nativeOrToolCall)
        )

        XCTAssertNoThrow(try BoneInferenceCapabilityValidator.validate(
            request: request,
            capabilities: [.text, .toolCalling],
            invocation: .nonStreaming
        ))
    }

    func testOpenAICompatibleInstanceDoesNotResolveNativeStructuredOutput() throws {
        let official = BoneOpenAIInferenceEngine(
            configuration: providerConfiguration(kind: .openAI),
            transport: CapabilityCapturingTransport()
        )
        let compatible = BoneOpenAIInferenceEngine(
            configuration: providerConfiguration(kind: .custom),
            transport: CapabilityCapturingTransport()
        )
        let request = BoneInferenceRequest(
            modelID: "same-model-name",
            messages: [.init(role: .user, content: "private-prompt")],
            responseFormat: .jsonObject(fallback: .requireNative)
        )

        let officialSnapshot = try official.resolvedCapabilities(
            for: request,
            invocation: .nonStreaming
        )
        let compatibleSnapshot = try compatible.resolvedCapabilities(
            for: request,
            invocation: .nonStreaming
        )

        XCTAssertTrue(officialSnapshot.capabilities.contains(.structuredOutput))
        XCTAssertFalse(compatibleSnapshot.capabilities.contains(.structuredOutput))
        XCTAssertEqual(officialSnapshot.modelID, request.modelID)
        XCTAssertEqual(compatibleSnapshot.invocation, .nonStreaming)
    }

    func testProviderModelProfileRemovesUnverifiedToolCalling() throws {
        let profile = try BoneModelCapabilityProfile(
            capabilities: [.text],
            source: .hostVerified,
            verifiedAt: "2026-09-02"
        )
        let engine = BoneOpenAIInferenceEngine(
            configuration: providerConfiguration(kind: .openAI),
            transport: CapabilityCapturingTransport(),
            modelCapabilityProfiles: ["model": profile]
        )
        let request = BoneInferenceRequest(
            modelID: "model",
            messages: [.init(role: .user, content: "private-prompt")],
            availableTools: [Self.toolDefinition]
        )
        let resolved = try engine.resolvedCapabilities(for: request, invocation: .nonStreaming)
        XCTAssertEqual(resolved.capabilities, [.text])
        XCTAssertThrowsError(try BoneInferenceCapabilityValidator.validate(
            request: request,
            capabilities: resolved.capabilities,
            invocation: resolved.invocation
        )) { error in
            XCTAssertEqual(error as? BoneInferenceError, .unsupportedCapability(.toolCalling))
        }
    }

    func testCompatibleRequireNativeFailsBeforeTransportUsingResolvedCapabilities() async throws {
        let transport = CapabilityCapturingTransport()
        let engine = BoneOpenAIInferenceEngine(
            configuration: providerConfiguration(kind: .custom),
            transport: transport
        )
        let request = BoneInferenceRequest(
            modelID: "model",
            messages: [.init(role: .user, content: "private-prompt")],
            responseFormat: .jsonObject(fallback: .requireNative)
        )

        await XCTAssertThrowsErrorAsync(try await engine.infer(request: request)) { error in
            XCTAssertEqual(error as? BoneInferenceError, .unsupportedStructuredOutput)
        }
        let sends = await transport.sendCount()
        XCTAssertEqual(sends, 0)
    }

    func testAgentRejectsMissingTextCapabilityBeforeRunEventOrProviderCall() async throws {
        let engine = RecordingEngine(capabilities: [])
        let recorder = EventRecorder()
        let agent = BoneAgent(
            inferenceEngine: engine,
            toolRegistry: try BoneAgentToolRegistry(tools: []),
            toolContext: BoneAgentEmptyContext(),
            configuration: try BoneAgentConfiguration(maximumSteps: 2),
            eventSink: BoneAgentEventSink { event in await recorder.record(event) }
        )

        do {
            _ = try await agent.run(
                modelID: "model",
                messages: [.init(role: .user, content: "private-prompt")]
            )
            XCTFail("缺少文本能力时必须在 Run 开始前失败")
        } catch let error as BoneAgentError {
            XCTAssertEqual(error, .unsupportedCapability(.text))
        }

        let requestCount = await engine.requestCount()
        let eventCount = await recorder.count()
        XCTAssertEqual(requestCount, 0)
        XCTAssertEqual(eventCount, 0)
    }

    func testAgentUsesResolvedCapabilitiesBeforeRunEventOrProviderCall() async throws {
        let engine = ResolvedRecordingEngine(
            capabilities: [.text, .toolCalling],
            resolved: [.text]
        )
        let recorder = EventRecorder()
        let registry = try BoneAgentToolRegistry(tools: [BoneAnyAgentTool(EchoTool())])
        let agent = BoneAgent(
            inferenceEngine: engine,
            toolRegistry: registry,
            toolContext: BoneAgentEmptyContext(),
            configuration: try BoneAgentConfiguration(maximumSteps: 2),
            eventSink: BoneAgentEventSink { event in await recorder.record(event) }
        )

        await XCTAssertThrowsErrorAsync(try await agent.run(
            modelID: "model",
            messages: [.init(role: .user, content: "private-prompt")]
        )) { error in
            XCTAssertEqual(error as? BoneAgentError, .unsupportedCapability(.toolCalling))
        }
        let requestCount = await engine.requestCount()
        let eventCount = await recorder.count()
        XCTAssertEqual(requestCount, 0)
        XCTAssertEqual(eventCount, 0)
    }

    func testAgentRejectsMissingToolCapabilityBeforeRunEventOrProviderCall() async throws {
        let engine = RecordingEngine(capabilities: [.text])
        let recorder = EventRecorder()
        let registry = try BoneAgentToolRegistry(tools: [BoneAnyAgentTool(EchoTool())])
        let agent = BoneAgent(
            inferenceEngine: engine,
            toolRegistry: registry,
            toolContext: BoneAgentEmptyContext(),
            configuration: try BoneAgentConfiguration(maximumSteps: 2),
            eventSink: BoneAgentEventSink { event in await recorder.record(event) }
        )

        do {
            _ = try await agent.run(
                modelID: "model",
                messages: [.init(role: .user, content: "private-prompt")]
            )
            XCTFail("缺少 Tool Calling 能力时必须在 Run 开始前失败")
        } catch let error as BoneAgentError {
            XCTAssertEqual(error, .unsupportedCapability(.toolCalling))
        }

        let requestCount = await engine.requestCount()
        let eventCount = await recorder.count()
        XCTAssertEqual(requestCount, 0)
        XCTAssertEqual(eventCount, 0)
    }

    private func providerConfiguration(
        kind: BoneInferenceProviderKind
    ) -> BoneInferenceProviderConfiguration {
        .init(
            kind: kind,
            apiKey: "test-key",
            baseURL: URL(string: "https://synthetic.invalid")!,
            endpointSecurityPolicy: kind == .custom ? .custom : .builtIn
        )
    }

    private func XCTAssertThrowsErrorAsync<T>(
        _ expression: @autoclosure () async throws -> T,
        _ handler: (Error) -> Void
    ) async {
        do {
            _ = try await expression()
            XCTFail("异步操作应抛出错误")
        } catch {
            handler(error)
        }
    }

    private static let toolDefinition = BoneAgentToolDefinition(
        id: "test.echo",
        version: "1",
        title: "Echo",
        summary: "Echo",
        wireName: "echo",
        schemaVersion: 1,
        inputSchema: .object(
            properties: ["value": .string(enumValues: [], minimumLength: nil, maximumLength: nil)],
            required: ["value"],
            additionalProperties: false
        )
    )
}

private actor CapabilityCapturingTransport: BoneInferenceHTTPTransport {
    private var sends = 0

    func send(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse {
        sends += 1
        return .init(statusCode: 200, data: Data(), headers: [:])
    }

    func sendEventStream(
        _ request: URLRequest,
        options: BoneInferenceEventStreamOptions
    ) async throws -> BoneInferenceEventStreamResponse {
        sends += 1
        return .init(statusCode: 200, events: [], headers: [:])
    }

    func sendRetryableForModels(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse {
        try await send(request)
    }

    func sendCount() -> Int { sends }
}

private struct CapabilityGuardedEngine: BoneInferenceEngine, BoneInferenceStreaming {
    let nonImageCapabilities: Set<BoneInferenceCapability>
    let imageGenerator: (any BoneInferenceImageGenerating)? = nil
    let transport: CapabilityCapturingTransport

    init(capabilities: Set<BoneInferenceCapability>, transport: CapabilityCapturingTransport) {
        nonImageCapabilities = capabilities
        self.transport = transport
    }

    func infer(request: BoneInferenceRequest) async throws -> BoneInferenceResponse {
        try BoneInferenceCapabilityValidator.validate(
            request: request,
            capabilities: capabilities,
            invocation: .nonStreaming
        )
        _ = try await transport.send(URLRequest(url: URL(string: "https://synthetic.invalid")!))
        return .finish(.init(text: "unexpected"))
    }

    func streamInference(
        request: BoneInferenceRequest,
        options: BoneInferenceEventStreamOptions
    ) async throws -> BoneInferenceResponse {
        try BoneInferenceCapabilityValidator.validate(
            request: request,
            capabilities: capabilities,
            invocation: .streaming
        )
        _ = try await transport.sendEventStream(
            URLRequest(url: URL(string: "https://synthetic.invalid")!),
            options: options
        )
        return .finish(.init(text: "unexpected"))
    }
}

private actor RecordingEngine: BoneInferenceEngine {
    nonisolated let nonImageCapabilities: Set<BoneInferenceCapability>
    nonisolated let imageGenerator: (any BoneInferenceImageGenerating)? = nil
    private var requests = 0

    init(capabilities: Set<BoneInferenceCapability>) {
        nonImageCapabilities = capabilities
    }

    func infer(request: BoneInferenceRequest) async throws -> BoneInferenceResponse {
        requests += 1
        return .finish(.init(text: "unexpected"))
    }

    func requestCount() -> Int { requests }
}

private actor ResolvedRecordingEngine: BoneInferenceEngine {
    nonisolated let nonImageCapabilities: Set<BoneInferenceCapability>
    nonisolated let imageGenerator: (any BoneInferenceImageGenerating)? = nil
    nonisolated private let resolved: Set<BoneInferenceCapability>
    private var requests = 0

    init(capabilities: Set<BoneInferenceCapability>, resolved: Set<BoneInferenceCapability>) {
        nonImageCapabilities = capabilities
        self.resolved = resolved
    }

    nonisolated func resolvedCapabilities(
        for request: BoneInferenceRequest,
        invocation: BoneInferenceInvocation
    ) throws -> BoneResolvedInferenceCapabilities {
        .init(modelID: request.modelID, invocation: invocation, capabilities: resolved)
    }

    func infer(request: BoneInferenceRequest) async throws -> BoneInferenceResponse {
        requests += 1
        return .finish(.init(text: "unexpected"))
    }

    func requestCount() -> Int { requests }
}

private actor EventRecorder {
    private var events: [BoneAgentEvent] = []
    func record(_ event: BoneAgentEvent) { events.append(event) }
    func count() -> Int { events.count }
}

private struct EchoTool: BoneAgentTool {
    struct Input: Codable, Sendable { let value: String }
    struct Output: Codable, Sendable { let value: String }
    typealias Context = BoneAgentEmptyContext

    static let definition = BoneAgentToolDefinition(
        id: "test.echo",
        version: "1",
        title: "Echo",
        summary: "Echo",
        wireName: "echo",
        schemaVersion: 1,
        inputSchema: .object(
            properties: ["value": .string(enumValues: [], minimumLength: nil, maximumLength: nil)],
            required: ["value"],
            additionalProperties: false
        )
    )

    func execute(input: Input, context: Context) async throws -> Output {
        Output(value: input.value)
    }
}
