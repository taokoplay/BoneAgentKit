import Foundation
import XCTest
import BoneAgentTesting
@testable import BoneAgentKit

/// Offline protocol/budget tests. Synthetic references do not assert visual recognition accuracy.
final class VisionInputTests: XCTestCase {
    private func image(_ id: String = "image", bytes: Int = 64, width: Int = 100) throws -> BoneInferenceImageInput {
        let metadata = try BoneInferenceImageMetadata(format: .png, width: width, height: 100, byteCount: bytes)
        return .init(reference: try BoneInferencePreparedImage(data: Data(repeating: 42, count: bytes), metadata: metadata)
            .reference(id: id, version: "v1"))
    }
    private func budget(_ window: Int = 2_000) throws -> BoneContextWindowBudget {
        try .init(contextWindowTokens: window, maximumOutputTokens: 200, source: .host)
    }
    private func profile(window: Int = 2_000, maximumImages: Int = 20, maximumBytes: Int = 5_242_880,
                         base64: Int = 20_971_520, body: Int = 33_554_432,
                         tokens: @escaping BoneInferenceImageTokenEstimator = { _ in 500 }) throws -> BoneInferenceImageInputProfile {
        try .init(contextBudget: budget(window), maximumImagesPerRequest: maximumImages,
                  maximumImageBytes: maximumBytes, maximumBase64BytesPerRequest: base64,
                  maximumRequestBodyBytes: body, safetyMarginTokens: 100, tokenEstimator: tokens)
    }
    private func configuration(_ profile: BoneInferenceImageInputProfile, image: BoneInferenceImageInput,
                               loads: VisionLoadRecorder) throws -> BoneInferenceImageInputConfiguration {
        try .init(profiles: ["vision": profile], resolver: .init(inspect: { _ in image.reference.metadata }, load: { reference in
            await loads.record(reference)
            return Data(repeating: 42, count: reference.metadata.byteCount)
        }))
    }
    private func request(_ images: [BoneInferenceImageInput], tools: [BoneAgentToolDefinition] = []) throws -> BoneInferenceRequest {
        .init(modelID: "vision", messages: [try .user(content: [.text("inspect")] + images.map { .image($0) })],
              availableTools: tools, generationOptions: .init(maximumOutputTokens: 200))
    }

