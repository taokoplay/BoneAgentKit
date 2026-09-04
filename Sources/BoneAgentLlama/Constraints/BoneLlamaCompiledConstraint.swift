import CryptoKit
import Foundation

public struct BoneLlamaConstraintCompilerIdentity: Codable, Equatable, Hashable, Sendable {
    public static let maximumComponentLength = 128

    public let id: String
    public let version: String
    public let dialect: String

    public init(id: String, version: String, dialect: String) throws {
        guard Self.isValid(id), Self.isValid(version), Self.isValid(dialect) else {
            throw BoneLlamaAdapterError.invalidGenerationControl
        }
        self.id = id
        self.version = version
        self.dialect = dialect
    }

    private static func isValid(_ value: String) -> Bool {
        !value.isEmpty && value.count <= maximumComponentLength && value.unicodeScalars.allSatisfy {
            (0x21...0x7E).contains($0.value)
        }
    }
}

/// 只应由受信任 `BoneLlamaConstraintCompiling` 实现产生的 Runtime 派生物。
///
/// Grammar 正文用于当前请求的 sampler，不应持久化到能力 Profile 或 Smoke 报告。
public struct BoneLlamaCompiledConstraint: Equatable, Sendable {
    public static let maximumSourceByteCount = 256 * 1_024
    public static let maximumRootRuleLength = 128

    public enum Format: String, Codable, Equatable, Sendable {
        case gbnf
    }

    public let format: Format
    public let source: String
    public let sourceDigest: String
    public let rootRule: String
    public let compilerIdentity: BoneLlamaConstraintCompilerIdentity

    init(
        format: Format,
        source: String,
        sourceDigest: String,
        rootRule: String,
        compilerIdentity: BoneLlamaConstraintCompilerIdentity
    ) throws {
        guard !source.isEmpty,
              source.lengthOfBytes(using: .utf8) <= Self.maximumSourceByteCount,
              Self.isValidDigest(sourceDigest),
              Self.digest(source) == sourceDigest,
              Self.isValidRule(rootRule) else {
            throw BoneLlamaAdapterError.invalidGenerationControl
        }
        self.format = format
        self.source = source
        self.sourceDigest = sourceDigest
        self.rootRule = rootRule
        self.compilerIdentity = compilerIdentity
    }

    private static func digest(_ source: String) -> String {
        (try? BoneLlamaCompiledConstraintDigest.digest(source)) ?? ""
    }

    private static func isValidDigest(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isNumber || ("a"..."f").contains(String($0)) }
    }

    private static func isValidRule(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= maximumRootRuleLength,
              let first = value.utf8.first,
              Self.isASCIILetter(first) else { return false }
        return value.utf8.allSatisfy { Self.isASCIILetter($0) || Self.isASCIIDigit($0) || $0 == 0x2D }
    }

    private static func isASCIILetter(_ byte: UInt8) -> Bool {
        (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
    }

    private static func isASCIIDigit(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte)
    }
}

enum BoneLlamaCompiledConstraintDigest {
    static func digest(_ source: String) throws -> String {
        SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public struct BoneLlamaCompiledGenerationControl: Equatable, Sendable {
    public let stopTokenIDs: [Int32]
    public let stopStrings: [String]
    public let sourceConstraint: BoneLlamaGenerationConstraint?
    public let compiledConstraint: BoneLlamaCompiledConstraint?

    public init(
        control: BoneLlamaGenerationControl,
        compiler: (any BoneLlamaConstraintCompiling)?
    ) throws {
        stopTokenIDs = control.stopTokenIDs
        stopStrings = control.stopStrings
        sourceConstraint = control.constraint
        if let constraint = control.constraint {
            guard let compiler else {
                throw BoneLlamaAdapterError.unsupportedGenerationControl
            }
            compiledConstraint = try compiler.compile(constraint)
        } else {
            compiledConstraint = nil
        }
    }
}
