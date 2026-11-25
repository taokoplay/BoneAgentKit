import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import BoneAgentKit

final class FlowControlledInferenceTests: XCTestCase {
    func testOpenAISlowConsumerKeepsBothQueuesBoundedAndCompletesUnicodeOnce() async throws {
        try await checkSlowConsumer(.openAI)
    }

    func testAnthropicSlowConsumerKeepsBothQueuesBoundedAndCompletesUnicodeOnce() async throws {
        try await checkSlowConsumer(.anthropic)
    }

    func testGeminiSlowConsumerKeepsBothQueuesBoundedAndCompletesUnicodeOnce() async throws {
        try await checkSlowConsumer(.gemini)
    }

    func testOversizedRawEventAndAggregatedResultFailWithoutCompleted() async throws {
        for provider in FlowTestProvider.allCases {
            for oversizedResult in [false, true] {
                let pieces = oversizedResult ? Array(repeating: "你🦴e\u{301}", count: 80)
                    : [String(repeating: "🦴", count: 300)]
                let events = try provider.events(pieces)
                let limits = try buffering(count: 2, bytes: 1_024, event: 512)
                if oversizedResult {
                    XCTAssertTrue(events.allSatisfy { BoneEventPayloadSize.raw($0) <= 512 })
                }
                let probe = FlowTestTransportProbe()
                defer { probe.stop() }
                let transport = FlowTestTransport(events: events, probe: probe)
                let engine = provider.engine(transport)
                let stream = engine.inferenceEvents(request: request(), options: options(), buffering: limits)
                let capture = try await completed { await flowTestCapture(stream) }
                XCTAssertEqual(capture.error as? BoneEventStreamError, .eventTooLarge, "\(provider)")
                XCTAssertFalse(capture.values.contains(where: isCompleted))
                if oversizedResult {
                    // Every raw frame and text delta fits; only the formal aggregate is oversized.
                    XCTAssertEqual(text(capture.values), pieces.joined())
                    XCTAssertGreaterThan(capture.values.count, 50)
                } else {
                    XCTAssertTrue(text(capture.values).isEmpty)
                }
                await fulfillment(of: [probe.productionStopped], timeout: 2)
                XCTAssertEqual(probe.calls, ["bounded"])
                XCTAssertEqual(stream.bufferSnapshot.bufferedPayloadBytes, 0)
                XCTAssertLessThanOrEqual(probe.rawSnapshot?.peakBufferedPayloadBytes ?? Int.max, 1_024)
            }
        }
    }

    func testRequestMaximumBytesSurvivesRepeatedSmallEventsAndContinuousDraining() async throws {
        for provider in FlowTestProvider.allCases {
            let piece = "中"
            let events = try provider.events(Array(repeating: piece, count: 256))
            let firstFrames = try provider.events([piece])
            let budget = firstFrames.reduce(0) { $0 + $1.data.utf8.count + ($1.event?.utf8.count ?? 0) }
            let probe = FlowTestTransportProbe()
            defer { probe.stop() }
            // This transport intentionally ignores maximumBytes; the engine must enforce it.
            let engine = provider.engine(FlowTestTransport(events: events, probe: probe))
            let stream = engine.inferenceEvents(request: request(),
                options: .init(firstEventTimeout: 1, idleTimeout: 1, maximumBytes: budget, totalTimeout: 2),
                buffering: try buffering(count: 1, bytes: 1_024, event: 512))
            let capture = try await completed { await flowTestCapture(stream) }
            XCTAssertEqual(capture.error as? BoneInferenceTransportError, .responseTooLarge, "\(provider)")
            XCTAssertFalse(capture.values.contains(where: isCompleted))
            XCTAssertFalse(text(capture.values).isEmpty)
            XCTAssertLessThan(text(capture.values).count, 256)
            await fulfillment(of: [probe.productionStopped], timeout: 2)
            XCTAssertEqual(probe.calls, ["bounded"])
            XCTAssertEqual(stream.bufferSnapshot.bufferedPayloadBytes, 0)
            XCTAssertLessThanOrEqual(stream.bufferSnapshot.peakBufferedEventCount, 1)
        }
    }

