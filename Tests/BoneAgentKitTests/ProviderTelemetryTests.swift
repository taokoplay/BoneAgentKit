import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import BoneAgentKit

final class ProviderTelemetryTests: XCTestCase {
    func testAnthropicUsageMergesCumulativeCountersAndDeduplicatesSnapshots() throws {
        var mapper = BoneAnthropicNormalizedEventMapper(disclosure: .hidden)
        let events = [
            telemetryEvent(["type": "message_start", "message": ["usage": [
                "input_tokens": 100, "output_tokens": 0,
                "cache_read_input_tokens": 12, "cache_creation_input_tokens": 7,
            ]]]),
            telemetryEvent(["type": "message_delta", "usage": ["output_tokens": 3]]),
            telemetryEvent(["type": "message_delta", "usage": ["output_tokens": 5]]),
            telemetryEvent(["type": "message_delta", "usage": ["output_tokens": 5]]),
            telemetryEvent(["type": "message_delta", "usage": [:]]),
            telemetryEvent(["type": "message_delta"]),
        ]
        let values = try events.flatMap { try mapper.consume($0) }.compactMap(telemetryUsage)
        XCTAssertEqual(values.map(\.inputTokens), [100, 100, 100])
        XCTAssertEqual(values.map(\.outputTokens), [0, 3, 5], "Output counts are cumulative, never summed")
        XCTAssertEqual(values.map(\.cachedInputTokens), [12, 12, 12])
        XCTAssertEqual(values.map(\.cacheCreationInputTokens), [7, 7, 7])
        XCTAssertEqual(values.last, try BoneProviderUsage.read(events, wire: .anthropic))
        for _ in 0..<1_000 {
            XCTAssertTrue(try mapper.consume(events[3]).isEmpty)
        }
    }

    func testAnthropicPartialUsageStaysUnknownUntilBothRequiredCountersArrive() throws {
        for first in ["input_tokens", "output_tokens"] {
            var mapper = BoneAnthropicNormalizedEventMapper(disclosure: .hidden)
            let initial = telemetryEvent(["type": "message_start", "message": ["usage": [first: 8]]])
            XCTAssertTrue(try mapper.consume(initial).isEmpty)
            XCTAssertNil(try BoneProviderUsage.read([initial], wire: .anthropic))
            XCTAssertTrue(try mapper.consume(telemetryEvent(["type": "message_delta", "usage": NSNull()])).isEmpty)
            XCTAssertTrue(try mapper.consume(telemetryEvent(["type": "message_delta", "usage": ["unused": 99]])).isEmpty)
            let other = first == "input_tokens" ? "output_tokens" : "input_tokens"
            let completed = try mapper.consume(telemetryEvent(["type": "message_delta", "usage": [other: 2]]))
            let usage = try XCTUnwrap(completed.compactMap(telemetryUsage).first)
            XCTAssertEqual(usage.inputTokens, first == "input_tokens" ? 8 : 2)
            XCTAssertEqual(usage.outputTokens, first == "output_tokens" ? 8 : 2)
            XCTAssertNil(usage.cachedInputTokens)
            XCTAssertNil(usage.cacheCreationInputTokens)
            let cached = try mapper.consume(telemetryEvent(["type": "message_delta", "usage": [
                "cache_read_input_tokens": 0, "cache_creation_input_tokens": 4,
            ]])).compactMap(telemetryUsage)
            XCTAssertEqual(cached.first?.cachedInputTokens, 0)
            XCTAssertEqual(cached.first?.cacheCreationInputTokens, 4)
        }
    }

