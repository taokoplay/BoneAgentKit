import Foundation

struct DemoChatMessageRecord: Codable, Identifiable, Equatable, Sendable {
    enum Role: String, Codable, Sendable { case user, assistant }
    let id: UUID
    let role: Role
    let text: String
    var detail: String?
    var imageIDs: [String]
    var resourceIDs: [String]
    /// 统一文件资源身份，与旧文本资源身份分开保存。
    var fileResourceIDs: [String]

    init(id: UUID = UUID(), role: Role, text: String, detail: String? = nil,
         imageIDs: [String] = [], resourceIDs: [String] = [], fileResourceIDs: [String] = []) {
        self.id = id
        self.role = role
        self.text = text
        self.detail = detail
        self.imageIDs = imageIDs
        self.resourceIDs = resourceIDs
        self.fileResourceIDs = fileResourceIDs
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, text, detail, imageIDs, resourceIDs, fileResourceIDs
    }

    /// 兼容统一文件资源接入前的旧消息归档。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        role = try container.decode(Role.self, forKey: .role)
        text = try container.decode(String.self, forKey: .text)
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
        imageIDs = try container.decode([String].self, forKey: .imageIDs)
        resourceIDs = try container.decode([String].self, forKey: .resourceIDs)
        fileResourceIDs = try container.decodeIfPresent([String].self, forKey: .fileResourceIDs) ?? []
    }
}

/// Private Host data; never a Workflow checkpoint, credential record or retry permit.
struct DemoConversationArchive: Codable, Sendable {
    var schemaVersion = 1
    let bindingID: String
    let sdkState: Data
    let textResourceState: Data
    let imageState: Data
    /// 统一文件资源 Host 的引用状态，不包含大文件正文。
    var fileResourceState: Data = Data()
    let messages: [DemoChatMessageRecord]
    var requestInFlight: Bool

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, bindingID, sdkState, textResourceState, imageState, fileResourceState, messages, requestInFlight
    }

    init(bindingID: String, sdkState: Data, textResourceState: Data, imageState: Data,
         fileResourceState: Data = Data(), messages: [DemoChatMessageRecord], requestInFlight: Bool) {
        self.bindingID = bindingID
        self.sdkState = sdkState
        self.textResourceState = textResourceState
        self.imageState = imageState
        self.fileResourceState = fileResourceState
        self.messages = messages
        self.requestInFlight = requestInFlight
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        bindingID = try container.decode(String.self, forKey: .bindingID)
        sdkState = try container.decode(Data.self, forKey: .sdkState)
        textResourceState = try container.decode(Data.self, forKey: .textResourceState)
        imageState = try container.decode(Data.self, forKey: .imageState)
        fileResourceState = try container.decodeIfPresent(Data.self, forKey: .fileResourceState) ?? Data()
        messages = try container.decode([DemoChatMessageRecord].self, forKey: .messages)
        requestInFlight = try container.decode(Bool.self, forKey: .requestInFlight)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(bindingID, forKey: .bindingID)
        try container.encode(sdkState, forKey: .sdkState)
        try container.encode(textResourceState, forKey: .textResourceState)
        try container.encode(imageState, forKey: .imageState)
        try container.encode(fileResourceState, forKey: .fileResourceState)
        try container.encode(messages, forKey: .messages)
        try container.encode(requestInFlight, forKey: .requestInFlight)
    }

    /// 校验归档中资源身份的固定字符集合，避免路径或控制字符进入存档。
    private static func validResourceID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 128 && id.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || $0 == 45 || $0 == 95
        }
    }

    func validated() throws {
        guard schemaVersion == 1,
              bindingID.count == 64, bindingID.allSatisfy({ $0.isHexDigit }),
              !sdkState.isEmpty, sdkState.count <= 12 * 1_048_576,
              textResourceState.count <= 4 * 1_048_576,
              imageState.count <= 20 * 1_048_576,
              fileResourceState.count <= 4 * 1_048_576,
              messages.count <= 128 else { throw DemoConversationStorageError.invalidArchive }
        var textBytes = 0
        for message in messages {
            guard message.text.utf8.count <= 256 * 1_024,
                  (message.detail?.utf8.count ?? 0) <= 1_024,
                  message.imageIDs.count <= 6,
                  message.imageIDs.allSatisfy({ UUID(uuidString: $0) != nil }),
                  message.resourceIDs.count <= 16,
                  message.fileResourceIDs.count <= 16,
                  message.resourceIDs.allSatisfy(Self.validResourceID),
                  message.fileResourceIDs.allSatisfy(Self.validResourceID) else {
                throw DemoConversationStorageError.invalidArchive
            }
            textBytes += message.text.utf8.count
        }
        guard textBytes <= 4 * 1_048_576,
              Set(messages.map(\.id)).count == messages.count else {
            throw DemoConversationStorageError.invalidArchive
        }
    }
}

enum DemoConversationStorageError: Error, Equatable, Sendable {
    case invalidArchive, bindingMismatch, unavailable, tooLarge
    var message: String {
        switch self {
        case .invalidArchive: return "本机会话记录无效，未恢复执行。可以清除后开始新对话。"
        case .bindingMismatch: return "保存的会话与当前连接、模型或工具配置不同，未载入。"
        case .unavailable: return "无法读写本机会话，请确认设备已解锁或关闭本机保存后重试。"
        case .tooLarge: return "本机会话已达到存储上限，请开始新对话。"
        }
    }
}
