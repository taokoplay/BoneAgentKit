import Foundation
import BoneAgentKit

/// Stable failures that never contain the supplied expression.
public enum BoneCalculatorError: String, Error, Codable, Equatable, Sendable {
    case invalidArguments
    case invalidExpression
    case expressionTooLong
    case tokenLimitExceeded
    case depthLimitExceeded
    case operationLimitExceeded
    case divisionByZero
    case domainError
    case nonFiniteResult
}

/// Evaluates a bounded arithmetic grammar without executing code.
///
/// Values use binary `Double` arithmetic, not decimal or financial precision.
/// `^` is right associative and binds more tightly than unary signs: `-2^2 == -4`.
/// `%` is a truncating remainder, and `round` rounds ties away from zero.
/// Functions are `abs`, `sqrt`, `round`, `floor`, `ceil`, `percent` (divide by 100),
/// and the two-argument functions `min` and `max`. Names are lowercase ASCII.
public struct BoneCalculatorTool<Context: BoneAgentToolContext>: BoneAgentTool {
    public static var maximumExpressionBytes: Int { 4_096 }
    public static var maximumTokenCount: Int { 512 }
    public static var maximumNestingDepth: Int { 64 }
    public static var maximumOperationCount: Int { 128 }

    public struct Input: Codable, Equatable, Sendable {
        public let expression: String

        public init(expression: String) {
            self.expression = expression
        }

        public init(from decoder: Decoder) throws {
            do {
                guard try BoneLocalToolSupport.containsOnlyKeys(decoder, allowed: ["expression"]) else {
                    throw BoneCalculatorError.invalidArguments
                }
                let container = try decoder.container(keyedBy: CodingKeys.self)
                expression = try container.decode(String.self, forKey: .expression)
                try BoneCalculatorTool.validateLength(expression)
            } catch let error as BoneCalculatorError {
                throw error
            } catch {
                throw BoneCalculatorError.invalidArguments
            }
        }

        private enum CodingKeys: String, CodingKey { case expression }
    }

    public struct Output: Codable, Equatable, Sendable {
        public let value: Double

        public init(value: Double) {
            self.value = value
        }
    }

    public init() {}

    public static var definition: BoneAgentToolDefinition {
        BoneAgentToolDefinition(
            id: "math.calculate",
            version: "1.0.0",
            title: "Calculator",
            summary: "Evaluate finite Double arithmetic: + - * / % ^, parentheses, unary signs, "
                + "abs/sqrt/round/floor/ceil/percent and two-argument min/max. ^ is right associative "
                + "and precedes unary signs; % is remainder. Not for financial precision. "
                + "Limits: 4096 ASCII bytes, 512 tokens, 64 nesting levels, 128 operations.",
            wireName: "math_calculate",
            schemaVersion: 1,
            inputSchema: .object(
                properties: [
                    "expression": .string(
                        enumValues: [], minimumLength: 1, maximumLength: maximumExpressionBytes
                    )
                ],
                required: ["expression"],
                additionalProperties: false
            ),
            executionPolicy: .serial,
            impact: BoneLocalToolSupport.impact
        )
    }

    public func execute(input: Input, context: Context) async throws -> Output {
        try Task.checkCancellation()
        try Self.validateLength(input.expression)
        var parser = try BoneArithmeticParser(
            expression: input.expression,
            maximumTokens: Self.maximumTokenCount,
            maximumDepth: Self.maximumNestingDepth,
            maximumOperations: Self.maximumOperationCount
        )
        let value = try parser.evaluate()
        try Task.checkCancellation()
        return Output(value: value)
    }

    private static func validateLength(_ expression: String) throws {
        guard !expression.isEmpty else { throw BoneCalculatorError.invalidExpression }
        guard expression.utf8.prefix(maximumExpressionBytes + 1).count <= maximumExpressionBytes else {
            throw BoneCalculatorError.expressionTooLong
        }
    }
}

private struct BoneArithmeticParser {
    private enum Token {
        case number(Double)
        case symbol(UInt8)
        case function(String)
    }

    private let tokens: [Token]
    private let maximumDepth: Int
    private let maximumOperations: Int
    private var position = 0
    private var operations = 0

    init(expression: String, maximumTokens: Int, maximumDepth: Int, maximumOperations: Int) throws {
        tokens = try Self.tokenize(expression, maximumTokens: maximumTokens)
        self.maximumDepth = maximumDepth
        self.maximumOperations = maximumOperations
    }

    mutating func evaluate() throws -> Double {
        let value = try expression(depth: 0)
        guard position == tokens.count else { throw BoneCalculatorError.invalidExpression }
        return try finite(value)
    }

