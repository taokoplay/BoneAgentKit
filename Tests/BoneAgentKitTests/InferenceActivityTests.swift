import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import BoneAgentKit

final class InferenceActivityTests: XCTestCase {
    func testNonStreamingAndBufferedCallsNeverReplayReasoningActivity() async throws {
        for provider in ActivityProvider.allCases {
            for invocation in ActivityInvocation.allCases where invocation != .events {
                for disclosure in [BoneInferenceReasoningDisclosure.hidden, .providerReadable] {
                    let log = ActivityLog()
                    let engine = provider.engine(ActivityTransport(provider: provider, log: log))
                    let result = try await BoneInferenceActivityReporting.withSink(log.sink) {
                        try await invocation.invoke(engine, request: activityRequest(disclosure: disclosure))
                    }
                    XCTAssertEqual(result.response.terminalAssistantTurn?.text, "ok")
                    if disclosure == .providerReadable, invocation == .detailed || invocation == .detailedBuffered {
                        XCTAssertEqual(result.reasoning?.text, "private thought")
                    }
                    let trace = await log.trace
                    XCTAssertEqual(trace, [.activity(.waitingForModel), .transport, .response,
                                           .activity(.validatingResponse)], "\(provider), \(invocation)")
                }
            }
        }
    }

    func testLiveStreamsObserveHiddenReasoningBeforeTextWithoutDisclosingIt() async throws {
        for provider in ActivityProvider.allCases {
            let log = ActivityLog()
            let engine = provider.engine(ActivityTransport(provider: provider, log: log))
            let events = try await collect(engine, request: activityRequest(), log: log)
            let activities = await log.activities
            XCTAssertEqual(activities, [.waitingForModel, .reasoning, .generatingResponse, .validatingResponse])
            XCTAssertTrue(events.filter(isReasoningEvent).isEmpty)
            XCTAssertEqual(events.compactMap(textDelta), ["o", "k"])
            guard case let .completed(result) = events.last else { return XCTFail("Missing completion") }
            XCTAssertNil(result.reasoning)
            XCTAssertEqual(result.response.terminalAssistantTurn?.text, "ok")
            // The fixture supplies one raw event per next() call. These snapshots prove that
            // the provider reports each stage while receiving, before later events arrive.
            let snapshots = await log.beforeEvents
            XCTAssertEqual(snapshots[provider.firstTextEvent], [.waitingForModel, .reasoning])
            XCTAssertEqual(snapshots[provider.secondTextEvent].last, .generatingResponse)
        }
    }

    func testLiveReadableReasoningPreservesExistingContentEvents() async throws {
        for provider in ActivityProvider.allCases {
            let log = ActivityLog()
            let engine = provider.engine(ActivityTransport(provider: provider, log: log))
            let events = try await collect(engine, request: activityRequest(disclosure: .providerReadable), log: log)
            XCTAssertEqual(events.filter(isReasoningEvent), [
                .reasoningStarted(kind: .providerReadable), .reasoningDelta("private "),
                .reasoningDelta("thought"), .reasoningCompleted,
            ])
            XCTAssertEqual(events.compactMap(textDelta), ["o", "k"])
            let activities = await log.activities
            XCTAssertEqual(activities, [.waitingForModel, .reasoning, .generatingResponse, .validatingResponse])
            if provider == .openAI {
                // OpenAI historically completes the readable reasoning event at finish_reason.
                // Its activity must nevertheless move to response generation on the first text.
                XCTAssertEqual(Array(events.prefix(5)), [
                    .reasoningStarted(kind: .providerReadable), .reasoningDelta("private "),
                    .reasoningDelta("thought"), .textDelta("o"), .textDelta("k"),
                ])
            }
        }
    }

    func testLiveToolSignalsReportToolGenerationWithoutInventingText() async throws {
        for provider in ActivityProvider.allCases {
            let log = ActivityLog()
            let engine = provider.engine(ActivityTransport(provider: provider, log: log, tools: true))
            let events = try await collect(engine, request: activityRequest(tools: true), log: log)
            let activities = await log.activities
            XCTAssertEqual(activities, [.waitingForModel, .reasoning, .generatingToolCall, .validatingResponse])
            XCTAssertTrue(events.contains(.toolCallStarted(id: "call", toolID: "probe")))
            XCTAssertTrue(events.contains(.toolCallCompleted(id: "call")))
            XCTAssertTrue(events.compactMap(textDelta).isEmpty)
            XCTAssertTrue(events.filter(isReasoningEvent).isEmpty)
            guard case .completed = events.last else { return XCTFail("Missing tool completion") }
        }
    }