    func testReferenceRoundTripContainsNoImageBytesAndRejectsInvalidMessageRole() throws {
        let value = try image(bytes: 512)
        let original = try request([value])
        let encoded = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(BoneInferenceRequest.self, from: encoded), original)
        let json = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(json.contains(Data(repeating: 42, count: 512).base64EncodedString()))
        XCTAssertFalse(json.contains("data:image"))
        XCTAssertFalse(json.contains("file://"))
        var invalid = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original.messages[0])) as? [String: Any])
        invalid["role"] = "assistant"
        XCTAssertThrowsError(try JSONDecoder().decode(BoneInferenceMessage.self, from: JSONSerialization.data(withJSONObject: invalid)))
        invalid["role"] = "user"; invalid["content"] = "two payloads"
        XCTAssertThrowsError(try JSONDecoder().decode(BoneInferenceMessage.self, from: JSONSerialization.data(withJSONObject: invalid)))
    }

    func testReferenceAndMetadataDecodeRevalidateHardLimits() throws {
        let reference = try image().reference
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(reference)) as? [String: Any])
        json["id"] = "../../private"
        XCTAssertThrowsError(try JSONDecoder().decode(BoneInferenceImageReference.self, from: JSONSerialization.data(withJSONObject: json)))
        XCTAssertThrowsError(try BoneInferenceImageMetadata(format: .png, width: Int.max, height: 1, byteCount: 1))
        XCTAssertThrowsError(try BoneInferenceImageMetadata(format: .png, width: 20_000, height: 20_000, byteCount: 1))
        XCTAssertThrowsError(try BoneInferenceMessage.user(content: []))
        XCTAssertThrowsError(try BoneInferenceMessage.user(content: [.text("")]))
        XCTAssertThrowsError(try BoneInferenceMessage.user(content: Array(repeating: .image(image()), count: 129)))
    }

    func testResolverRejectsReplacementMetadataAndRevocation() async throws {
        let value = try image()
        let metadata = value.reference.metadata
        let wrongHash = BoneInferenceImageResolver(inspect: { _ in metadata }, load: { _ in Data(repeating: 43, count: 64) })
        let wrongMetadata = BoneInferenceImageResolver(inspect: { _ in
            try .init(format: .png, width: 99, height: 100, byteCount: 64)
        }, load: { _ in Data(repeating: 42, count: 64) })
        for resolver in [wrongHash, wrongMetadata] {
            do { _ = try await resolver.resolve(value.reference); XCTFail("Reference changed") }
            catch { XCTAssertEqual(error as? BoneInferenceImageInputError, .referenceMismatch) }
        }
        let denied = BoneInferenceImageResolver(inspect: { _ in metadata }, load: { _ in throw VisionTestError.denied })
        do { _ = try await denied.resolve(value.reference); XCTFail("Must propagate host revocation") }
        catch { XCTAssertEqual(error as? VisionTestError, .denied) }
    }

    func testVisualTokensCountOccurrencesAndNotBase64Bytes() throws {
        let small = try image(bytes: 64)
        let large = try image(bytes: 9_000)
        let one = try request([small])
        let two = try request([small, small])
        let estimator: BoneInferenceImageTokenEstimator = { _ in 777 }
        let first = try BoneTokenEstimator.estimateRequestTokens(one, imageTokenEstimator: estimator)
        XCTAssertEqual(try BoneTokenEstimator.estimateRequestTokens(two, imageTokenEstimator: estimator) - first, 777 + 32)
        XCTAssertEqual(try BoneTokenEstimator.estimateRequestTokens(request([large]), imageTokenEstimator: estimator), first)
        XCTAssertGreaterThan(try request([large]).accountedInputBytes, try one.accountedInputBytes)
        XCTAssertEqual(try two.accountedInputBytes, try JSONEncoder().encode(two).count + small.base64ByteCount * 2)
    }

    func testEstimatorUsesFinalDimensionsAndDetail() throws {
        let small = try image(width: 100)
        let wide = try image(width: 1_000)
        let high = BoneInferenceImageInput(reference: small.reference, detail: .high)
        let estimator: BoneInferenceImageTokenEstimator = { $0.reference.metadata.width + ($0.detail == .high ? 200 : 0) }
        let base = try BoneTokenEstimator.estimateRequestTokens(request([small]), imageTokenEstimator: estimator)
        XCTAssertEqual(try BoneTokenEstimator.estimateRequestTokens(request([wide]), imageTokenEstimator: estimator) - base, 900)
        XCTAssertEqual(try BoneTokenEstimator.estimateRequestTokens(request([high]), imageTokenEstimator: estimator) - base, 200)
    }

    func testUnknownInvalidAndOverflowingVisualEstimatesFailClosed() throws {
        let request = try request([image()])
        XCTAssertEqual(BoneTokenEstimator.estimateMessages(request.messages), Int.max)
        XCTAssertThrowsError(try BoneTokenEstimator.estimateRequestTokens(request, imageTokenEstimator: nil)) {
            XCTAssertEqual($0 as? BoneInferenceImageInputError, .missingTokenEstimator)
        }
        for value in [0, -1, Int.max] {
            XCTAssertThrowsError(try BoneTokenEstimator.estimateRequestTokens(request, imageTokenEstimator: { _ in value }))
        }
        XCTAssertThrowsError(try profile(tokens: { _ in 0 }).estimatedTokens(for: image()))
    }

    func testToolSchemasContributeAndOutputProtocolSafetyReserveCapacity() throws {
        let input = try image()
        let plain = try request([input])
        let withSchema = try request([input], tools: [VisionContentTool.definition])
        XCTAssertGreaterThan(try BoneTokenEstimator.estimateRequestTokens(withSchema, imageTokenEstimator: { _ in 500 }),
                             try BoneTokenEstimator.estimateRequestTokens(plain, imageTokenEstimator: { _ in 500 }))
        // The complete request must fit after output, protocol and safety reserves.
        let loads = VisionLoadRecorder()
        let configured = try configuration(profile(tokens: { _ in 1_000 }), image: input, loads: loads)
        XCTAssertEqual(try configured.maximumOutputTokens(for: plain, budget: budget()), 200)
        let capacity = try budget().availableInputTokens(configuredOutputTokens: 200, preferredOutputTokens: nil,
                                                        protocolReserveTokens: 128, safetyMarginTokens: 100)
        XCTAssertEqual(capacity.availableInputTokens, 1_572)
    }

    func testPreflightRejectsCountBytesDetailAndTokensBeforeResolving() async throws {
        let input = try image()
        let high = BoneInferenceImageInput(reference: input.reference, detail: .high)
        let cases: [(BoneInferenceImageInputProfile, [BoneInferenceImageInput], BoneInferenceImageInputError)] = [
            (try profile(maximumImages: 1), [input, input], .tooManyImages),
            (try profile(maximumBytes: 32), [input], .imageBytesExceeded),
            (try profile(base64: 64), [input], .imageBytesExceeded),
            (try profile(body: 64), [input], .requestBytesExceeded),
            (try profile(), [high], .unsupportedDetail),
            (try profile(tokens: { _ in 1_600 }), [input], .inputTokensExceeded)
        ]
        for (profile, images, expected) in cases {
            let loads = VisionLoadRecorder()
            let configured = try configuration(profile, image: input, loads: loads)
            do { _ = try await configured.prepare(request(images), engineBudget: nil, supportsDetail: false); XCTFail("Preflight should fail") }
            catch { XCTAssertEqual(error as? BoneInferenceImageInputError, expected) }
            let count = await loads.references.count
            XCTAssertEqual(count, 0)
        }
    }

    func testDuplicateReferencesLoadOnceButConsumeBudgetTwice() async throws {
        let input = try image()
        let loads = VisionLoadRecorder()
        let configured = try configuration(profile(), image: input, loads: loads)
        let prepared = try await configured.prepare(request([input, input]), engineBudget: nil, supportsDetail: true)
        XCTAssertEqual(prepared.count, 1)
        let count = await loads.references.count
        XCTAssertEqual(count, 1)
        do { _ = try await configured.prepare(request([input, input, input, input]), engineBudget: nil, supportsDetail: true); XCTFail("All occurrences count") }
        catch { XCTAssertEqual(error as? BoneInferenceImageInputError, .inputTokensExceeded) }
        let finalCount = await loads.references.count
        XCTAssertEqual(finalCount, 1)
    }

    func testExactModelRequiredAndBodyLimitValidated() async throws {
        let input = try image()
        let loads = VisionLoadRecorder()
        let configured = try configuration(profile(body: 512), image: input, loads: loads)
        let unknown = BoneInferenceRequest(modelID: "vision-alias", messages: try request([input]).messages)
        do { _ = try await configured.prepare(unknown, engineBudget: nil, supportsDetail: true); XCTFail("No model-name inference") }
        catch { XCTAssertEqual(error as? BoneInferenceError, .unsupportedCapability(.imageInput)) }
        XCTAssertThrowsError(try configured.validateBody(Data(count: 513), for: request([input])))
        let count = await loads.references.count
        XCTAssertEqual(count, 0)
    }

    func testImageTokensTriggerCompactionAndKeepCurrentImage() async throws {
        let old = try image("old", width: 900)
        let current = try image("current", width: 500)
        let engine = try VisionBudgetEngine(budget: budget(), margin: 100)
        let policy = try BoneContextManagementConfiguration(protocolReserveTokens: 0, safetyMarginTokens: 0)
        let messages: [BoneInferenceMessage] = [try .user(content: [.image(old)]), .init(role: .assistant, content: "old observation"),
                                                try .user(content: [.text("current"), .image(current)])]
        var session = BoneContextSession()
        let prepared = try await session.prepare(request: .init(modelID: "vision", messages: messages,
            generationOptions: .init(maximumOutputTokens: 200)), engine: engine, policy: policy, meter: nil, clock: { 0 })
        XCTAssertEqual(prepared.history, [messages[2]])
        XCTAssertEqual(prepared.receipt?.removedTurnCount, 1)
        XCTAssertGreaterThan(prepared.receipt?.estimatedRequestTokenReduction ?? 0, 900)
        XCTAssertEqual(prepared.request.imageInputs, [current])
        XCTAssertEqual(session.revision, 1)
    }

    func testProtectedImagesOverflowWithoutSendingOrChangingSession() async throws {
        let engine = try VisionBudgetEngine(budget: budget(), margin: 100)
        let policy = try BoneContextManagementConfiguration(protocolReserveTokens: 0, safetyMarginTokens: 0)
        var session = BoneContextSession()
        do {
            _ = try await session.prepare(request: request([image(width: 1_600)]), engine: engine, policy: policy, meter: nil, clock: { 0 })
            XCTFail("Protected current image cannot be dropped")
        } catch {
            guard case .mandatoryMessagesExceedBudget = error as? BoneContextCompactionError else { return XCTFail("Unexpected \(error)") }
        }
        XCTAssertEqual(session.revision, 0)
        let requests = await engine.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testMultimodalToolResultIsNeverClampedAndOldPairCanBeRemoved() async throws {
        let old = try image("old", width: 1_200)
        let current = try image("current", width: 400)
        let call = BoneInferenceToolCall(id: "call", toolID: "vision.image", arguments: Data("{}".utf8))
        let result = try BoneInferenceToolResult(callID: call.id, toolID: call.toolID,
            content: .multimodal([.text("caption"), .image(old)]), isError: false, ordinal: 0)
        let messages: [BoneInferenceMessage] = [.init(role: .user, content: "old task"),
            .assistant(try .init(content: [.toolCall(call)])), .toolResult(result), .init(role: .assistant, content: "done"),
            try .user(content: [.image(current)])]
        let clamped = try BoneContextCompactor.clampToolResults(in: messages, policy: { _ in .clamp(maximumBytes: 32) })
        XCTAssertEqual(clamped.messages, messages)
        XCTAssertEqual(clamped.clampedToolResultCount, 0)
        let compacted = try BoneContextCompactor.compact(messages: messages, budget: budget(), configuredOutputTokens: 200,
            protocolReserveTokens: 128, safetyMarginTokens: 100, imageTokenEstimator: { $0.reference.metadata.width })
        XCTAssertEqual(compacted.messages, [messages[4]])
        XCTAssertNoThrow(try BoneContextTurn.split(compacted.messages))
    }

    func testSessionRefusesImageWithoutModelEstimatorEvenWithTextCounter() async throws {
        var session = BoneContextSession()
        let budget = try budget()
        let policy = try BoneContextManagementConfiguration(budgetProvider: { _ in budget })
        do {
            _ = try await session.prepare(request: request([image()]), engine: VisionTextOnlyCounter(), policy: policy, meter: nil, clock: { 0 })
            XCTFail("Text counter cannot make image cost zero")
        } catch { XCTAssertEqual(error as? BoneInferenceImageInputError, .missingTokenEstimator) }
    }

    func testSummaryIsExplicitlyTextOnlyAndDoesNotPretendToSeePixels() throws {
        let original = try request([image()])
        let summary = try BoneContextSummaryCodec.request(modelID: "text-summary", messages: original.messages, previous: nil, maximumOutputTokens: 200)
        XCTAssertTrue(summary.imageInputs.isEmpty)
        XCTAssertTrue(summary.messages[0].content?.contains("no image pixels") == true)
        XCTAssertFalse(summary.messages[1].content?.contains("data:image") == true)
    }

    func testAgentContentToolFeedsNativeImageResultInLegacyAndBatchedPaths() async throws {
        let input = try image()
        for legacy in [true, false] {
            let call = BoneInferenceToolCall(id: "call", toolID: VisionContentTool.definition.id, arguments: Data("{}".utf8))
            let first: BoneInferenceResponse = legacy ? .toolCall(call) : .assistantTurn(turn: try .init(content: [.toolCall(call)]),
                finishReason: .toolCalls, usage: nil, refusal: nil, providerContinuation: nil)
            let engine = try VisionBudgetEngine(budget: budget(8_000), script: [first, .init(text: "attachment accepted")])
            let agent = try BoneAgentBuilder(inferenceEngine: engine).withTool(VisionContentTool(image: input)).build()
            let completed = try await agent.run(modelID: "vision", messages: [.init(role: .user, content: "read image")])
            XCTAssertEqual(completed.output, .text("attachment accepted"))
            let requests = await engine.requests
            XCTAssertEqual(requests.count, 2)
            XCTAssertEqual(requests[1].imageInputs, [input])
            let result = try XCTUnwrap(requests[1].messages.last).requiredToolResults().results[0]
            XCTAssertEqual(result.content, .multimodal([.text("fixture"), .image(input)]))
            XCTAssertEqual(result.callID, "call")
        }
    }

    func testOrdinaryJSONToolIsNotInterpretedAsContentEnvelope() async throws {
        let input = try image()
        let registry = try BoneAgentToolRegistry(tools: [BoneAnyAgentTool(VisionJSONTool(image: input))])
        let output = try await registry.executeContent(id: VisionJSONTool.definition.id, input: Data("{}".utf8), context: BoneAgentEmptyContext())
        guard case .json = output else { return XCTFail("Ordinary tool Output stays JSON") }
        XCTAssertTrue(output.imageInputs.isEmpty)
    }

    func testConversationPersistsReferencesAndRestoresNextTurn() async throws {
        let input = try image(bytes: 512)
        let engine = try VisionBudgetEngine(budget: budget(8_000), script: [.init(text: "first"), .init(text: "second")])
        let agent = try BoneAgentBuilder(inferenceEngine: engine).build()
        let conversation = try await agent.makeConversation(modelID: "vision", bindingID: "fixture")
        _ = try await conversation.send(content: [.text("inspect"), .image(input)])
        let data = try await conversation.exportPrivateState()
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(Data(repeating: 42, count: 512).base64EncodedString()))
        let id = await conversation.id
        let restored = try await agent.restoreConversation(privateState: data, modelID: "vision", bindingID: "fixture", expectedID: id, expectedRevision: 1)
        _ = try await restored.send("follow up")
        let requests = await engine.requests
        XCTAssertEqual(requests.last?.imageInputs, [input])
        let revision = await restored.revision
        XCTAssertEqual(revision, 2)
    }

    func testAgentRunByteBudgetIncludesBase64OccurrencesBeforeInference() async throws {
        let input = try image(bytes: 9_000)
        let engine = try VisionBudgetEngine(budget: budget(8_000))
        let runBudget = try BoneRunBudget(maximumInferenceCalls: 1, maximumToolCalls: 1,
            maximumInputBytes: 5_000, maximumOutputBytes: 1_000, maximumTurns: 1,
            maximumWallClockSeconds: 60, maximumConcurrentToolCalls: 1, maximumEstimatedCostMicrounits: 0)
        let agent = try BoneAgentBuilder(inferenceEngine: engine).withConfiguration(
            .init(maximumSteps: 1, runBudget: runBudget, inferenceCostEstimator: { _ in 0 })).build()
        do { _ = try await agent.run(request: request([input])); XCTFail("Base64 exceeds byte budget") }
        catch { XCTAssertEqual(error as? BoneAgentError, .budgetExceeded) }
        let requests = await engine.requests
        XCTAssertTrue(requests.isEmpty)
    }


    func testDirectPlannerDropsWholeImageTurnAndPreservesToolPairs() throws {
        let call = BoneInferenceToolCall(id: "c", toolID: "tool", arguments: Data("{}".utf8))
        let history: [BoneInferenceMessage] = [try .user(content: [.image(image("old", width: 1_200))]),
            .assistant(try .init(content: [.toolCall(call)])),
            .toolResult(try .init(callID: "c", toolID: "tool", content: .text("result"), isError: false, ordinal: 0))]
        let mandatory = try BoneInferenceMessage.user(content: [.image(image("current", width: 500))])
        let plan = try BoneContextWindowPlanner.plan(mandatoryMessages: [mandatory], history: history,
            budget: budget(), configuredOutputTokens: 200, preferredOutputTokens: nil,
            protocolReserveTokens: 128, safetyMarginTokens: 100, imageTokenEstimator: { $0.reference.metadata.width })
        XCTAssertEqual(plan.messages, [mandatory])
        XCTAssertEqual(plan.removedHistoryMessageCount, 3)
        XCTAssertNoThrow(try BoneContextTurn.split(plan.messages))
    }

    func testToolAssociationReserveCoversRepeatedLongIdentifiersAndWireLabels() throws {
        let result = try BoneInferenceToolResult(callID: String(repeating: "c", count: 1_000),
            toolID: String(repeating: "t", count: 128), content: .multimodal([.image(image())]), isError: true, ordinal: 0)
        let count = try BoneTokenEstimator.estimateMessage(.toolResult(result), imageTokenEstimator: { _ in 100 })
        let sourceText = BoneProviderImageWire.toolText(result) + "\n" +
            BoneProviderImageWire.attachmentLabel(result, imageIndex: 0, toolName: String(repeating: "w", count: 64))
        XCTAssertGreaterThan(count, 100 + BoneTokenEstimator.estimateText(sourceText))
    }
}

