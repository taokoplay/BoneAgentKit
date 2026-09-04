import Foundation

struct BoneLlamaGBNFWriter {
    private(set) var rules: [String] = []

    mutating func addRule(name: String, expression: String) {
        rules.append("\(name) ::= \(expression)")
    }

    func source() -> String {
        rules.joined(separator: "\n") + "\n"
    }

    static func literal(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22: result += "\\\""
            case 0x5C: result += "\\\\"
            case 0x09: result += "\\t"
            case 0x0A: result += "\\n"
            case 0x0D: result += "\\r"
            case 0x00...0x1F, 0x7F:
                result += String(format: "\\x%02x", scalar.value)
            default:
                result.append(String(scalar))
            }
        }
        result += "\""
        return result
    }
}