    func testRedactedAnthropicThinkingReportsOnlyActivityWhenHidden() async throws {
        let log = ActivityLog()
        let redacted = [
            #"{"type":"message_start","message":{"usage":{"input_tokens":1,"output_tokens":0}}}"#,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"redacted_thinking","data":"private-redacted"}}"#,
            #"{"type":"content_block_stop","index":0}"#,
        ].map { BoneInferenceEventStreamEvent(data: $0) }
        let events = redacted + Array(ActivityProvider.anthropic.events(tools: false).dropFirst(7))
        let engine = ActivityProvider.anthropic.engine(ActivityTransport(provider: .anthropic, log: log, events: events))
        let values = try await collect(engine, request: activityRequest(), log: log)
        let activities = await log.activities
        XCTAssertEqual(activities, [.waitingForModel, .reasoning, .generatingResponse, .validatingResponse])
        XCTAssertTrue(values.filter(isReasoningEvent).isEmpty)
        guard case let .completed(result) = values.last else { return XCTFail("Missing completion") }
        XCTAssertNil(result.reasoning)
        XCTAssertEqual(result.response.terminalAssistantTurn?.text, "ok")
    }

    func testLateSignatureMetadataDoesNotRestartReasoningDuringText() throws {
        var mapper = BoneAnthropicNormalizedEventMapper(disclosure: .hidden)
        var activities: [BoneInferenceActivity] = []
        var content: [BoneInferenceStreamEvent] = []
        for data in [
            #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"ok"}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"private-signature"}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"content_block_stop","index":1}"#,
            #"{"type":"message_stop"}"#,
        ] {
            content += try mapper.consume(.init(data: data))
            activities += mapper.activities
        }
        XCTAssertEqual(activities, [.reasoning, .generatingResponse, .validatingResponse])
        XCTAssertEqual(content, [.textDelta("ok")])
    }

    func testImageResolutionPrecedesTransportAcrossAllProviderInvocations() async throws {
        let fixture = try ActivityImage()
        for provider in ActivityProvider.allCases {
            for invocation in ActivityInvocation.allCases {
                let log = ActivityLog()
                let images = try fixture.configuration(log: log)
                let engine = provider.engine(ActivityTransport(provider: provider, log: log), images: images)
                _ = try await BoneInferenceActivityReporting.withSink(log.sink) {
                    try await invocation.invoke(engine, request: activityRequest(image: fixture.image))
                }
                let trace = await log.trace
                XCTAssertEqual(Array(trace.prefix(4)), [.activity(.resolvingImages), .load,
                                                        .activity(.waitingForModel), .transport])
                let activities = await log.activities
                XCTAssertEqual(activities, invocation == .events
                    ? [.resolvingImages, .waitingForModel, .reasoning, .generatingResponse, .validatingResponse]
                    : [.resolvingImages, .waitingForModel, .validatingResponse])
            }
        }
    }

    func testImageCountByteAndTokenPreflightFailuresReportNoActivity() async throws {
        let fixture = try ActivityImage()
        for provider in ActivityProvider.allCases {
            for failure in 0..<5 {
                let log = ActivityLog()
                let images = try fixture.configuration(log: log, maximumImages: failure == 0 ? 1 : 2,
                    maximumImageBytes: failure == 1 ? 2 : 1024,
                    maximumBase64Bytes: failure == 2 ? 3 : 4096,
                    maximumBodyBytes: failure == 3 ? 3 : 100_000,
                    imageTokens: failure == 4 ? 10_000 : 64)
                let engine = provider.engine(ActivityTransport(provider: provider, log: log), images: images)
                let request = BoneInferenceRequest(modelID: "model", messages: [try .user(content: [
                    .image(fixture.image), .image(fixture.image),
                ])])
                do {
                    _ = try await BoneInferenceActivityReporting.withSink(log.sink) {
                        try await engine.infer(request: request)
                    }
                    XCTFail("Expected image preflight rejection")
                } catch {
                    let expected: BoneInferenceImageInputError = failure == 0 ? .tooManyImages
                        : failure == 3 ? .requestBytesExceeded : failure == 4 ? .inputTokensExceeded : .imageBytesExceeded
                    XCTAssertEqual(error as? BoneInferenceImageInputError, expected)
                }
                let trace = await log.trace
                XCTAssertTrue(trace.isEmpty, "Preflight must precede reporting, loading and transport")
            }
        }
    }