    func testIncompatibleTransportsFailLocalValidationWithoutRequestsAndKeepLegacyUsable() async throws {
        for provider in FlowTestProvider.allCases {
            for legacyOnly in [true, false] {
                let probe = FlowTestTransportProbe()
                defer { probe.stop() }
                let base = FlowTestTransport(events: try provider.events(["旧🦴接口"]), probe: probe,
                    providesLiveEventTiming: legacyOnly, allowLegacy: true)
                let transport: any BoneInferenceHTTPTransport = legacyOnly
                    ? FlowTestLegacyTransport(base: base) : base
                let engine = provider.engine(transport)
                XCTAssertThrowsError(try engine.validateEventFlowControl()) {
                    XCTAssertEqual($0 as? BoneEventStreamError, .flowControlUnavailable)
                }
                XCTAssertTrue(probe.calls.isEmpty)
                let stream = engine.inferenceEvents(request: request(), options: options(), buffering: .init())
                let rejected = try await completed { await flowTestCapture(stream) }
                XCTAssertEqual(rejected.error as? BoneEventStreamError, .flowControlUnavailable)
                XCTAssertTrue(rejected.values.isEmpty)
                XCTAssertTrue(probe.calls.isEmpty, "The bounded path must not replay a legacy stream")
                let legacy = engine.inferenceEvents(request: request(), options: options())
                let accepted = try await completed { await flowTestCapture(legacy) }
                assertSuccessful(accepted, expectedText: "旧🦴接口")
                XCTAssertEqual(probe.calls, ["legacy"])
            }
        }
    }

    func testURLSessionDecodesSplitUTF8AndRequiresCompleteSSEAtEOF() async throws {
        for completeFrame in [true, false] {
            let body = completeFrame
                ? "event: message\r\nid: first\r\ndata: 你🦴e\u{301}\r\n\r\ndata: 世界\n\n"
                : "data: 完整\n\ndata: 未结束\n"
            let fixture = FlowTestURLFixture(chunks: Data(body.utf8).map { Data([$0]) }, finishes: true)
            let (transport, request) = network(fixture)
            defer { FlowTestURLProtocol.remove(fixture) }
            let stream = transport.eventStream(request, options: options(), buffering: try buffering(count: 4))
            let capture = try await completed { await flowTestCapture(stream) }
            if completeFrame {
                XCTAssertNil(capture.error)
                XCTAssertEqual(capture.values, [
                    .init(event: "message", id: "first", data: "你🦴e\u{301}"), .init(data: "世界"),
                ])
            } else {
                XCTAssertEqual(capture.error as? BoneInferenceTransportError, .invalidResponse)
                XCTAssertEqual(capture.values, [.init(data: "完整")])
            }
            await fulfillment(of: [fixture.started.expectation, fixture.delivered.expectation], timeout: 2)
            XCTAssertEqual(stream.bufferSnapshot.bufferedEventCount, 0)
        }
    }

    func testURLSessionOneCallbackBurstOverflowsExplicitlyPreservesOrderAndCancelsRequest() async throws {
        let body = (0..<10).map { "data: \($0)\n\n" }.joined()
        let fixture = FlowTestURLFixture(chunks: [Data(body.utf8)], finishes: false)
        let (transport, request) = network(fixture)
        defer { FlowTestURLProtocol.remove(fixture) }
        let stream = transport.eventStream(request, options: options(), buffering: try buffering(count: 2))
        // Do not create an iterator until URLSession has cancelled the overflowing callback.
        await fulfillment(of: [fixture.stopped.expectation], timeout: 2)
        XCTAssertEqual(stream.bufferSnapshot.bufferedEventCount, 2)
        XCTAssertEqual(stream.bufferSnapshot.peakBufferedEventCount, 2)
        let capture = try await completed { await flowTestCapture(stream) }
        XCTAssertEqual(capture.values.map(\.data), ["0", "1"])
        XCTAssertEqual(capture.error as? BoneEventStreamError, .bufferOverflow)
        XCTAssertEqual(stream.bufferSnapshot.bufferedPayloadBytes, 0)
    }

