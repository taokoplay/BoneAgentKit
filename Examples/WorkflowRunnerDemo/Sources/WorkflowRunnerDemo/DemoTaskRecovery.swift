import Foundation

/// Chooses a free draft slot without replacing text the user has already composed.
enum DemoTaskRecovery {
    enum Destination: Equatable, Sendable { case draft, retained, alreadyPresent, full }

    static func destination(for task: DemoChatTaskBundle, draft: DemoChatTaskBundle, retained: DemoChatTaskBundle?) -> Destination {
        if task.isEmpty || task.hasSameContents(as: draft) || retained?.hasSameContents(as: task) == true { return .alreadyPresent }
        if (draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.text == task.text) &&
            draft.materials.isSubset(of: task.materials) { return .draft }
        return retained == nil ? .retained : .full
    }

    struct RetryDrafts: Equatable, Sendable { let task: String; let retained: String? }

    static func preparingRetry(original: String, draft: String, retained: String?) -> RetryDrafts? {
        guard !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if draft == original || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .init(task: original, retained: retained)
        }
        if retained == nil || retained == original || retained == draft {
            return .init(task: original, retained: draft)
        }
        return nil
    }

    static func destination(for text: String, draft: String, retained: String?) -> Destination {
        guard !text.isEmpty, draft != text, retained != text else { return .alreadyPresent }
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .draft }
        if retained == nil { return .retained }
        return .full
    }
}
