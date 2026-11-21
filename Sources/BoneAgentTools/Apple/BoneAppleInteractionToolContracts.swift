import Foundation
import BoneAgentKit

/// Apple 前台交互工具使用的输入上限和基础校验。
private enum BoneAppleInteractionSupport {
    /// 文本字段的最大 UTF-8 字节数。
    static let maximumTextBytes = 4_096
    /// 地址、图片和资源标识的最大 UTF-8 字节数。
    static let maximumIdentifierBytes = 128
    /// 单次分享或草稿允许携带的最大收件人数量。
    static let maximumRecipientCount = 20
    /// 反向地理编码返回的最大地址数量。
    static let maximumPlacemarkCount = 10

    /// 判断可选文本是否满足长度约束。
    /// - Parameters:
    ///   - value: 待检查文本。
    ///   - maximumBytes: 允许的最大 UTF-8 字节数。
    ///   - required: 是否必须包含非空内容。
    /// - Returns: 文本满足约束时返回 true。
    static func validText(_ value: String?, maximumBytes: Int, required: Bool = false) -> Bool {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (!required || !trimmed.isEmpty) && trimmed.utf8.count <= maximumBytes
    }

    /// 判断不透明标识是否满足传输边界。
    /// - Parameter value: 待检查标识。
    /// - Returns: 标识非空且长度受限时返回 true。
    static func validIdentifier(_ value: String?) -> Bool {
        guard let value, !value.isEmpty, value.utf8.count <= maximumIdentifierBytes else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.")).contains(scalar)
        }
    }

    /// 验证网页地址，避免把任意本地路径交给分享 Host。
    /// - Parameter value: 待检查 URL 字符串。
    /// - Returns: 使用 HTTP 或 HTTPS 且带主机名时返回 true。
    static func validWebURL(_ value: String?) -> Bool {
        guard let value, value.utf8.count <= maximumTextBytes,
              let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else { return false }
        return true
    }

    /// 读取严格限制在模型输入合同内的键集合。
    /// - Parameters:
    ///   - decoder: 当前解码器。
    ///   - allowed: 允许出现的键名。
    /// - Returns: 所有键都在允许集合中时返回 true。
    static func containsOnlyKeys(_ decoder: Decoder, allowed: Set<String>) throws -> Bool {
        let container = try decoder.container(keyedBy: AnyKey.self)
        return container.allKeys.allSatisfy { allowed.contains($0.stringValue) }
    }

    /// 供严格输入解码使用的动态键。
    private struct AnyKey: CodingKey {
        /// 动态键的字符串名称。
        let stringValue: String
        /// 动态键不支持整数索引。
        var intValue: Int? { nil }
        /// 创建字符串动态键。
        init?(stringValue: String) { self.stringValue = stringValue }
        /// 拒绝整数动态键。
        init?(intValue: Int) { return nil }
    }
}

/// 位置工具的操作类型。
public enum BoneLocationAction: String, Codable, CaseIterable, Sendable {
    /// 请求当前设备位置。
    case current
    /// 对指定坐标执行反向地理编码。
    case reverseGeocode
}

/// 位置坐标的稳定返回模型。
public struct BoneLocationCoordinate: Codable, Equatable, Sendable {
    /// 纬度，范围为 -90 到 90。
    public let latitude: Double
    /// 经度，范围为 -180 到 180。
    public let longitude: Double
    /// 海拔，单位为米。
    public let altitude: Double?
    /// 水平精度，单位为米。
    public let horizontalAccuracy: Double?
    /// 位置采集时间。
    public let timestamp: String?

    /// 创建位置坐标结果。
    /// - Parameters:
    ///   - latitude: 纬度。
    ///   - longitude: 经度。
    ///   - altitude: 可选海拔。
    ///   - horizontalAccuracy: 可选水平精度。
    ///   - timestamp: 可选 ISO 8601 时间。
    public init(latitude: Double, longitude: Double, altitude: Double? = nil,
                horizontalAccuracy: Double? = nil, timestamp: String? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.horizontalAccuracy = horizontalAccuracy
        self.timestamp = timestamp
    }
}