    func testURLSessionOversizedEventFailsWithEventTooLargeAndCancelsRequest() async throws {
        let body = "data: " + String(repeating: "🦴", count: 128) + "\n\n"
        let fixture = FlowTestURLFixture(chunks: [Data(body.utf8)], finishes: false)
        let (transport, request) = network(fixture)
        defer { FlowTestURLProtocol.remove(fixture) }
        let stream = transport.eventStream(request, options: options(),
            buffering: try buffering(count: 2, bytes: 512, event: 128))
        await fulfillment(of: [fixture.stopped.expectation], timeout: 2)
        let capture = try await completed { await flowTestCapture(stream) }
        XCTAssertTrue(capture.values.isEmpty)
        XCTAssertEqual(capture.error as? BoneEventStreamError, .eventTooLarge)
        XCTAssertEqual(stream.bufferSnapshot.peakBufferedPayloadBytes, 0)
    }

    func testURLSessionEarlyBreakCancelsNetworkWhileStreamIsStillRetained() async throws {
        let fixture = FlowTestURLFixture(chunks: [Data("data: first\n\ndata: second\n\n".utf8)], finishes: false)
        let (transport, request) = network(fixture)
        defer { FlowTestURLProtocol.remove(fixture) }
        let stream = transport.eventStream(request, options: options(), buffering: try buffering(count: 4))
        let first = try await completed { () async throws -> String? in
            var first: String?
            for try await event in stream {
                first = event.data
                break
            }
            return first
        }
        XCTAssertEqual(first, "first")
        await fulfillment(of: [fixture.stopped.expectation], timeout: 2)
        XCTAssertEqual(stream.bufferSnapshot.bufferedEventCount, 0)
        XCTAssertEqual(stream.bufferSnapshot.bufferedPayloadBytes, 0)
    }

    func testURLSessionCancellingWaitingConsumerCancelsNetwork() async throws {
        let fixture = FlowTestURLFixture(chunks: [], finishes: false)
        let (transport, request) = network(fixture)
        defer { FlowTestURLProtocol.remove(fixture) }
        let stream = transport.eventStream(request, options: options(), buffering: .init())
        let result = FlowTestAsyncResult<FlowTestCapture<BoneInferenceEventStreamEvent>>()
        let consumer = Task { result.complete(.success(await flowTestCapture(stream))) }
        defer { consumer.cancel() }
        await fulfillment(of: [fixture.started.expectation], timeout: 2)
        consumer.cancel()
        await fulfillment(of: [result.finished, fixture.stopped.expectation], timeout: 2)
        let capture = try XCTUnwrap(result.result).get()
        XCTAssertTrue(capture.error is CancellationError)
        XCTAssertTrue(capture.values.isEmpty)
        XCTAssertEqual(stream.bufferSnapshot.bufferedEventCount, 0)
    }

