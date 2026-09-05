import XCTest
@testable import BoneAgentLlama

final class BoneLlamaGBNFCompilerTests: XCTestCase {
    func testCompilesExactEnumChoicesToDeterministicGBNF() throws {
        let compiler = BoneLlamaGBNFCompiler()
        let choices = ["a", "ab", "中文", "🐟", "quote\"", "slash\\", "line\nnext"]

        let first = try compiler.compile(.enumChoice(choices))
        let second = try compiler.compile(.enumChoice(choices))

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.rootRule, "root")
        XCTAssertEqual(first.compilerIdentity, compiler.identity)
        XCTAssertEqual(
            first.source,
            "root ::= \"a\" | \"ab\" | \"中文\" | \"🐟\" | \"quote\\\"\" | \"slash\\\\\" | \"line\\nnext\"\n"
        )
        XCTAssertEqual(try EnumGrammarFixture(source: first.source).acceptedValues(), choices)
    }

    func testPreservesChoiceOrderAsExecutionIdentity() throws {
        let compiler = BoneLlamaGBNFCompiler()
        let first = try compiler.compile(.enumChoice(["yes", "no"]))
        let second = try compiler.compile(.enumChoice(["no", "yes"]))

        XCTAssertNotEqual(first.source, second.source)
        XCTAssertNotEqual(first.sourceDigest, second.sourceDigest)
    }

    func testRejectsInvalidOrOverBudgetEnumBeforeProducingGrammar() throws {
        let compiler = BoneLlamaGBNFCompiler(
            limits: .init(
                maximumGrammarByteCount: 1_024,
                maximumRuleCount: 16,
                maximumExpandedNodeCount: 16,
                maximumEnumTerminalByteCount: 4
            )
        )

        XCTAssertThrowsError(try compiler.compile(.enumChoice([]))) { error in
            XCTAssertEqual(error as? BoneLlamaConstraintCompilerError, .invalidConstraint)
        }
        XCTAssertThrowsError(try compiler.compile(.enumChoice(["12345"]))) { error in
            XCTAssertEqual(error as? BoneLlamaConstraintCompilerError, .resourceLimitExceeded)
        }
    }

    func testEscapesAllASCIIControlBytesWithoutEmbeddingThem() throws {
        let value = String(UnicodeScalar(1)) + "\t\r\n"
        let compiled = try BoneLlamaGBNFCompiler().compile(.enumChoice([value]))

        XCTAssertEqual(compiled.source, "root ::= \"\\x01\\t\\r\\n\"\n")
        XCTAssertEqual(try EnumGrammarFixture(source: compiled.source).acceptedValues(), [value])
    }
}

private struct EnumGrammarFixture {
    let source: String

    func acceptedValues() throws -> [String] {
        guard source.hasPrefix("root ::= "), source.hasSuffix("\n") else {
            throw FixtureError.invalidGrammar
        }
        let body = source.dropFirst("root ::= ".count).dropLast()
        return try splitAlternatives(String(body)).map(decodeLiteral)
    }

    private func splitAlternatives(_ value: String) throws -> [String] {
        var result: [String] = []
        var current = ""
        var escaped = false
        var quoted = false
        var index = value.startIndex
        while index < value.endIndex {
            let character = value[index]
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" {
                current.append(character)
                escaped = true
            } else if character == "\"" {
                current.append(character)
                quoted.toggle()
            } else if !quoted, value[index...].hasPrefix(" | ") {
                result.append(current)
                current = ""
                index = value.index(index, offsetBy: 2)
            } else {
                current.append(character)
            }
            index = value.index(after: index)
        }
        guard !quoted, !escaped else { throw FixtureError.invalidGrammar }
        result.append(current)
        return result
    }

    private func decodeLiteral(_ literal: String) throws -> String {
        guard literal.first == "\"", literal.last == "\"" else {
            throw FixtureError.invalidGrammar
        }
        let body = literal.dropFirst().dropLast()
        var bytes: [UInt8] = []
        var index = body.startIndex
        while index < body.endIndex {
            let character = body[index]
            guard character == "\\" else {
                bytes.append(contentsOf: String(character).utf8)
                index = body.index(after: index)
                continue
            }
            index = body.index(after: index)
            guard index < body.endIndex else { throw FixtureError.invalidGrammar }
            let escape = body[index]
            switch escape {
            case "\"": bytes.append(0x22)
            case "\\": bytes.append(0x5C)
            case "n": bytes.append(0x0A)
            case "r": bytes.append(0x0D)
            case "t": bytes.append(0x09)
            case "x":
                let first = body.index(after: index)
                guard first < body.endIndex else { throw FixtureError.invalidGrammar }
                let second = body.index(after: first)
                guard second < body.endIndex,
                      let byte = UInt8(String(body[first...second]), radix: 16) else {
                    throw FixtureError.invalidGrammar
                }
                bytes.append(byte)
                index = second
            default: throw FixtureError.invalidGrammar
            }
            index = body.index(after: index)
        }
        guard let result = String(bytes: bytes, encoding: .utf8) else {
            throw FixtureError.invalidGrammar
        }
        return result
    }

    private enum FixtureError: Error { case invalidGrammar }
}
