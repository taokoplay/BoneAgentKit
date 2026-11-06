import Foundation
import XCTest
import BoneAgentKit
import BoneAgentLlama

final class LlamaVisionInputTests: XCTestCase {
    func testTextRuntimeRejectsImagesButAcceptsTextParts() throws {
        let metadata = try BoneInferenceImageMetadata(format: .png, width: 1, height: 1, byteCount: 3)
        let reference = try BoneInferencePreparedImage(data: Data([1, 2, 3]), metadata: metadata).reference(id: "fixture", version: "1")
        let imageRequest = BoneInferenceRequest(modelID: "local", messages: [try .user(content: [.image(.init(reference: reference))])])
        XCTAssertThrowsError(try BoneLlamaConversationBuilder.build(request: imageRequest))
        let text = BoneInferenceRequest(modelID: "local", messages: [try .user(content: [.text("one"), .text("two")])])
        XCTAssertNoThrow(try BoneLlamaConversationBuilder.build(request: text))
    }
}