    func testOpenAIAndGeminiMappedUsageMatchesFinalWireParsers() throws {
        for provider in [TelemetryProvider.openAI, .gemini] {
            let fixture = provider.fixture()
            var openAI = BoneOpenAINormalizedEventMapper(disclosure: .hidden, definitions: [])
            var gemini = BoneGeminiNormalizedEventMapper(disclosure: .hidden, definitions: [])
            var usages: [BoneInferenceUsage] = []
            for event in fixture.events {
                let mapped = try provider == .openAI ? openAI.consume(event) : gemini.consume(event)
                usages += mapped.compactMap(telemetryUsage)
            }
            XCTAssertEqual(usages, [provider.usage(output: 0), provider.usage(output: 5)])
            XCTAssertEqual(usages.last, try BoneProviderUsage.read(fixture.events, wire: provider.wire))
            XCTAssertEqual(usages.last?.cachedInputTokens, 12)
            XCTAssertEqual(usages.last?.reasoningTokens, 2)
            for malformed in [NSNull(), ["unexpected": 1], "invalid"] as [Any] {
                let json: [String: Any] = provider == .openAI
                    ? ["choices": [], "usage": malformed]
                    : ["candidates": [[:]], "usageMetadata": malformed]
                if malformed is NSNull {
                    let mapped = try provider == .openAI
                        ? openAI.consume(telemetryEvent(json)) : gemini.consume(telemetryEvent(json))
                    XCTAssertTrue(mapped.isEmpty)
                    XCTAssertNil(try BoneProviderUsage.read(json, wire: provider.wire))
                } else {
                    XCTAssertThrowsError(try BoneProviderUsage.read(json, wire: provider.wire))
                    XCTAssertThrowsError(try provider == .openAI
                        ? openAI.consume(telemetryEvent(json)) : gemini.consume(telemetryEvent(json)))
                }
            }
        }
    }

    func testAllFiveInvocationPathsReportTransportBoundaries() async throws {
        for provider in TelemetryProvider.allCases {
            for invocation in TelemetryInvocation.allCases {
                let log = TelemetryLog()
                let engine = try provider.engine(TelemetryTransport(fixture: provider.fixture(), log: log))
                let values = try await observeTelemetry(log) {
                    try await invocation.invoke(engine, request: telemetryRequest())
                }
                guard case .completed(let result) = values.last else { return XCTFail("Missing completion") }
                XCTAssertEqual(result.response.usage, provider.usage(output: 5))
                let trace = await log.trace
                XCTAssertEqual(Array(trace.prefix(3)), [
                    .activity(.waitingForModel), .telemetry(.requestStarted(liveTiming: invocation == .events)), .transport,
                ], "\(provider), \(invocation)")
                let eof = try XCTUnwrap(trace.firstIndex(of: .response))
                XCTAssertEqual(trace[eof + 1], .telemetry(.responseFinished))
                let telemetry = await log.telemetry
                XCTAssertEqual(telemetry.filter { $0 == .responseFinished }.count, 1)
                if invocation == .events {
                    XCTAssertEqual(telemetry.filter { $0 == .firstOutputToken }.count, 1)
                    XCTAssertEqual(telemetry.compactMap(reportedUsage), [provider.usage(output: 0), provider.usage(output: 5)])
                } else {
                    XCTAssertEqual(telemetry, [.requestStarted(liveTiming: false), .responseFinished])
                    XCTAssertEqual(trace[eof + 2], .activity(.validatingResponse))
                }
            }
        }
    }

    func testCancellationAfterEitherObserverNeverSendsAcrossAllPaths() async throws {
        for provider in TelemetryProvider.allCases {
            for invocation in TelemetryInvocation.allCases {
                for cancelInTelemetry in [false, true] {
                    let log = TelemetryLog()
                    let engine = try provider.engine(TelemetryTransport(fixture: provider.fixture(), log: log))
                    let task = Task {
                        try await BoneInferenceActivityReporting.withSink(.init { activity in
                            await log.record(.activity(activity))
                            if !cancelInTelemetry, activity == .waitingForModel {
                                withUnsafeCurrentTask { $0?.cancel() }
                            }
                        }) {
                            try await BoneInferenceTelemetryReporting.withSink(.init { event in
                                await log.record(.telemetry(event))
                                if cancelInTelemetry, case .requestStarted = event {
                                    withUnsafeCurrentTask { $0?.cancel() }
                                }
                            }) {
                                try await invocation.invoke(engine, request: telemetryRequest())
                            }
                        }
                    }
                    do { _ = try await task.value; XCTFail("Expected cancellation") }
                    catch { XCTAssertTrue(error is CancellationError, "\(error)") }
                    let trace = await log.trace
                    XCTAssertEqual(trace, [.activity(.waitingForModel)] + (cancelInTelemetry
                        ? [.telemetry(.requestStarted(liveTiming: invocation == .events))] : []))
                }
            }
        }
    }