    func testPastDeadlineNeverStartsURLSessionOrProviderTransport() async throws {
        let fixture = FlowTestURLFixture(chunks: [], finishes: false)
        let (transport, request) = network(fixture)
        defer { FlowTestURLProtocol.remove(fixture) }
        let expired = BoneInferenceEventStreamOptions(deadlineUptime: ProcessInfo.processInfo.systemUptime - 1)
        let stream = transport.eventStream(request, options: expired, buffering: .init())
        let capture = try await completed { await flowTestCapture(stream) }
        XCTAssertTrue(capture.error is BoneInferenceStreamDeadlineExceeded)
        XCTAssertTrue(capture.values.isEmpty)
        let noStart = XCTestExpectation(description: "expired request must not start URLProtocol")
        noStart.isInverted = true
        fixture.started.observe(noStart)
        await fulfillment(of: [noStart], timeout: 0.03)
        fixture.started.stopObserving()
        for provider in FlowTestProvider.allCases {
            let probe = FlowTestTransportProbe()
            defer { probe.stop() }
            let engine = provider.engine(FlowTestTransport(events: try provider.events(["unused"]), probe: probe))
            let stream = engine.inferenceEvents(request: self.request(), options: expired, buffering: .init())
            let capture = try await completed { await flowTestCapture(stream) }
            XCTAssertTrue(capture.error is BoneInferenceStreamDeadlineExceeded)
            XCTAssertTrue(probe.calls.isEmpty)
        }
    }

    func testProvidersRespectTotalTimeoutWhileBlockedSendingToFullQueue() async throws {
        try await checkDeadlineWhileFull(absolute: false)
    }

    func testProvidersRespectMonotonicDeadlineWhileBlockedSendingToFullQueue() async throws {
        try await checkDeadlineWhileFull(absolute: true)
    }

    private func checkSlowConsumer(_ provider: FlowTestProvider) async throws {
        let pieces = Array(repeating: ["你", "好", "🦴", "e\u{301}", "🌍", "末"], count: 4).flatMap { $0 }
        let gate = FlowTestGate()
        let probe = FlowTestTransportProbe()
        defer { probe.stop() }
        let engine = provider.engine(FlowTestTransport(events: try provider.events(pieces), probe: probe, gate: gate))
        try engine.validateEventFlowControl()
        let limits = try buffering(count: 2, bytes: 4_096, event: 2_048)
        let stream = engine.inferenceEvents(request: request(), options: options(), buffering: limits)
        let full = FlowTestSignal("raw and normalized queues are full")
        probe.observeAttempts { raw in
            if raw.bufferedEventCount == 2, stream.bufferSnapshot.bufferedEventCount == 2 { full.fire() }
        }
        await gate.open()
        await fulfillment(of: [full.expectation], timeout: 2)
        XCTAssertEqual(stream.bufferSnapshot.bufferedEventCount, 2)
        XCTAssertEqual(probe.rawSnapshot?.bufferedEventCount, 2)
        // Holding consumption until both stages fill establishes actual backpressure.
        let capture = try await completed { await flowTestCapture(stream, yieldBetweenEvents: true) }
        assertSuccessful(capture, expectedText: pieces.joined())
        await fulfillment(of: [probe.productionStopped], timeout: 2)
        XCTAssertEqual(probe.calls, ["bounded"])
        let raw = try XCTUnwrap(probe.rawSnapshot)
        let normalized = stream.bufferSnapshot
        XCTAssertEqual(raw.peakBufferedEventCount, 2)
        XCTAssertEqual(normalized.peakBufferedEventCount, 2)
        XCTAssertLessThanOrEqual(raw.peakBufferedPayloadBytes, 4_096)
        XCTAssertLessThanOrEqual(normalized.peakBufferedPayloadBytes, 4_096)
        XCTAssertEqual(raw.bufferedPayloadBytes, 0)
        XCTAssertEqual(normalized.bufferedPayloadBytes, 0)
        XCTAssertGreaterThan(raw.peakBufferedPayloadBytes, 0)
        XCTAssertGreaterThan(normalized.peakBufferedPayloadBytes, 0)
    }