/// 反向地理编码返回的最小地址字段。
public struct BoneLocationPlacemark: Codable, Equatable, Sendable {
    /// 国家或地区名称。
    public let country: String?
    /// 行政区域名称。
    public let administrativeArea: String?
    /// 城市或区县名称。
    public let locality: String?
    /// 街道名称。
    public let thoroughfare: String?
    /// 门牌号。
    public let subThoroughfare: String?
    /// 邮政编码。
    public let postalCode: String?
    /// 由系统拼接出的展示地址。
    public let formattedAddress: String?

    /// 创建地址结果。
    /// - Parameters:
    ///   - country: 国家或地区。
    ///   - administrativeArea: 行政区域。
    ///   - locality: 城市或区县。
    ///   - thoroughfare: 街道。
    ///   - subThoroughfare: 门牌号。
    ///   - postalCode: 邮政编码。
    ///   - formattedAddress: 展示地址。
    public init(country: String?, administrativeArea: String?, locality: String?, thoroughfare: String?,
                subThoroughfare: String?, postalCode: String?, formattedAddress: String?) {
        self.country = country
        self.administrativeArea = administrativeArea
        self.locality = locality
        self.thoroughfare = thoroughfare
        self.subThoroughfare = subThoroughfare
        self.postalCode = postalCode
        self.formattedAddress = formattedAddress
    }
}

/// 位置工具请求。
public struct BoneLocationRequest: Codable, Equatable, Sendable {
    /// 位置操作类型。
    public let action: BoneLocationAction
    /// 反向地理编码使用的纬度。
    public let latitude: Double?
    /// 反向地理编码使用的经度。
    public let longitude: Double?
    /// 反向地理编码最多返回的地址数量。
    public let limit: Int

    /// 创建位置请求并执行参数校验。
    /// - Parameters:
    ///   - action: 位置操作类型。
    ///   - latitude: 反向地理编码纬度。
    ///   - longitude: 反向地理编码经度。
    ///   - limit: 地址返回上限。
    public init(action: BoneLocationAction, latitude: Double? = nil, longitude: Double? = nil, limit: Int = 1) throws {
        self.action = action
        self.latitude = latitude
        self.longitude = longitude
        self.limit = limit
        try Self.validate(action: action, latitude: latitude, longitude: longitude, limit: limit)
    }

    /// 从模型 JSON 解码位置请求并复用同一校验逻辑。
    /// - Parameter decoder: 模型参数解码器。
    /// - Throws: 输入字段未知或参数不符合边界时抛出 Apple 工具错误。
    public init(from decoder: Decoder) throws {
        guard try BoneAppleInteractionSupport.containsOnlyKeys(decoder, allowed: ["action", "latitude", "longitude", "limit"]) else {
            throw BoneAppleToolError.invalidArguments
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let action = try container.decodeIfPresent(BoneLocationAction.self, forKey: .action) else {
            throw BoneAppleToolError.invalidArguments
        }
        let latitude = try container.decodeIfPresent(Double.self, forKey: .latitude)
        let longitude = try container.decodeIfPresent(Double.self, forKey: .longitude)
        let limit = try container.decodeIfPresent(Int.self, forKey: .limit) ?? 1
        try self.init(action: action, latitude: latitude, longitude: longitude, limit: limit)
    }

    /// 校验位置请求的操作与坐标关系。
    /// - Parameters:
    ///   - action: 位置操作类型。
    ///   - latitude: 纬度。
    ///   - longitude: 经度。
    ///   - limit: 地址返回上限。
    /// - Throws: 参数不符合合同边界时抛出 Apple 工具错误。
    private static func validate(action: BoneLocationAction, latitude: Double?, longitude: Double?, limit: Int) throws {
        guard (1...BoneAppleInteractionSupport.maximumPlacemarkCount).contains(limit) else {
            throw BoneAppleToolError.invalidArguments
        }
        switch action {
        case .current:
            guard latitude == nil, longitude == nil else { throw BoneAppleToolError.invalidArguments }
        case .reverseGeocode:
            guard let latitude, let longitude, latitude.isFinite, longitude.isFinite,
                  (-90...90).contains(latitude), (-180...180).contains(longitude) else {
                throw BoneAppleToolError.invalidArguments
            }
        }
    }

    /// 位置请求 JSON 字段。
    private enum CodingKeys: String, CodingKey { case action, latitude, longitude, limit }
}

/// 位置工具结果。
public struct BoneLocationResult: Codable, Equatable, Sendable {
    /// 操作状态。
    public let status: BoneAppleOperationStatus
    /// 当前设备位置，反向地理编码时为空。
    public let location: BoneLocationCoordinate?
    /// 反向地理编码地址列表。
    public let placemarks: [BoneLocationPlacemark]