    func testUsageAndHiddenReasoningTimingSurviveOutputConstraintSuppression() async throws {
        for provider in TelemetryProvider.allCases {
            let log = TelemetryLog()
            let fixture = provider.fixture(fragment: .reasoning, text: #"{"value":"ok"}"#)
            let engine = try provider.engine(TelemetryTransport(fixture: fixture, log: log), constrained: true)
            let values = try await observeTelemetry(log) {
                try await TelemetryInvocation.events.invoke(engine, request: telemetryRequest(constrained: true))
            }
            XCTAssertEqual(values.count, 1, "Constrained content and normalized usage stay suppressed")
            guard case .completed(let result) = values.last else { return XCTFail("Missing completion") }
            XCTAssertEqual(result.response.terminalAssistantTurn?.text, "ok")
            XCTAssertNil(result.reasoning)
            let telemetry = await log.telemetry
            XCTAssertEqual(telemetry.compactMap(reportedUsage), [provider.usage(output: 0), provider.usage(output: 5)])
            let trace = await log.trace
            let token = try XCTUnwrap(trace.firstIndex(of: .telemetry(.firstOutputToken)))
            XCTAssertEqual(trace[token - 1], .event(fixture.firstOutputIndex))
        }
    }

    func testResponseFinishedPrecedesSemanticFailureAndPreservesProvisionalUsage() async throws {
        for provider in TelemetryProvider.allCases {
            for invocation in TelemetryInvocation.allCases {
                let log = TelemetryLog()
                let engine = try provider.engine(TelemetryTransport(fixture: provider.fixture(text: "invalid JSON"), log: log), constrained: true)
                do {
                    _ = try await observeTelemetry(log) {
                        try await invocation.invoke(engine, request: telemetryRequest(constrained: true))
                    }
                    XCTFail("Expected output validation failure")
                } catch {
                    let trace = await log.trace
                    let eof = try XCTUnwrap(trace.firstIndex(of: .response))
                    XCTAssertEqual(trace[eof + 1], .telemetry(.responseFinished))
                    let telemetry = await log.telemetry
                    XCTAssertEqual(telemetry.last, .responseFinished)
                    XCTAssertEqual(telemetry.compactMap(reportedUsage).last,
                                   invocation == .events ? provider.usage(output: 5) : nil)
                }
            }
        }
    }

    func testFirstOutputRequiresMeaningfulTextReasoningOrArgumentsForEveryProvider() async throws {
        for provider in TelemetryProvider.allCases {
            for fragment in TelemetryFragment.allCases {
                for disclosure in [BoneInferenceReasoningDisclosure.hidden, .providerReadable] {
                    let log = TelemetryLog()
                    let fixture = provider.fixture(fragment: fragment)
                    let engine = try provider.engine(TelemetryTransport(fixture: fixture, log: log))
                    let values = try await observeTelemetry(log) {
                        try await TelemetryInvocation.events.invoke(engine, request: telemetryRequest(
                            tools: fragment == .tool, disclosure: disclosure))
                    }
                    let trace = await log.trace
                    let markers = trace.indices.filter { trace[$0] == .telemetry(.firstOutputToken) }
                    XCTAssertEqual(markers.count, 1, "\(provider), \(fragment), \(disclosure)")
                    let marker = try XCTUnwrap(markers.first)
                    XCTAssertEqual(trace[marker - 1], .event(fixture.firstOutputIndex))
                    if disclosure == .hidden {
                        XCTAssertFalse(values.contains { if case .reasoningDelta = $0 { return true }; return false })
                    }
                }
            }
        }
    }

    func testMetadataOnlyStreamsNeverReportFirstOutputEvenAtInvalidEOF() async throws {
        for provider in TelemetryProvider.allCases {
            let log = TelemetryLog()
            let full = provider.fixture(fragment: .reasoning)
            let fixture = TelemetryFixture(response: full.response,
                events: Array(full.events.prefix(full.firstOutputIndex)), firstOutputIndex: 0)
            let engine = try provider.engine(TelemetryTransport(fixture: fixture, log: log))
            do {
                _ = try await observeTelemetry(log) {
                    try await TelemetryInvocation.events.invoke(engine, request: telemetryRequest())
                }
                XCTFail("Incomplete semantic response should fail")
            } catch {
                let telemetry = await log.telemetry
                XCTAssertFalse(telemetry.contains(.firstOutputToken))
                XCTAssertEqual(telemetry.last, .responseFinished)
                XCTAssertEqual(telemetry.compactMap(reportedUsage).last, provider.usage(output: 0))
            }
        }
    }

    func testBufferedFallbackAndInjectedURLSessionLoadersNeverClaimLiveTiming() async throws {
        XCTAssertTrue(BoneInferenceURLSessionTransport().providesLiveEventTiming)
        XCTAssertFalse(BoneInferenceURLSessionTransport(loader: { _ in
            (Data(), .init(statusCode: 200))
        }).providesLiveEventTiming)
        for provider in TelemetryProvider.allCases {
            for injectedLoader in [false, true] {
                let log = TelemetryLog()
                let base = TelemetryTransport(fixture: provider.fixture(), log: log)
                let transport: any BoneInferenceHTTPTransport = injectedLoader
                    ? BoneInferenceURLSessionTransport(streamLoader: { request, options in
                        try await base.sendEventStream(request, options: options)
                    }) : TelemetryBufferedTransport(base: base)
                XCTAssertFalse(transport.providesLiveEventTiming)
                let engine = try provider.engine(transport)
                _ = try await observeTelemetry(log) {
                    try await TelemetryInvocation.events.invoke(engine, request: telemetryRequest())
                }
                let telemetry = await log.telemetry
                XCTAssertEqual(telemetry.first, .requestStarted(liveTiming: false))
                XCTAssertFalse(telemetry.contains(.firstOutputToken))
                XCTAssertEqual(telemetry.last, .responseFinished)
                XCTAssertEqual(telemetry.compactMap(reportedUsage).last, provider.usage(output: 5))
            }
        }
    }
}

private typealias TelemetryEngine = BoneInferenceEngine & BoneInferenceBufferedStreaming &
    BoneInferenceDetailedResultProviding & BoneInferenceDetailedBufferedStreaming & BoneInferenceEventStreaming

private let telemetryTool = BoneAgentToolDefinition(id: "probe", version: "1", title: "Probe", summary: "Probe",
    wireName: "probe", schemaVersion: 1, inputSchema: .object(properties: [:], required: [], additionalProperties: false))

private func telemetryRequest(tools: Bool = false, disclosure: BoneInferenceReasoningDisclosure = .hidden,
                              constrained: Bool = false) -> BoneInferenceRequest {
    .init(modelID: "model", messages: [.init(role: .user, content: "hello")],
          availableTools: tools ? [telemetryTool] : [],
          outputConstraint: constrained ? .enumChoice(["ok", "no"]) : nil, reasoningDisclosure: disclosure)
}

private func telemetryUsage(_ event: BoneInferenceStreamEvent) -> BoneInferenceUsage? {
    if case .usage(let usage) = event { return usage }; return nil
}

private func reportedUsage(_ event: BoneInferenceTelemetryEvent) -> BoneInferenceUsage? {
    if case .usage(let usage) = event { return usage }; return nil
}

private func telemetryEvent(_ json: [String: Any]) -> BoneInferenceEventStreamEvent {
    .init(data: String(decoding: try! JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]), as: UTF8.self))
}

