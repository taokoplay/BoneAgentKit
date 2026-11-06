import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import BoneAgentKit

final class VisionProviderTests: XCTestCase {
    // These three-byte fixtures exercise trusted resolver/inspector wiring, not real image decoding.
    // Real codec validation belongs to the ImageIO tests.
    func testUserImageBodiesAndReservedOutputAcrossEveryInvocation() async throws {
        let fixture = try VisionFixture()
        XCTAssertEqual(fixture.image.reference.sha256, "039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81")
        for provider in VisionProvider.allCases {
            for invocation in VisionInvocation.allCases {
                let transport = VisionTransport(provider: provider)
                let loader = VisionLoader(fixtures: [fixture])
                let engine = provider.engine(transport, images: try configuration(loader, fixtures: [fixture]))
                let request = try imageRequest(fixture.image)
                XCTAssertFalse(engine.nonImageCapabilities.contains(.imageInput))
                XCTAssertTrue(try engine.resolvedCapabilities(for: request, invocation: .nonStreaming).capabilities.contains(.imageInput))
                try await invocation.invoke(engine, request)
                let bodies = await transport.bodies
                XCTAssertEqual(bodies.count, 1)
                let body = try object(XCTUnwrap(bodies.first))
                let rows = try XCTUnwrap(body[provider == .gemini ? "contents" : "messages"] as? [[String: Any]])
                let parts = try XCTUnwrap(rows[0][provider == .gemini ? "parts" : "content"] as? [[String: Any]])
                XCTAssertEqual(parts.count, 3)
                XCTAssertEqual(parts[0]["text"] as? String, "before")
                XCTAssertEqual(parts[2]["text"] as? String, "after")
                try assertImage(parts[1], provider: provider, fixture: fixture)
                XCTAssertEqual(outputTokens(body, provider), 128)
                let count = await loader.count
                XCTAssertEqual(count, 1)
            }
        }
    }

    func testOpenAIDetailAndOtherProvidersRejectDetailBeforeResolving() async throws {
        let fixture = try VisionFixture()
        for detail in [BoneInferenceImageDetail.automatic, .low, .high] {
            let image = BoneInferenceImageInput(reference: fixture.image.reference, detail: detail)
            let transport = VisionTransport(provider: .openAI)
            let loader = VisionLoader(fixtures: [fixture])
            let engine = VisionProvider.openAI.engine(transport, images: try configuration(loader, fixtures: [fixture]))
            _ = try await engine.infer(request: imageRequest(image))
            let bodies = await transport.bodies
            let body = try object(XCTUnwrap(bodies.first))
            let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
            let parts = try XCTUnwrap(messages[0]["content"] as? [[String: Any]])
            XCTAssertEqual((parts[1]["image_url"] as? [String: String])?["detail"], detail == .automatic ? "auto" : detail.rawValue)
            if detail == .automatic { continue }
            for provider in [VisionProvider.anthropic, .gemini] {
                let deniedTransport = VisionTransport(provider: provider)
                let deniedLoader = VisionLoader(fixtures: [fixture])
                let deniedEngine = provider.engine(deniedTransport, images: try configuration(deniedLoader, fixtures: [fixture]))
                await expectImageError(.unsupportedDetail) { _ = try await deniedEngine.infer(request: self.imageRequest(image)) }
                await assertCounts(deniedLoader, deniedTransport, loads: 0, sends: 0)
            }
        }
    }

    func testToolImageBatchesPreserveCallOrderAssociationAndErrorOrigin() async throws {
        let first = try VisionFixture(id: "first")
        let second = try VisionFixture(id: "second", data: Data([4, 5, 6]))
        let results = try toolResults(first: [.text("first text"), .image(first.image), .text("between"), .image(second.image)],
                                      second: [.image(second.image), .text("failed text")])
        for provider in VisionProvider.allCases {
            let transport = VisionTransport(provider: provider)
            let loader = VisionLoader(fixtures: [first, second])
            let engine = provider.engine(transport, images: try configuration(loader, fixtures: [first, second]))
            _ = try await engine.infer(request: toolRequest(results))
            let bodies = await transport.bodies
            let body = try object(XCTUnwrap(bodies.first))
            let rows = try XCTUnwrap(body[provider == .gemini ? "contents" : "messages"] as? [[String: Any]])
            switch provider {
            case .openAI:
                XCTAssertEqual(rows.compactMap { $0["role"] as? String }, ["user", "assistant", "tool", "tool", "user"])
                XCTAssertEqual(rows[2]["tool_call_id"] as? String, "call-a")
                XCTAssertEqual(rows[3]["tool_call_id"] as? String, "call-b")
                let text = try XCTUnwrap(rows[2]["content"] as? String)
                XCTAssertTrue(text.contains("first text"))
                XCTAssertTrue(text.contains("between"))
                XCTAssertTrue(text.contains("call-a"))
                XCTAssertFalse(text.contains("base64"))
                let parts = try XCTUnwrap(rows[4]["content"] as? [[String: Any]])
                XCTAssertEqual(parts.count, 6)
                try assertToolAttachmentParts(parts, provider: provider, first: first, second: second)
            case .anthropic:
                XCTAssertEqual(rows.compactMap { $0["role"] as? String }, ["user", "assistant", "user"])
                let blocks = try XCTUnwrap(rows[2]["content"] as? [[String: Any]])
                XCTAssertEqual(blocks.compactMap { $0["tool_use_id"] as? String }, ["call-a", "call-b"])
                XCTAssertEqual(blocks[1]["is_error"] as? Bool, true)
                let firstParts = try XCTUnwrap(blocks[0]["content"] as? [[String: Any]])
                XCTAssertEqual(firstParts.compactMap { $0["type"] as? String }, ["text", "image", "text", "image"])
                try assertImage(firstParts[1], provider: provider, fixture: first)
                try assertImage(firstParts[3], provider: provider, fixture: second)
                let errorParts = try XCTUnwrap(blocks[1]["content"] as? [[String: Any]])
                try assertImage(errorParts[0], provider: provider, fixture: second)
                XCTAssertEqual(errorParts[1]["text"] as? String, "failed text")
            case .gemini:
                XCTAssertEqual(rows.compactMap { $0["role"] as? String }, ["user", "model", "user"])
                let parts = try XCTUnwrap(rows[2]["parts"] as? [[String: Any]])
                XCTAssertEqual(parts.count, 8)
                let responses = parts.prefix(2).compactMap { $0["functionResponse"] as? [String: Any] }
                XCTAssertEqual(responses.compactMap { $0["id"] as? String }, ["call-a", "call-b"])
                XCTAssertEqual(responses.compactMap { $0["name"] as? String }, ["inspect_a", "inspect_b"])
                XCTAssertNil(responses[0]["parts"])
                XCTAssertEqual((responses[1]["response"] as? [String: Any])?["isError"] as? Bool, true)
                XCTAssertTrue(((responses[0]["response"] as? [String: Any])?["text"] as? String)?.contains("between") == true)
                try assertToolAttachmentParts(Array(parts.dropFirst(2)), provider: provider, first: first, second: second)
            }
            // The repeated second reference is resolved once, but is sent and budgeted twice.
            await assertCounts(loader, transport, loads: 2, sends: 1)
        }
    }

