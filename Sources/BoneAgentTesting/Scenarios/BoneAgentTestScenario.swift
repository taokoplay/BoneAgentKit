import Foundation

/// 运行闭包只驻留内存，类型刻意不遵循 Codable。
public struct BoneAgentTestScenario<Output: Sendable>: Sendable {
    public let id: String
    private let runClosure: @Sendable (UInt64) async -> Output

    public init(id: String, run: @escaping @Sendable (UInt64) async -> Output) {
        self.id = id
        runClosure = run
    }

    public func run(seed: UInt64) async -> Output {
        await runClosure(seed)
    }
}

public enum BoneDeterministicTestDelay {
    public static func nanoseconds(seed: UInt64, ordinal: Int, upperBound: UInt64) -> UInt64 {
        guard upperBound > 0 else { return 0 }
        var value = seed &+ UInt64(bitPattern: Int64(ordinal)) &* 0x9E3779B97F4A7C15
        value ^= value >> 30
        value &*= 0xBF58476D1CE4E5B9
        value ^= value >> 27
        value &*= 0x94D049BB133111EB
        value ^= value >> 31
        return value % upperBound
    }
}
