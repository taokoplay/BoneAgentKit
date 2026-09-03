import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import BoneAgentKit

final class OpenAIOutputConstraintTests: XCTestCase {
    private let modelID = "gpt-4.1-mini"
    private let constraint = BoneInferenceOutputConstraint.enumChoice(["approve", "reject"])

    func testRequiresMatchingVerifiedIdentityBeforeTransport() async throws {
        let transport = OpenAIConstraintTransport(response: Self.response(text: #"{"value":"approve"}"#))
        let configuration = Self.configuration(kind: .openAI)
        let unverified = BoneOpenAIInferenceEngine(configuration: configuration, transport: transport)

        await assertUnsupported(unverified, transport: transport)

        let wrongProfile = try profile(configuration: configuration, invocation: .streaming)
        let wrong = BoneOpenAIInferenceEngine(
            configuration: configuration,
            transport: transport,
            modelCapabilityProfiles: [modelID: wrongProfile]
        )
        await assertUnsupported(wrong, transport: transport)
    }

    func testOfficialVerifiedModelMapsAndValidatesConstraint() async throws {
        let transport = OpenAIConstraintTransport(response: Self.response(text: #"{"value":"approve"}"#))
        let configuration = Self.configuration(kind: .openAI)
        let engine = BoneOpenAIInferenceEngine(
            configuration: configuration,
            transport: transport,
            modelCapabilityProfiles: [modelID: try profile(configuration: configuration)]
        )

        let response = try await engine.infer(request: request())
        XCTAssertEqual(response, .finish(.init(text: "approve")))
        let capturedBody = await transport.body()
        let body = try XCTUnwrap(capturedBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let format = try XCTUnwrap(json["response_format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        XCTAssertNil(json["tools"])
    }

    func testConstrainedEventStreamDoesNotPublishTentativeInvalidText() async throws {
        let events = [
            BoneInferenceEventStreamEvent(
                event: nil,
                data: #"{"choices":[{"index":0,"delta":{"content":"{\"value\":\"PRIVATE-CANARY\"}"},"finish_reason":null}]}"#
            ),
            BoneInferenceEventStreamEvent(
                event: nil,
                data: #"{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#
            ),
            BoneInferenceEventStreamEvent(event: nil, data: "[DONE]"),
        ]
        let transport = OpenAIConstraintTransport(response: Data(), events: events)
        let configuration = Self.configuration(kind: .openAI)
        let engine = BoneOpenAIInferenceEngine(
            configuration: configuration,
            transport: transport,
            modelCapabilityProfiles: [
                modelID: try profile(configuration: configuration, invocation: .streaming),
            ]
        )
        var published: [BoneInferenceStreamEvent] = []
        do {
            for try await event in engine.inferenceEvents(
                request: request(),
                options: .init()
            ) {
                published.append(event)
            }
            XCTFail("invalid constrained stream must fail")
        } catch {
            XCTAssertEqual(error as? BoneInferenceTransportError, .invalidResponse)
        }
        XCTAssertTrue(published.isEmpty)
    }

    func testCompatibleProviderNeverInheritsOfficialConstraintCapability() async throws {
        let transport = OpenAIConstraintTransport(response: Self.response(text: #"{"value":"approve"}"#))
        let configuration = Self.configuration(kind: .custom)
        let engine = BoneOpenAIInferenceEngine(
            configuration: configuration,
            transport: transport,
            modelCapabilityProfiles: [modelID: try profile(configuration: configuration, providerKind: .custom)]
        )

        await assertUnsupported(engine, transport: transport)
    }

    func testRejectsInvalidTruncatedAndAmbiguousConstraintResponses() async throws {
        let configuration = Self.configuration(kind: .openAI)
        for data in [
            Self.response(text: #"{"value":"Approve"}"#),
            Self.response(text: #"{"value":"approve"}"#, finishReason: "length"),
            Self.response(text: #"{"value":"approve"}"#, finishReason: "content_filter"),
            Self.response(text: #"{"value":"approve"}"#, index: 1),
            Self.multipleChoiceResponse(),
        ] {
            let transport = OpenAIConstraintTransport(response: data)
            let engine = BoneOpenAIInferenceEngine(
                configuration: configuration,
                transport: transport,
                modelCapabilityProfiles: [modelID: try profile(configuration: configuration)]
            )
            do {
                _ = try await engine.infer(request: request())
                XCTFail("invalid constrained output must fail")
            } catch let error as BoneInferenceTransportError {
                XCTAssertTrue(error == .invalidResponse || error == .outputTruncated)
            }
        }
    }

    private func assertUnsupported(
        _ engine: BoneOpenAIInferenceEngine,
        transport: OpenAIConstraintTransport
    ) async {
        do {
            _ = try await engine.infer(request: request())
            XCTFail("unverified constraints must fail before transport")
        } catch let error as BoneInferenceError {
            XCTAssertEqual(error, .unsupportedCapability(.constrainedOutput))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        let count = await transport.sendCount()
        XCTAssertEqual(count, 0)
    }

    private func request() -> BoneInferenceRequest {
        .init(
            modelID: modelID,
            messages: [.init(role: .user, content: "decide")],
            outputConstraint: constraint
        )
    }

    private func profile(
        configuration: BoneInferenceProviderConfiguration,
        providerKind: BoneInferenceProviderKind = .openAI,
        invocation: BoneInferenceInvocation = .nonStreaming
    ) throws -> BoneModelCapabilityProfile {
        let adapter = BoneOpenAIOutputConstraintAdapter()
        let identity = try BoneProviderVerificationIdentitySupport.identity(
            configuration: configuration,
            protocolVariant: .openAI,
            apiVersion: "v1",
            modelID: modelID,
            requestMapperID: "bone.openai.chat-completions",
            requestMapperVersion: "1",
            responseDecoderID: "bone.openai.chat-completions",
            responseDecoderVersion: "1",
            constraintDialectID: adapter.identity.id,
            constraintDialectVersion: adapter.identity.version,
            invocation: invocation
        )
        XCTAssertEqual(identity.providerKind, providerKind)
        return try .init(
            capabilities: [.text, .constrainedOutput, .streaming],
            source: .providerSmoke,
            verifiedAt: "2026-09-03",
            providerVerificationIdentities: [identity]
        )
    }

    private static func configuration(kind: BoneInferenceProviderKind) -> BoneInferenceProviderConfiguration {
        .init(
            kind: kind,
            apiKey: "test-key",
            baseURL: URL(string: "https://synthetic.invalid")!,
            endpointSecurityPolicy: .custom
        )
    }

    private static func response(
        text: String,
        finishReason: String = "stop",
        index: Int = 0
    ) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "choices": [[
                "index": index,
                "message": ["role": "assistant", "content": text],
                "finish_reason": finishReason,
            ]],
        ])
    }

    private static func multipleChoiceResponse() -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "choices": [
                ["index": 0, "message": ["role": "assistant", "content": #"{"value":"approve"}"#], "finish_reason": "stop"],
                ["index": 1, "message": ["role": "assistant", "content": #"{"value":"reject"}"#], "finish_reason": "stop"],
            ],
        ])
    }
}

private actor OpenAIConstraintTransport: BoneInferenceHTTPTransport {
    private let response: Data
    private let events: [BoneInferenceEventStreamEvent]
    private var requests: [URLRequest] = []

    init(response: Data, events: [BoneInferenceEventStreamEvent] = []) {
        self.response = response
        self.events = events
    }

    func send(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse {
        requests.append(request)
        return .init(statusCode: 200, data: response, headers: [:])
    }

    func sendEventStream(
        _ request: URLRequest,
        options: BoneInferenceEventStreamOptions
    ) async throws -> BoneInferenceEventStreamResponse {
        requests.append(request)
        return .init(statusCode: 200, events: events, headers: [:])
    }

    func sendRetryableForModels(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse {
        try await send(request)
    }

    func sendCount() -> Int { requests.count }
    func body() -> Data? { requests.last?.httpBody }
}