    func testTextOnlyMultimodalNeedsNoImageProfile() async throws {
        let results = try toolResults(first: [.text("alpha"), .text("beta")], second: [.text("failed")])
        for provider in VisionProvider.allCases {
            let transport = VisionTransport(provider: provider)
            let engine = provider.engine(transport)
            var history = try toolRequest(results).messages
            history[0] = try .user(content: [.text("before"), .text("after")])
            let request = BoneInferenceRequest(modelID: "model", messages: history, availableTools: tools)
            XCTAssertTrue(request.imageInputs.isEmpty)
            _ = try await engine.infer(request: request)
            let bodies = await transport.bodies
            let body = try object(XCTUnwrap(bodies.first))
            let rows = try XCTUnwrap(body[provider == .gemini ? "contents" : "messages"] as? [[String: Any]])
            switch provider {
            case .openAI:
                XCTAssertEqual(rows.count, 4)
                XCTAssertEqual(rows[2]["content"] as? String, "alpha\nbeta")
                XCTAssertNil(outputTokens(body, provider))
            case .anthropic:
                let blocks = try XCTUnwrap(rows[2]["content"] as? [[String: Any]])
                let parts = try XCTUnwrap(blocks[0]["content"] as? [[String: Any]])
                XCTAssertEqual(parts.compactMap { $0["text"] as? String }, ["alpha", "beta"])
                XCTAssertEqual(outputTokens(body, provider), 4096)
            case .gemini:
                let parts = try XCTUnwrap(rows[2]["parts"] as? [[String: Any]])
                XCTAssertEqual(parts.count, 2)
                let response = try XCTUnwrap(parts[0]["functionResponse"] as? [String: Any])
                XCTAssertEqual((response["response"] as? [String: Any])?["text"] as? String, "alpha\nbeta")
                XCTAssertNil(outputTokens(body, provider))
            }
        }
    }

    func testCapabilityGatesRejectBeforeResolverAndTransportInEveryInvocation() async throws {
        let fixture = try VisionFixture()
        let textOnly = BoneModelMetadata(provenance: .init(source: .host, providerID: "fixture", retrievedAt: "2026-01-01",
            sourceURL: URL(string: "https://fixture.invalid")!),
            declaration: .init(id: "model", modalities: .init(input: ["text"], output: ["text"])))
        let restricted = try BoneModelCapabilityProfile(capabilities: [.text, .toolCalling, .streaming], source: .hostVerified, verifiedAt: "2026-01-01")
        for provider in VisionProvider.allCases {
            for deniedCase in 0..<4 {
                let transport = VisionTransport(provider: provider)
                let loader = VisionLoader(fixtures: [fixture])
                let config = try configuration(loader, fixtures: [fixture])
                let engine = provider.engine(transport, images: deniedCase == 0 ? nil : config,
                    metadata: deniedCase == 2 ? ["model": textOnly] : [:],
                    capabilities: deniedCase == 3 ? ["model": restricted] : [:])
                let request = try imageRequest(fixture.image, model: deniedCase == 1 ? "unknown-vision-model" : "model")
                XCTAssertFalse(try engine.resolvedCapabilities(for: request, invocation: .nonStreaming).capabilities.contains(.imageInput))
                for invocation in VisionInvocation.allCases {
                    do { try await invocation.invoke(engine, request); XCTFail("Expected image capability rejection") }
                    catch { XCTAssertEqual(error as? BoneInferenceError, .unsupportedCapability(.imageInput)) }
                }
                if deniedCase <= 1 {
                    XCTAssertThrowsError(try engine.imageTokens(for: fixture.image, modelID: request.modelID)) {
                        XCTAssertEqual($0 as? BoneInferenceError, .unsupportedCapability(.imageInput))
                    }
                }
                await assertCounts(loader, transport, loads: 0, sends: 0)
            }
        }
    }

