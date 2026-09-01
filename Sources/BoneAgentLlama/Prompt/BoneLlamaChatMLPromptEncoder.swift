import BoneAgentKit
import Foundation

public struct BoneLlamaChatMLPromptEncoder: BoneLlamaPromptEncoding, Sendable {
    public init() {}

    public func encode(request: BoneInferenceRequest) throws -> String {
        guard !request.messages.isEmpty,
              request.availableTools.isEmpty,
              request.providerContinuation == nil,
              request.reasoningDisclosure == .hidden,
              request.responseFormat == .text else {
            throw BoneLlamaAdapterError.unsupportedRequest
        }
        var prompt = ""
        for message in request.messages {
            guard let content = message.content,
                  !content.isEmpty,
                  message.assistantTurn == nil,
                  message.toolResult == nil,
                  message.toolResults == nil,
                  message.role != .tool else {
                throw BoneLlamaAdapterError.unsupportedRequest
            }
            prompt += "<|im_start|>\(message.role.rawValue)\n"
            prompt += content
            prompt += "<|im_end|>\n"
        }
        prompt += "<|im_start|>assistant\n"
        return prompt
    }
}