    func testCancellationDuringWaitingObserverPreventsEveryTransportEntryPoint() async throws {
        for provider in ActivityProvider.allCases {
            for invocation in ActivityInvocation.allCases {
                let log = ActivityLog()
                let engine = provider.engine(ActivityTransport(provider: provider, log: log))
                let task = Task {
                    try await BoneInferenceActivityReporting.withSink(.init { activity in
                        await log.record(.activity(activity))
                        if activity == .waitingForModel { withUnsafeCurrentTask { $0?.cancel() } }
                    }) {
                        try await invocation.invoke(engine, request: activityRequest())
                    }
                }
                do { _ = try await task.value; XCTFail("Expected cancellation") }
                catch { XCTAssertTrue(error is CancellationError, "\(error)") }
                let trace = await log.trace
                XCTAssertEqual(trace, [.activity(.waitingForModel)])
            }
        }
    }

    func testCancellationDuringImageObserverPreventsLoadsAndTransport() async throws {
        let fixture = try ActivityImage()
        for provider in ActivityProvider.allCases {
            for invocation in ActivityInvocation.allCases {
                let log = ActivityLog()
                let engine = provider.engine(ActivityTransport(provider: provider, log: log),
                    images: try fixture.configuration(log: log))
                let task = Task {
                    try await BoneInferenceActivityReporting.withSink(.init { activity in
                        await log.record(.activity(activity))
                        if activity == .resolvingImages { withUnsafeCurrentTask { $0?.cancel() } }
                    }) {
                        try await invocation.invoke(engine, request: activityRequest(image: fixture.image))
                    }
                }
                do { _ = try await task.value; XCTFail("Expected cancellation") }
                catch { XCTAssertTrue(error is CancellationError, "\(error)") }
                let trace = await log.trace
                XCTAssertEqual(trace, [.activity(.resolvingImages)])
            }
        }
    }

    func testConcurrentScopesOnSameEngineRemainIndependent() async throws {
        let directLog = ActivityLog()
        let streamLog = ActivityLog()
        let barrier = ActivityBarrier()
        let engine = ActivityProvider.openAI.engine(ActivityTransport(provider: .openAI, log: ActivityLog()))
        async let direct: BoneInferenceResponse = BoneInferenceActivityReporting.withSink(.init { activity in
            await directLog.record(.activity(activity))
            if activity == .waitingForModel { await barrier.arrive() }
        }) {
            try await engine.infer(request: activityRequest())
        }
        async let stream: BoneInferenceDetailedResult = BoneInferenceActivityReporting.withSink(.init { activity in
            await streamLog.record(.activity(activity))
            if activity == .waitingForModel { await barrier.arrive() }
        }) {
            try await ActivityInvocation.events.invoke(engine, request: activityRequest())
        }
        _ = try await (direct, stream)
        await BoneInferenceActivityReporting.report(.resolvingImages)
        let directActivities = await directLog.activities
        let streamActivities = await streamLog.activities
        XCTAssertEqual(directActivities, [.waitingForModel, .validatingResponse])
        XCTAssertEqual(streamActivities, [.waitingForModel, .reasoning, .generatingResponse, .validatingResponse])
    }

    private func collect(_ engine: any ActivityEngine, request: BoneInferenceRequest,
                         log: ActivityLog) async throws -> [BoneInferenceStreamEvent] {
        try await BoneInferenceActivityReporting.withSink(log.sink) {
            var events: [BoneInferenceStreamEvent] = []
            for try await event in engine.inferenceEvents(request: request, options: .init()) { events.append(event) }
            return events
        }
    }

    private func isReasoningEvent(_ event: BoneInferenceStreamEvent) -> Bool {
        switch event {
        case .reasoningStarted, .reasoningDelta, .reasoningCompleted: return true
        default: return false
        }
    }

    private func textDelta(_ event: BoneInferenceStreamEvent) -> String? {
        if case .textDelta(let text) = event { return text }
        return nil
    }
}

private typealias ActivityEngine = BoneInferenceEngine & BoneInferenceBufferedStreaming &
    BoneInferenceDetailedResultProviding & BoneInferenceDetailedBufferedStreaming & BoneInferenceEventStreaming

private let activityTool = BoneAgentToolDefinition(id: "probe", version: "1", title: "Probe", summary: "Probe",
    wireName: "probe", schemaVersion: 1, inputSchema: .object(properties: [:], required: [], additionalProperties: false))

private func activityRequest(disclosure: BoneInferenceReasoningDisclosure = .hidden,
                             tools: Bool = false, image: BoneInferenceImageInput? = nil) throws -> BoneInferenceRequest {
    let message: BoneInferenceMessage
    if let image { message = try .user(content: [.text("inspect"), .image(image)]) }
    else { message = .init(role: .user, content: "hello") }
    return .init(modelID: "model", messages: [message], availableTools: tools ? [activityTool] : [],
                 reasoningDisclosure: disclosure)
}