    func testExpiredHashDimensionsAndLengthMismatchNeverSend() async throws {
        let fixture = try VisionFixture()
        for provider in VisionProvider.allCases {
            for failure in 0..<4 {
                let transport = VisionTransport(provider: provider)
                let loader = VisionLoader(fixtures: [fixture], expired: failure == 0)
                let original = fixture.image.reference
                let metadata = try BoneInferenceImageMetadata(format: .png, width: failure == 2 ? 9 : 2, height: 3,
                    byteCount: failure == 3 ? 4 : 3)
                let reference = try BoneInferenceImageReference(id: original.id, version: original.version,
                    sha256: failure == 1 ? String(repeating: "0", count: 64) : original.sha256, metadata: metadata)
                let engine = provider.engine(transport, images: try configuration(loader, fixtures: [fixture]))
                do { _ = try await engine.infer(request: imageRequest(.init(reference: reference))); XCTFail("Expected resolver rejection") }
                catch {
                    if failure == 0 { XCTAssertEqual(error as? VisionFixtureError, .expired) }
                    else { XCTAssertEqual(error as? BoneInferenceImageInputError, .referenceMismatch) }
                }
                await assertCounts(loader, transport, loads: 1, sends: 0)
            }
        }
    }

    func testImageCountByteAndEstimatorLimitsRejectBeforeResolver() async throws {
        let fixture = try VisionFixture()
        for provider in VisionProvider.allCases {
            for failure in 0..<4 {
                let transport = VisionTransport(provider: provider)
                let loader = VisionLoader(fixtures: [fixture])
                let policy = try profile(images: failure == 0 ? 1 : 20, imageBytes: failure == 1 ? 2 : 1024,
                    base64Bytes: failure == 2 ? 7 : 4096, visualTokens: failure == 3 ? 0 : 64)
                let engine = provider.engine(transport, images: try configuration(loader, fixtures: [fixture], profile: policy))
                let request = BoneInferenceRequest(modelID: "model", messages: [try .user(content: [.image(fixture.image), .image(fixture.image)])])
                let expected: BoneInferenceImageInputError = failure == 0 ? .tooManyImages : failure == 3 ? .invalidTokenEstimate : .imageBytesExceeded
                await expectImageError(expected) { _ = try await engine.infer(request: request) }
                await assertCounts(loader, transport, loads: 0, sends: 0)
            }
        }
    }

    func testAggregateEncodedBodyLimitIncludesAllImageOccurrences() async throws {
        let fixture = try VisionFixture()
        for provider in VisionProvider.allCases {
            let baselineTransport = VisionTransport(provider: provider)
            let baselineLoader = VisionLoader(fixtures: [fixture])
            let baseline = provider.engine(baselineTransport, images: try configuration(baselineLoader, fixtures: [fixture]))
            _ = try await baseline.infer(request: imageRequest(fixture.image))
            let bodies = await baselineTransport.bodies
            let singleBodyBytes = try XCTUnwrap(bodies.first).count
            let transport = VisionTransport(provider: provider)
            let loader = VisionLoader(fixtures: [fixture])
            let policy = try profile(bodyBytes: singleBodyBytes)
            let engine = provider.engine(transport, images: try configuration(loader, fixtures: [fixture], profile: policy))
            let request = BoneInferenceRequest(modelID: "model", messages: [try .user(content: [
                .text("before"), .image(fixture.image), .image(fixture.image), .text("after")])])
            for invocation in VisionInvocation.allCases {
                await expectImageError(.requestBytesExceeded) { try await invocation.invoke(engine, request) }
            }
            await assertCounts(loader, transport, loads: VisionInvocation.allCases.count, sends: 0)
        }
    }

    func testCompleteTokenBudgetRejectsOneTokenOverAndAcceptsBoundary() async throws {
        let fixture = try VisionFixture()
        let request = try imageRequest(fixture.image)
        let budget = try BoneContextWindowBudget(contextWindowTokens: 512, maximumOutputTokens: 64, source: .host)
        let capacity = try budget.availableInputTokens(configuredOutputTokens: 64, preferredOutputTokens: nil,
            protocolReserveTokens: 128, safetyMarginTokens: 16).availableInputTokens
        let base = try BoneTokenEstimator.estimateRequestTokens(request, imageTokenEstimator: { _ in 1 })
        let boundaryVisualTokens = capacity - base + 1
        XCTAssertGreaterThan(boundaryVisualTokens, 0)
        for provider in VisionProvider.allCases {
            for overflow in [true, false] {
                let transport = VisionTransport(provider: provider)
                let loader = VisionLoader(fixtures: [fixture])
                let policy = try profile(window: 512, output: 64, visualTokens: boundaryVisualTokens + (overflow ? 1 : 0))
                let engine = provider.engine(transport, images: try configuration(loader, fixtures: [fixture], profile: policy))
                XCTAssertEqual(try engine.imageTokens(for: fixture.image, modelID: "model"), boundaryVisualTokens + (overflow ? 1 : 0))
                if overflow {
                    for invocation in VisionInvocation.allCases {
                        await expectImageError(.inputTokensExceeded) { try await invocation.invoke(engine, request) }
                    }
                    await assertCounts(loader, transport, loads: 0, sends: 0)
                } else {
                    _ = try await engine.infer(request: request)
                    let bodies = await transport.bodies
                    XCTAssertEqual(outputTokens(try object(XCTUnwrap(bodies.first)), provider), 64)
                    await assertCounts(loader, transport, loads: 1, sends: 1)
                }
            }
        }
    }