    private func checkDeadlineWhileFull(absolute: Bool) async throws {
        for provider in FlowTestProvider.allCases {
            let gate = FlowTestGate()
            let probe = FlowTestTransportProbe()
            defer { probe.stop() }
            let engine = provider.engine(FlowTestTransport(events: try provider.events(Array(repeating: "中", count: 64)),
                probe: probe, gate: gate))
            let budget = BoneInferenceEventStreamOptions(firstEventTimeout: 2, idleTimeout: 2,
                totalTimeout: absolute ? nil : 0.3,
                deadlineUptime: absolute ? ProcessInfo.processInfo.systemUptime + 0.3 : nil)
            let stream = engine.inferenceEvents(request: request(), options: budget,
                buffering: try buffering(count: 1, bytes: 1_024, event: 512))
            let full = FlowTestSignal("provider blocked by full normalized and raw queues")
            probe.observeAttempts { raw in
                if raw.bufferedEventCount == 1, stream.bufferSnapshot.bufferedEventCount == 1 { full.fire() }
            }
            await gate.open()
            await fulfillment(of: [full.expectation], timeout: 2)
            // No next() calls: the provider must time out while its send is suspended.
            await fulfillment(of: [probe.productionStopped], timeout: 2)
            XCTAssertEqual(stream.bufferSnapshot.bufferedEventCount, 1)
            let capture = try await completed { await flowTestCapture(stream) }
            XCTAssertTrue(capture.error is BoneInferenceStreamDeadlineExceeded, "\(provider): \(String(describing: capture.error))")
            XCTAssertFalse(capture.values.contains(where: isCompleted))
            XCTAssertEqual(probe.calls, ["bounded"])
            XCTAssertEqual(probe.termination, .cancelled)
            XCTAssertEqual(stream.bufferSnapshot.bufferedPayloadBytes, 0)
        }
    }

    private func request() -> BoneInferenceRequest {
        .init(modelID: "model", messages: [.init(role: .user, content: "synthetic request")])
    }

    private func options() -> BoneInferenceEventStreamOptions {
        .init(firstEventTimeout: 1, idleTimeout: 1, totalTimeout: 2)
    }

    private func buffering(count: Int, bytes: Int = 4_096, event: Int = 2_048) throws -> BoneEventBufferLimits {
        try .init(maximumEventCount: count, maximumQueuedPayloadBytes: bytes, maximumEventPayloadBytes: event)
    }

    private func text(_ events: [BoneInferenceStreamEvent]) -> String {
        events.compactMap { if case .textDelta(let text) = $0 { return text }; return nil }.joined()
    }

    private func isCompleted(_ event: BoneInferenceStreamEvent) -> Bool {
        if case .completed = event { return true }
        return false
    }

    private func assertSuccessful(_ capture: FlowTestCapture<BoneInferenceStreamEvent>, expectedText: String,
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(capture.error, file: file, line: line)
        XCTAssertEqual(text(capture.values), expectedText, file: file, line: line)
        XCTAssertEqual(capture.values.filter(isCompleted).count, 1, file: file, line: line)
        guard case .completed(let result) = capture.values.last else {
            return XCTFail("The only formal completion must be last", file: file, line: line)
        }
        XCTAssertEqual(result.response.terminalAssistantTurn?.text, expectedText, file: file, line: line)
    }

    private func completed<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let result = FlowTestAsyncResult<Value>()
        let task = Task {
            do { result.complete(.success(try await operation())) }
            catch { result.complete(.failure(error)) }
        }
        defer { task.cancel() }
        await fulfillment(of: [result.finished], timeout: 3)
        // A failed test never waits forever for a task that ignored cancellation.
        return try XCTUnwrap(result.result, "Asynchronous operation did not complete").get()
    }

    private func network(_ fixture: FlowTestURLFixture) -> (BoneInferenceURLSessionTransport, URLRequest) {
        FlowTestURLProtocol.install(fixture)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FlowTestURLProtocol.self]
        return (BoneInferenceURLSessionTransport(configuration: configuration),
                URLRequest(url: URL(string: "https://\(fixture.host)/events")!))
    }
}