    /// 创建位置结果。
    /// - Parameters:
    ///   - status: 操作状态。
    ///   - location: 当前设备位置。
    ///   - placemarks: 地址列表。
    public init(status: BoneAppleOperationStatus, location: BoneLocationCoordinate? = nil,
                placemarks: [BoneLocationPlacemark] = []) {
        self.status = status
        self.location = location
        self.placemarks = placemarks
    }
}

/// 位置工具的 Host 注入适配器。
public struct BoneLocationTool<Context: BoneAgentToolContext>: BoneAgentTool {
    /// 工具输入类型。
    public typealias Input = BoneLocationRequest
    /// 工具输出类型。
    public typealias Output = BoneLocationResult
    /// Host 处理闭包类型。
    public typealias Handler = @Sendable (Input, Context) async throws -> Output
    /// Host 处理闭包。
    private let handler: Handler

    /// 创建位置工具。
    /// - Parameter handler: 由平台 Host 执行的位置处理闭包。
    public init(handler: @escaping Handler) { self.handler = handler }

    /// 返回位置工具定义。
    public static var definition: BoneAgentToolDefinition {
        .init(id: "location.lookup", version: "1.0.0", title: "查询位置",
              summary: "查询当前设备位置或把坐标转换为地址。首次查询当前位置需要用户授权。",
              wireName: "location_lookup", schemaVersion: 1,
              inputSchema: .object(properties: [
                "action": .string(enumValues: BoneLocationAction.allCases.map(\.rawValue), minimumLength: nil, maximumLength: nil),
                "latitude": .number(minimum: nil, maximum: nil),
                "longitude": .number(minimum: nil, maximum: nil),
                "limit": .integer(minimum: 1, maximum: BoneAppleInteractionSupport.maximumPlacemarkCount)
              ], required: ["action"], additionalProperties: false), executionPolicy: .serial,
              impact: .init(dataAccess: .userPrivate, externalTransmission: .none, stateChange: .none,
                            economic: .none, userVisible: .none, permissionChange: .grantsAccess))
    }

    /// 执行位置查询并传播取消状态。
    /// - Parameters:
    ///   - input: 已校验的位置请求。
    ///   - context: 当前工具执行上下文。
    /// - Returns: Host 返回的位置结果。
    public func execute(input: Input, context: Context) async throws -> Output {
        try Task.checkCancellation()
        let result = try await handler(input, context)
        try Task.checkCancellation()
        return result
    }
}

/// 系统分享内容类型。
public enum BoneShareContentType: String, Codable, CaseIterable, Sendable {
    /// 分享普通文本。
    case text
    /// 分享 HTTP 或 HTTPS 链接。
    case url
    /// 分享 Host 已登记的图片。
    case image
}

/// 系统分享工具请求。
public struct BoneShareRequest: Codable, Equatable, Sendable {
    /// 分享内容类型。
    public let contentType: BoneShareContentType
    /// 文本分享内容。
    public let text: String?
    /// 链接分享内容。
    public let url: String?
    /// Host 已登记图片的透明标识。
    public let imageID: String?