    func testTextAndRequestedOutputParticipateInImageBudget() async throws {
        let fixture = try VisionFixture()
        for provider in VisionProvider.allCases {
            let transport = VisionTransport(provider: provider)
            let loader = VisionLoader(fixtures: [fixture])
            let policy = try profile(window: 512, output: 64)
            let engine = provider.engine(transport, images: try configuration(loader, fixtures: [fixture], profile: policy))
            let tooMuchText = BoneInferenceRequest(modelID: "model", messages: [try .user(content: [
                .text(String(repeating: "x", count: 2000)), .image(fixture.image)])])
            await expectImageError(.inputTokensExceeded) { _ = try await engine.infer(request: tooMuchText) }
            let tooMuchOutput = BoneInferenceRequest(modelID: "model", messages: try imageRequest(fixture.image).messages,
                generationOptions: .init(maximumOutputTokens: 65))
            do { _ = try await engine.infer(request: tooMuchOutput); XCTFail("Expected output rejection") }
            catch { XCTAssertEqual(error as? BoneInferenceError, .invalidGenerationOptions) }
            await assertCounts(loader, transport, loads: 0, sends: 0)
        }
    }

    func testImageBudgetIntersectsExistingModelLimits() async throws {
        let fixture = try VisionFixture()
        let limits = try BoneModelContextLimits(contextWindowTokens: 512, maximumInputTokens: 300, maximumOutputTokens: 64,
            source: .official, verifiedAt: "2026-01-01", documentationURL: URL(string: "https://fixture.invalid")!)
        for provider in VisionProvider.allCases {
            let transport = VisionTransport(provider: provider)
            let loader = VisionLoader(fixtures: [fixture])
            let engine = provider.engine(transport, images: try configuration(loader, fixtures: [fixture]), limits: ["model": limits, "text-model": limits])
            let budget = try XCTUnwrap(engine.contextBudget(for: "model"))
            XCTAssertEqual(budget.contextWindowTokens, 512)
            XCTAssertEqual(budget.maximumInputTokens, 300)
            XCTAssertEqual(budget.maximumOutputTokens, 64)
            XCTAssertEqual(try engine.contextBudget(for: "text-model"), limits.contextWindowBudget)
            XCTAssertNil(try engine.contextBudget(for: "unknown"))
            _ = try await engine.infer(request: imageRequest(fixture.image))
            let bodies = await transport.bodies
            XCTAssertEqual(outputTokens(try object(XCTUnwrap(bodies.first)), provider), 64)
        }
    }

    func testCancellationBeforeAndDuringResolutionNeverSends() async throws {
        let fixture = try VisionFixture()
        for provider in VisionProvider.allCases {
            for before in [true, false] {
                let transport = VisionTransport(provider: provider)
                let loader = VisionLoader(fixtures: [fixture], cancel: !before)
                let engine = provider.engine(transport, images: try configuration(loader, fixtures: [fixture]))
                let request = try imageRequest(fixture.image)
                let task = Task {
                    if before { withUnsafeCurrentTask { $0?.cancel() } }
                    return try await engine.infer(request: request)
                }
                do { _ = try await task.value; XCTFail("Expected cancellation") }
                catch { XCTAssertTrue(error is CancellationError) }
                await assertCounts(loader, transport, loads: before ? 0 : 1, sends: 0)
            }
        }
    }

    func testOpenAIThinkingContinuationSkipsAddedToolImageRow() async throws {
        let fixture = try VisionFixture()
        let transport = VisionTransport(provider: .openAI, responses: [
            #"{"choices":[{"message":{"content":"checking","reasoning_content":"before-image","tool_calls":[{"id":"call-a","type":"function","function":{"name":"inspect_a","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}"#,
            #"{"choices":[{"message":{"content":"answer","reasoning_content":"after-image"},"finish_reason":"stop"}]}"#,
        ])
        let loader = VisionLoader(fixtures: [fixture])
        let engine = VisionProvider.openAI.engine(transport, images: try configuration(loader, fixtures: [fixture]),
            reasoning: ["model": .init(wireFormat: .thinkingType, continuation: .reasoningContent)])
        let initial = try BoneInferenceRequest(modelID: "model", messages: [.user(content: [.image(fixture.image)])], availableTools: tools)
        let first = try await engine.infer(request: initial)
        let result = try BoneInferenceToolResult(callID: "call-a", toolID: "tool-a", content: .multimodal([.image(fixture.image)]), isError: false, ordinal: 0)
        let history = initial.messages + [.assistant(try XCTUnwrap(first.terminalAssistantTurn)), .toolResult(result)]
        let second = try await engine.infer(request: .init(modelID: "model", messages: history, availableTools: tools,
            providerContinuation: continuation(first)))
        _ = try await engine.infer(request: .init(modelID: "model", messages: history + [
            .assistant(try XCTUnwrap(second.terminalAssistantTurn)), .init(role: .user, content: "next")],
            availableTools: tools, providerContinuation: continuation(second)))
        let bodies = await transport.bodies
        let body = try object(XCTUnwrap(bodies.last))
        let rows = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(rows.compactMap { $0["role"] as? String }, ["user", "assistant", "tool", "user", "assistant", "user"])
        XCTAssertEqual(rows[1]["reasoning_content"] as? String, "before-image")
        XCTAssertNil(rows[3]["reasoning_content"])
        XCTAssertEqual(rows[4]["reasoning_content"] as? String, "after-image")
    }

