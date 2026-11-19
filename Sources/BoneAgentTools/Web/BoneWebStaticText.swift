import Foundation

/// A bounded static HTML text extractor. It does not execute JavaScript, load linked
/// resources, interpret CSS, or implement full readability/HTML5 parsing.
enum BoneWebStaticText {
    static func extract(_ html: String) throws -> (title: String, text: String) {
        let bytes = Array(html.utf8)
        let ignored: Set<String> = ["script", "style", "nav", "footer", "header", "aside", "form",
                                     "noscript", "template", "svg", "iframe", "object", "canvas", "textarea", "select"]
        var body: [UInt8] = []
        var title: [UInt8] = []
        var blocked: String?
        var blockedDepth = 0
        var inHead = false
        var inTitle = false
        var sawTitle = false
        var index = 0
        var nextCancellationCheck = 0
        while index < bytes.count {
            if index >= nextCancellationCheck {
                try Task.checkCancellation()
                nextCancellationCheck = index + 16_384
            }
            if bytes[index] != 60 {
                if blocked == nil {
                    if inTitle { title.append(bytes[index]) }
                    else if !inHead { body.append(bytes[index]) }
                }
                index += 1
                continue
            }
            if let current = blocked, current == "script" || current == "style" {
                let closing = Array(("</" + current).utf8)
                let end = index + closing.count
                let matches = end < bytes.count && zip(bytes[index..<end], closing).allSatisfy { actual, expected in
                    (65...90).contains(actual) ? actual + 32 == expected : actual == expected
                } && (isSpace(bytes[end]) || bytes[end] == 62 || bytes[end] == 47)
                if !matches { index += 1; continue }
            }
            if bytes[index...].starts(with: [60, 33, 45, 45]) {
                index += 4
                while index + 2 < bytes.count && !bytes[index...].starts(with: [45, 45, 62]) { index += 1 }
                index = min(bytes.count, index + 3)
                continue
            }
            var end = index + 1
            var quote: UInt8?
            while end < bytes.count {
                let byte = bytes[end]
                if let current = quote {
                    if byte == current { quote = nil }
                } else if byte == 34 || byte == 39 { quote = byte }
                else if byte == 62 { break }
                end += 1
            }
            guard end < bytes.count else { break }
            var cursor = index + 1
            while cursor < end && isSpace(bytes[cursor]) { cursor += 1 }
            let closing = cursor < end && bytes[cursor] == 47
            if closing { cursor += 1 }
            let start = cursor
            while cursor < end && isName(bytes[cursor]) { cursor += 1 }
            let name = String(decoding: bytes[start..<cursor], as: UTF8.self).lowercased()
            index = end + 1
            guard !name.isEmpty else { continue }
            if let current = blocked {
                if closing && name == current {
                    blockedDepth -= 1
                    if blockedDepth == 0 { blocked = nil; body.append(32) }
                } else if !closing && name == current && current != "script" && current != "style" {
                    blockedDepth += 1
                }
                continue
            }
            if ignored.contains(name) && !closing {
                blocked = name
                blockedDepth = 1
                body.append(32)
            } else if name == "head" { inHead = !closing }
            else if name == "body" && !closing { inHead = false }
            else if name == "title" {
                if closing { inTitle = false }
                else if !sawTitle { inTitle = true; sawTitle = true }
            } else if !inHead && !inTitle { body.append(32) }
        }
        try Task.checkCancellation()
        return (normalize(decodeEntities(String(decoding: title, as: UTF8.self))),
                normalize(decodeEntities(String(decoding: body, as: UTF8.self))))
    }

    static func normalize(_ value: String) -> String {
        value.split(whereSeparator: { $0.isWhitespace || $0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) })
            .joined(separator: " ")
    }

    static func decodeEntities(_ value: String) -> String {
        let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
                     "copy": "©", "reg": "®", "ndash": "–", "mdash": "—", "hellip": "…",
                     "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "bull": "•",
                     "middot": "·", "euro": "€", "pound": "£", "yen": "¥", "cent": "¢", "trade": "™"]
        let bytes = Array(value.utf8)
        var output: [UInt8] = []
        var index = 0
        while index < bytes.count {
            if bytes[index] == 38 {
                var end = index + 1
                while end < bytes.count && end - index <= 32 && bytes[end] != 59 && bytes[end] != 38 && !isSpace(bytes[end]) { end += 1 }
                if end < bytes.count && end - index <= 32 && bytes[end] == 59 {
                    let entity = String(decoding: bytes[(index + 1)..<end], as: UTF8.self)
                    var replacement = named[entity]
                    if entity.hasPrefix("#") {
                        let hex = entity.hasPrefix("#x") || entity.hasPrefix("#X")
                        let digits = entity.dropFirst(hex ? 2 : 1)
                        if let number = UInt32(digits, radix: hex ? 16 : 10), number != 0,
                           let scalar = UnicodeScalar(number) { replacement = String(scalar) }
                    }
                    if let replacement {
                        output.append(contentsOf: replacement.utf8)
                        index = end + 1
                        continue
                    }
                }
            }
            output.append(bytes[index])
            index += 1
        }
        return String(decoding: output, as: UTF8.self)
    }

    private static func isSpace(_ byte: UInt8) -> Bool { byte == 32 || (9...13).contains(byte) }
    private static func isName(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || byte == 45
    }
}