private enum VisionTestError: Error, Equatable { case denied, exhausted }
private actor VisionLoadRecorder {
    var references: [BoneInferenceImageReference] = []
    func record(_ reference: BoneInferenceImageReference) { references.append(reference) }
}
private actor VisionBudgetEngine: BoneInferenceEngine, BoneInferenceContextBudgetProviding, BoneInferenceImageTokenProviding {
    nonisolated let nonImageCapabilities: Set<BoneInferenceCapability> = [.text, .toolCalling, .imageInput]
    nonisolated let imageGenerator: (any BoneInferenceImageGenerating)? = nil
    nonisolated let budget: BoneContextWindowBudget
    nonisolated let margin: Int
    var script: [BoneInferenceResponse]
    var requests: [BoneInferenceRequest] = []
    init(budget: BoneContextWindowBudget, margin: Int = 0, script: [BoneInferenceResponse] = [.init(text: "done")]) throws {
        self.budget = budget; self.margin = margin; self.script = script
    }
    nonisolated func contextBudget(for modelID: String) throws -> BoneContextWindowBudget? { budget }
    nonisolated func imageTokens(for image: BoneInferenceImageInput, modelID: String) throws -> Int { image.reference.metadata.width }
    nonisolated func imageInputSafetyMarginTokens(for modelID: String) throws -> Int { margin }
    func infer(request: BoneInferenceRequest) async throws -> BoneInferenceResponse {
        requests.append(request)
        guard !script.isEmpty else { throw VisionTestError.exhausted }
        return script.removeFirst()
    }
}
private struct VisionTextOnlyCounter: BoneInferenceEngine, BoneInferenceContextTokenCounting {
    let nonImageCapabilities: Set<BoneInferenceCapability> = [.text, .imageInput]
    let imageGenerator: (any BoneInferenceImageGenerating)? = nil
    func countContextTokens(request: BoneInferenceRequest) async throws -> Int { 0 }
    func infer(request: BoneInferenceRequest) async throws -> BoneInferenceResponse { .init(text: "unused") }
}
private struct VisionEmptyInput: Codable, Sendable {}
private struct VisionContentTool: BoneAgentContentTool {
    typealias Input = VisionEmptyInput
    typealias Context = BoneAgentEmptyContext
    let image: BoneInferenceImageInput
    static var definition: BoneAgentToolDefinition {
        .init(id: "vision.image", version: "1", title: "Fixture image", summary: "Read a synthetic public fixture",
              wireName: "vision_image", schemaVersion: 1, inputSchema: .object(properties: [:], required: [], additionalProperties: false),
              impact: .ordinaryPublicRead)
    }
    func execute(input: Input, context: Context) async throws -> BoneToolResultContent { .multimodal([.text("fixture"), .image(image)]) }
}
private struct VisionJSONTool: BoneAgentTool {
    typealias Input = VisionEmptyInput
    typealias Context = BoneAgentEmptyContext
    typealias Output = BoneToolResultContent
    let image: BoneInferenceImageInput
    static var definition: BoneAgentToolDefinition { VisionContentTool.definition }
    func execute(input: Input, context: Context) async throws -> Output { .multimodal([.image(image)]) }
}