    func testOpenAICollectsImagesAfterConsecutiveSingleToolResponses() async throws {
        let fixture = try VisionFixture()
        let batch = try toolResults(first: [.image(fixture.image)], second: [.text("second result")])
        let original = try toolRequest(batch)
        let singleResults = try batch.results.map {
            BoneInferenceMessage.toolResult(try .init(callID: $0.callID, toolID: $0.toolID,
                content: $0.content, isError: $0.isError, ordinal: 0))
        }
        let transport = VisionTransport(provider: .openAI)
        let loader = VisionLoader(fixtures: [fixture])
        let engine = VisionProvider.openAI.engine(transport, images: try configuration(loader, fixtures: [fixture]))
        let fullHistory = Array(original.messages.prefix(2)) + singleResults
        let plan = try BoneContextWindowPlanner.plan(mandatoryMessages: [], history: fullHistory,
            budget: .init(contextWindowTokens: 8_192, maximumOutputTokens: 128, source: .host),
            configuredOutputTokens: 128, preferredOutputTokens: nil, imageTokenEstimator: { _ in 64 })
        XCTAssertEqual(plan.messages, fullHistory)
        XCTAssertThrowsError(try BoneContextTurn.split(Array(fullHistory.dropLast())))
        _ = try await engine.infer(request: .init(modelID: "model", messages: Array(original.messages.prefix(2)) + singleResults,
            availableTools: tools))
        let bodies = await transport.bodies
        let rows = try XCTUnwrap(object(XCTUnwrap(bodies.first))["messages"] as? [[String: Any]])
        XCTAssertEqual(rows.compactMap { $0["role"] as? String }, ["user", "assistant", "tool", "tool", "user"])
    }

    func testGeminiSignedContinuationKeepsOriginalMessageIndicesWithToolImages() async throws {
        let fixture = try VisionFixture()
        let transport = VisionTransport(provider: .gemini, responses: [
            #"{"candidates":[{"content":{"parts":[{"functionCall":{"id":"call-a","name":"inspect_a","args":{}},"thoughtSignature":"before-image"}]},"finishReason":"STOP"}]}"#,
            #"{"candidates":[{"content":{"parts":[{"text":"answer","thoughtSignature":"after-image"}]},"finishReason":"STOP"}]}"#,
        ])
        let loader = VisionLoader(fixtures: [fixture])
        let engine = VisionProvider.gemini.engine(transport, images: try configuration(loader, fixtures: [fixture]))
        let initial = BoneInferenceRequest(modelID: "model", messages: [.init(role: .user, content: "look")], availableTools: tools)
        let first = try await engine.infer(request: initial)
        let result = try BoneInferenceToolResult(callID: "call-a", toolID: "tool-a", content: .multimodal([.image(fixture.image)]), isError: false, ordinal: 0)
        let history = initial.messages + [.assistant(try XCTUnwrap(first.terminalAssistantTurn)), .toolResult(result)]
        let second = try await engine.infer(request: .init(modelID: "model", messages: history, availableTools: tools,
            providerContinuation: continuation(first)))
        _ = try await engine.infer(request: .init(modelID: "model", messages: history + [
            .assistant(try XCTUnwrap(second.terminalAssistantTurn)), .init(role: .user, content: "next")],
            availableTools: tools, providerContinuation: continuation(second)))
        let bodies = await transport.bodies
        let rows = try XCTUnwrap(object(XCTUnwrap(bodies.last))["contents"] as? [[String: Any]])
        XCTAssertEqual(rows.compactMap { $0["role"] as? String }, ["user", "model", "user", "model", "user"])
        let before = try XCTUnwrap(rows[1]["parts"] as? [[String: Any]])
        let after = try XCTUnwrap(rows[3]["parts"] as? [[String: Any]])
        XCTAssertEqual(before[0]["thoughtSignature"] as? String, "before-image")
        XCTAssertEqual(after[0]["thoughtSignature"] as? String, "after-image")
    }

