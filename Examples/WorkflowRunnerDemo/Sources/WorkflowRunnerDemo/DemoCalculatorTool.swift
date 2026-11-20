import Foundation
import BoneAgentKit

/// Four local arithmetic operations; never interprets expressions or performs I/O.
struct DemoCalculatorTool: BoneAgentTool {
    typealias Context = BoneAgentEmptyContext

    enum Operation: String, Codable, CaseIterable, Sendable {
        case add, subtract, multiply, divide
    }

    struct Input: Codable, Sendable {
        let operation: Operation
        let left: Double
        let right: Double
    }

    struct Output: Codable, Equatable, Sendable {
        let value: Double
    }

    enum CalculationError: Error, Equatable, Sendable {
        case invalidNumber
        case divisionByZero
        case nonFiniteResult
    }

    static let definition = BoneAgentToolDefinition(
        id: "demo.calculate",
        version: "1.0.0",
        title: "计算器",
        summary: "对两个有限数字执行加、减、乘、除；输入绝对值不超过 1e12，除数不能为零。",
        wireName: "demo_calculate",
        schemaVersion: 1,
        inputSchema: .object(
            properties: [
                "operation": .string(enumValues: Operation.allCases.map(\.rawValue), minimumLength: nil, maximumLength: nil),
                "left": .number(minimum: nil, maximum: 1e12),
                "right": .number(minimum: nil, maximum: 1e12),
            ],
            required: ["operation", "left", "right"],
            additionalProperties: false
        ),
        executionPolicy: .serial,
        impact: .ordinaryPublicRead
    )

    func execute(input: Input, context: Context) async throws -> Output {
        try Task.checkCancellation()
        guard input.left.isFinite, input.right.isFinite,
              abs(input.left) <= 1e12, abs(input.right) <= 1e12 else {
            throw CalculationError.invalidNumber
        }
        let value: Double
        switch input.operation {
        case .add: value = input.left + input.right
        case .subtract: value = input.left - input.right
        case .multiply: value = input.left * input.right
        case .divide:
            guard input.right != 0 else { throw CalculationError.divisionByZero }
            value = input.left / input.right
        }
        guard value.isFinite else { throw CalculationError.nonFiniteResult }
        return Output(value: value)
    }
}