private func observeTelemetry<Value: Sendable>(_ log: TelemetryLog,
    operation: @Sendable () async throws -> Value) async rethrows -> Value {
    try await BoneInferenceActivityReporting.withSink(.init { await log.record(.activity($0)) }) {
        try await BoneInferenceTelemetryReporting.withSink(.init { await log.record(.telemetry($0)) }) {
            try await operation()
        }
    }
}

private enum TelemetryInvocation: CaseIterable, Sendable {
    case infer, detailed, buffered, detailedBuffered, events
    func invoke(_ engine: any TelemetryEngine, request: BoneInferenceRequest) async throws -> [BoneInferenceStreamEvent] {
        switch self {
        case .infer: return try await [.completed(.init(response: engine.infer(request: request), reasoning: nil))]
        case .detailed: return try await [.completed(engine.inferDetailed(request: request))]
        case .buffered: return try await [.completed(.init(response: engine.inferUsingStream(request: request, options: .init()), reasoning: nil))]
        case .detailedBuffered: return try await [.completed(engine.inferDetailedUsingStream(request: request, options: .init()))]
        case .events:
            var values: [BoneInferenceStreamEvent] = []
            for try await event in engine.inferenceEvents(request: request, options: .init()) { values.append(event) }
            return values
        }
    }
}