    func testImageUserAnchorsAttachReplayRebindAndDropSignedTurns() async throws {
        let old = try VisionFixture(id: "old")
        let current = try VisionFixture(id: "current", data: Data([4, 5, 6]))
        let matchingTurn = try BoneInferenceAssistantTurn(content: [.text("answer")])
        for provider in VisionProvider.allCases {
            let response: String
            let reasoning: [String: BoneInferenceReasoningProfile]
            switch provider {
            case .openAI:
                response = #"{"choices":[{"message":{"content":"answer","reasoning_content":"private-signature"},"finish_reason":"stop"}]}"#
                reasoning = ["model": .init(wireFormat: .thinkingType, continuation: .reasoningContent)]
            case .anthropic:
                response = #"{"content":[{"type":"thinking","thinking":"private-thought","signature":"signed"},{"type":"text","text":"answer"}],"stop_reason":"end_turn"}"#
                reasoning = ["model": .init(wireFormat: .anthropicBudget, continuation: .anthropicThinking)]
            case .gemini:
                response = #"{"candidates":[{"content":{"parts":[{"text":"answer","thoughtSignature":"signed"}]},"finishReason":"STOP"}]}"#
                reasoning = [:]
            }
            let transport = VisionTransport(provider: provider, responses: [response])
            let loader = VisionLoader(fixtures: [old, current])
            let engine = provider.engine(transport, images: try configuration(loader, fixtures: [old, current]), reasoning: reasoning)
            let initial = try BoneInferenceRequest(modelID: "model", messages: [
                .user(content: [.text("same question"), .image(old.image)]), .assistant(matchingTurn),
                .user(content: [.text("same question"), .image(current.image)])])
            let first = try await engine.infer(request: initial)
            let signed = try XCTUnwrap(continuation(first))
            let full = initial.messages + [.assistant(try XCTUnwrap(first.terminalAssistantTurn))]
            let retained = Array(full.dropFirst(2))
            let adapter = try XCTUnwrap(engine as? any BoneInferenceContextRebinding)
            let rebound = try XCTUnwrap(adapter.rebindContextContinuation(signed, from: full, to: retained))
            _ = try await engine.infer(request: .init(modelID: "model", messages: retained + [.init(role: .user, content: "next")],
                providerContinuation: rebound))
            XCTAssertNil(try adapter.rebindContextContinuation(signed, from: full, to: [.init(role: .user, content: "fresh")]))
            if provider != .gemini {
                var changed = full
                changed[2] = try .user(content: [.text("same question"), .image(old.image)])
                XCTAssertThrowsError(try engine.resolvedCapabilities(for: .init(modelID: "model", messages: changed,
                    providerContinuation: signed), invocation: .nonStreaming)) {
                    XCTAssertEqual($0 as? BoneInferenceError, .invalidProviderContinuation)
                }
            }
            let bodies = await transport.bodies
            let body = try object(XCTUnwrap(bodies.last))
            let rows = try XCTUnwrap(body[provider == .gemini ? "contents" : "messages"] as? [[String: Any]])
            XCTAssertEqual(rows.count, 3)
            switch provider {
            case .openAI: XCTAssertEqual(rows[1]["reasoning_content"] as? String, "private-signature")
            case .anthropic: XCTAssertEqual((rows[1]["content"] as? [[String: Any]])?.first?["signature"] as? String, "signed")
            case .gemini: XCTAssertEqual((rows[1]["parts"] as? [[String: Any]])?.first?["thoughtSignature"] as? String, "signed")
            }
        }
    }

    func testAgentCompactionUsesProviderMarginAndNeverLoadsRemovedImages() async throws {
        let old = try VisionFixture(id: "expired-old")
        let current = try VisionFixture(id: "current", data: Data([7, 8, 9]))
        let profile = try BoneInferenceImageInputProfile(
            contextBudget: .init(contextWindowTokens: 2_000, maximumOutputTokens: 128, source: .host),
            safetyMarginTokens: 500, tokenEstimator: { $0.reference.id == "current" ? 500 : 700 })
        for provider in VisionProvider.allCases {
            let transport = VisionTransport(provider: provider)
            // The removed image is deliberately unavailable to the resolver.
            let loader = VisionLoader(fixtures: [current])
            let engine = provider.engine(transport, images: try configuration(loader, fixtures: [current], profile: profile))
            XCTAssertEqual(try engine.imageInputSafetyMarginTokens(for: "model"), 500)
            let agent = try BoneAgentBuilder(inferenceEngine: engine).withConfiguration(
                .init(maximumSteps: 1, contextManagement: .init(protocolReserveTokens: 0, safetyMarginTokens: 0))).build()
            let result = try await agent.run(modelID: "model", messages: [
                .user(content: [.image(old.image)]), .init(role: .assistant, content: "earlier"),
                .user(content: [.image(current.image)])])
            XCTAssertEqual(result.output, .text("ok"))
            await assertCounts(loader, transport, loads: 1, sends: 1)
            let bodies = await transport.bodies
            let body = try object(XCTUnwrap(bodies.first))
            let rows = try XCTUnwrap(body[provider == .gemini ? "contents" : "messages"] as? [[String: Any]])
            XCTAssertEqual(rows.count, 1)
            let parts = try XCTUnwrap(rows[0][provider == .gemini ? "parts" : "content"] as? [[String: Any]])
            try assertImage(parts[0], provider: provider, fixture: current)
        }
    }

    func testAgentProtectedImageOverflowNeverResolvesOrSends() async throws {
        let fixture = try VisionFixture()
        for provider in VisionProvider.allCases {
            let transport = VisionTransport(provider: provider)
            let loader = VisionLoader(fixtures: [fixture])
            let engine = provider.engine(transport, images: try configuration(loader, fixtures: [fixture],
                profile: profile(window: 512, visualTokens: 500)))
            let agent = try BoneAgentBuilder(inferenceEngine: engine).withConfiguration(
                .init(maximumSteps: 1, contextManagement: .init(protocolReserveTokens: 0, safetyMarginTokens: 0))).build()
            do { _ = try await agent.run(request: imageRequest(fixture.image)); XCTFail("Mandatory image exceeds capacity") }
            catch { XCTAssertEqual(error as? BoneAgentError, .contextManagementFailed) }
            await assertCounts(loader, transport, loads: 0, sends: 0)
        }
    }

    private var tools: [BoneAgentToolDefinition] {
        ["a", "b"].map { .init(id: "tool-\($0)", version: "1.0.0", title: "Inspect", summary: "Inspect",
            wireName: "inspect_\($0)", schemaVersion: 1,
            inputSchema: .object(properties: [:], required: [], additionalProperties: false)) }
    }

