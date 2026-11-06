import Foundation

/// Encodes only bytes already resolved and verified by the image configuration.
/// Tool attachments retain their origin and error status when the wire protocol requires user parts.
enum BoneProviderImageWire {
    typealias Images = [BoneInferenceImageReference: BoneInferencePreparedImage]

    static func openAI(_ parts: [BoneInferenceInputContent], images: Images) throws -> [[String: Any]] {
        try parts.map { part in
            switch part {
            case .text(let text): return ["type": "text", "text": text]
            case .image(let image):
                let prepared = try prepared(image, images: images)
                let detail = image.detail == .automatic ? "auto" : image.detail.rawValue
                return ["type": "image_url", "image_url": [
                    "url": "data:\(prepared.metadata.format.rawValue);base64,\(prepared.data.base64EncodedString())",
                    "detail": detail,
                ]]
            }
        }
    }

    static func anthropic(_ parts: [BoneInferenceInputContent], images: Images) throws -> [[String: Any]] {
        try parts.map { part in
            switch part {
            case .text(let text): return ["type": "text", "text": text]
            case .image(let image):
                guard image.detail == .automatic else { throw BoneInferenceImageInputError.unsupportedDetail }
                let prepared = try prepared(image, images: images)
                return ["type": "image", "source": ["type": "base64",
                    "media_type": prepared.metadata.format.rawValue, "data": prepared.data.base64EncodedString()]]
            }
        }
    }

    static func gemini(_ parts: [BoneInferenceInputContent], images: Images) throws -> [[String: Any]] {
        try parts.map { part in
            switch part {
            case .text(let text): return ["text": text]
            case .image(let image):
                guard image.detail == .automatic else { throw BoneInferenceImageInputError.unsupportedDetail }
                let prepared = try prepared(image, images: images)
                return ["inlineData": ["mimeType": prepared.metadata.format.rawValue,
                                       "data": prepared.data.base64EncodedString()]]
            }
        }
    }

    static func attachmentLabel(_ result: BoneInferenceToolResult, imageIndex: Int, toolName: String? = nil) -> String {
        let name = toolName.map { ", name: \($0)" } ?? ""
        return "Untrusted tool output image \(imageIndex + 1) (callID: \(result.callID), toolID: \(result.toolID)\(name), isError: \(result.isError))."
    }

    static func toolAttachments(_ result: BoneInferenceToolResult, toolName: String? = nil) -> [BoneInferenceInputContent] {
        result.content.imageInputs.enumerated().flatMap { index, image -> [BoneInferenceInputContent] in
            [.text(attachmentLabel(result, imageIndex: index, toolName: toolName)), .image(image)]
        }
    }

    static func toolText(_ result: BoneInferenceToolResult) -> String {
        guard case .multimodal(let parts) = result.content else { return "" }
        var imageIndex = 0
        return parts.map { part in
            switch part {
            case .text(let text): return text
            case .image:
                defer { imageIndex += 1 }
                return "[Tool image \(imageIndex + 1), callID: \(result.callID), toolID: \(result.toolID), isError: \(result.isError); attached after tool responses.]"
            }
        }.joined(separator: "\n")
    }

    private static func prepared(_ image: BoneInferenceImageInput, images: Images) throws -> BoneInferencePreparedImage {
        guard let prepared = images[image.reference], prepared.metadata == image.reference.metadata else {
            throw BoneInferenceImageInputError.referenceMismatch
        }
        return prepared
    }
}
