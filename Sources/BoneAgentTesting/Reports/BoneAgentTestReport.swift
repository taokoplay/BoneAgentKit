import Foundation

public enum BoneAgentTestReportOutcome: String, Codable, Equatable, Sendable {
    case passed, failed, recoveryRequired
}

/// 固定白名单报告；不接收或编码正文、Prompt、Tool 参数、原始响应及自由文本 note。
public struct BoneAgentTestReport: Codable, Equatable, Sendable {
    private enum CodingKeys: CodingKey {
        case schemaVersion, scenarioID, outcome, assertionCount
        case checkpointCount, crashBoundaryCount, durationMilliseconds
    }
    public let schemaVersion: Int
    public let scenarioID: String
    public let outcome: BoneAgentTestReportOutcome
    public let assertionCount: Int
    public let checkpointCount: Int
    public let crashBoundaryCount: Int
    public let durationMilliseconds: Int

    public init(
        scenarioID: String,
        outcome: BoneAgentTestReportOutcome,
        assertionCount: Int,
        checkpointCount: Int,
        crashBoundaryCount: Int,
        durationMilliseconds: Int,
        note: String? = nil
    ) throws {
        let allowedScenarioIDCharacters = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-"
        )
        guard !scenarioID.isEmpty, scenarioID.count <= 128,
              scenarioID.unicodeScalars.allSatisfy(allowedScenarioIDCharacters.contains),
              assertionCount >= 0, checkpointCount >= 0,
              crashBoundaryCount >= 0, durationMilliseconds >= 0 else {
            throw BoneAgentTestReportError.invalidField
        }
        schemaVersion = 1
        self.scenarioID = scenarioID
        self.outcome = outcome
        self.assertionCount = assertionCount
        self.checkpointCount = checkpointCount
        self.crashBoundaryCount = crashBoundaryCount
        self.durationMilliseconds = durationMilliseconds
        _ = note // 明确丢弃；只为调用方防误传提供兼容入口。
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(Int.self, forKey: .schemaVersion) == 1 else {
            throw BoneAgentTestReportError.invalidField
        }
        try self.init(
            scenarioID: container.decode(String.self, forKey: .scenarioID),
            outcome: container.decode(BoneAgentTestReportOutcome.self, forKey: .outcome),
            assertionCount: container.decode(Int.self, forKey: .assertionCount),
            checkpointCount: container.decode(Int.self, forKey: .checkpointCount),
            crashBoundaryCount: container.decode(Int.self, forKey: .crashBoundaryCount),
            durationMilliseconds: container.decode(Int.self, forKey: .durationMilliseconds)
        )
    }
}

public enum BoneAgentTestReportError: Error, Equatable, Sendable {
    case invalidField
}
