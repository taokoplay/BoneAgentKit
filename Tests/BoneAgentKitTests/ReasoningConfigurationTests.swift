import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import BoneAgentKit

final class ReasoningConfigurationTests: XCTestCase {
    private func request(_ options: BoneInferenceReasoningOptions?, temperature: Double? = nil, maxTokens: Int? = 4096) -> BoneInferenceRequest {
        .init(modelID: "m", messages: [.init(role: .user, content: "hello")],
              generationOptions: .init(temperature: temperature, maximumOutputTokens: maxTokens, reasoning: options))
    }
    private func configuration(_ kind: BoneInferenceProviderKind = .openAI) -> BoneInferenceProviderConfiguration {
        .init(kind: kind, apiKey: "fixture", baseURL: URL(string: "https://example.com")!,
              authenticationMode: kind == .google ? .googleAPIKey : .bearer)
    }
    private func metadata(tool: Bool? = nil, temperature: Bool? = nil) -> BoneModelMetadata {
        .init(provenance: .init(source: .modelsDev, providerID: "p", retrievedAt: "2026-10-09", sourceURL: URL(string: "https://models.dev/api.json")!),
              declaration: .init(id: "m", toolCalling: tool, temperature: temperature))
    }

    func testLegacyOptionsDecodeAndContextReplacementRetainsReasoning() throws {
        let old = try JSONDecoder().decode(BoneInferenceGenerationOptions.self, from: Data(#"{"temperature":0.5,"maximumOutputTokens":100}"#.utf8))
        XCTAssertNil(old.reasoning)
        let req = request(.init(effort: "high"))
        let replacement = BoneContextSession.replacing(req, messages: req.messages, output: 3000)
        XCTAssertEqual(replacement.generationOptions.reasoning, req.generationOptions.reasoning)
        XCTAssertEqual(replacement.generationOptions.maximumOutputTokens, 3000)
        XCTAssertEqual(try JSONDecoder().decode(BoneInferenceGenerationOptions.self, from: JSONEncoder().encode(req.generationOptions)), req.generationOptions)
    }

    func testFixedProtocolMappings() throws {
        typealias S = BoneInferenceReasoningRequestSupport
        var fields = try S.fields(request: request(.init(effort: "high")), profile: .init(wireFormat: .openAIChat, effortValues: ["high"]), wire: .openAI)
        XCTAssertEqual(fields["reasoning_effort"] as? String, "high")
        fields = try S.fields(request: request(.init(mode: .enabled, effort: "max")), profile: .init(wireFormat: .thinkingType, modes: [.enabled, .disabled], effortValues: ["high", "max"]), wire: .openAI)
        XCTAssertEqual((fields["thinking"] as? [String: String])?["type"], "enabled")
        fields = try S.fields(request: request(.init(mode: .enabled, budgetTokens: 1024)), profile: .init(wireFormat: .anthropicBudget, modes: [.enabled, .disabled], budgetRange: 1024...32000), wire: .anthropic)
        XCTAssertEqual((fields["thinking"] as? [String: Any])?["budget_tokens"] as? Int, 1024)
        fields = try S.fields(request: request(.init(mode: .adaptive, effort: "high")), profile: .init(wireFormat: .anthropicAdaptive, modes: [.adaptive, .disabled], effortValues: ["high"]), wire: .anthropic)
        XCTAssertEqual((fields["thinking"] as? [String: String])?["type"], "adaptive")
        fields = try S.fields(request: request(.init(mode: .disabled)), profile: .init(wireFormat: .geminiBudget, modes: [.enabled, .disabled], budgetRange: -1...24576), wire: .gemini)
        XCTAssertEqual((fields["thinkingConfig"] as? [String: Int])?["thinkingBudget"], 0)
        fields = try S.fields(request: request(.init(effort: "low")), profile: .init(wireFormat: .geminiLevel, effortValues: ["low", "high"]), wire: .gemini)
        XCTAssertEqual((fields["thinkingConfig"] as? [String: String])?["thinkingLevel"], "LOW")
    }

    func testInvalidCombinationsFailRatherThanDowngrade() throws {
        typealias S = BoneInferenceReasoningRequestSupport
        XCTAssertThrowsError(try request(.init(mode: .disabled, effort: "high")).generationOptions.validated())
        XCTAssertThrowsError(try S.fields(request: request(.init(effort: "high")), profile: nil, wire: .openAI))
        let budget = BoneInferenceReasoningProfile(wireFormat: .anthropicBudget, modes: [.enabled], budgetRange: 1024...32000)
        XCTAssertThrowsError(try S.fields(request: request(.init(mode: .enabled, budgetTokens: 4096)), profile: budget, wire: .anthropic))
        XCTAssertThrowsError(try S.fields(request: request(.init(mode: .enabled, budgetTokens: 1024)), profile: budget, wire: .anthropic, forcedTool: true))
        XCTAssertThrowsError(try S.fields(request: request(.init(mode: .enabled, budgetTokens: 1024)), profile: budget, wire: .openAI))
        XCTAssertThrowsError(try S.fields(request: request(.init(mode: .enabled, budgetTokens: 1024), temperature: 0.5), profile: budget, wire: .anthropic))
        XCTAssertThrowsError(try S.fields(request: request(.init(effort: "max")), profile: .init(wireFormat: .openAIChat, effortValues: ["low", "high"]), wire: .openAI))
        XCTAssertThrowsError(try S.fields(request: request(.init(effort: "high")), profile: .init(wireFormat: .geminiLevel, effortValues: ["high"]), wire: .openAI))
    }

    func testMetadataOnlyRestrictsAndNeverGrantsVerifiedConstraints() throws {
        let transport = ReasoningCaptureTransport()
        let engine = BoneOpenAIInferenceEngine(configuration: configuration(), transport: transport,
                                              modelMetadata: ["m": metadata(tool: false)])
        let resolved = try engine.resolvedCapabilities(for: request(nil), invocation: .nonStreaming)
        XCTAssertFalse(resolved.capabilities.contains(.toolCalling))
        XCTAssertFalse(resolved.capabilities.contains(.constrainedOutput))
        let temperatureEngine = BoneOpenAIInferenceEngine(configuration: configuration(), transport: transport,
                                                         modelMetadata: ["m": metadata(temperature: false)])
        XCTAssertThrowsError(try temperatureEngine.resolvedCapabilities(for: request(nil, temperature: 0.2), invocation: .streaming))
    }

    func testOpenAIWireUsesCompletionLimitAndPreflightBlocksUnknownModel() async throws {
        let transport = ReasoningCaptureTransport()
        let engine = BoneOpenAIInferenceEngine(configuration: configuration(), transport: transport,
             modelReasoningProfiles: ["m": .init(wireFormat: .openAIChat, effortValues: ["high"])])
        _ = try await engine.infer(request: request(.init(effort: "high")))
        let data = await transport.body
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(data)) as? [String: Any])
        XCTAssertEqual(body["reasoning_effort"] as? String, "high")
        XCTAssertEqual(body["max_completion_tokens"] as? Int, 4096)
        XCTAssertNil(body["max_tokens"])
        let unconfigured = BoneOpenAIInferenceEngine(configuration: configuration(), transport: transport)
        do { _ = try await unconfigured.infer(request: request(.init(effort: "high"))); XCTFail("must reject") }
        catch { XCTAssertEqual(error as? BoneInferenceReasoningConfigurationError, .missingProfile) }
        let sends = await transport.sends
        XCTAssertEqual(sends, 1)
    }
}

private actor ReasoningCaptureTransport: BoneInferenceHTTPTransport {
    var body: Data?
    var sends = 0
    func send(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse {
        sends += 1; body = request.httpBody
        return .init(statusCode: 200, data: Data(#"{"choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}"#.utf8))
    }
    func sendRetryableForModels(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse { try await send(request) }
    func sendEventStream(_ request: URLRequest, options: BoneInferenceEventStreamOptions) async throws -> BoneInferenceEventStreamResponse { throw BoneInferenceTransportError.invalidConfiguration }
}
