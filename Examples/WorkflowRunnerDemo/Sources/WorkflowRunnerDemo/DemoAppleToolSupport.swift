import Foundation
import BoneAgentKit
import BoneAgentTools

/// Demo Host 注入的 Apple 系统工具适配器。
/// - Note: SDK 工具只依赖这些闭包，不直接依赖 EventKit、Photos 或 UserNotifications。
struct DemoAppleToolHandlers: Sendable {
    /// 日历事件处理闭包，参数和结果均为跨平台 DTO。
    let calendar: @Sendable (BoneCalendarRequest) async throws -> BoneCalendarResult
    /// 提醒事项处理闭包，参数和结果均为跨平台 DTO。
    let reminders: @Sendable (BoneReminderRequest) async throws -> BoneReminderResult
    /// 本地通知处理闭包，只管理当前 App 创建的通知。
    let notifications: @Sendable (BoneNotificationRequest) async throws -> BoneNotificationResult
    /// 相册写入处理闭包，图片正文由 Host 根据 imageID 解析。
    let photos: @Sendable (BonePhotoRequest) async throws -> BonePhotoResult
    /// 联系人查询和写入处理闭包。
    let contacts: @Sendable (BoneContactRequest) async throws -> BoneContactResult
    /// 当前位置和反向地理编码处理闭包。
    let location: @Sendable (BoneLocationRequest) async throws -> BoneLocationResult
    /// 系统分享面板处理闭包。
    let share: @Sendable (BoneShareRequest) async throws -> BoneShareResult
    /// 邮件或信息草稿编辑器处理闭包。
    let compose: @Sendable (BoneComposeRequest) async throws -> BoneComposeResult

    /// 创建所有 Apple 能力都不可用的适配器，供 macOS Demo 和离线测试使用。
    static let unavailable = Self(
        calendar: { _ in throw BoneAppleToolError.unavailable },
        reminders: { _ in throw BoneAppleToolError.unavailable },
        notifications: { _ in throw BoneAppleToolError.unavailable },
        photos: { _ in throw BoneAppleToolError.unavailable },
        contacts: { _ in throw BoneAppleToolError.unavailable },
        location: { _ in throw BoneAppleToolError.unavailable },
        share: { _ in throw BoneAppleToolError.unavailable },
        compose: { _ in throw BoneAppleToolError.unavailable }
    )
}
