import Foundation

enum BoneStructuredJSONShape: String, Equatable, Sendable {
    case direct
    case completeFence
    case uniqueWrappedObject
}

struct BoneStructuredJSONObjectNormalization: Equatable, Sendable {
    let data: Data
    let shape: BoneStructuredJSONShape
}

/// 只为显式结构化输出文本回退剥离无歧义外壳；不修复 JSON 内部语法。
enum BoneStructuredJSONObjectNormalizer {
    static func normalize(_ text: String) -> BoneStructuredJSONObjectNormalization? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let data = validObjectData(trimmed) {
            return .init(data: data, shape: .direct)
        }
        if let fenced = completeFenceContent(trimmed), let data = validObjectData(fenced) {
            return .init(data: data, shape: .completeFence)
        }
        guard let range = uniqueCompleteObjectRange(in: trimmed) else { return nil }
        let candidate = String(trimmed[range])
        guard let data = validObjectData(candidate) else { return nil }
        return .init(data: data, shape: .uniqueWrappedObject)
    }

    private static func validObjectData(_ text: String) -> Data? {
        guard !containsTrailingComma(text) else { return nil }
        let data = Data(text.utf8)
        guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else { return nil }
        return data
    }

    /// Foundation 在部分系统版本接受尾逗号；结构化契约必须按严格 JSON 拒绝。
    private static func containsTrailingComma(_ text: String) -> Bool {
        var inString = false
        var escaped = false
        var previousSignificant: Character?
        for character in text {
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
                continue
            }
            if character == "\"" {
                inString = true
                previousSignificant = character
            } else if character == "}" || character == "]" {
                if previousSignificant == "," { return true }
                previousSignificant = character
            } else if !character.isWhitespace {
                previousSignificant = character
            }
        }
        return false
    }

    private static func completeFenceContent(_ text: String) -> String? {
        guard text.hasPrefix("```"), text.hasSuffix("```"),
              let openingEnd = text.firstIndex(of: "\n") else { return nil }
        let closingStart = text.index(text.endIndex, offsetBy: -3)
        let contentStart = text.index(after: openingEnd)
        guard contentStart <= closingStart else { return nil }
        return String(text[contentStart..<closingStart])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func uniqueCompleteObjectRange(in text: String) -> Range<String.Index>? {
        var rootRange: Range<String.Index>?
        var depth = 0
        var inString = false
        var escaped = false
        var start: String.Index?
        var cursor = text.startIndex
        while cursor < text.endIndex {
            let character = text[cursor]
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
            } else if character == "\"" {
                inString = true
            } else if character == "[" {
                // 对象外数组结构会使外围语义产生歧义。
                if depth == 0 { return nil }
            } else if character == "{" {
                if depth == 0 {
                    guard rootRange == nil else { return nil }
                    start = cursor
                }
                depth += 1
            } else if character == "}" {
                guard depth > 0 else { return nil }
                depth -= 1
                if depth == 0, let start {
                    rootRange = start..<text.index(after: cursor)
                }
            }
            cursor = text.index(after: cursor)
        }
        guard depth == 0, !inString else { return nil }
        return rootRange
    }
}
