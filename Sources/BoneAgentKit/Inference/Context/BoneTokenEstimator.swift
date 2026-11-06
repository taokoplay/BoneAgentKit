import Foundation

/// 文本采用确定性保守估算，图片必须使用精确模型的视觉规则；不是厂商真实 Usage。
public enum BoneTokenEstimator {
    public static let messageEnvelopeTokens = 8

    public static func estimateText(_ text: String) -> Int {
        var asciiScalars = 0
        var nonASCIITokens = 0
        for scalar in text.unicodeScalars {
            if scalar.isASCII { asciiScalars += 1 }
            else if scalar.properties.isEmojiPresentation || scalar.value > 0xFFFF { nonASCIITokens += 2 }
            else { nonASCIITokens += 1 }
        }
        return asciiScalars / 4 + (asciiScalars % 4 == 0 ? 0 : 1) + nonASCIITokens
    }

    /// 兼容入口。图片没有模型估算规则时返回 Int.max（不可规划），绝不按 0 计数。
    public static func estimateMessage(_ message: BoneInferenceMessage) -> Int {
        (try? estimateMessage(message, imageTokenEstimator: nil)) ?? Int.max
    }
    public static func estimateMessages(_ messages: [BoneInferenceMessage]) -> Int {
        (try? estimateMessages(messages, imageTokenEstimator: nil)) ?? Int.max
    }

    public static func estimateMessage(_ message: BoneInferenceMessage,
                                      imageTokenEstimator: BoneInferenceImageTokenEstimator?) throws -> Int {
        var tokens = messageEnvelopeTokens + estimateText(message.role.rawValue)
        if let content = message.content { tokens = try checkedAdd(tokens, estimateText(content)) }
        if let parts = message.inputContent { tokens = try checkedAdd(tokens, estimateParts(parts, imageTokenEstimator: imageTokenEstimator)) }
        if let turn = message.assistantTurn {
            for block in turn.content {
                switch block {
                case .text(let value): tokens = try checkedAdd(tokens, estimateText(value))
                case .structured(let data): tokens = try checkedAdd(tokens, estimateBytes(data.count))
                case .toolCall(let call):
                    tokens = try checkedAdd(tokens, estimateText(call.id))
                    tokens = try checkedAdd(tokens, estimateText(call.toolID))
                    tokens = try checkedAdd(tokens, estimateBytes(call.arguments.count))
                }
            }
        }
        let results = message.toolResults?.results ?? message.toolResult.map { [$0] } ?? []
        for result in results {
            tokens = try checkedAdd(tokens, estimateText(result.callID))
            tokens = try checkedAdd(tokens, estimateText(result.toolID))
            if case .multimodal(let parts) = result.content {
                tokens = try checkedAdd(tokens, estimateParts(parts, imageTokenEstimator: imageTokenEstimator))
                // Tool images may require a user attachment row plus source labels in
                // both the result and attachment. Reserve for both IDs twice, the
                // bounded wire name, separators, error flag and message envelopes.
                for _ in result.content.imageInputs {
                    var association = 128
                    for _ in 0..<2 {
                        association = try checkedAdd(association, estimateText(result.callID))
                        association = try checkedAdd(association, estimateText(result.toolID))
                    }
                    tokens = try checkedAdd(tokens, association)
                }
            } else {
                tokens = try checkedAdd(tokens, estimateBytes(result.content.byteCount))
            }
        }
        return tokens
    }

    public static func estimateMessages(_ messages: [BoneInferenceMessage],
                                       imageTokenEstimator: BoneInferenceImageTokenEstimator?) throws -> Int {
        try messages.reduce(0) { try checkedAdd($0, estimateMessage($1, imageTokenEstimator: imageTokenEstimator)) }
    }

    /// 完整输入估算：文字、图片（每次出现）、Tool Schema、输出格式、续接协议等。
    public static func estimateRequestTokens(_ request: BoneInferenceRequest,
                                            imageTokenEstimator: BoneInferenceImageTokenEstimator?) throws -> Int {
        try checkedAdd(estimateMessages(request.messages, imageTokenEstimator: imageTokenEstimator), estimateRequestOverhead(request))
    }

    private static func estimateParts(_ parts: [BoneInferenceInputContent],
                                      imageTokenEstimator: BoneInferenceImageTokenEstimator?) throws -> Int {
        try parts.reduce(0) { count, part in
            switch part {
            case .text(let value): return try checkedAdd(count, estimateText(value))
            case .image(let image):
                guard let imageTokenEstimator else { throw BoneInferenceImageInputError.missingTokenEstimator }
                let visual = try imageTokenEstimator(image)
                guard visual > 0 else { throw BoneInferenceImageInputError.invalidTokenEstimate }
                // 固定图片 block 协议包装，不把 Base64、hash 或路径当作视觉内容 Token。
                return try checkedAdd(count, checkedAdd(visual, 32))
            }
        }
    }

    private static func estimateBytes(_ count: Int) -> Int {
        max(0, count) / 3 + (max(0, count) % 3 == 0 ? 0 : 1)
    }

    public static func estimateRequestOverhead(_ request: BoneInferenceRequest) throws -> Int {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var total = estimateBytes(try encoder.encode(request.availableTools).count)
        total = try checkedAdd(total, estimateBytes(encoder.encode(request.responseFormat).count))
        if let constraint = request.outputConstraint { total = try checkedAdd(total, estimateBytes(encoder.encode(constraint).count)) }
        if let continuation = request.providerContinuation { total = try checkedAdd(total, estimateBytes(continuation.data.count)) }
        return total
    }

    static func checkedAdd(_ lhs: Int, _ rhs: Int) throws -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard lhs >= 0, rhs >= 0, !overflow else { throw BoneInferenceImageInputError.tokenOverflow }
        return sum
    }
}

extension BoneInferenceRequest {
    /// Run 字节预算除私有引用 JSON 外还预留图片 Base64 的每次出现；不是视觉 Token 或精确 wire 长度。
    var accountedInputBytes: Int {
        get throws {
            try imageInputs.reduce(JSONEncoder().encode(self).count) { try BoneTokenEstimator.checkedAdd($0, $1.base64ByteCount) }
        }
    }
}
