import Foundation
import BoneAgentKit

public enum BoneAskUserError: Error, Equatable, Sendable {
    case invalidQuestion, invalidAnswer, unavailable
}

public struct BoneUserQuestion: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case singleChoice, multipleChoice, text }
    public struct Option: Codable, Equatable, Identifiable, Sendable {
        public let id: String
        public let label: String
        public init(id: String, label: String) { self.id = id; self.label = label }
    }
    public let question: String
    public let kind: Kind
    public let options: [Option]
    public init(question: String, kind: Kind, options: [Option] = []) throws {
        self.question = question; self.kind = kind; self.options = options
        try validated()
    }
    public func validated() throws {
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              question.utf8.count <= 2_048, options.count <= 12,
              Set(options.map(\.id)).count == options.count else { throw BoneAskUserError.invalidQuestion }
        for option in options {
            guard (1...64).contains(option.id.utf8.count), option.id.utf8.allSatisfy({
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
            }), !option.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            option.label.utf8.count <= 256 else { throw BoneAskUserError.invalidQuestion }
        }
        switch kind {
        case .text: guard options.isEmpty else { throw BoneAskUserError.invalidQuestion }
        case .singleChoice: guard options.count >= 2 else { throw BoneAskUserError.invalidQuestion }
        case .multipleChoice: guard !options.isEmpty else { throw BoneAskUserError.invalidQuestion }
        }
    }
}

/// A reply is ordinary user data, never a capability grant or an approval ticket for another tool.
public struct BoneUserAnswer: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case answered, cancelled }
    public let status: Status
    public let selectedOptionIDs: [String]
    public let text: String?
    public init(status: Status = .answered, selectedOptionIDs: [String] = [], text: String? = nil) {
        self.status = status; self.selectedOptionIDs = selectedOptionIDs; self.text = text
    }
    public func validated(for question: BoneUserQuestion) throws -> Self {
        try question.validated()
        guard selectedOptionIDs.count <= 12,
              Set(selectedOptionIDs).count == selectedOptionIDs.count,
              (text?.utf8.count ?? 0) <= 8_192 else { throw BoneAskUserError.invalidAnswer }
        if status == .cancelled {
            guard selectedOptionIDs.isEmpty, text == nil else { throw BoneAskUserError.invalidAnswer }
            return self
        }
        switch question.kind {
        case .text:
            guard selectedOptionIDs.isEmpty, let text,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BoneAskUserError.invalidAnswer }
        case .singleChoice, .multipleChoice:
            guard text == nil, !selectedOptionIDs.isEmpty,
                  question.kind != .singleChoice || selectedOptionIDs.count == 1,
                  selectedOptionIDs.allSatisfy({ id in question.options.contains { $0.id == id } }) else {
                throw BoneAskUserError.invalidAnswer
            }
        }
        return self
    }
}

/// The Host owns presentation, bounded waiting, identity and cancellation. Nothing is auto-answered.
/// User-visible interaction is an effect: Agent execution needs its normal Host policy + effect pipeline.
public struct BoneAskUserTool<Context: BoneAgentToolContext>: BoneAgentTool {
    public typealias Input = BoneUserQuestion
    public typealias Output = BoneUserAnswer
    public typealias Handler = @Sendable (Input, Context) async throws -> Output
    private let handler: Handler
    public init(ask: @escaping Handler) { handler = ask }
    public static var definition: BoneAgentToolDefinition {
        .init(id: "user.ask", version: "1.0.0", title: "询问用户",
              summary: "通过宿主询问用户并等待真实回答。singleChoice为单选，multipleChoice为多选，text为自由文本。选项ID稳定且不重复；取消不代表同意，任何回答都不授予其他工具权限。",
              wireName: "user_ask", schemaVersion: 1,
              inputSchema: .object(properties: [
                "question": .string(enumValues: [], minimumLength: 1, maximumLength: 2_048),
                "kind": .string(enumValues: ["singleChoice", "multipleChoice", "text"], minimumLength: nil, maximumLength: nil),
                "options": .array(items: .object(properties: [
                    "id": .string(enumValues: [], minimumLength: 1, maximumLength: 64),
                    "label": .string(enumValues: [], minimumLength: 1, maximumLength: 256)
                ], required: ["id", "label"], additionalProperties: false), minimumItems: 0, maximumItems: 12)
              ], required: ["question", "kind", "options"], additionalProperties: false),
              executionPolicy: .serial,
              impact: .init(dataAccess: .userPrivate, externalTransmission: .none, stateChange: .none,
                  economic: .none, userVisible: .notification, permissionChange: .none))
    }
    public func execute(input: Input, context: Context) async throws -> Output {
        try input.validated(); try Task.checkCancellation()
        let answer = try await handler(input, context)
        try Task.checkCancellation()
        return try answer.validated(for: input)
    }
}