private enum ActivityInvocation: CaseIterable, Sendable {
    case infer, detailed, buffered, detailedBuffered, events
    func invoke(_ engine: any ActivityEngine, request: BoneInferenceRequest) async throws -> BoneInferenceDetailedResult {
        switch self {
        case .infer: return try await .init(response: engine.infer(request: request), reasoning: nil)
        case .detailed: return try await engine.inferDetailed(request: request)
        case .buffered: return try await .init(response: engine.inferUsingStream(request: request, options: .init()), reasoning: nil)
        case .detailedBuffered: return try await engine.inferDetailedUsingStream(request: request, options: .init())
        case .events:
            var completed: BoneInferenceDetailedResult?
            for try await event in engine.inferenceEvents(request: request, options: .init()) {
                if case .completed(let result) = event { completed = result }
            }
            return try XCTUnwrap(completed)
        }
    }
}

private enum ActivityProvider: CaseIterable, Sendable {
    case openAI, anthropic, gemini

    func engine(_ transport: ActivityTransport, images: BoneInferenceImageInputConfiguration? = nil) -> any ActivityEngine {
        let configuration = BoneInferenceProviderConfiguration(
            kind: self == .openAI ? .openAI : self == .anthropic ? .anthropic : .google,
            apiKey: "synthetic", baseURL: URL(string: "https://fixture.invalid")!,
            authenticationMode: self == .openAI ? .bearer : self == .anthropic ? .anthropicDual : .googleAPIKey)
        switch self {
        case .openAI: return BoneOpenAIInferenceEngine(configuration: configuration, transport: transport, imageInputConfiguration: images)
        case .anthropic: return BoneAnthropicInferenceEngine(configuration: configuration, transport: transport, imageInputConfiguration: images)
        case .gemini: return BoneGeminiInferenceEngine(configuration: configuration, transport: transport, imageInputConfiguration: images)
        }
    }

    var response: Data {
        let json: String
        switch self {
        case .openAI:
            json = #"{"choices":[{"message":{"role":"assistant","content":"ok","reasoning_content":"private thought"},"finish_reason":"stop"}]}"#
        case .anthropic:
            json = #"{"content":[{"type":"thinking","thinking":"private thought","signature":"private-signature"},{"type":"text","text":"ok"}],"stop_reason":"end_turn"}"#
        case .gemini:
            json = #"{"candidates":[{"content":{"parts":[{"thought":true,"text":"private thought"},{"text":"ok"}]},"finishReason":"STOP"}]}"#
        }
        return Data(json.utf8)
    }

    var firstTextEvent: Int { self == .anthropic ? 7 : 2 }
    var secondTextEvent: Int { self == .anthropic ? 9 : 3 }