private enum TelemetryFragment: CaseIterable { case text, reasoning, tool }

private enum TelemetryProvider: CaseIterable, Sendable {
    case openAI, anthropic, gemini
    var wire: BoneProviderUsage.Wire { self == .openAI ? .openAI : self == .anthropic ? .anthropic : .gemini }

    func engine(_ transport: any BoneInferenceHTTPTransport, constrained: Bool = false) throws -> any TelemetryEngine {
        let configuration = BoneInferenceProviderConfiguration(
            kind: self == .openAI ? .openAI : self == .anthropic ? .anthropic : .google,
            apiKey: "synthetic", baseURL: URL(string: "https://fixture.invalid")!,
            authenticationMode: self == .openAI ? .bearer : self == .anthropic ? .anthropicDual : .googleAPIKey)
        var profiles: [String: BoneModelCapabilityProfile] = [:]
        if constrained {
            let identities = try [BoneInferenceInvocationMode.nonStreaming, .streaming].map { invocation in
                switch self {
                case .openAI: return try BoneOpenAIInferenceEngine(configuration: configuration, transport: transport)
                    .constraintVerificationIdentity(modelID: "model", invocation: invocation)
                case .anthropic: return try BoneAnthropicInferenceEngine(configuration: configuration, transport: transport)
                    .constraintVerificationIdentity(modelID: "model", invocation: invocation)
                case .gemini: return try BoneGeminiInferenceEngine(configuration: configuration, transport: transport)
                    .constraintVerificationIdentity(modelID: "model", invocation: invocation)
                }
            }
            profiles["model"] = try .init(capabilities: [.text, .streaming, .constrainedOutput],
                source: .providerSmoke, verifiedAt: "2026-01-01", providerVerificationIdentities: identities)
        }
        switch self {
        case .openAI: return BoneOpenAIInferenceEngine(configuration: configuration, transport: transport, modelCapabilityProfiles: profiles)
        case .anthropic: return BoneAnthropicInferenceEngine(configuration: configuration, transport: transport, modelCapabilityProfiles: profiles)
        case .gemini: return BoneGeminiInferenceEngine(configuration: configuration, transport: transport, modelCapabilityProfiles: profiles)
        }
    }

    func usage(output: Int) -> BoneInferenceUsage {
        .init(inputTokens: 100, outputTokens: output, cachedInputTokens: 12,
              reasoningTokens: self == .anthropic ? nil : 2, cacheCreationInputTokens: self == .anthropic ? 7 : nil)
    }