    private static func tokenize(_ expression: String, maximumTokens: Int) throws -> [Token] {
        let bytes = Array(expression.utf8)
        var tokens: [Token] = []
        var index = 0
        while index < bytes.count {
            try Task.checkCancellation()
            let byte = bytes[index]
            if [9, 10, 13, 32].contains(byte) { index += 1; continue }
            guard tokens.count < maximumTokens else { throw BoneCalculatorError.tokenLimitExceeded }
            if isDigit(byte) || byte == 46 {
                let start = index
                var digits = 0
                while index < bytes.count, isDigit(bytes[index]) { index += 1; digits += 1 }
                if index < bytes.count, bytes[index] == 46 {
                    index += 1
                    while index < bytes.count, isDigit(bytes[index]) { index += 1; digits += 1 }
                }
                guard digits > 0 else { throw BoneCalculatorError.invalidExpression }
                if index < bytes.count, bytes[index] == 101 || bytes[index] == 69 {
                    index += 1
                    if index < bytes.count, bytes[index] == 43 || bytes[index] == 45 { index += 1 }
                    let exponentStart = index
                    while index < bytes.count, isDigit(bytes[index]) { index += 1 }
                    guard index > exponentStart else { throw BoneCalculatorError.invalidExpression }
                }
                guard let value = Double(String(decoding: bytes[start..<index], as: UTF8.self)) else {
                    throw BoneCalculatorError.invalidExpression
                }
                guard value.isFinite else { throw BoneCalculatorError.nonFiniteResult }
                tokens.append(.number(value))
            } else if (97...122).contains(byte) {
                let start = index
                while index < bytes.count, (97...122).contains(bytes[index]) { index += 1 }
                let name = String(decoding: bytes[start..<index], as: UTF8.self)
                guard ["abs", "sqrt", "min", "max", "round", "floor", "ceil", "percent"].contains(name) else {
                    throw BoneCalculatorError.invalidExpression
                }
                tokens.append(.function(name))
            } else if [43, 45, 42, 47, 37, 94, 40, 41, 44].contains(byte) {
                tokens.append(.symbol(byte))
                index += 1
            } else {
                throw BoneCalculatorError.invalidExpression
            }
        }
        return tokens
    }

    private static func isDigit(_ byte: UInt8) -> Bool { (48...57).contains(byte) }

    private mutating func expression(depth: Int) throws -> Double {
        try checkDepth(depth)
        var value = try product(depth: depth)
        while let symbol = currentSymbol, symbol == 43 || symbol == 45 {
            position += 1
            let rhs = try product(depth: depth)
            try countOperation()
            value = try finite(symbol == 43 ? value + rhs : value - rhs)
        }
        return value
    }

    private mutating func product(depth: Int) throws -> Double {
        var value = try unary(depth: depth)
        while let symbol = currentSymbol, symbol == 42 || symbol == 47 || symbol == 37 {
            position += 1
            let rhs = try unary(depth: depth)
            try countOperation()
            if symbol != 42, rhs == 0 { throw BoneCalculatorError.divisionByZero }
            switch symbol {
            case 42: value = try finite(value * rhs)
            case 47: value = try finite(value / rhs)
            default: value = try finite(value.truncatingRemainder(dividingBy: rhs))
            }
        }
        return value
    }

    private mutating func unary(depth: Int) throws -> Double {
        try checkDepth(depth)
        if let symbol = currentSymbol, symbol == 43 || symbol == 45 {
            position += 1
            let value = try unary(depth: depth + 1)
            try countOperation()
            return try finite(symbol == 45 ? -value : value)
        }
        return try power(depth: depth)
    }

    private mutating func power(depth: Int) throws -> Double {
        let base = try primary(depth: depth)
        guard consume(94) else { return base }
        // Recursing through unary permits 2^-2 and right-associative 2^3^2.
        let exponent = try unary(depth: depth + 1)
        try countOperation()
        if base == 0, exponent < 0 { throw BoneCalculatorError.divisionByZero }
        if base < 0, exponent.rounded(.towardZero) != exponent { throw BoneCalculatorError.domainError }
        return try finite(pow(base, exponent))
    }

    private mutating func primary(depth: Int) throws -> Double {
        try checkDepth(depth)
        guard position < tokens.count else { throw BoneCalculatorError.invalidExpression }
        switch tokens[position] {
        case let .number(value):
            position += 1
            return value
        case .symbol(40):
            position += 1
            let value = try expression(depth: depth + 1)
            guard consume(41) else { throw BoneCalculatorError.invalidExpression }
            return value
        case let .function(name):
            position += 1
            guard consume(40) else { throw BoneCalculatorError.invalidExpression }
            let first = try expression(depth: depth + 1)
            var second: Double?
            if name == "min" || name == "max" {
                guard consume(44) else { throw BoneCalculatorError.invalidExpression }
                second = try expression(depth: depth + 1)
            }
            guard consume(41) else { throw BoneCalculatorError.invalidExpression }
            try countOperation()
            let value: Double
            switch name {
            case "abs": value = abs(first)
            case "sqrt":
                guard first >= 0 else { throw BoneCalculatorError.domainError }
                value = sqrt(first)
            case "min":
                guard let second else { throw BoneCalculatorError.invalidExpression }
                value = min(first, second)
            case "max":
                guard let second else { throw BoneCalculatorError.invalidExpression }
                value = max(first, second)
            case "round": value = first.rounded(.toNearestOrAwayFromZero)
            case "floor": value = first.rounded(.down)
            case "ceil": value = first.rounded(.up)
            case "percent": value = first / 100
            default: throw BoneCalculatorError.invalidExpression
            }
            return try finite(value)
        default:
            throw BoneCalculatorError.invalidExpression
        }
    }

    private var currentSymbol: UInt8? {
        guard position < tokens.count, case let .symbol(symbol) = tokens[position] else { return nil }
        return symbol
    }

    private mutating func consume(_ symbol: UInt8) -> Bool {
        guard currentSymbol == symbol else { return false }
        position += 1
        return true
    }

    private func checkDepth(_ depth: Int) throws {
        try Task.checkCancellation()
        guard depth <= maximumDepth else { throw BoneCalculatorError.depthLimitExceeded }
    }

    private mutating func countOperation() throws {
        try Task.checkCancellation()
        guard operations < maximumOperations else { throw BoneCalculatorError.operationLimitExceeded }
        operations += 1
    }

    private func finite(_ value: Double) throws -> Double {
        guard value.isFinite else { throw BoneCalculatorError.nonFiniteResult }
        return value
    }
}
