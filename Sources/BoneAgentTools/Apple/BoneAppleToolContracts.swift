import Foundation
import BoneAgentKit

/// Apple 系统工具的稳定输入和执行错误分类。
public enum BoneAppleToolError: Error, Codable, Equatable, Sendable {
    case invalidArguments
    case permissionDenied
    case unavailable
    case notFound
    case conflict
    case cancelled
    case unsupported
    case operationFailed
}

/// Apple 系统工具的有限操作状态。
public enum BoneAppleOperationStatus: String, Codable, Equatable, Sendable {
    case completed
    case scheduled
    case cancelled
    case deleted
    case permissionRequired
}

private enum BoneAppleToolSupport {
    static let maximumIdentifierLength = 128
    static let maximumTitleLength = 256
    static let maximumBodyLength = 2_048
    static let maximumNotesLength = 4_096
    static let maximumQueryLength = 256
    static let maximumLimit = 50

    static func validText(_ value: String?, maximumBytes: Int, required: Bool = false) -> Bool {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (!required || !trimmed.isEmpty) && trimmed.utf8.count <= maximumBytes
    }

    static func validIdentifier(_ value: String?) -> Bool {
        guard let value, !value.isEmpty, value.utf8.count <= maximumIdentifierLength else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.")).contains(scalar)
        }
    }

    static func validISO8601(_ value: String?) -> Bool {
        guard let value, value.utf8.count <= 64 else { return false }
        return ISO8601DateFormatter().date(from: value) != nil
    }

    static func validLimit(_ value: Int) -> Bool { (1...maximumLimit).contains(value) }

    static func decodeOptional<Value: Decodable, Key: CodingKey>(
        _ type: Value.Type,
        from container: KeyedDecodingContainer<Key>,
        forKey key: Key
    ) throws -> Value? {
        guard container.contains(key) else { return nil }
        return try container.decode(Value.self, forKey: key)
    }

    static func containsOnlyKeys(_ decoder: Decoder, allowed: Set<String>) throws -> Bool {
        let container = try decoder.container(keyedBy: AnyKey.self)
        return container.allKeys.allSatisfy { allowed.contains($0.stringValue) }
    }

    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
}

/// 日历事件的最小安全返回字段。
public struct BoneCalendarEvent: Codable, Equatable, Sendable {
    public let identifier: String
    public let calendarIdentifier: String
    public let calendarTitle: String
    public let title: String
    public let notes: String?
    public let startDate: String
    public let endDate: String
    public let isAllDay: Bool
    public let lastModifiedDate: String?

    public init(identifier: String, calendarIdentifier: String, calendarTitle: String, title: String,
                notes: String?, startDate: String, endDate: String, isAllDay: Bool,
                lastModifiedDate: String?) {
        self.identifier = identifier
        self.calendarIdentifier = calendarIdentifier
        self.calendarTitle = calendarTitle
        self.title = title
        self.notes = notes
        self.startDate = startDate
        self.endDate = endDate
        self.isAllDay = isAllDay
        self.lastModifiedDate = lastModifiedDate
    }
}

/// 日历工具的查询、创建、更新和删除请求。
public struct BoneCalendarRequest: Codable, Equatable, Sendable {
    public enum Action: String, Codable, CaseIterable, Sendable { case search, get, create, update, delete }

    public let action: Action
    public let identifier: String?
    public let calendarIdentifier: String?
    public let title: String?
    public let notes: String?
    public let startDate: String?
    public let endDate: String?
    public let query: String?
    public let limit: Int

    public init(action: Action, identifier: String? = nil, calendarIdentifier: String? = nil,
                title: String? = nil, notes: String? = nil, startDate: String? = nil,
                endDate: String? = nil, query: String? = nil, limit: Int = 20) throws {
        self.action = action
        self.identifier = identifier
        self.calendarIdentifier = calendarIdentifier
        self.title = title
        self.notes = notes
        self.startDate = startDate
        self.endDate = endDate
        self.query = query
        self.limit = limit
        try Self.validate(action: action, identifier: identifier, calendarIdentifier: calendarIdentifier,
                          title: title, notes: notes, startDate: startDate, endDate: endDate,
                          query: query, limit: limit)
    }