    func usageJSON(output: Int) -> [String: Any] {
        switch self {
        case .openAI: return ["prompt_tokens": 100, "completion_tokens": output,
                             "prompt_tokens_details": ["cached_tokens": 12], "completion_tokens_details": ["reasoning_tokens": 2]]
        case .anthropic: return ["input_tokens": 100, "output_tokens": output,
                                "cache_read_input_tokens": 12, "cache_creation_input_tokens": 7]
        case .gemini: return ["promptTokenCount": 100, "candidatesTokenCount": output,
                             "cachedContentTokenCount": 12, "thoughtsTokenCount": 2]
        }
    }

    func fixture(fragment: TelemetryFragment = .text, text: String = "ok") -> TelemetryFixture {
        var values: [BoneInferenceEventStreamEvent] = []
        let response: [String: Any]
        let first: Int
        switch self {
        case .openAI:
            func delta(_ value: [String: Any], reason: String? = nil) -> BoneInferenceEventStreamEvent {
                var choice: [String: Any] = ["index": 0, "delta": value]
                if let reason { choice["finish_reason"] = reason }
                return telemetryEvent(["choices": [choice]])
            }
            values = [telemetryEvent(["choices": [], "usage": usageJSON(output: 0)]),
                      delta(["role": "assistant"]), delta(["content": "", "reasoning_content": ""])]
            if fragment == .tool {
                values.append(delta(["tool_calls": [["index": 0, "id": "call", "type": "function",
                    "function": ["name": "probe", "arguments": ""]]]]))
            }
            first = values.count
            switch fragment {
            case .text: values += [delta(["content": text]), delta(["content": " "])]
            case .reasoning: values += [delta(["reasoning_content": "private "]), delta(["reasoning_content": "thought"]), delta(["content": text])]
            case .tool: values += [delta(["tool_calls": [["index": 0, "function": ["arguments": "{"]]]]),
                                   delta(["tool_calls": [["index": 0, "function": ["arguments": "}"]]]])]
            }
            values += [delta([:], reason: fragment == .tool ? "tool_calls" : "stop"),
                       telemetryEvent(["choices": [], "usage": usageJSON(output: 5)]), .init(data: "[DONE]")]
            response = ["choices": [["message": ["role": "assistant", "content": text], "finish_reason": "stop"]], "usage": usageJSON(output: 5)]
        case .anthropic:
            let block: [String: Any] = fragment == .reasoning ? ["type": "thinking", "thinking": ""]
                : fragment == .tool ? ["type": "tool_use", "id": "call", "name": "probe", "input": [:]] : ["type": "text", "text": ""]
            let deltaType = fragment == .reasoning ? "thinking_delta" : fragment == .tool ? "input_json_delta" : "text_delta"
            let key = fragment == .reasoning ? "thinking" : fragment == .tool ? "partial_json" : "text"
            func delta(_ value: String) -> BoneInferenceEventStreamEvent {
                telemetryEvent(["type": "content_block_delta", "index": 0, "delta": ["type": deltaType, key: value]])
            }
            values = [telemetryEvent(["type": "message_start", "message": ["usage": usageJSON(output: 0)]]),
                      telemetryEvent(["type": "ping"]), telemetryEvent(["type": "content_block_start", "index": 0, "content_block": block]), delta("")]
            if fragment == .reasoning {
                values.append(telemetryEvent(["type": "content_block_delta", "index": 0,
                    "delta": ["type": "signature_delta", "signature": "opaque"]]))
            }
            first = values.count
            values += [delta(fragment == .reasoning ? "private " : fragment == .tool ? "{" : text),
                       delta(fragment == .reasoning ? "thought" : fragment == .tool ? "}" : " "),
                       telemetryEvent(["type": "content_block_stop", "index": 0])]
            if fragment == .reasoning {
                values += [telemetryEvent(["type": "content_block_start", "index": 1, "content_block": ["type": "text", "text": ""]]),
                           telemetryEvent(["type": "content_block_delta", "index": 1, "delta": ["type": "text_delta", "text": text]]),
                           telemetryEvent(["type": "content_block_stop", "index": 1])]
            }
            values += [telemetryEvent(["type": "message_delta", "delta": ["stop_reason": fragment == .tool ? "tool_use" : "end_turn"], "usage": ["output_tokens": 5]]),
                       telemetryEvent(["type": "message_stop"])]
            response = ["content": [["type": "text", "text": text]], "stop_reason": "end_turn", "usage": usageJSON(output: 5)]
        case .gemini:
            func parts(_ parts: [[String: Any]]) -> BoneInferenceEventStreamEvent {
                telemetryEvent(["candidates": [["content": ["role": "model", "parts": parts]]]])
            }
            values = [telemetryEvent(["candidates": [[:]], "usageMetadata": usageJSON(output: 0)]), parts([]),
                      parts([["thought": true, "text": "", "thoughtSignature": "opaque"]])]
            first = values.count
            switch fragment {
            case .text: values += [parts([["text": text]]), parts([["text": " "]])]
            case .reasoning: values += [parts([["thought": true, "text": "private "]]), parts([["thought": true, "text": "thought"]]), parts([["text": text]])]
            case .tool: values += [parts([["functionCall": ["id": "call", "name": "probe", "args": [:]]]])]
            }
            values += [telemetryEvent(["candidates": [["finishReason": "STOP"]], "usageMetadata": usageJSON(output: 5)])]
            response = ["candidates": [["content": ["parts": [["text": text]]], "finishReason": "STOP"]], "usageMetadata": usageJSON(output: 5)]
        }
        return .init(response: try! JSONSerialization.data(withJSONObject: response), events: values, firstOutputIndex: first)
    }
}