    private func toolResults(first: [BoneInferenceInputContent], second: [BoneInferenceInputContent]) throws -> BoneInferenceToolResultBatch {
        try .init(results: [
            .init(callID: "call-a", toolID: "tool-a", content: .multimodal(first), isError: false, ordinal: 0),
            .init(callID: "call-b", toolID: "tool-b", content: .multimodal(second), isError: true, ordinal: 1),
        ])
    }

    private func toolRequest(_ results: BoneInferenceToolResultBatch) throws -> BoneInferenceRequest {
        let turn = try BoneInferenceAssistantTurn(content: [
            .toolCall(.init(id: "call-a", toolID: "tool-a", arguments: Data("{}".utf8), ordinal: 0)),
            .toolCall(.init(id: "call-b", toolID: "tool-b", arguments: Data("{}".utf8), ordinal: 1)),
        ])
        return .init(modelID: "model", messages: [.init(role: .user, content: "look"), .assistant(turn), .toolResults(results)], availableTools: tools)
    }

    private func imageRequest(_ image: BoneInferenceImageInput, model: String = "model") throws -> BoneInferenceRequest {
        .init(modelID: model, messages: [try .user(content: [.text("before"), .image(image), .text("after")])])
    }

    private func profile(window: Int = 8192, output: Int = 128, images: Int = 20, imageBytes: Int = 1024,
                         base64Bytes: Int = 4096, bodyBytes: Int = 100_000, visualTokens: Int = 64) throws -> BoneInferenceImageInputProfile {
        try .init(contextBudget: .init(contextWindowTokens: window, maximumOutputTokens: output, source: .host),
            maximumImagesPerRequest: images, maximumImageBytes: imageBytes, maximumBase64BytesPerRequest: base64Bytes,
            maximumRequestBodyBytes: bodyBytes, safetyMarginTokens: 16, tokenEstimator: { _ in visualTokens })
    }