    /// 创建分享请求并校验内容类型与字段关系。
    /// - Parameters:
    ///   - contentType: 分享内容类型。
    ///   - text: 文本内容。
    ///   - url: HTTP 或 HTTPS 链接。
    ///   - imageID: Host 已登记图片标识。
    public init(contentType: BoneShareContentType, text: String? = nil, url: String? = nil, imageID: String? = nil) throws {
        self.contentType = contentType
        self.text = text
        self.url = url
        self.imageID = imageID
        try Self.validate(contentType: contentType, text: text, url: url, imageID: imageID)
    }

    /// 从模型 JSON 解码分享请求。
    /// - Parameter decoder: 模型参数解码器。
    /// - Throws: 输入字段未知或内容不完整时抛出 Apple 工具错误。
    public init(from decoder: Decoder) throws {
        guard try BoneAppleInteractionSupport.containsOnlyKeys(decoder, allowed: ["contentType", "text", "url", "imageID"]) else {
            throw BoneAppleToolError.invalidArguments
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let contentType = try container.decodeIfPresent(BoneShareContentType.self, forKey: .contentType) else {
            throw BoneAppleToolError.invalidArguments
        }
        try self.init(contentType: contentType,
                      text: try container.decodeIfPresent(String.self, forKey: .text),
                      url: try container.decodeIfPresent(String.self, forKey: .url),
                      imageID: try container.decodeIfPresent(String.self, forKey: .imageID))
    }

    /// 校验分享请求只携带一种受支持的内容。
    /// - Parameters:
    ///   - contentType: 分享内容类型。
    ///   - text: 文本内容。
    ///   - url: 链接内容。
    ///   - imageID: 图片标识。
    /// - Throws: 内容缺失、冲突或超限时抛出 Apple 工具错误。
    private static func validate(contentType: BoneShareContentType, text: String?, url: String?, imageID: String?) throws {
        let values = [text != nil, url != nil, imageID != nil].filter { $0 }.count
        guard values == 1 else { throw BoneAppleToolError.invalidArguments }
        switch contentType {
        case .text:
            guard text != nil, BoneAppleInteractionSupport.validText(text, maximumBytes: BoneAppleInteractionSupport.maximumTextBytes, required: true) else {
                throw BoneAppleToolError.invalidArguments
            }
        case .url:
            guard BoneAppleInteractionSupport.validWebURL(url) else { throw BoneAppleToolError.invalidArguments }
        case .image:
            guard BoneAppleInteractionSupport.validIdentifier(imageID) else { throw BoneAppleToolError.invalidArguments }
        }
    }

    /// 分享请求 JSON 字段。
    private enum CodingKeys: String, CodingKey { case contentType, text, url, imageID }
}

/// 系统分享工具结果。
public struct BoneShareResult: Codable, Equatable, Sendable {
    /// 用户完成或取消的状态。
    public let status: BoneAppleOperationStatus
    /// 请求的内容类型。
    public let contentType: BoneShareContentType
    /// 系统返回的活动标识。
    public let activityType: String?

    /// 创建分享结果。
    /// - Parameters:
    ///   - status: 操作状态。
    ///   - contentType: 内容类型。
    ///   - activityType: 系统返回的活动标识。
    public init(status: BoneAppleOperationStatus, contentType: BoneShareContentType, activityType: String? = nil) {
        self.status = status
        self.contentType = contentType
        self.activityType = activityType
    }
}

/// 系统分享工具的 Host 注入适配器。
public struct BoneShareTool<Context: BoneAgentToolContext>: BoneAgentTool {
    /// 工具输入类型。
    public typealias Input = BoneShareRequest
    /// 工具输出类型。
    public typealias Output = BoneShareResult
    /// Host 处理闭包类型。
    public typealias Handler = @Sendable (Input, Context) async throws -> Output
    /// Host 处理闭包。
    private let handler: Handler

