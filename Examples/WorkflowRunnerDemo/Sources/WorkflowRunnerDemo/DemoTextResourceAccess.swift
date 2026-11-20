import BoneAgentKit

/// A Conversation may read only references explicitly sent into that Conversation.
/// Pending drafts and retained failed-task files remain local until selected for a send.
actor DemoTextResourceAccess {
    private var allowed: [String: BoneToolTextResourceReference] = [:]
    func allow(_ references: [BoneToolTextResourceReference]) {
        for reference in references { allowed[reference.id] = reference }
    }
    /// 撤销当前会话的单份授权；已有工具对象之后的每次操作仍须检查。
    func revoke(id: String) { allowed.removeValue(forKey: id) }
    func permits(_ reference: BoneToolTextResourceReference) -> Bool { allowed[reference.id] == reference }
    func reference(id: String) -> BoneToolTextResourceReference? { allowed[id] }
    func references() -> [BoneToolTextResourceReference] { Array(allowed.values) }
}
