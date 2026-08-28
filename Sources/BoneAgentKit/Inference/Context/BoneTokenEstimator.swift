import Foundation

/// 不依赖厂商 Tokenizer 的确定性保守 Token 估算器。
public enum BoneTokenEstimator {
    public static let messageEnvelopeTokens = 8

    /// 估算纯文本 Token 数；仅用于请求前安全预算，不代表供应商真实 Usage。
    public static func estimateText(_ text: String) -> Int {
        var asciiScalars = 0
        var nonASCIITokens = 0
        for scalar in text.unicodeScalars {
            if scalar.isASCII {
                asciiScalars += 1
            } else if scalar.properties.isEmojiPresentation || scalar.value > 0xFFFF {
                nonASCIITokens += 2
            } else {
                nonASCIITokens += 1
            }
        }
        return ((asciiScalars + 3) / 4) + nonASCIITokens
    }

    /// 估算消息角色、正文与固定协议包装的 Token 数。
    public static func estimateMessage(_ message: BoneInferenceMessage) -> Int {
        var tokens = messageEnvelopeTokens + estimateText(message.role.rawValue)
        if let content = message.content { tokens += estimateText(content) }
        if let assistantTurn = message.assistantTurn {
            for block in assistantTurn.content {
                switch block {
                case let .text(value):
                    tokens += estimateText(value)
                case let .structured(data):
                    tokens += estimateBytes(data.count)
                case let .toolCall(call):
                    tokens += estimateText(call.id)
                        + estimateText(call.toolID)
                        + estimateBytes(call.arguments.count)
                }
            }
        }
        if let toolResult = message.toolResult {
            tokens += estimateToolResult(toolResult)
        }
        if let toolResults = message.toolResults {
            tokens += toolResults.results.reduce(0) { $0 + estimateToolResult($1) }
        }
        return tokens
    }

    private static func estimateToolResult(_ result: BoneInferenceToolResult) -> Int {
        estimateText(result.callID)
            + estimateText(result.toolID)
            + estimateBytes(result.content.byteCount)
    }

    private static func estimateBytes(_ count: Int) -> Int {
        (max(0, count) + 2) / 3
    }

    /// 估算消息数组总 Token 数。
    public static func estimateMessages(_ messages: [BoneInferenceMessage]) -> Int {
        messages.reduce(0) { $0 + estimateMessage($1) }
    }
}