    /// 创建分享工具。
    /// - Parameter handler: 由平台 Host 执行的分享处理闭包。
    public init(handler: @escaping Handler) { self.handler = handler }

    /// 返回分享工具定义。
    public static var definition: BoneAgentToolDefinition {
        .init(id: "share.present", version: "1.0.0", title: "打开分享面板",
              summary: "把文本、链接或已登记图片交给系统分享面板，由用户选择目标并确认。",
              wireName: "share_present", schemaVersion: 1,
              inputSchema: .object(properties: [
                "contentType": .string(enumValues: BoneShareContentType.allCases.map(\.rawValue), minimumLength: nil, maximumLength: nil),
                "text": .string(enumValues: [], minimumLength: 1, maximumLength: 4_096),
                "url": .string(enumValues: [], minimumLength: 1, maximumLength: 4_096),
                "imageID": .string(enumValues: [], minimumLength: 1, maximumLength: BoneAppleInteractionSupport.maximumIdentifierBytes)
              ], required: ["contentType"], additionalProperties: false), executionPolicy: .serial,
              impact: .init(dataAccess: .userPrivate, externalTransmission: .none, stateChange: .none,
                            economic: .none, userVisible: .publication, permissionChange: .none))
    }

    /// 执行分享面板展示并传播取消状态。
    /// - Parameters:
    ///   - input: 已校验的分享请求。
    ///   - context: 当前工具执行上下文。
    /// - Returns: Host 返回的分享结果。
    public func execute(input: Input, context: Context) async throws -> Output {
        try Task.checkCancellation()
        let result = try await handler(input, context)
        try Task.checkCancellation()
        return result
    }
}

/// 草稿编辑渠道。
public enum BoneComposeChannel: String, Codable, CaseIterable, Sendable {
    /// 邮件草稿。
    case mail
    /// 信息草稿。
    case message
}

/// 邮件或信息草稿请求。
public struct BoneComposeRequest: Codable, Equatable, Sendable {
    /// 草稿渠道。
    public let channel: BoneComposeChannel
    /// 收件人或消息号码。
    public let recipients: [String]
    /// 邮件主题，信息渠道忽略该字段。
    public let subject: String?
    /// 草稿正文。
    public let body: String

    /// 创建草稿请求并校验收件人与正文。
    /// - Parameters:
    ///   - channel: 草稿渠道。
    ///   - recipients: 收件人或号码。
    ///   - subject: 邮件主题。
    ///   - body: 草稿正文。
    public init(channel: BoneComposeChannel, recipients: [String], subject: String? = nil, body: String) throws {
        self.channel = channel
        self.recipients = recipients
        self.subject = subject
        self.body = body
        try Self.validate(recipients: recipients, subject: subject, body: body)
    }

