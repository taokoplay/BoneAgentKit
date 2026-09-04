import BoneAgentKit
import Foundation

struct SchemaGrammarBuilder {
    let limits: BoneLlamaGBNFCompilerLimits
    private var expressions: [String] = []
    private var expandedNodeCount = 0
    private var enumTerminalByteCount = 0

    init(limits: BoneLlamaGBNFCompilerLimits) {
        self.limits = limits
    }

    mutating func compile(_ schema: BoneToolSchema) throws -> String {
        let rootNode = try add(schema)
        guard expressions.count + 7 <= limits.maximumRuleCount else {
            throw BoneLlamaConstraintCompilerError.resourceLimitExceeded
        }
        var writer = BoneLlamaGBNFWriter()
        writer.addRule(name: "root", expression: rootNode)
        for (index, expression) in expressions.enumerated() {
            writer.addRule(name: "node-\(index)", expression: expression)
        }
        writer.addRule(
            name: "json-string",
            expression: "\(BoneLlamaGBNFWriter.literal("\"")) json-char* \(BoneLlamaGBNFWriter.literal("\""))"
        )
        writer.addRule(
            name: "json-char",
            expression: #"[^"\\\x00-\x1F] | "\\" (["\\/bfnrt] | unicode-escape)"#
        )
        writer.addRule(
            name: "unicode-escape",
            expression: #""u" (([0-9a-cA-C] [0-9a-fA-F]{3}) | ([dD] [0-7] [0-9a-fA-F]{2}) | ([e-fE-F] [0-9a-fA-F]{3}) | ([dD] [89aAbB] [0-9a-fA-F]{2} "\\" "u" [dD] [c-fC-F] [0-9a-fA-F]{2}))"#
        )
        // The numeric language is intentionally narrower than the validator: at most nine
        // integer digits and, for number, at most nine fractional digits with no exponent.
        writer.addRule(name: "integer", expression: #""-"? ("0" | [1-9] [0-9]{0,8})"#)
        writer.addRule(name: "number", expression: #""-"? ("0" | [1-9] [0-9]{0,8}) ("." [0-9] [0-9]{0,8})?"#)
        writer.addRule(name: "ws", expression: #"[ \t\n\r]*"#)
        return writer.source()
    }

    private mutating func add(_ schema: BoneToolSchema) throws -> String {
        expandedNodeCount += 1
        guard expandedNodeCount <= limits.maximumExpandedNodeCount else {
            throw BoneLlamaConstraintCompilerError.resourceLimitExceeded
        }
        let name = "node-\(expressions.count)"
        expressions.append("")
        let expression: String
        switch schema {
        case .boolean:
            expression = "\(BoneLlamaGBNFWriter.literal("true")) | \(BoneLlamaGBNFWriter.literal("false"))"

        case let .integer(minimum, maximum):
            guard minimum == nil, maximum == nil else { throw BoneLlamaConstraintCompilerError.unsupportedSchema }
            expression = "integer"

        case let .number(minimum, maximum):
            guard minimum == nil, maximum == nil else { throw BoneLlamaConstraintCompilerError.unsupportedSchema }
            expression = "number"

        case let .string(values, minimumLength, maximumLength):
            guard minimumLength == nil, maximumLength == nil else {
                throw BoneLlamaConstraintCompilerError.unsupportedSchema
            }
            if values.isEmpty {
                expression = "json-string"
            } else {
                enumTerminalByteCount += values.reduce(0) { $0 + $1.utf8.count }
                guard enumTerminalByteCount <= limits.maximumEnumTerminalByteCount else {
                    throw BoneLlamaConstraintCompilerError.resourceLimitExceeded
                }
                expression = values.map { BoneLlamaGBNFWriter.literal(Self.jsonString($0)) }.joined(separator: " | ")
            }

        case let .array(items, minimumItems, maximumItems):
            guard minimumItems == nil, maximumItems == nil else {
                throw BoneLlamaConstraintCompilerError.unsupportedSchema
            }
            let child = try add(items)
            expression = "\"[\" ws (\(child) (ws \",\" ws \(child))*)? ws \"]\""

        case let .object(properties, required, additionalProperties):
            guard !additionalProperties,
                  Set(required) == Set(properties.keys),
                  required.count == properties.count else {
                throw BoneLlamaConstraintCompilerError.unsupportedSchema
            }
            let keys = properties.keys.sorted(by: Self.utf8Less)
            var members: [String] = []
            for key in keys {
                guard let childSchema = properties[key] else {
                    throw BoneLlamaConstraintCompilerError.invalidConstraint
                }
                let child = try add(childSchema)
                members.append("\(BoneLlamaGBNFWriter.literal(Self.jsonString(key))) ws \":\" ws \(child)")
            }
            expression = "\"{\" ws " + members.joined(separator: " ws \",\" ws ") + " ws \"}\""

        case let .taggedUnion(discriminator, variants):
            let sorted = try variants.sorted {
                try Self.discriminatorValue($0, discriminator: discriminator).utf8.lexicographicallyPrecedes(
                    Self.discriminatorValue($1, discriminator: discriminator).utf8
                )
            }
            expression = try sorted.map { try add($0) }.joined(separator: " | ")
        }
        expressions[Int(name.dropFirst("node-".count))!] = expression
        return name
    }

    private static func jsonString(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22: result += "\\\""
            case 0x5C: result += "\\\\"
            case 0x08: result += "\\b"
            case 0x0C: result += "\\f"
            case 0x0A: result += "\\n"
            case 0x0D: result += "\\r"
            case 0x09: result += "\\t"
            case 0x00...0x1F: result += String(format: "\\u%04x", scalar.value)
            default: result.append(String(scalar))
            }
        }
        result += "\""
        return result
    }

    private static func discriminatorValue(_ schema: BoneToolSchema, discriminator: String) throws -> String {
        guard case let .object(properties, required, additionalProperties) = schema,
              !additionalProperties,
              required.contains(discriminator),
              case let .string(values, nil, nil)? = properties[discriminator],
              values.count == 1 else {
            throw BoneLlamaConstraintCompilerError.unsupportedSchema
        }
        return values[0]
    }

    private static func utf8Less(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }
}