    private func configuration(_ loader: VisionLoader, fixtures: [VisionFixture], profile: BoneInferenceImageInputProfile? = nil) throws -> BoneInferenceImageInputConfiguration {
        let knownMetadata = Dictionary(uniqueKeysWithValues: fixtures.map { ($0.data, $0.image.reference.metadata) })
        return try .init(profiles: ["model": try profile ?? self.profile()], resolver: .init(inspect: { bytes in
            // A trusted fixture inspector, deliberately not an image decoder.
            guard let metadata = knownMetadata[bytes] else { throw BoneInferenceImageInputError.decodingFailed }
            return metadata
        }, load: { try await loader.load($0) }))
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func outputTokens(_ body: [String: Any], _ provider: VisionProvider) -> Int? {
        provider == .gemini ? (body["generationConfig"] as? [String: Any])?["maxOutputTokens"] as? Int : body["max_tokens"] as? Int
    }

    private func assertImage(_ part: [String: Any], provider: VisionProvider, fixture: VisionFixture) throws {
        switch provider {
        case .openAI:
            XCTAssertEqual(part["type"] as? String, "image_url")
            let image = try XCTUnwrap(part["image_url"] as? [String: String])
            XCTAssertEqual(image["url"], "data:image/png;base64,\(fixture.data.base64EncodedString())")
        case .anthropic:
            XCTAssertEqual(part["type"] as? String, "image")
            let source = try XCTUnwrap(part["source"] as? [String: String])
            XCTAssertEqual(source["type"], "base64")
            XCTAssertEqual(source["media_type"], "image/png")
            XCTAssertEqual(source["data"], fixture.data.base64EncodedString())
        case .gemini:
            let inline = try XCTUnwrap(part["inlineData"] as? [String: String])
            XCTAssertEqual(inline["mimeType"], "image/png")
            XCTAssertEqual(inline["data"], fixture.data.base64EncodedString())
        }
    }

    private func assertToolAttachmentParts(_ parts: [[String: Any]], provider: VisionProvider,
                                          first: VisionFixture, second: VisionFixture) throws {
        for (index, fixture) in [first, second, second].enumerated() {
            let label = try XCTUnwrap(parts[index * 2]["text"] as? String)
            XCTAssertTrue(label.contains(index == 2 ? "call-b" : "call-a"))
            XCTAssertTrue(label.contains(index == 2 ? "tool-b" : "tool-a"))
            XCTAssertTrue(label.contains(index == 2 ? "isError: true" : "isError: false"))
            XCTAssertTrue(label.contains("tool output"))
            if provider == .gemini { XCTAssertTrue(label.contains(index == 2 ? "inspect_b" : "inspect_a")) }
            try assertImage(parts[index * 2 + 1], provider: provider, fixture: fixture)
        }
    }

    private func expectImageError(_ expected: BoneInferenceImageInputError, operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected \(expected)") }
        catch { XCTAssertEqual(error as? BoneInferenceImageInputError, expected) }
    }

    private func assertCounts(_ loader: VisionLoader, _ transport: VisionTransport, loads: Int, sends: Int) async {
        let loadCount = await loader.count
        let bodies = await transport.bodies
        XCTAssertEqual(loadCount, loads)
        XCTAssertEqual(bodies.count, sends)
    }

    private func continuation(_ response: BoneInferenceResponse) -> BoneInferenceProviderContinuation? {
        if case .assistantTurn(_, _, _, _, let value) = response { return value }
        return nil
    }
}

private typealias VisionEngine = BoneInferenceEngine & BoneInferenceBufferedStreaming & BoneInferenceDetailedResultProviding &
    BoneInferenceDetailedBufferedStreaming & BoneInferenceEventStreaming & BoneInferenceContextBudgetProviding & BoneInferenceImageTokenProviding

private enum VisionProvider: CaseIterable {
    case openAI, anthropic, gemini
    func engine(_ transport: VisionTransport, images: BoneInferenceImageInputConfiguration? = nil,
                metadata: [String: BoneModelMetadata] = [:], capabilities: [String: BoneModelCapabilityProfile] = [:],
                limits: [String: BoneModelContextLimits] = [:], reasoning: [String: BoneInferenceReasoningProfile] = [:]) -> any VisionEngine {
        let kind: BoneInferenceProviderKind = self == .openAI ? .openAI : self == .anthropic ? .anthropic : .google
        let config = BoneInferenceProviderConfiguration(kind: kind, apiKey: "synthetic",
            baseURL: URL(string: "https://fixture.invalid")!,
            authenticationMode: self == .gemini ? .googleAPIKey : self == .anthropic ? .anthropicDual : .bearer)
        switch self {
        case .openAI: return BoneOpenAIInferenceEngine(configuration: config, transport: transport,
            modelCapabilityProfiles: capabilities, modelContextLimits: limits, modelMetadata: metadata,
            modelReasoningProfiles: reasoning, imageInputConfiguration: images)
        case .anthropic: return BoneAnthropicInferenceEngine(configuration: config, transport: transport,
            modelCapabilityProfiles: capabilities, modelContextLimits: limits, modelMetadata: metadata,
            modelReasoningProfiles: reasoning, imageInputConfiguration: images)
        case .gemini: return BoneGeminiInferenceEngine(configuration: config, transport: transport,
            modelCapabilityProfiles: capabilities, modelContextLimits: limits, modelMetadata: metadata,
            modelReasoningProfiles: reasoning, imageInputConfiguration: images)
        }
    }
}

private enum VisionInvocation: CaseIterable {
    case infer, detailed, buffered, detailedBuffered, events
    func invoke(_ engine: any VisionEngine, _ request: BoneInferenceRequest) async throws {
        switch self {
        case .infer: _ = try await engine.infer(request: request)
        case .detailed: _ = try await engine.inferDetailed(request: request)
        case .buffered: _ = try await engine.inferUsingStream(request: request, options: .init())
        case .detailedBuffered: _ = try await engine.inferDetailedUsingStream(request: request, options: .init())
        case .events:
            var completed = false
            for try await event in engine.inferenceEvents(request: request, options: .init()) {
                if case .completed = event { completed = true }
            }
            XCTAssertTrue(completed)
        }
    }
}

private struct VisionFixture: Sendable {
    let image: BoneInferenceImageInput
    let data: Data
    init(id: String = "fixture", data: Data = Data([1, 2, 3])) throws {
        self.data = data
        let metadata = try BoneInferenceImageMetadata(format: .png, width: 2, height: 3, byteCount: data.count)
        let prepared = try BoneInferencePreparedImage(data: data, metadata: metadata)
        image = .init(reference: try prepared.reference(id: id, version: "v1"))
    }
}

private enum VisionFixtureError: Error { case expired }

private actor VisionLoader {
    let fixtures: [String: Data]
    let expired: Bool
    let cancel: Bool
    private(set) var count = 0
    init(fixtures: [VisionFixture], expired: Bool = false, cancel: Bool = false) {
        self.fixtures = Dictionary(uniqueKeysWithValues: fixtures.map { ($0.image.reference.id, $0.data) })
        self.expired = expired; self.cancel = cancel
    }
    func load(_ reference: BoneInferenceImageReference) throws -> Data {
        count += 1
        if expired { throw VisionFixtureError.expired }
        if cancel { withUnsafeCurrentTask { $0?.cancel() } }
        return fixtures[reference.id] ?? Data()
    }
}

private actor VisionTransport: BoneInferenceHTTPTransport {
    let provider: VisionProvider
    private var responses: [String]
    private(set) var bodies: [Data] = []
    init(provider: VisionProvider, responses: [String] = []) { self.provider = provider; self.responses = responses }
    func send(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse {
        bodies.append(request.httpBody ?? Data())
        if !responses.isEmpty { return .init(statusCode: 200, data: Data(responses.removeFirst().utf8)) }
        let json: String
        switch provider {
        case .openAI: json = #"{"choices":[{"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}"#
        case .anthropic: json = #"{"content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn"}"#
        case .gemini: json = #"{"candidates":[{"content":{"parts":[{"text":"ok"}]},"finishReason":"STOP"}]}"#
        }
        return .init(statusCode: 200, data: Data(json.utf8))
    }
    func sendRetryableForModels(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse { try await send(request) }
    func sendEventStream(_ request: URLRequest, options: BoneInferenceEventStreamOptions) async throws -> BoneInferenceEventStreamResponse {
        bodies.append(request.httpBody ?? Data())
        let values: [String]
        switch provider {
        case .openAI:
            values = [#"{"choices":[{"index":0,"delta":{"content":"ok"},"finish_reason":"stop"}]}"#, "[DONE]"]
        case .anthropic:
            values = [#"{"type":"message_start","message":{"usage":{"input_tokens":1,"output_tokens":0}}}"#,
                #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
                #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ok"}}"#,
                #"{"type":"content_block_stop","index":0}"#,
                #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}"#,
                #"{"type":"message_stop"}"#]
        case .gemini:
            values = [#"{"candidates":[{"content":{"parts":[{"text":"ok"}]},"finishReason":"STOP"}]}"#]
        }
        return .init(statusCode: 200, events: values.map { .init(data: $0) })
    }
}
