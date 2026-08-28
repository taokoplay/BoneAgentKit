import Foundation

public enum BoneTestAssertionResult: Equatable, Sendable {
    case passed(label: String)
    case failed(label: String)
}

public enum BoneTestAssertion {
    public static func equal<Value: Equatable>(
        _ actual: Value,
        _ expected: Value,
        label: String
    ) -> BoneTestAssertionResult {
        actual == expected ? .passed(label: label) : .failed(label: label)
    }

    public static func isTrue(_ value: Bool, label: String) -> BoneTestAssertionResult {
        value ? .passed(label: label) : .failed(label: label)
    }
}

public enum BonePrivacyTestAssertion {
    public static func forbiddenMatches(in data: Data, canaries: [String]) throws -> [String] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return canaries.filter { !$0.isEmpty && text.contains($0) }
    }
}