private typealias FlowTestRaw = BoneInferenceEventStreamEvent
private typealias FlowTestRawStream = BoneBoundedEventStream<FlowTestRaw>

private struct FlowTestCapture<Element: Sendable>: Sendable {
    let values: [Element]
    let error: Error?
}

private func flowTestCapture<Sequence: AsyncSequence>(
    _ stream: Sequence, yieldBetweenEvents: Bool = false
) async -> FlowTestCapture<Sequence.Element> where Sequence.Element: Sendable {
    var values: [Sequence.Element] = []
    do {
        for try await value in stream {
            values.append(value)
            if yieldBetweenEvents { await Task.yield() }
        }
        return .init(values: values, error: nil)
    } catch { return .init(values: values, error: error) }
}

private enum FlowTestProvider: CaseIterable, Sendable {
    case openAI, anthropic, gemini

    func engine(_ transport: any BoneInferenceHTTPTransport) -> any BoneInferenceFlowControlledEventStreaming {
        let configuration = BoneInferenceProviderConfiguration(
            kind: self == .openAI ? .openAI : self == .anthropic ? .anthropic : .google,
            apiKey: "synthetic", baseURL: URL(string: "https://provider.flow-controlled-inference.invalid")!,
            authenticationMode: self == .openAI ? .bearer : self == .anthropic ? .anthropicDual : .googleAPIKey)
        switch self {
        case .openAI: return BoneOpenAIInferenceEngine(configuration: configuration, transport: transport)
        case .anthropic: return BoneAnthropicInferenceEngine(configuration: configuration, transport: transport)
        case .gemini: return BoneGeminiInferenceEngine(configuration: configuration, transport: transport)
        }
    }

    // Full provider sequences, including their distinct formal wire terminal markers.
    func events(_ pieces: [String]) throws -> [FlowTestRaw] {
        switch self {
        case .openAI:
            let initial = try json(["choices": [["index": 0, "delta": ["role": "assistant"]]]])
            let deltas = try pieces.map { try json(["choices": [["index": 0, "delta": ["content": $0]]]]) }
            let stop = try json(["choices": [["index": 0, "delta": [:], "finish_reason": "stop"]]])
            return [initial] + deltas + [stop, .init(data: "[DONE]")]
        case .anthropic:
            let start = try json(["type": "message_start", "message": ["id": "flow-message", "type": "message",
                "role": "assistant", "model": "model", "content": [], "stop_reason": NSNull(),
                "stop_sequence": NSNull(), "usage": ["input_tokens": 1, "output_tokens": 0]]])
            let block = try json(["type": "content_block_start", "index": 0,
                                  "content_block": ["type": "text", "text": ""]])
            let deltas = try pieces.map { try json(["type": "content_block_delta", "index": 0,
                                                   "delta": ["type": "text_delta", "text": $0]]) }
            let endBlock = try json(["type": "content_block_stop", "index": 0])
            let stop = try json(["type": "message_delta", "delta": ["stop_reason": "end_turn", "stop_sequence": NSNull()],
                                 "usage": ["output_tokens": pieces.count]])
            return [start, block] + deltas + [endBlock, stop, try json(["type": "message_stop"])]
        case .gemini:
            let deltas = try pieces.map { try json(["candidates": [["index": 0,
                "content": ["role": "model", "parts": [["text": $0]]]]]]) }
            let stop = try json(["candidates": [["index": 0, "finishReason": "STOP"]],
                                 "usageMetadata": ["promptTokenCount": 1, "candidatesTokenCount": pieces.count]])
            return deltas + [stop]
        }
    }

    private func json(_ object: [String: Any]) throws -> FlowTestRaw {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return .init(event: self == .anthropic ? object["type"] as? String : nil,
                     data: String(decoding: data, as: UTF8.self))
    }
}

private struct FlowTestTransport: BoneInferenceFlowControlledHTTPTransport {
    let events: [FlowTestRaw]
    let probe: FlowTestTransportProbe
    var providesLiveEventTiming = true
    var allowLegacy = false
    var gate: FlowTestGate?