private struct TelemetryFixture: Sendable {
    let response: Data
    let events: [BoneInferenceEventStreamEvent]
    let firstOutputIndex: Int
}

private enum TelemetryTrace: Equatable, Sendable {
    case activity(BoneInferenceActivity), telemetry(BoneInferenceTelemetryEvent), transport, response, event(Int)
}

private actor TelemetryLog {
    private(set) var trace: [TelemetryTrace] = []
    var telemetry: [BoneInferenceTelemetryEvent] {
        trace.compactMap { if case .telemetry(let event) = $0 { return event }; return nil }
    }
    func record(_ value: TelemetryTrace) { trace.append(value) }
}

private struct TelemetryTransport: BoneInferenceHTTPTransport {
    let fixture: TelemetryFixture
    let log: TelemetryLog
    // This synthetic stream advances one arrival per next(), explicitly opting in.
    var providesLiveEventTiming: Bool { true }
    func send(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse {
        await log.record(.transport)
        await log.record(.response)
        return .init(statusCode: 200, data: fixture.response)
    }
    func sendRetryableForModels(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse { try await send(request) }
    func sendEventStream(_ request: URLRequest, options: BoneInferenceEventStreamOptions) async throws -> BoneInferenceEventStreamResponse {
        await log.record(.transport)
        await log.record(.response)
        return .init(statusCode: 200, events: fixture.events)
    }
    func eventStream(_ request: URLRequest, options: BoneInferenceEventStreamOptions) -> BoneInferenceRawEventStream {
        let cursor = TelemetryCursor(events: fixture.events, log: log)
        return AsyncThrowingStream(unfolding: { await cursor.next() })
    }
}

private struct TelemetryBufferedTransport: BoneInferenceHTTPTransport {
    let base: TelemetryTransport
    func send(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse { try await base.send(request) }
    func sendRetryableForModels(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse { try await send(request) }
    func sendEventStream(_ request: URLRequest, options: BoneInferenceEventStreamOptions) async throws -> BoneInferenceEventStreamResponse {
        try await base.sendEventStream(request, options: options)
    }
}

private actor TelemetryCursor {
    let events: [BoneInferenceEventStreamEvent]
    let log: TelemetryLog
    private var index = 0
    init(events: [BoneInferenceEventStreamEvent], log: TelemetryLog) { self.events = events; self.log = log }
    func next() async -> BoneInferenceEventStreamEvent? {
        if index == 0 { await log.record(.transport) }
        guard index < events.count else { await log.record(.response); return nil }
        await log.record(.event(index))
        defer { index += 1 }
        return events[index]
    }
}