    func events(tools: Bool) -> [BoneInferenceEventStreamEvent] {
        let values: [String]
        switch self {
        case .openAI:
            values = [
                #"{"choices":[{"index":0,"delta":{"reasoning_content":"private "},"finish_reason":null}]}"#,
                #"{"choices":[{"index":0,"delta":{"reasoning_content":"thought"},"finish_reason":null}]}"#,
            ] + (tools ? [
                #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call","type":"function","function":{"name":"probe","arguments":"{"}}]},"finish_reason":null}]}"#,
                #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"}"}}]},"finish_reason":null}]}"#,
                #"{"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#,
            ] : [
                #"{"choices":[{"index":0,"delta":{"content":"o"},"finish_reason":null}]}"#,
                #"{"choices":[{"index":0,"delta":{"content":"k"},"finish_reason":null}]}"#,
                #"{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#,
            ]) + ["[DONE]"]
        case .anthropic:
            values = [
                #"{"type":"message_start","message":{"usage":{"input_tokens":1,"output_tokens":0}}}"#,
                #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
                #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"private "}}"#,
                #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"thought"}}"#,
                #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"private-signature"}}"#,
                #"{"type":"content_block_stop","index":0}"#,
                #"{"type":"ping"}"#,
            ] + (tools ? [
                #"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"call","name":"probe","input":{}}}"#,
                #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{}"}}"#,
                #"{"type":"content_block_stop","index":1}"#,
                #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":2}}"#,
            ] : [
                #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
                #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"o"}}"#,
                #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"k"}}"#,
                #"{"type":"content_block_stop","index":1}"#,
                #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":2}}"#,
            ]) + [#"{"type":"message_stop"}"#]
        case .gemini:
            values = [
                #"{"candidates":[{"content":{"role":"model","parts":[{"thought":true,"text":"private "}]}}]}"#,
                #"{"candidates":[{"content":{"role":"model","parts":[{"thought":true,"text":"thought"}]}}]}"#,
            ] + (tools ? [
                #"{"candidates":[{"content":{"role":"model","parts":[{"functionCall":{"id":"call","name":"probe","args":{}}}]}}]}"#,
            ] : [
                #"{"candidates":[{"content":{"role":"model","parts":[{"text":"o"}]}}]}"#,
                #"{"candidates":[{"content":{"role":"model","parts":[{"text":"k"}]}}]}"#,
            ]) + [#"{"candidates":[{"finishReason":"STOP"}]}"#]
        }
        return values.map { .init(data: $0) }
    }
}

private enum ActivityTrace: Equatable, Sendable {
    case activity(BoneInferenceActivity), load, transport, response
}

private actor ActivityLog {
    private(set) var trace: [ActivityTrace] = []
    private(set) var beforeEvents: [[BoneInferenceActivity]] = []
    var activities: [BoneInferenceActivity] {
        trace.compactMap { if case .activity(let activity) = $0 { return activity }; return nil }
    }
    nonisolated var sink: BoneInferenceActivitySink { .init { await self.record(.activity($0)) } }
    func record(_ event: ActivityTrace) { trace.append(event) }
    func beforeEvent() { beforeEvents.append(activities) }
}

private struct ActivityTransport: BoneInferenceHTTPTransport {
    let provider: ActivityProvider
    let log: ActivityLog
    let streamEvents: [BoneInferenceEventStreamEvent]
    init(provider: ActivityProvider, log: ActivityLog, tools: Bool = false, events: [BoneInferenceEventStreamEvent]? = nil) {
        self.provider = provider; self.log = log; streamEvents = events ?? provider.events(tools: tools)
    }
    func send(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse {
        await log.record(.transport)
        await log.record(.response)
        return .init(statusCode: 200, data: provider.response)
    }
    func sendRetryableForModels(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse { try await send(request) }
    func sendEventStream(_ request: URLRequest, options: BoneInferenceEventStreamOptions) async throws -> BoneInferenceEventStreamResponse {
        await log.record(.transport)
        await log.record(.response)
        return .init(statusCode: 200, events: streamEvents)
    }
    func eventStream(_ request: URLRequest, options: BoneInferenceEventStreamOptions) -> BoneInferenceRawEventStream {
        let cursor = ActivityStreamCursor(events: streamEvents, log: log)
        return AsyncThrowingStream(unfolding: { await cursor.next() })
    }
}

private actor ActivityStreamCursor {
    let events: [BoneInferenceEventStreamEvent]
    let log: ActivityLog
    var index = 0
    init(events: [BoneInferenceEventStreamEvent], log: ActivityLog) { self.events = events; self.log = log }
    func next() async -> BoneInferenceEventStreamEvent? {
        if index == 0 { await log.record(.transport) }
        guard index < events.count else { await log.record(.response); return nil }
        await log.beforeEvent()
        defer { index += 1 }
        return events[index]
    }
}

private struct ActivityImage: Sendable {
    let data = Data([1, 2, 3])
    let metadata: BoneInferenceImageMetadata
    let image: BoneInferenceImageInput
    init() throws {
        metadata = try .init(format: .png, width: 2, height: 3, byteCount: 3)
        let prepared = try BoneInferencePreparedImage(data: data, metadata: metadata)
        image = .init(reference: try prepared.reference(id: "private-asset-id", version: "v1"))
    }
    func configuration(log: ActivityLog, maximumImages: Int = 2, maximumImageBytes: Int = 1024,
                       maximumBase64Bytes: Int = 4096, maximumBodyBytes: Int = 100_000,
                       imageTokens: Int = 64) throws -> BoneInferenceImageInputConfiguration {
        let profile = try BoneInferenceImageInputProfile(
            contextBudget: .init(contextWindowTokens: 8192, maximumOutputTokens: 128, source: .host),
            maximumImagesPerRequest: maximumImages, maximumImageBytes: maximumImageBytes,
            maximumBase64BytesPerRequest: maximumBase64Bytes, maximumRequestBodyBytes: maximumBodyBytes,
            safetyMarginTokens: 16, tokenEstimator: { _ in imageTokens })
        // Trusted fixture inspection; this exercises reporting, not image decoding.
        return try .init(profiles: ["model": profile], resolver: .init(inspect: { _ in metadata }, load: { _ in
            await log.record(.load)
            return data
        }))
    }
}

private actor ActivityBarrier {
    private var first: CheckedContinuation<Void, Never>?
    func arrive() async {
        if let first { self.first = nil; first.resume() }
        else { await withCheckedContinuation { first = $0 } }
    }
}