    /// 从模型 JSON 解码草稿请求。
    /// - Parameter decoder: 模型参数解码器。
    /// - Throws: 输入字段未知或草稿内容超限时抛出 Apple 工具错误。
    public init(from decoder: Decoder) throws {
        guard try BoneAppleInteractionSupport.containsOnlyKeys(decoder, allowed: ["channel", "recipients", "subject", "body"]) else {
            throw BoneAppleToolError.invalidArguments
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let channel = try container.decodeIfPresent(BoneComposeChannel.self, forKey: .channel),
              let recipients = try container.decodeIfPresent([String].self, forKey: .recipients),
              let body = try container.decodeIfPresent(String.self, forKey: .body) else {
            throw BoneAppleToolError.invalidArguments
        }
        try self.init(channel: channel, recipients: recipients,
                      subject: try container.decodeIfPresent(String.self, forKey: .subject), body: body)
    }

    /// 校验草稿正文和收件人列表。
    /// - Parameters:
    ///   - recipients: 收件人或号码列表。
    ///   - subject: 邮件主题。
    ///   - body: 草稿正文。
    /// - Throws: 列表为空、字段超限或正文为空时抛出 Apple 工具错误。
    private static func validate(recipients: [String], subject: String?, body: String) throws {
        guard !recipients.isEmpty, recipients.count <= BoneAppleInteractionSupport.maximumRecipientCount,
              recipients.allSatisfy({ BoneAppleInteractionSupport.validText($0, maximumBytes: 256, required: true) }),
              BoneAppleInteractionSupport.validText(subject, maximumBytes: 256),
              BoneAppleInteractionSupport.validText(body, maximumBytes: BoneAppleInteractionSupport.maximumTextBytes, required: true) else {
            throw BoneAppleToolError.invalidArguments
        }
    }

    /// 草稿请求 JSON 字段。
    private enum CodingKeys: String, CodingKey { case channel, recipients, subject, body }
}

/// 草稿编辑工具结果。
public struct BoneComposeResult: Codable, Equatable, Sendable {
    /// 用户完成或取消的状态。
    public let status: BoneAppleOperationStatus
    /// 实际使用的编辑渠道。
    public let channel: BoneComposeChannel
    /// 系统返回的编辑器类型或结果标识。
    public let activityType: String?

    /// 创建草稿结果。
    /// - Parameters:
    ///   - status: 操作状态。
    ///   - channel: 编辑渠道。
    ///   - activityType: 系统结果标识。
    public init(status: BoneAppleOperationStatus, channel: BoneComposeChannel, activityType: String? = nil) {
        self.status = status
        self.channel = channel
        self.activityType = activityType
    }
}

/// 邮件或信息草稿工具的 Host 注入适配器。
public struct BoneComposeTool<Context: BoneAgentToolContext>: BoneAgentTool {
    /// 工具输入类型。
    public typealias Input = BoneComposeRequest
    /// 工具输出类型。
    public typealias Output = BoneComposeResult
    /// Host 处理闭包类型。
    public typealias Handler = @Sendable (Input, Context) async throws -> Output
    /// Host 处理闭包。
    private let handler: Handler

    /// 创建草稿工具。
    /// - Parameter handler: 由平台 Host 执行的草稿处理闭包。
    public init(handler: @escaping Handler) { self.handler = handler }

    /// 返回草稿工具定义。
    public static var definition: BoneAgentToolDefinition {
        .init(id: "compose.present", version: "1.0.0", title: "打开邮件或信息草稿",
              summary: "生成邮件或信息草稿并打开系统编辑界面，由用户检查、修改和发送。",
              wireName: "compose_present", schemaVersion: 1,
              inputSchema: .object(properties: [
                "channel": .string(enumValues: BoneComposeChannel.allCases.map(\.rawValue), minimumLength: nil, maximumLength: nil),
                "recipients": .array(items: .string(enumValues: [], minimumLength: 1, maximumLength: 256), minimumItems: 1, maximumItems: BoneAppleInteractionSupport.maximumRecipientCount),
                "subject": .string(enumValues: [], minimumLength: 0, maximumLength: 256),
                "body": .string(enumValues: [], minimumLength: 1, maximumLength: 4_096)
              ], required: ["channel", "recipients", "body"], additionalProperties: false), executionPolicy: .serial,
              impact: .init(dataAccess: .userPrivate, externalTransmission: .none, stateChange: .none,
                            economic: .none, userVisible: .publication, permissionChange: .none))
    }

    /// 执行草稿编辑界面展示并传播取消状态。
    /// - Parameters:
    ///   - input: 已校验的草稿请求。
    ///   - context: 当前工具执行上下文。
    /// - Returns: Host 返回的草稿结果。
    public func execute(input: Input, context: Context) async throws -> Output {
        try Task.checkCancellation()
        let result = try await handler(input, context)
        try Task.checkCancellation()
        return result
    }
}