    func eventStream(_ request: URLRequest, options: BoneInferenceEventStreamOptions,
                     buffering: BoneEventBufferLimits) -> FlowTestRawStream {
        probe.record("bounded")
        let (stream, producer) = FlowTestRawStream.makeStream(limits: buffering) { BoneEventPayloadSize.raw($0) }
        probe.hold(stream)
        producer.onTermination { reason in
            probe.recordTermination(reason)
            if reason != .finished { probe.cancellation.cancel() }
        }
        let task = Task {
            do {
                if let gate { await gate.wait() }
                for event in events {
                    try Task.checkCancellation()
                    probe.attempt()
                    try await producer.send(event)
                }
                producer.finish()
            } catch { producer.finish(throwing: error) }
            probe.productionStopped.fulfill()
        }
        probe.cancellation.install(task)
        return stream
    }

    func eventStream(_ request: URLRequest, options: BoneInferenceEventStreamOptions) -> BoneInferenceRawEventStream {
        probe.record("legacy")
        return AsyncThrowingStream { continuation in
            guard allowLegacy else {
                XCTFail("Flow-controlled inference called the legacy transport entry point")
                continuation.finish(throwing: BoneEventStreamError.flowControlUnavailable)
                return
            }
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }

    func send(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse {
        probe.record("send")
        throw BoneInferenceTransportError.invalidConfiguration
    }

    func sendRetryableForModels(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse {
        try await send(request)
    }

    func sendEventStream(_ request: URLRequest, options: BoneInferenceEventStreamOptions) async throws -> BoneInferenceEventStreamResponse {
        probe.record("buffered")
        return .init(statusCode: 200, events: events)
    }
}

/// This wrapper deliberately has live timing but does not adopt the optional bounded protocol.
private struct FlowTestLegacyTransport: BoneInferenceHTTPTransport {
    let base: FlowTestTransport
    var providesLiveEventTiming: Bool { base.providesLiveEventTiming }
    func send(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse { try await base.send(request) }
    func sendRetryableForModels(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse { try await base.send(request) }
    func sendEventStream(_ request: URLRequest, options: BoneInferenceEventStreamOptions) async throws -> BoneInferenceEventStreamResponse {
        try await base.sendEventStream(request, options: options)
    }
    func eventStream(_ request: URLRequest, options: BoneInferenceEventStreamOptions) -> BoneInferenceRawEventStream {
        base.eventStream(request, options: options)
    }
}

private final class FlowTestTransportProbe: @unchecked Sendable {
    let productionStopped = XCTestExpectation(description: "controlled raw producer stopped")
    let cancellation = BoneEventProducerCancellation()
    private let lock = NSLock()
    private var methods: [String] = []
    private var raw: FlowTestRawStream?
    private var reason: FlowTestRawStream.Termination?
    private var observer: (@Sendable (BoneEventBufferSnapshot) -> Void)?

    var calls: [String] { lock.withLock { methods } }
    var termination: FlowTestRawStream.Termination? { lock.withLock { reason } }
    var rawSnapshot: BoneEventBufferSnapshot? {
        let stream = lock.withLock { raw }
        return stream?.bufferSnapshot
    }

    func record(_ method: String) { lock.withLock { methods.append(method) } }
    func recordTermination(_ reason: FlowTestRawStream.Termination) { lock.withLock { self.reason = reason } }
    func hold(_ stream: FlowTestRawStream) { lock.withLock { raw = stream } }
    func observeAttempts(_ observer: @escaping @Sendable (BoneEventBufferSnapshot) -> Void) {
        lock.withLock { self.observer = observer }
    }
    func attempt() {
        let (stream, observer) = lock.withLock { (raw, observer) }
        if let stream { observer?(stream.bufferSnapshot) }
    }
    func stop() {
        cancellation.cancel()
        // Release stream/closures outside this lock: ARC cleanup can notify termination.
        let retired = lock.withLock { () -> (FlowTestRawStream?, (@Sendable (BoneEventBufferSnapshot) -> Void)?) in
            let retired = (raw, observer)
            raw = nil
            observer = nil
            return retired
        }
        withExtendedLifetime(retired) {}
    }
}

private actor FlowTestGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        let previous = waiters
        waiters = []
        previous.forEach { $0.resume() }
    }
}

private final class FlowTestAsyncResult<Value: Sendable>: @unchecked Sendable {
    let finished = XCTestExpectation(description: "asynchronous operation finished")
    private let lock = NSLock()
    private var storage: Result<Value, Error>?
    var result: Result<Value, Error>? { lock.withLock { storage } }
    func complete(_ result: Result<Value, Error>) {
        lock.withLock { storage = result }
        finished.fulfill()
    }
}

private final class FlowTestSignal: @unchecked Sendable {
    let expectation: XCTestExpectation
    private let lock = NSLock()
    private var fired = false
    private var observer: XCTestExpectation?
    init(_ description: String) { expectation = XCTestExpectation(description: description) }
    func fire() {
        let action = lock.withLock { () -> (Bool, XCTestExpectation?) in
            guard !fired else { return (false, nil) }
            fired = true
            return (true, observer)
        }
        if action.0 { expectation.fulfill(); action.1?.fulfill() }
    }
    func observe(_ expectation: XCTestExpectation) {
        let alreadyFired = lock.withLock { observer = expectation; return fired }
        if alreadyFired { expectation.fulfill() }
    }
    func stopObserving() { lock.withLock { observer = nil } }
}

private final class FlowTestURLFixture: @unchecked Sendable {
    let host = UUID().uuidString.lowercased() + ".flow-controlled-inference.invalid"
    let chunks: [Data]
    let finishes: Bool
    let started = FlowTestSignal("dedicated URLProtocol started")
    let delivered = FlowTestSignal("dedicated URLProtocol delivered finite chunks")
    let stopped = FlowTestSignal("dedicated URLProtocol was cancelled")
    init(chunks: [Data], finishes: Bool) { self.chunks = chunks; self.finishes = finishes }
}

/// Per-host registry; this class never intercepts existing tests or performs real networking.
private final class FlowTestURLProtocol: URLProtocol, @unchecked Sendable {
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var fixtures: [String: FlowTestURLFixture] = [:]
    private let stateLock = NSLock()
    private var active: FlowTestURLFixture?
    private var stopped = false

    static func install(_ fixture: FlowTestURLFixture) {
        registryLock.withLock { fixtures[fixture.host] = fixture }
    }
    static func remove(_ fixture: FlowTestURLFixture) {
        _ = registryLock.withLock { fixtures.removeValue(forKey: fixture.host) }
    }
    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host, host.hasSuffix(".flow-controlled-inference.invalid") else { return false }
        return registryLock.withLock { fixtures[host] != nil }
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let host = request.url?.host,
              let fixture = Self.registryLock.withLock({ Self.fixtures[host] }), let client else { return }
        let alreadyStopped = stateLock.withLock { active = fixture; return stopped }
        fixture.started.fire()
        if alreadyStopped { fixture.stopped.fire(); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/event-stream; charset=utf-8"])!
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in fixture.chunks {
            if stateLock.withLock({ stopped }) { return }
            client.urlProtocol(self, didLoad: chunk)
        }
        fixture.delivered.fire()
        if fixture.finishes, !stateLock.withLock({ stopped }) { client.urlProtocolDidFinishLoading(self) }
        // Open responses retain no blocked thread/task; the stream's finite timers stop them.
    }

    override func stopLoading() {
        let fixture = stateLock.withLock { stopped = true; return active }
        fixture?.stopped.fire()
    }
}