    public init(from decoder: Decoder) throws {
        guard try BoneAppleToolSupport.containsOnlyKeys(decoder, allowed: [
            "action", "identifier", "calendarIdentifier", "title", "notes", "startDate", "endDate", "query", "limit"
        ]) else { throw BoneAppleToolError.invalidArguments }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(action: container.decode(Action.self, forKey: .action),
                      identifier: try BoneAppleToolSupport.decodeOptional(String.self, from: container, forKey: .identifier),
                      calendarIdentifier: try BoneAppleToolSupport.decodeOptional(String.self, from: container, forKey: .calendarIdentifier),
                      title: try BoneAppleToolSupport.decodeOptional(String.self, from: container, forKey: .title),
                      notes: try BoneAppleToolSupport.decodeOptional(String.self, from: container, forKey: .notes),
                      startDate: try BoneAppleToolSupport.decodeOptional(String.self, from: container, forKey: .startDate),
                      endDate: try BoneAppleToolSupport.decodeOptional(String.self, from: container, forKey: .endDate),
                      query: try BoneAppleToolSupport.decodeOptional(String.self, from: container, forKey: .query),
                      limit: try container.decodeIfPresent(Int.self, forKey: .limit) ?? 20)
    }

    private static func validate(action: Action, identifier: String?, calendarIdentifier: String?, title: String?,
                                 notes: String?, startDate: String?, endDate: String?, query: String?, limit: Int) throws {
        guard BoneAppleToolSupport.validLimit(limit),
              (identifier == nil || BoneAppleToolSupport.validIdentifier(identifier)),
              (calendarIdentifier == nil || BoneAppleToolSupport.validIdentifier(calendarIdentifier)),
              BoneAppleToolSupport.validText(title, maximumBytes: BoneAppleToolSupport.maximumTitleLength),
              BoneAppleToolSupport.validText(notes, maximumBytes: BoneAppleToolSupport.maximumNotesLength),
              BoneAppleToolSupport.validText(query, maximumBytes: BoneAppleToolSupport.maximumQueryLength),
              (startDate == nil || BoneAppleToolSupport.validISO8601(startDate)),
              (endDate == nil || BoneAppleToolSupport.validISO8601(endDate)) else {
            throw BoneAppleToolError.invalidArguments
        }
        switch action {
        case .search:
            guard startDate == nil || endDate != nil else { throw BoneAppleToolError.invalidArguments }
        case .get, .delete:
            guard BoneAppleToolSupport.validIdentifier(identifier) else { throw BoneAppleToolError.invalidArguments }
        case .create:
            guard BoneAppleToolSupport.validText(title, maximumBytes: BoneAppleToolSupport.maximumTitleLength, required: true),
                  BoneAppleToolSupport.validISO8601(startDate), BoneAppleToolSupport.validISO8601(endDate) else {
                throw BoneAppleToolError.invalidArguments
            }
        case .update:
            guard BoneAppleToolSupport.validIdentifier(identifier),
                  title != nil || notes != nil || startDate != nil || endDate != nil || calendarIdentifier != nil else {
                throw BoneAppleToolError.invalidArguments
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case action, identifier, calendarIdentifier, title, notes, startDate, endDate, query, limit
    }
}

/// 日历工具的结果。
public struct BoneCalendarResult: Codable, Equatable, Sendable {
    public let status: BoneAppleOperationStatus
    public let events: [BoneCalendarEvent]
    public let event: BoneCalendarEvent?
    public let identifier: String?

    public init(status: BoneAppleOperationStatus, events: [BoneCalendarEvent] = [],
                event: BoneCalendarEvent? = nil, identifier: String? = nil) {
        self.status = status
        self.events = events
        self.event = event
        self.identifier = identifier
    }
}

/// 日历工具的 Host 注入适配器。
public struct BoneCalendarTool<Context: BoneAgentToolContext>: BoneAgentTool {
    public typealias Input = BoneCalendarRequest
    public typealias Output = BoneCalendarResult
    public typealias Handler = @Sendable (Input, Context) async throws -> Output
    private let handler: Handler

    public init(handler: @escaping Handler) { self.handler = handler }

    public static var definition: BoneAgentToolDefinition {
        .init(id: "calendar.manage", version: "1.0.0", title: "管理日历",
              summary: "查询或管理用户授权的日历事件。创建、修改和删除前需要宿主确认。",
              wireName: "calendar_manage", schemaVersion: 1,
              inputSchema: .object(properties: [
                "action": .string(enumValues: BoneCalendarRequest.Action.allCases.map(\.rawValue), minimumLength: nil, maximumLength: nil),
                "identifier": .string(enumValues: [], minimumLength: 1, maximumLength: 128),
                "calendarIdentifier": .string(enumValues: [], minimumLength: 1, maximumLength: 128),
                "title": .string(enumValues: [], minimumLength: 1, maximumLength: 256),
                "notes": .string(enumValues: [], minimumLength: 0, maximumLength: 4_096),
                "startDate": .string(enumValues: [], minimumLength: 1, maximumLength: 64),
                "endDate": .string(enumValues: [], minimumLength: 1, maximumLength: 64),
                "query": .string(enumValues: [], minimumLength: 0, maximumLength: 256),
                "limit": .integer(minimum: 1, maximum: 50)
              ], required: ["action"], additionalProperties: false), executionPolicy: .serial,
              impact: .init(dataAccess: .userPrivate, externalTransmission: .none,
                            stateChange: .reversible, economic: .none, userVisible: .none,
                            permissionChange: .grantsAccess))
    }

    public func execute(input: Input, context: Context) async throws -> Output {
        try Task.checkCancellation()
        let result = try await handler(input, context)
        try Task.checkCancellation()
        return result
    }
}

/// 提醒事项的最小安全返回字段。
public struct BoneReminderItem: Codable, Equatable, Sendable {
    public let identifier: String
    public let listIdentifier: String
    public let listTitle: String
    public let title: String
    public let notes: String?
    public let dueDate: String?
    public let isCompleted: Bool

    public init(identifier: String, listIdentifier: String, listTitle: String, title: String,
                notes: String?, dueDate: String?, isCompleted: Bool) {
        self.identifier = identifier
        self.listIdentifier = listIdentifier
        self.listTitle = listTitle
        self.title = title
        self.notes = notes
        self.dueDate = dueDate
        self.isCompleted = isCompleted
    }
}

/// 提醒事项工具的查询和变更请求。
public struct BoneReminderRequest: Codable, Equatable, Sendable {
    public enum Action: String, Codable, CaseIterable, Sendable { case search, create, update, complete, delete }
    public let action: Action
    public let identifier: String?
    public let listIdentifier: String?
    public let title: String?
    public let notes: String?
    public let dueDate: String?
    public let query: String?
    public let limit: Int

    public init(action: Action, identifier: String? = nil, listIdentifier: String? = nil, title: String? = nil,
                notes: String? = nil, dueDate: String? = nil, query: String? = nil, limit: Int = 20) throws {
        self.action = action; self.identifier = identifier; self.listIdentifier = listIdentifier
        self.title = title; self.notes = notes; self.dueDate = dueDate; self.query = query; self.limit = limit
        try Self.validate(action: action, identifier: identifier, listIdentifier: listIdentifier, title: title,
                          notes: notes, dueDate: dueDate, query: query, limit: limit)
    }

    public init(from decoder: Decoder) throws {
        guard try BoneAppleToolSupport.containsOnlyKeys(decoder, allowed: [
            "action", "identifier", "listIdentifier", "title", "notes", "dueDate", "query", "limit"
        ]) else { throw BoneAppleToolError.invalidArguments }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(action: container.decode(Action.self, forKey: .action),
                      identifier: try BoneAppleToolSupport.decodeOptional(String.self, from: container, forKey: .identifier),
                      listIdentifier: try BoneAppleToolSupport.decodeOptional(String.self, from: container, forKey: .listIdentifier),
                      title: try BoneAppleToolSupport.decodeOptional(String.self, from: container, forKey: .title),
                      notes: try BoneAppleToolSupport.decodeOptional(String.self, from: container, forKey: .notes),
                      dueDate: try BoneAppleToolSupport.decodeOptional(String.self, from: container, forKey: .dueDate),
                      query: try BoneAppleToolSupport.decodeOptional(String.self, from: container, forKey: .query),
                      limit: try container.decodeIfPresent(Int.self, forKey: .limit) ?? 20)
    }

    private static func validate(action: Action, identifier: String?, listIdentifier: String?, title: String?,
                                 notes: String?, dueDate: String?, query: String?, limit: Int) throws {
        guard BoneAppleToolSupport.validLimit(limit),
              (identifier == nil || BoneAppleToolSupport.validIdentifier(identifier)),
              (listIdentifier == nil || BoneAppleToolSupport.validIdentifier(listIdentifier)),
              BoneAppleToolSupport.validText(title, maximumBytes: BoneAppleToolSupport.maximumTitleLength),
              BoneAppleToolSupport.validText(notes, maximumBytes: BoneAppleToolSupport.maximumNotesLength),
              BoneAppleToolSupport.validText(query, maximumBytes: BoneAppleToolSupport.maximumQueryLength),
              (dueDate == nil || BoneAppleToolSupport.validISO8601(dueDate)) else { throw BoneAppleToolError.invalidArguments }
        switch action {
        case .search:
            break
        case .create:
            guard BoneAppleToolSupport.validText(title, maximumBytes: BoneAppleToolSupport.maximumTitleLength, required: true) else {
                throw BoneAppleToolError.invalidArguments
            }
        case .update:
            guard BoneAppleToolSupport.validIdentifier(identifier),
                  title != nil || notes != nil || dueDate != nil || listIdentifier != nil else {
                throw BoneAppleToolError.invalidArguments
            }
        case .complete, .delete:
            guard BoneAppleToolSupport.validIdentifier(identifier) else { throw BoneAppleToolError.invalidArguments }
        }
    }

    private enum CodingKeys: String, CodingKey { case action, identifier, listIdentifier, title, notes, dueDate, query, limit }
}

/// 提醒事项工具的结果。
public struct BoneReminderResult: Codable, Equatable, Sendable {
    public let status: BoneAppleOperationStatus
    public let reminders: [BoneReminderItem]
    public let reminder: BoneReminderItem?
    public let identifier: String?

    public init(status: BoneAppleOperationStatus, reminders: [BoneReminderItem] = [],
                reminder: BoneReminderItem? = nil, identifier: String? = nil) {
        self.status = status; self.reminders = reminders; self.reminder = reminder; self.identifier = identifier
    }
}

/// 提醒事项工具的 Host 注入适配器。
public struct BoneReminderTool<Context: BoneAgentToolContext>: BoneAgentTool {
    public typealias Input = BoneReminderRequest
    public typealias Output = BoneReminderResult
    public typealias Handler = @Sendable (Input, Context) async throws -> Output
    private let handler: Handler

    public init(handler: @escaping Handler) { self.handler = handler }

    public static var definition: BoneAgentToolDefinition {
        .init(id: "reminder.manage", version: "1.0.0", title: "管理提醒事项",
              summary: "查询或管理用户授权的提醒事项。创建、完成和删除前需要宿主确认。",
              wireName: "reminder_manage", schemaVersion: 1,
              inputSchema: .object(properties: [
                "action": .string(enumValues: BoneReminderRequest.Action.allCases.map(\.rawValue), minimumLength: nil, maximumLength: nil),
                "identifier": .string(enumValues: [], minimumLength: 1, maximumLength: 128),
                "listIdentifier": .string(enumValues: [], minimumLength: 1, maximumLength: 128),
                "title": .string(enumValues: [], minimumLength: 1, maximumLength: 256),
                "notes": .string(enumValues: [], minimumLength: 0, maximumLength: 4_096),
                "dueDate": .string(enumValues: [], minimumLength: 1, maximumLength: 64),
                "query": .string(enumValues: [], minimumLength: 0, maximumLength: 256),
                "limit": .integer(minimum: 1, maximum: 50)
              ], required: ["action"], additionalProperties: false), executionPolicy: .serial,
              impact: .init(dataAccess: .userPrivate, externalTransmission: .none,
                            stateChange: .reversible, economic: .none, userVisible: .none,
                            permissionChange: .grantsAccess))
    }

    public func execute(input: Input, context: Context) async throws -> Output {
        try Task.checkCancellation()
        let result = try await handler(input, context)
        try Task.checkCancellation()
        return result
    }
}

/// 本地通知的最小安全返回字段。
public struct BoneNotificationItem: Codable, Equatable, Sendable {
    public let identifier: String
    public let title: String
    public let body: String
    public let fireDate: String?
    public let repeats: Bool

    public init(identifier: String, title: String, body: String, fireDate: String?, repeats: Bool) {
        self.identifier = identifier; self.title = title; self.body = body; self.fireDate = fireDate; self.repeats = repeats
    }
}

/// 本地通知工具请求。列表和取消只作用于本工具登记过的通知。
public struct BoneNotificationRequest: Codable, Equatable, Sendable {
    public enum Action: String, Codable, CaseIterable, Sendable { case schedule, list, cancel }
    public let action: Action
    public let identifier: String?
    public let title: String?
    public let body: String?
    public let fireDate: String?
    public let repeats: Bool

    public init(action: Action, identifier: String? = nil, title: String? = nil, body: String? = nil,
                fireDate: String? = nil, repeats: Bool = false) throws {
        self.action = action; self.identifier = identifier; self.title = title; self.body = body
        self.fireDate = fireDate; self.repeats = repeats
        try Self.validate(action: action, identifier: identifier, title: title, body: body, fireDate: fireDate)
    }

    public init(from decoder: Decoder) throws {
        guard try BoneAppleToolSupport.containsOnlyKeys(decoder, allowed: ["action", "identifier", "title", "body", "fireDate", "repeats"]) else {
            throw BoneAppleToolError.invalidArguments
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(action: container.decode(Action.self, forKey: .action),
                      identifier: try BoneAppleToolSupport.decodeOptional(String.self, from: container, forKey: .identifier),
                      title: try BoneAppleToolSupport.decodeOptional(String.self, from: container, forKey: .title),
                      body: try BoneAppleToolSupport.decodeOptional(String.self, from: container, forKey: .body),
                      fireDate: try BoneAppleToolSupport.decodeOptional(String.self, from: container, forKey: .fireDate),
                      repeats: try container.decodeIfPresent(Bool.self, forKey: .repeats) ?? false)
    }

    private static func validate(action: Action, identifier: String?, title: String?, body: String?, fireDate: String?) throws {
        guard (identifier == nil || BoneAppleToolSupport.validIdentifier(identifier)),
              BoneAppleToolSupport.validText(title, maximumBytes: BoneAppleToolSupport.maximumTitleLength),
              BoneAppleToolSupport.validText(body, maximumBytes: BoneAppleToolSupport.maximumBodyLength),
              (fireDate == nil || BoneAppleToolSupport.validISO8601(fireDate)) else { throw BoneAppleToolError.invalidArguments }
        switch action {
        case .schedule:
            guard BoneAppleToolSupport.validIdentifier(identifier),
                  BoneAppleToolSupport.validText(title, maximumBytes: BoneAppleToolSupport.maximumTitleLength, required: true),
                  BoneAppleToolSupport.validISO8601(fireDate),
                  let fireDate, let date = ISO8601DateFormatter().date(from: fireDate), date > Date() else {
                throw BoneAppleToolError.invalidArguments
            }
        case .list, .cancel:
            if action == .cancel && !BoneAppleToolSupport.validIdentifier(identifier) { throw BoneAppleToolError.invalidArguments }
        }
    }

    private enum CodingKeys: String, CodingKey { case action, identifier, title, body, fireDate, repeats }
}

/// 本地通知工具的结果。
public struct BoneNotificationResult: Codable, Equatable, Sendable {
    public let status: BoneAppleOperationStatus
    public let notifications: [BoneNotificationItem]
    public let identifier: String?

    public init(status: BoneAppleOperationStatus, notifications: [BoneNotificationItem] = [], identifier: String? = nil) {
        self.status = status; self.notifications = notifications; self.identifier = identifier
    }
}

/// 本地通知工具的 Host 注入适配器。
public struct BoneNotificationTool<Context: BoneAgentToolContext>: BoneAgentTool {
    public typealias Input = BoneNotificationRequest
    public typealias Output = BoneNotificationResult
    public typealias Handler = @Sendable (Input, Context) async throws -> Output
    private let handler: Handler

    public init(handler: @escaping Handler) { self.handler = handler }

    public static var definition: BoneAgentToolDefinition {
        .init(id: "notification.manage", version: "1.0.0", title: "管理本地通知",
              summary: "创建、列出和取消本 App 创建的本地通知。不能读取其他 App 的系统通知。",
              wireName: "notification_manage", schemaVersion: 1,
              inputSchema: .object(properties: [
                "action": .string(enumValues: BoneNotificationRequest.Action.allCases.map(\.rawValue), minimumLength: nil, maximumLength: nil),
                "identifier": .string(enumValues: [], minimumLength: 1, maximumLength: 128),
                "title": .string(enumValues: [], minimumLength: 1, maximumLength: 256),
                "body": .string(enumValues: [], minimumLength: 0, maximumLength: 2_048),
                "fireDate": .string(enumValues: [], minimumLength: 1, maximumLength: 64),
                "repeats": .boolean
              ], required: ["action"], additionalProperties: false), executionPolicy: .serial,
              impact: .init(dataAccess: .userPrivate, externalTransmission: .none,
                            stateChange: .reversible, economic: .none, userVisible: .notification,
                            permissionChange: .grantsAccess))
    }

    public func execute(input: Input, context: Context) async throws -> Output {
        try Task.checkCancellation()
        let result = try await handler(input, context)
        try Task.checkCancellation()
        return result
    }
}

/// 相册工具请求。save 使用 Host 已登记的图片 ID，避免把图片正文放入工具参数。
public struct BonePhotoRequest: Codable, Equatable, Sendable {
    public enum Action: String, Codable, CaseIterable, Sendable { case save }
    public let action: Action
    public let imageID: String
    public let albumTitle: String?

    public init(action: Action = .save, imageID: String, albumTitle: String? = nil) throws {
        self.action = action; self.imageID = imageID; self.albumTitle = albumTitle
        guard BoneAppleToolSupport.validIdentifier(imageID),
              BoneAppleToolSupport.validText(albumTitle, maximumBytes: BoneAppleToolSupport.maximumTitleLength) else {
            throw BoneAppleToolError.invalidArguments
        }
    }

    public init(from decoder: Decoder) throws {
        guard try BoneAppleToolSupport.containsOnlyKeys(decoder, allowed: ["action", "imageID", "albumTitle"]) else {
            throw BoneAppleToolError.invalidArguments
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(action: container.decodeIfPresent(Action.self, forKey: .action) ?? .save,
                      imageID: container.decode(String.self, forKey: .imageID),
                      albumTitle: try BoneAppleToolSupport.decodeOptional(String.self, from: container, forKey: .albumTitle))
    }

    private enum CodingKeys: String, CodingKey { case action, imageID, albumTitle }
}

/// 相册工具结果。
public struct BonePhotoResult: Codable, Equatable, Sendable {
    public let status: BoneAppleOperationStatus
    public let imageID: String
    public let assetIdentifier: String?

    public init(status: BoneAppleOperationStatus, imageID: String, assetIdentifier: String?) {
        self.status = status; self.imageID = imageID; self.assetIdentifier = assetIdentifier
    }
}

/// 相册工具的 Host 注入适配器。
public struct BonePhotoTool<Context: BoneAgentToolContext>: BoneAgentTool {
    public typealias Input = BonePhotoRequest
    public typealias Output = BonePhotoResult
    public typealias Handler = @Sendable (Input, Context) async throws -> Output
    private let handler: Handler

    public init(handler: @escaping Handler) { self.handler = handler }

    public static var definition: BoneAgentToolDefinition {
        .init(id: "photo.manage", version: "1.0.0", title: "保存到相册",
              summary: "把用户已选择或本 App 已生成的图片保存到系统相册。保存前需要宿主确认。",
              wireName: "photo_manage", schemaVersion: 1,
              inputSchema: .object(properties: [
                "action": .string(enumValues: BonePhotoRequest.Action.allCases.map(\.rawValue), minimumLength: nil, maximumLength: nil),
                "imageID": .string(enumValues: [], minimumLength: 1, maximumLength: 128),
                "albumTitle": .string(enumValues: [], minimumLength: 0, maximumLength: 256)
              ], required: ["imageID"], additionalProperties: false), executionPolicy: .serial,
              impact: .init(dataAccess: .userPrivate, externalTransmission: .none,
                            stateChange: .reversible, economic: .none, userVisible: .publication,
                            permissionChange: .grantsAccess))
    }

    public func execute(input: Input, context: Context) async throws -> Output {
        try Task.checkCancellation()
        let result = try await handler(input, context)
        try Task.checkCancellation()
        return result
    }
}

/// 联系人的有界联系方式字段。
public struct BoneContactValue: Codable, Equatable, Sendable {
    public let label: String?
    public let value: String

    /// 创建联系人联系方式返回值。
    /// - Parameters:
    ///   - label: 系统标签，可为空。
    ///   - value: 电话号码或电子邮箱地址。
    public init(label: String?, value: String) {
        self.label = label
        self.value = value
    }
}

/// 联系人的最小安全返回字段。
public struct BoneContactItem: Codable, Equatable, Sendable {
    public let identifier: String
    public let givenName: String
    public let familyName: String
    public let middleName: String
    public let organizationName: String
    public let phones: [BoneContactValue]
    public let emails: [BoneContactValue]

    /// 创建联系人返回值。
    /// - Parameters:
    ///   - identifier: 系统联系人标识。
    ///   - givenName: 名。
    ///   - familyName: 姓。
    ///   - middleName: 中间名。
    ///   - organizationName: 组织名称。
    ///   - phones: 有界电话号码列表。
    ///   - emails: 有界电子邮箱列表。
    public init(identifier: String, givenName: String, familyName: String, middleName: String,
                organizationName: String, phones: [BoneContactValue], emails: [BoneContactValue]) {
        self.identifier = identifier
        self.givenName = givenName
        self.familyName = familyName
        self.middleName = middleName
        self.organizationName = organizationName
        self.phones = phones
        self.emails = emails
    }
}

/// 联系人工具的查询和变更请求。
public struct BoneContactRequest: Codable, Equatable, Sendable {
    public enum Action: String, Codable, CaseIterable, Sendable { case search, get, create, update, delete }

    public let action: Action
    public let identifier: String?
    public let givenName: String?
    public let familyName: String?
    public let middleName: String?
    public let organizationName: String?
    public let phones: [String]?
    public let emails: [String]?
    public let query: String?
    public let limit: Int

    /// 创建并校验联系人请求。
    /// - Parameters:
    ///   - action: 查询、获取、创建、更新或删除。
    ///   - identifier: 查询、更新或删除目标联系人标识。
    ///   - givenName: 联系人名。
    ///   - familyName: 联系人姓。
    ///   - middleName: 联系人中间名。
    ///   - organizationName: 联系人组织名称。
    ///   - phones: 联系人电话号码列表。
    ///   - emails: 联系人电子邮箱列表。
    ///   - query: 按姓名、组织、电话或邮箱搜索的文本。
    ///   - limit: 搜索结果最大条数。
    public init(action: Action, identifier: String? = nil, givenName: String? = nil,
                familyName: String? = nil, middleName: String? = nil, organizationName: String? = nil,
                phones: [String]? = nil, emails: [String]? = nil, query: String? = nil, limit: Int = 20) throws {
        self.action = action
        self.identifier = identifier
        self.givenName = givenName
        self.familyName = familyName
        self.middleName = middleName
        self.organizationName = organizationName
        self.phones = phones
        self.emails = emails
        self.query = query
        self.limit = limit
        try Self.validate(action: action, identifier: identifier, givenName: givenName,
                          familyName: familyName, middleName: middleName,
                          organizationName: organizationName, phones: phones, emails: emails,
                          query: query, limit: limit)
    }

    /// 从模型 JSON 解码并校验联系人请求。
    /// - Parameter decoder: 模型工具参数解码器。
    public init(from decoder: Decoder) throws {
        guard try BoneAppleToolSupport.containsOnlyKeys(decoder, allowed: [
            "action", "identifier", "givenName", "familyName", "middleName", "organizationName",
            "phones", "emails", "query", "limit"
        ]) else { throw BoneAppleToolError.invalidArguments }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            action: container.decode(Action.self, forKey: .action),
            identifier: try BoneAppleToolSupport.decodeOptional(String.self, from: container, forKey: .identifier),
            givenName: try BoneAppleToolSupport.decodeOptional(String.self, from: container, forKey: .givenName),
            familyName: try BoneAppleToolSupport.decodeOptional(String.self, from: container, forKey: .familyName),
            middleName: try BoneAppleToolSupport.decodeOptional(String.self, from: container, forKey: .middleName),
            organizationName: try BoneAppleToolSupport.decodeOptional(String.self, from: container, forKey: .organizationName),
            phones: try BoneAppleToolSupport.decodeOptional([String].self, from: container, forKey: .phones),
            emails: try BoneAppleToolSupport.decodeOptional([String].self, from: container, forKey: .emails),
            query: try BoneAppleToolSupport.decodeOptional(String.self, from: container, forKey: .query),
            limit: try container.decodeIfPresent(Int.self, forKey: .limit) ?? 20
        )
    }

    private enum CodingKeys: String, CodingKey {
        case action, identifier, givenName, familyName, middleName, organizationName, phones, emails, query, limit
    }

    /// 校验联系人输入的字段范围和动作约束。
    /// - Parameters: 与初始化器对应的联系人请求字段。
    private static func validate(action: Action, identifier: String?, givenName: String?, familyName: String?,
                                 middleName: String?, organizationName: String?, phones: [String]?, emails: [String]?,
                                 query: String?, limit: Int) throws {
        guard BoneAppleToolSupport.validLimit(limit),
              (identifier == nil || BoneAppleToolSupport.validIdentifier(identifier)),
              BoneAppleToolSupport.validText(givenName, maximumBytes: BoneAppleToolSupport.maximumTitleLength),
              BoneAppleToolSupport.validText(familyName, maximumBytes: BoneAppleToolSupport.maximumTitleLength),
              BoneAppleToolSupport.validText(middleName, maximumBytes: BoneAppleToolSupport.maximumTitleLength),
              BoneAppleToolSupport.validText(organizationName, maximumBytes: BoneAppleToolSupport.maximumTitleLength),
              BoneAppleToolSupport.validText(query, maximumBytes: BoneAppleToolSupport.maximumQueryLength),
              validValues(phones), validValues(emails) else {
            throw BoneAppleToolError.invalidArguments
        }
        switch action {
        case .search:
            break
        case .get, .delete:
            guard BoneAppleToolSupport.validIdentifier(identifier) else { throw BoneAppleToolError.invalidArguments }
        case .create:
            guard hasIdentity(givenName: givenName, familyName: familyName, organizationName: organizationName) else {
                throw BoneAppleToolError.invalidArguments
            }
        case .update:
            guard BoneAppleToolSupport.validIdentifier(identifier),
                  givenName != nil || familyName != nil || middleName != nil || organizationName != nil ||
                  phones != nil || emails != nil else {
                throw BoneAppleToolError.invalidArguments
            }
        }
    }

    /// 校验电话号码或邮箱数组的数量与单项长度。
    /// - Parameter values: 待校验的联系方式数组。
    /// - Returns: 数组满足有界输入合同。
    private static func validValues(_ values: [String]?) -> Bool {
        guard let values else { return true }
        return values.count <= 8 && values.allSatisfy {
            BoneAppleToolSupport.validText($0, maximumBytes: BoneAppleToolSupport.maximumBodyLength, required: true)
        }
    }

    /// 判断联系人创建请求是否至少包含一个可识别主体字段。
    /// - Parameters:
    ///   - givenName: 联系人名。
    ///   - familyName: 联系人姓。
    ///   - organizationName: 组织名称。
    /// - Returns: 至少有一个非空主体字段。
    private static func hasIdentity(givenName: String?, familyName: String?, organizationName: String?) -> Bool {
        [givenName, familyName, organizationName].contains {
            BoneAppleToolSupport.validText($0, maximumBytes: BoneAppleToolSupport.maximumTitleLength, required: true)
        }
    }
}

/// 联系人工具的结果。
public struct BoneContactResult: Codable, Equatable, Sendable {
    public let status: BoneAppleOperationStatus
    public let contacts: [BoneContactItem]
    public let contact: BoneContactItem?
    public let identifier: String?

    /// 创建联系人操作结果。
    /// - Parameters:
    ///   - status: 操作状态。
    ///   - contacts: 搜索结果。
    ///   - contact: 单个联系人结果。
    ///   - identifier: 受影响联系人标识。
    public init(status: BoneAppleOperationStatus, contacts: [BoneContactItem] = [],
                contact: BoneContactItem? = nil, identifier: String? = nil) {
        self.status = status
        self.contacts = contacts
        self.contact = contact
        self.identifier = identifier
    }
}

/// 联系人的 Host 注入适配器。
public struct BoneContactTool<Context: BoneAgentToolContext>: BoneAgentTool {
    public typealias Input = BoneContactRequest
    public typealias Output = BoneContactResult
    public typealias Handler = @Sendable (Input, Context) async throws -> Output
    private let handler: Handler

    /// 创建联系人 Host 适配器。
    /// - Parameter handler: 由平台 Host 执行的联系人处理闭包。
    public init(handler: @escaping Handler) { self.handler = handler }

    public static var definition: BoneAgentToolDefinition {
        .init(id: "contact.manage", version: "1.0.0", title: "管理联系人",
              summary: "查询或管理用户授权的联系人。创建、修改和删除前需要宿主确认。",
              wireName: "contact_manage", schemaVersion: 1,
              inputSchema: .object(properties: [
                "action": .string(enumValues: BoneContactRequest.Action.allCases.map(\.rawValue), minimumLength: nil, maximumLength: nil),
                "identifier": .string(enumValues: [], minimumLength: 1, maximumLength: 128),
                "givenName": .string(enumValues: [], minimumLength: 0, maximumLength: 256),
                "familyName": .string(enumValues: [], minimumLength: 0, maximumLength: 256),
                "middleName": .string(enumValues: [], minimumLength: 0, maximumLength: 256),
                "organizationName": .string(enumValues: [], minimumLength: 0, maximumLength: 256),
                "phones": .array(items: .string(enumValues: [], minimumLength: 1, maximumLength: 2_048), minimumItems: 0, maximumItems: 8),
                "emails": .array(items: .string(enumValues: [], minimumLength: 1, maximumLength: 2_048), minimumItems: 0, maximumItems: 8),
                "query": .string(enumValues: [], minimumLength: 0, maximumLength: 256),
                "limit": .integer(minimum: 1, maximum: 50)
              ], required: ["action"], additionalProperties: false), executionPolicy: .serial,
              impact: .init(dataAccess: .userPrivate, externalTransmission: .none,
                            stateChange: .reversible, economic: .none, userVisible: .none,
                            permissionChange: .grantsAccess))
    }

    /// 执行联系人工具并传播取消状态。
    /// - Parameters:
    ///   - input: 已校验的联系人请求。
    ///   - context: 当前工具执行上下文。
    /// - Returns: Host 返回的联系人结果。
    public func execute(input: Input, context: Context) async throws -> Output {
        try Task.checkCancellation()
        let result = try await handler(input, context)
        try Task.checkCancellation()
        return result
    }
}
