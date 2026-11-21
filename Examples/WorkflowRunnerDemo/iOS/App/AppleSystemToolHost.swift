import Foundation
import BoneAgentKit
import BoneAgentTools
import Contacts
import CoreLocation
import EventKit
import MessageUI
import MapKit
import Photos
import UIKit
import UserNotifications

/// iOS Host 对 Apple 系统框架的适配器。
/// - Note: 该类型只存在于 Demo App，跨平台 SDK 通过 `DemoAppleToolHandlers` 接收闭包。
@MainActor
final class DemoAppleSystemToolHost: NSObject, CLLocationManagerDelegate, MFMailComposeViewControllerDelegate, MFMessageComposeViewControllerDelegate {
    private let eventStore = EKEventStore()
    private let contactStore = CNContactStore()
    private let notificationCenter = UNUserNotificationCenter.current()
    private let locationManager = CLLocationManager()
    private let imageDataProvider: @Sendable (String) async throws -> Data
    private let notificationDefaults: UserDefaults
    private var notificationIdentifiers: Set<String>
    /// 当前定位请求的异步等待句柄。
    private var locationContinuation: CheckedContinuation<CLLocation, Error>?
    /// 当前定位请求的唯一身份，用于隔离取消回调与后续请求。
    private var locationRequestID: UUID?
    /// 当前分享请求的异步等待句柄。
    private var shareContinuation: CheckedContinuation<BoneShareResult, Error>?
    /// 当前分享请求的系统面板控制器。
    private var shareController: UIActivityViewController?
    /// 当前分享请求的唯一身份。
    private var shareRequestID: UUID?
    /// 当前邮件或信息草稿请求的唯一身份。
    private var composeRequestID: UUID?
    /// 当前邮件或信息草稿请求的系统编辑器。
    private var composeController: UIViewController?
    private var composeContinuation: CheckedContinuation<(BoneAppleOperationStatus, String?), Error>?

    private static let notificationDefaultsKey = "boneagentkit.appleTools.notificationIdentifiers"
    private static let notificationIdentifierPrefix = "boneagentkit.notification."

    /// 创建 Apple 工具 Host。
    /// - Parameters:
    ///   - imageDataProvider: 根据受控 imageID 读取图片规范化字节。
    ///   - notificationDefaults: 保存本 App 工具通知登记表的私有设置容器。
    init(imageDataProvider: @escaping @Sendable (String) async throws -> Data,
         notificationDefaults: UserDefaults = .standard) {
        self.imageDataProvider = imageDataProvider
        self.notificationDefaults = notificationDefaults
        self.notificationIdentifiers = Set(notificationDefaults.stringArray(forKey: Self.notificationDefaultsKey) ?? [])
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    /// 将 iOS 框架适配为跨平台 Demo 工具处理闭包。
    var handlers: DemoAppleToolHandlers {
        DemoAppleToolHandlers(
            calendar: { [weak self] request in
                guard let self else { throw BoneAppleToolError.unavailable }
                return try await self.handleCalendar(request)
            },
            reminders: { [weak self] request in
                guard let self else { throw BoneAppleToolError.unavailable }
                return try await self.handleReminder(request)
            },
            notifications: { [weak self] request in
                guard let self else { throw BoneAppleToolError.unavailable }
                return try await self.handleNotification(request)
            },
            photos: { [weak self] request in
                guard let self else { throw BoneAppleToolError.unavailable }
                return try await self.handlePhoto(request)
            },
            contacts: { [weak self] request in
                guard let self else { throw BoneAppleToolError.unavailable }
                return try await self.handleContact(request)
            },
            location: { [weak self] request in
                guard let self else { throw BoneAppleToolError.unavailable }
                return try await self.handleLocation(request)
            },
            share: { [weak self] request in
                guard let self else { throw BoneAppleToolError.unavailable }
                return try await self.handleShare(request)
            },
            compose: { [weak self] request in
                guard let self else { throw BoneAppleToolError.unavailable }
                return try await self.handleCompose(request)
            }
        )
    }

    /// 处理当前位置和反向地理编码工具调用。
    /// - Parameter request: 已通过 SDK 输入校验的位置请求。
    /// - Returns: 有界位置或地址结果。
    private func handleLocation(_ request: BoneLocationRequest) async throws -> BoneLocationResult {
        switch request.action {
        case .current:
            let location = try await currentLocation()
            return .init(status: .completed, location: Self.locationCoordinate(location))
        case .reverseGeocode:
            let location = CLLocation(latitude: request.latitude!, longitude: request.longitude!)
            guard let geocodingRequest = MKReverseGeocodingRequest(location: location) else {
                throw BoneAppleToolError.invalidArguments
            }
            let mapItems = try await geocodingRequest.mapItems
            let placemarks = mapItems.prefix(request.limit).map(Self.locationPlacemark)
            return .init(status: .completed, placemarks: Array(placemarks))
        }
    }

    /// 请求一次当前设备位置，使用前台 When In Use 权限。
    /// - Returns: 系统返回的第一条有效位置。
    private func currentLocation() async throws -> CLLocation {
        guard CLLocationManager.locationServicesEnabled() else { throw BoneAppleToolError.unavailable }
        switch locationManager.authorizationStatus {
        case .denied, .restricted:
            throw BoneAppleToolError.permissionDenied
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        default:
            break
        }
        guard locationManager.authorizationStatus != .denied,
              locationManager.authorizationStatus != .restricted else {
            throw BoneAppleToolError.permissionDenied
        }
        if let lastLocation = locationManager.location, lastLocation.timestamp.timeIntervalSinceNow > -300 {
            return lastLocation
        }
        guard locationContinuation == nil else { throw BoneAppleToolError.conflict }
        let requestID = UUID()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                locationRequestID = requestID
                locationContinuation = continuation
                locationManager.requestLocation()
            }
        }, onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.locationRequestID == requestID,
                      let continuation = self.locationContinuation else { return }
                self.locationRequestID = nil
                self.locationContinuation = nil
                self.locationManager.stopUpdatingLocation()
                continuation.resume(throwing: CancellationError())
            }
        })
    }

    /// 将系统位置转换为跨平台坐标 DTO。
    /// - Parameter location: Core Location 位置对象。
    /// - Returns: 位置工具稳定结果。
    private static func locationCoordinate(_ location: CLLocation) -> BoneLocationCoordinate {
        .init(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
              altitude: location.altitude.isFinite ? location.altitude : nil,
              horizontalAccuracy: location.horizontalAccuracy >= 0 ? location.horizontalAccuracy : nil,
              timestamp: iso8601(location.timestamp))
    }

    /// 将系统地标转换为跨平台地址 DTO。
    /// - Parameter placemark: Core Location 地标对象。
    /// - Returns: 地址工具稳定结果。
    private static func locationPlacemark(_ mapItem: MKMapItem) -> BoneLocationPlacemark {
        let address = mapItem.address
        let representations = mapItem.addressRepresentations
        return .init(country: representations?.regionName,
                     administrativeArea: nil,
                     locality: representations?.cityName,
                     thoroughfare: nil,
                     subThoroughfare: nil,
                     postalCode: nil,
                     formattedAddress: address?.fullAddress ?? representations?.fullAddress(includingRegion: true, singleLine: true))
    }

    /// 处理系统分享面板工具调用。
    /// - Parameter request: 已通过 SDK 输入校验的分享请求。
    /// - Returns: 用户完成或取消分享的结果。
    private func handleShare(_ request: BoneShareRequest) async throws -> BoneShareResult {
        guard shareRequestID == nil else { throw BoneAppleToolError.conflict }
        let requestID = UUID()
        shareRequestID = requestID
        do {
            let result = try await withTaskCancellationHandler(operation: {
                try await prepareAndPresentShare(request, requestID: requestID)
            }, onCancel: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.cancelShare(requestID: requestID)
                }
            })
            if shareRequestID == requestID {
                shareRequestID = nil
            }
            return result
        } catch {
            if shareRequestID == requestID {
                shareRequestID = nil
            }
            throw error
        }
    }

    /// 准备分享内容并等待系统分享面板结束。
    /// - Parameters:
    ///   - request: 已通过 SDK 输入校验的分享请求。
    ///   - requestID: 当前分享请求的唯一身份。
    /// - Returns: 用户完成或取消分享的结果。
    private func prepareAndPresentShare(_ request: BoneShareRequest, requestID: UUID) async throws -> BoneShareResult {
        let item: Any
        switch request.contentType {
        case .text:
            item = request.text!
        case .url:
            item = URL(string: request.url!)!
        case .image:
            guard let image = UIImage(data: try await imageDataProvider(request.imageID!)) else {
                throw BoneAppleToolError.unsupported
            }
            item = image
        }
        try Task.checkCancellation()
        guard shareRequestID == requestID else { throw CancellationError() }
        guard let presenter = topViewController() else {
            throw BoneAppleToolError.unavailable
        }
        let controller = UIActivityViewController(activityItems: [item], applicationActivities: nil)
        if let popover = controller.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
        }
        shareController = controller
        return try await withCheckedThrowingContinuation { continuation in
            guard !Task.isCancelled, shareRequestID == requestID else {
                shareController = nil
                continuation.resume(throwing: CancellationError())
                return
            }
            shareContinuation = continuation
            controller.completionWithItemsHandler = { [weak self] activityType, completed, _, error in
                Task { @MainActor [weak self] in
                    self?.finishShare(requestID: requestID, contentType: request.contentType,
                                      activityType: activityType?.rawValue, completed: completed, error: error)
                }
            }
            presenter.present(controller, animated: true)
        }
    }

    /// 处理分享面板结束回调，并确保同一请求只恢复一次。
    /// - Parameters:
    ///   - requestID: 回调对应的分享请求身份。
    ///   - contentType: 分享内容类型。
    ///   - activityType: 系统返回的目标活动类型。
    ///   - completed: 系统是否报告完成。
    ///   - error: 系统返回的错误。
    private func finishShare(requestID: UUID, contentType: BoneShareContentType,
                            activityType: String?, completed: Bool, error: Error?) {
        guard shareRequestID == requestID, let continuation = shareContinuation else { return }
        shareRequestID = nil
        shareContinuation = nil
        shareController = nil
        if error != nil {
            continuation.resume(throwing: BoneAppleToolError.operationFailed)
        } else {
            continuation.resume(returning: .init(status: completed ? .completed : .cancelled,
                                                 contentType: contentType, activityType: activityType))
        }
    }

    /// 取消当前分享请求并关闭系统面板。
    /// - Parameter requestID: 待取消的分享请求身份。
    private func cancelShare(requestID: UUID) {
        guard shareRequestID == requestID else { return }
        let controller = shareController
        let continuation = shareContinuation
        shareRequestID = nil
        shareController = nil
        shareContinuation = nil
        controller?.dismiss(animated: true)
        continuation?.resume(throwing: CancellationError())
    }

    /// 处理邮件或信息草稿工具调用。
    /// - Parameter request: 已通过 SDK 输入校验的草稿请求。
    /// - Returns: 用户在系统编辑器中的最终操作结果。
    private func handleCompose(_ request: BoneComposeRequest) async throws -> BoneComposeResult {
        guard composeRequestID == nil else { throw BoneAppleToolError.conflict }
        let requestID = UUID()
        guard let presenter = topViewController() else { throw BoneAppleToolError.unavailable }
        let controller: UIViewController
        switch request.channel {
        case .mail:
            guard MFMailComposeViewController.canSendMail() else { throw BoneAppleToolError.unavailable }
            let mail = MFMailComposeViewController()
            mail.setToRecipients(request.recipients)
            mail.setSubject(request.subject ?? "")
            mail.setMessageBody(request.body, isHTML: false)
            mail.mailComposeDelegate = self
            controller = mail
        case .message:
            guard MFMessageComposeViewController.canSendText() else { throw BoneAppleToolError.unavailable }
            let message = MFMessageComposeViewController()
            message.recipients = request.recipients
            message.body = request.body
            message.messageComposeDelegate = self
            controller = message
        }
        composeRequestID = requestID
        composeController = controller
        do {
            let result: (BoneAppleOperationStatus, String?) = try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { continuation in
                    guard !Task.isCancelled, composeRequestID == requestID else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    composeContinuation = continuation
                    presenter.present(controller, animated: true)
                }
            }, onCancel: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.cancelCompose(requestID: requestID)
                }
            })
            if composeRequestID == requestID {
                composeRequestID = nil
                composeController = nil
            }
            return .init(status: result.0, channel: request.channel, activityType: result.1)
        } catch {
            if composeRequestID == requestID {
                composeRequestID = nil
                composeController = nil
            }
            throw error
        }
    }

    /// 取消当前邮件或信息草稿请求，并关闭系统编辑器。
    /// - Parameter requestID: 待取消的草稿请求身份。
    private func cancelCompose(requestID: UUID) {
        guard composeRequestID == requestID else { return }
        let controller = composeController
        let continuation = composeContinuation
        composeRequestID = nil
        composeController = nil
        composeContinuation = nil
        controller?.dismiss(animated: true)
        continuation?.resume(throwing: CancellationError())
    }

    /// 查找当前前台场景最上层的视图控制器。
    /// - Returns: 可以呈现系统界面的视图控制器。
    private func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? scenes.flatMap(\.windows).first
        var controller = window?.rootViewController
        while let presented = controller?.presentedViewController { controller = presented }
        return controller
    }

    /// CLLocationManager 授权状态变化回调。
    /// - Parameter manager: 发生状态变化的位置管理器。
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            self?.handleLocationAuthorizationChange(status)
        }
    }

    /// 在主 Actor 上处理定位授权变化并继续或结束当前请求。
    /// - Parameter status: 系统返回的授权状态。
    private func handleLocationAuthorizationChange(_ status: CLAuthorizationStatus) {
        guard let continuation = locationContinuation else { return }
        switch status {
        case .denied, .restricted:
            locationRequestID = nil
            locationContinuation = nil
            continuation.resume(throwing: BoneAppleToolError.permissionDenied)
        case .authorizedWhenInUse, .authorizedAlways:
            locationManager.requestLocation()
        default:
            break
        }
    }

    /// CLLocationManager 单次位置更新回调。
    /// - Parameters:
    ///   - manager: 返回位置的位置管理器。
    ///   - locations: 系统返回的位置列表。
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor [weak self] in
            guard let self, let continuation = self.locationContinuation else { return }
            self.locationRequestID = nil
            self.locationContinuation = nil
            continuation.resume(returning: location)
        }
    }

    /// CLLocationManager 失败回调。
    /// - Parameters:
    ///   - manager: 发生失败的位置管理器。
    ///   - error: 系统返回的定位错误。
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, let continuation = self.locationContinuation else { return }
            self.locationRequestID = nil
            self.locationContinuation = nil
            if (error as NSError).code == CLError.denied.rawValue {
                continuation.resume(throwing: BoneAppleToolError.permissionDenied)
            } else {
                continuation.resume(throwing: BoneAppleToolError.operationFailed)
            }
        }
    }

    /// 邮件编辑器结束回调。
    /// - Parameters:
    ///   - controller: 邮件编辑器。
    ///   - result: 用户操作结果。
    ///   - error: 系统返回的错误。
    nonisolated func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
        Task { @MainActor [weak self] in
            self?.finishCompose(controller, result: result, error: error)
        }
    }

    /// 信息编辑器结束回调。
    /// - Parameters:
    ///   - controller: 信息编辑器。
    ///   - result: 用户操作结果。
    /// - Returns: 无返回值，结果通过挂起的工具调用继续传递。
    nonisolated func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let status: BoneAppleOperationStatus = result == .cancelled ? .cancelled : .completed
            let error: Error? = result == .failed ? BoneAppleToolError.operationFailed : nil
            self.finishCompose(controller, status: status, error: error)
        }
    }

    /// 统一完成邮件编辑器的挂起调用。
    /// - Parameters:
    ///   - controller: 邮件编辑器。
    ///   - result: 用户操作结果。
    ///   - error: 系统返回的错误。
    private func finishCompose(_ controller: MFMailComposeViewController, result: MFMailComposeResult, error: Error?) {
        finishCompose(controller, status: result == .cancelled ? .cancelled : .completed,
                      error: error ?? (result == .failed ? BoneAppleToolError.operationFailed : nil))
    }

    /// 统一结束邮件或信息编辑器请求，并检查回调是否属于当前控制器。
    /// - Parameters:
    ///   - controller: 已结束的系统编辑器。
    ///   - status: 用户操作状态。
    ///   - error: 需要交给工具调用的固定错误。
    private func finishCompose(_ controller: UIViewController, status: BoneAppleOperationStatus, error: Error?) {
        guard let currentController = composeController, currentController === controller,
              let continuation = composeContinuation else { return }
        composeRequestID = nil
        composeController = nil
        composeContinuation = nil
        controller.dismiss(animated: true)
        if let error {
            continuation.resume(throwing: error is BoneAppleToolError ? error : BoneAppleToolError.operationFailed)
        } else {
            continuation.resume(returning: (status, nil))
        }
    }

    /// 处理日历工具调用。
    /// - Parameter request: 已通过 SDK 输入校验的日历请求。
    /// - Returns: 有界事件结果。
    private func handleCalendar(_ request: BoneCalendarRequest) async throws -> BoneCalendarResult {
        try await requestCalendarAccess()
        switch request.action {
        case .search:
            let start = try date(request.startDate) ?? Calendar.current.date(byAdding: .day, value: -1, to: Date())!
            let end = try date(request.endDate) ?? Calendar.current.date(byAdding: .day, value: 7, to: start)!
            guard end > start else { throw BoneAppleToolError.invalidArguments }
            let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)
            let events = eventStore.events(matching: predicate)
                .filter { request.query?.isEmpty != false || $0.title.localizedCaseInsensitiveContains(request.query!) }
                .prefix(request.limit)
                .map(Self.calendarEvent)
            return .init(status: .completed, events: Array(events))
        case .get:
            guard let event = eventStore.event(withIdentifier: request.identifier!) else { throw BoneAppleToolError.notFound }
            return .init(status: .completed, event: Self.calendarEvent(event), identifier: event.eventIdentifier)
        case .create:
            let event = EKEvent(eventStore: eventStore)
            event.title = request.title!
            event.notes = request.notes
            event.startDate = try date(request.startDate)!
            event.endDate = try date(request.endDate)!
            event.calendar = try calendar(identifier: request.calendarIdentifier)
            try eventStore.save(event, span: .thisEvent, commit: true)
            return .init(status: .completed, event: Self.calendarEvent(event), identifier: event.eventIdentifier)
        case .update:
            guard let event = eventStore.event(withIdentifier: request.identifier!) else { throw BoneAppleToolError.notFound }
            if let title = request.title { event.title = title }
            if let notes = request.notes { event.notes = notes }
            if let startDate = request.startDate { event.startDate = try date(startDate)! }
            if let endDate = request.endDate { event.endDate = try date(endDate)! }
            if let calendarIdentifier = request.calendarIdentifier { event.calendar = try calendar(identifier: calendarIdentifier) }
            try eventStore.save(event, span: .thisEvent, commit: true)
            return .init(status: .completed, event: Self.calendarEvent(event), identifier: event.eventIdentifier)
        case .delete:
            guard let event = eventStore.event(withIdentifier: request.identifier!) else { throw BoneAppleToolError.notFound }
            try eventStore.remove(event, span: .thisEvent, commit: true)
            return .init(status: .deleted, identifier: request.identifier)
        }
    }

    /// 处理提醒事项工具调用。
    /// - Parameter request: 已通过 SDK 输入校验的提醒请求。
    /// - Returns: 有界提醒结果。
    private func handleReminder(_ request: BoneReminderRequest) async throws -> BoneReminderResult {
        try await requestRemindersAccess()
        switch request.action {
        case .search:
            let predicate = eventStore.predicateForReminders(in: nil)
            let reminders = try await fetchReminderItems(matching: predicate)
                .filter { request.query?.isEmpty != false || $0.title.localizedCaseInsensitiveContains(request.query!) }
                .prefix(request.limit)
            return .init(status: .completed, reminders: Array(reminders))
        case .create:
            let reminder = EKReminder(eventStore: eventStore)
            reminder.title = request.title!
            reminder.notes = request.notes
            reminder.calendar = try reminderCalendar(identifier: request.listIdentifier)
            if let dueDate = request.dueDate {
                reminder.dueDateComponents = Calendar.current.dateComponents([.calendar, .year, .month, .day, .hour, .minute], from: try date(dueDate)!)
            }
            try eventStore.save(reminder, commit: true)
            return .init(status: .completed, reminder: Self.reminderItem(reminder), identifier: reminder.calendarItemIdentifier)
        case .update:
            guard let reminder = eventStore.calendarItem(withIdentifier: request.identifier!) as? EKReminder else { throw BoneAppleToolError.notFound }
            if let title = request.title { reminder.title = title }
            if let notes = request.notes { reminder.notes = notes }
            if let listIdentifier = request.listIdentifier { reminder.calendar = try reminderCalendar(identifier: listIdentifier) }
            if let dueDate = request.dueDate {
                reminder.dueDateComponents = Calendar.current.dateComponents([.calendar, .year, .month, .day, .hour, .minute], from: try date(dueDate)!)
            }
            try eventStore.save(reminder, commit: true)
            return .init(status: .completed, reminder: Self.reminderItem(reminder), identifier: reminder.calendarItemIdentifier)
        case .complete:
            guard let reminder = eventStore.calendarItem(withIdentifier: request.identifier!) as? EKReminder else { throw BoneAppleToolError.notFound }
            reminder.isCompleted = true
            try eventStore.save(reminder, commit: true)
            return .init(status: .completed, reminder: Self.reminderItem(reminder), identifier: reminder.calendarItemIdentifier)
        case .delete:
            guard let reminder = eventStore.calendarItem(withIdentifier: request.identifier!) as? EKReminder else { throw BoneAppleToolError.notFound }
            try eventStore.remove(reminder, commit: true)
            return .init(status: .deleted, identifier: request.identifier)
        }
    }

    /// 处理本地通知工具调用。
    /// - Parameter request: 已通过 SDK 输入校验的通知请求。
    /// - Returns: 只包含本 App 登记过的通知。
    private func handleNotification(_ request: BoneNotificationRequest) async throws -> BoneNotificationResult {
        switch request.action {
        case .schedule:
            let settings = await notificationCenter.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                let granted = try await notificationCenter.requestAuthorization(options: [.alert, .sound, .badge])
                guard granted else { throw BoneAppleToolError.permissionDenied }
            } else if settings.authorizationStatus != .authorized && settings.authorizationStatus != .provisional {
                throw BoneAppleToolError.permissionDenied
            }
            let content = UNMutableNotificationContent()
            content.title = request.title!
            content.body = request.body ?? ""
            content.sound = .default
            let fireDate = try date(request.fireDate)!
            let components = Calendar.current.dateComponents([.calendar, .year, .month, .day, .hour, .minute, .second], from: fireDate)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: request.repeats)
            let logicalIdentifier = request.identifier!
            let notificationRequest = UNNotificationRequest(
                identifier: Self.systemNotificationIdentifier(for: logicalIdentifier),
                content: content, trigger: trigger
            )
            try await notificationCenter.add(notificationRequest)
            notificationIdentifiers.insert(logicalIdentifier)
            persistNotificationIdentifiers()
            return .init(status: .scheduled, identifier: logicalIdentifier)
        case .list:
            let pending = await notificationCenter.pendingNotificationRequests()
                .compactMap { request -> BoneNotificationItem? in
                    guard request.identifier.hasPrefix(Self.notificationIdentifierPrefix) else { return nil }
                    let logicalIdentifier = String(request.identifier.dropFirst(Self.notificationIdentifierPrefix.count))
                    guard notificationIdentifiers.contains(logicalIdentifier) else { return nil }
                    let trigger = request.trigger as? UNCalendarNotificationTrigger
                    let fireDate = trigger?.nextTriggerDate().map(Self.iso8601)
                    return BoneNotificationItem(identifier: logicalIdentifier, title: request.content.title,
                                                body: request.content.body, fireDate: fireDate, repeats: trigger?.repeats ?? false)
                }
                .prefix(50)
            return .init(status: .completed, notifications: Array(pending))
        case .cancel:
            let logicalIdentifier = request.identifier!
            guard notificationIdentifiers.contains(logicalIdentifier) else { throw BoneAppleToolError.notFound }
            let systemIdentifier = Self.systemNotificationIdentifier(for: logicalIdentifier)
            notificationCenter.removePendingNotificationRequests(withIdentifiers: [systemIdentifier])
            notificationCenter.removeDeliveredNotifications(withIdentifiers: [systemIdentifier])
            notificationIdentifiers.remove(logicalIdentifier)
            persistNotificationIdentifiers()
            return .init(status: .cancelled, identifier: logicalIdentifier)
        }
    }

    /// 处理联系人查询和变更。
    /// - Parameter request: 已通过 SDK 输入校验的联系人请求。
    /// - Returns: 有界联系人结果。
    private func handleContact(_ request: BoneContactRequest) async throws -> BoneContactResult {
        try await requestContactsAccess()
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactMiddleNameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor
        ]
        switch request.action {
        case .search:
            let contacts: [CNContact]
            if let query = request.query, !query.isEmpty {
                contacts = try searchContacts(query: query, keys: keys, limit: request.limit)
            } else {
                contacts = try fetchContacts(matching: NSPredicate(value: true), keys: keys, limit: request.limit)
            }
            return .init(status: .completed, contacts: contacts.map(Self.contactItem))
        case .get:
            guard let contact = try fetchContact(identifier: request.identifier!, keys: keys) else {
                throw BoneAppleToolError.notFound
            }
            return .init(status: .completed, contact: Self.contactItem(contact), identifier: contact.identifier)
        case .create:
            let contact = CNMutableContact()
            apply(request, to: contact)
            let save = CNSaveRequest()
            save.add(contact, toContainerWithIdentifier: nil)
            try execute(save)
            return .init(status: .completed, contact: Self.contactItem(contact), identifier: contact.identifier)
        case .update:
            guard let source = try fetchContact(identifier: request.identifier!, keys: keys) else {
                throw BoneAppleToolError.notFound
            }
            let contact = source.mutableCopy() as! CNMutableContact
            apply(request, to: contact)
            let save = CNSaveRequest()
            save.update(contact)
            try execute(save)
            return .init(status: .completed, contact: Self.contactItem(contact), identifier: contact.identifier)
        case .delete:
            guard let source = try fetchContact(identifier: request.identifier!, keys: keys) else {
                throw BoneAppleToolError.notFound
            }
            let save = CNSaveRequest()
            save.delete(source.mutableCopy() as! CNMutableContact)
            try execute(save)
            return .init(status: .deleted, identifier: request.identifier)
        }
    }

    /// 按姓名、组织、电话号码或电子邮箱搜索联系人，并保持结果有界。
    /// - Parameters:
    ///   - query: 用户输入的搜索文本。
    ///   - keys: 只读取工具需要的字段。
    ///   - limit: 最大返回条数。
    /// - Returns: 去重后的联系人对象。
    private func searchContacts(query: String, keys: [CNKeyDescriptor], limit: Int) throws -> [CNContact] {
        var identifiers = Set<String>()
        var matches: [CNContact] = []
        let predicates: [NSPredicate] = [
            CNContact.predicateForContacts(matchingName: query),
            CNContact.predicateForContacts(matchingEmailAddress: query),
            CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: query))
        ]
        for predicate in predicates {
            for contact in try fetchContacts(matching: predicate, keys: keys, limit: limit) {
                guard identifiers.insert(contact.identifier).inserted else { continue }
                matches.append(contact)
                if matches.count >= limit { return matches }
            }
        }

        // 组织名称没有对应的 Contacts predicate，只有在候选结果不足时才扫描剩余联系人，避免每次搜索都全量读取通讯录。
        let fetchRequest = CNContactFetchRequest(keysToFetch: keys)
        fetchRequest.predicate = NSPredicate(value: true)
        fetchRequest.sortOrder = .userDefault
        do {
            try contactStore.enumerateContacts(with: fetchRequest) { contact, stop in
                guard !identifiers.contains(contact.identifier), Self.contactMatches(contact, query: query) else { return }
                identifiers.insert(contact.identifier)
                matches.append(contact)
                if matches.count >= limit { stop.pointee = true }
            }
        } catch {
            throw mapContactError(error)
        }
        return matches
    }

    /// 读取一页联系人，限制枚举数量并统一映射系统错误。
    /// - Parameters:
    ///   - predicate: Contacts 框架过滤条件。
    ///   - keys: 只读取工具需要的字段。
    ///   - limit: 最大读取条数。
    /// - Returns: 有界联系人对象。
    private func fetchContacts(matching predicate: NSPredicate, keys: [CNKeyDescriptor], limit: Int) throws -> [CNContact] {
        var contacts: [CNContact] = []
        let fetchRequest = CNContactFetchRequest(keysToFetch: keys)
        fetchRequest.predicate = predicate
        fetchRequest.sortOrder = .userDefault
        do {
            try contactStore.enumerateContacts(with: fetchRequest) { contact, stop in
                contacts.append(contact)
                if contacts.count >= limit { stop.pointee = true }
            }
        } catch {
            throw mapContactError(error)
        }
        return contacts
    }

    /// 判断联系人是否包含组织名称或联系方式搜索命中。
    /// - Parameters:
    ///   - contact: 已按工具字段读取的联系人。
    ///   - query: 用户输入的搜索文本。
    /// - Returns: 任一支持字段命中时返回 true。
    private static func contactMatches(_ contact: CNContact, query: String) -> Bool {
        let values = [contact.givenName, contact.familyName, contact.middleName, contact.organizationName]
            + contact.phoneNumbers.map { $0.value.stringValue }
            + contact.emailAddresses.map { $0.value as String }
        return values.contains { $0.localizedCaseInsensitiveContains(query) }
    }

    /// 根据请求字段更新联系人对象，未提供的更新字段保持原值。
    /// - Parameters:
    ///   - request: 联系人请求。
    ///   - contact: 待创建或更新的可变联系人。
    private func apply(_ request: BoneContactRequest, to contact: CNMutableContact) {
        if let givenName = request.givenName { contact.givenName = givenName }
        if let familyName = request.familyName { contact.familyName = familyName }
        if let middleName = request.middleName { contact.middleName = middleName }
        if let organizationName = request.organizationName { contact.organizationName = organizationName }
        if let phones = request.phones {
            contact.phoneNumbers = phones.map { CNLabeledValue(label: CNLabelPhoneNumberMain, value: CNPhoneNumber(stringValue: $0)) }
        }
        if let emails = request.emails {
            contact.emailAddresses = emails.map { CNLabeledValue(label: CNLabelHome, value: NSString(string: $0)) }
        }
    }

    /// 按系统标识读取联系人。
    /// - Parameters:
    ///   - identifier: 系统联系人标识。
    ///   - keys: 只读取工具需要的字段。
    /// - Returns: 联系人对象或空值。
    private func fetchContact(identifier: String, keys: [CNKeyDescriptor]) throws -> CNContact? {
        do {
            return try contactStore.unifiedContact(withIdentifier: identifier, keysToFetch: keys)
        } catch {
            throw mapContactError(error)
        }
    }

    /// 执行联系人保存请求并映射系统错误。
    /// - Parameter request: 联系人保存请求。
    private func execute(_ request: CNSaveRequest) throws {
        do {
            try contactStore.execute(request)
        } catch {
            throw mapContactError(error)
        }
    }

    /// 将联系人系统对象投影为跨平台 DTO。
    /// - Parameter contact: 联系人系统对象。
    /// - Returns: 不含头像、备注和地址的有界联系人结果。
    private static func contactItem(_ contact: CNContact) -> BoneContactItem {
        .init(identifier: contact.identifier, givenName: contact.givenName, familyName: contact.familyName,
              middleName: contact.middleName, organizationName: contact.organizationName,
              phones: contact.phoneNumbers.prefix(8).map { .init(label: $0.label, value: $0.value.stringValue) },
              emails: contact.emailAddresses.prefix(8).map { .init(label: $0.label, value: $0.value as String) })
    }

    /// 请求联系人访问权限并映射拒绝状态。
    private func requestContactsAccess() async throws {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        if status == .authorized || (status == .limited) { return }
        guard status == .notDetermined else { throw BoneAppleToolError.permissionDenied }
        let granted = await withCheckedContinuation { continuation in
            contactStore.requestAccess(for: .contacts) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
        guard granted else { throw BoneAppleToolError.permissionDenied }
    }

    /// 将联系人错误映射为稳定的 Apple 工具错误。
    /// - Parameter error: Contacts 框架错误。
    /// - Returns: 不暴露系统原始文本的固定错误。
    private func mapContactError(_ error: Error) -> BoneAppleToolError {
        let nsError = error as NSError
        if nsError.domain == CNErrorDomain, nsError.code == CNError.Code.authorizationDenied.rawValue {
            return .permissionDenied
        }
        if nsError.domain == CNErrorDomain, nsError.code == CNError.Code.recordDoesNotExist.rawValue {
            return .notFound
        }
        return .operationFailed
    }

    /// 处理图片保存到相册。
    /// - Parameter request: 已通过 SDK 输入校验的图片请求。
    /// - Returns: 保存后的相册资源身份。
    private func handlePhoto(_ request: BonePhotoRequest) async throws -> BonePhotoResult {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .notDetermined {
            let requested = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard requested == .authorized else { throw BoneAppleToolError.permissionDenied }
        } else if status != .authorized && status != .limited {
            throw BoneAppleToolError.permissionDenied
        }
        let data = try await imageDataProvider(request.imageID)
        guard let image = UIImage(data: data) else { throw BoneAppleToolError.unsupported }
        guard let albumTitle = request.albumTitle, !albumTitle.isEmpty else {
            var assetPlaceholder: PHObjectPlaceholder?
            try await PHPhotoLibrary.shared().performChanges {
                assetPlaceholder = PHAssetChangeRequest.creationRequestForAsset(from: image).placeholderForCreatedAsset
            }
            guard let assetIdentifier = assetPlaceholder?.localIdentifier else { throw BoneAppleToolError.operationFailed }
            return .init(status: .completed, imageID: request.imageID, assetIdentifier: assetIdentifier)
        }
        var assetPlaceholder: PHObjectPlaceholder?
        try await PHPhotoLibrary.shared().performChanges {
            let assetRequest = PHAssetChangeRequest.creationRequestForAsset(from: image)
            assetPlaceholder = assetRequest.placeholderForCreatedAsset
            guard let assetPlaceholder else { return }
            let collectionRequest = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: albumTitle)
            collectionRequest.addAssets([assetPlaceholder] as NSArray)
        }
        guard let assetIdentifier = assetPlaceholder?.localIdentifier else { throw BoneAppleToolError.operationFailed }
        return .init(status: .completed, imageID: request.imageID, assetIdentifier: assetIdentifier)
    }

    /// 通过 EventKit 的 completion API 读取提醒事项并立即投影为跨隔离 DTO。
    /// - Parameter predicate: EventKit 提醒事项过滤条件。
    /// - Returns: 当前授权范围内的提醒事项 DTO。
    private func fetchReminderItems(matching predicate: NSPredicate) async throws -> [BoneReminderItem] {
        try await withCheckedThrowingContinuation { continuation in
            eventStore.fetchReminders(matching: predicate) { reminders in
                let items = (reminders ?? []).map { reminder in
                    let dueDate = reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
                    return BoneReminderItem(
                        identifier: reminder.calendarItemIdentifier,
                        listIdentifier: reminder.calendar.calendarIdentifier,
                        listTitle: reminder.calendar.title,
                        title: reminder.title ?? "",
                        notes: reminder.notes,
                        dueDate: dueDate.map(Self.iso8601),
                        isCompleted: reminder.isCompleted
                    )
                }
                continuation.resume(returning: items)
            }
        }
    }

    /// 将逻辑通知 ID 映射为本 App 的独立系统 ID，避免覆盖其他业务模块的通知。
    /// - Parameter identifier: 工具输入中的稳定逻辑 ID。
    /// - Returns: 只供本 Host 使用的系统通知 ID。
    private static func systemNotificationIdentifier(for identifier: String) -> String {
        notificationIdentifierPrefix + identifier
    }

    /// 持久化工具通知登记表，使 App 重启后仍能列出和取消已安排通知。
    private func persistNotificationIdentifiers() {
        notificationDefaults.set(notificationIdentifiers.sorted(), forKey: Self.notificationDefaultsKey)
    }

    /// 请求日历完整读取权限。
    private func requestCalendarAccess() async throws {
        if #available(iOS 17.0, *) {
            let status = EKEventStore.authorizationStatus(for: .event)
            if status == .fullAccess { return }
            guard status == .notDetermined, try await eventStore.requestFullAccessToEvents() else { throw BoneAppleToolError.permissionDenied }
        } else {
            guard try await eventStore.requestAccess(to: .event) else { throw BoneAppleToolError.permissionDenied }
        }
    }

    /// 请求提醒事项完整读取权限。
    private func requestRemindersAccess() async throws {
        if #available(iOS 17.0, *) {
            let status = EKEventStore.authorizationStatus(for: .reminder)
            if status == .fullAccess { return }
            guard status == .notDetermined, try await eventStore.requestFullAccessToReminders() else { throw BoneAppleToolError.permissionDenied }
        } else {
            guard try await eventStore.requestAccess(to: .reminder) else { throw BoneAppleToolError.permissionDenied }
        }
    }

    /// 查找或选择目标日历。
    private func calendar(identifier: String?) throws -> EKCalendar {
        if let identifier, let calendar = eventStore.calendar(withIdentifier: identifier) { return calendar }
        guard let calendar = eventStore.defaultCalendarForNewEvents else { throw BoneAppleToolError.unavailable }
        return calendar
    }

    /// 查找或选择目标提醒列表。
    private func reminderCalendar(identifier: String?) throws -> EKCalendar {
        if let identifier, let calendar = eventStore.calendar(withIdentifier: identifier) { return calendar }
        guard let calendar = eventStore.defaultCalendarForNewReminders() else { throw BoneAppleToolError.unavailable }
        return calendar
    }

    /// 解析受限 ISO 8601 时间。
    private func date(_ value: String?) throws -> Date? {
        guard let value else { return nil }
        guard let date = ISO8601DateFormatter().date(from: value) else { throw BoneAppleToolError.invalidArguments }
        return date
    }

    /// 将日历事件投影为稳定 DTO。
    private static func calendarEvent(_ event: EKEvent) -> BoneCalendarEvent {
        .init(identifier: event.eventIdentifier ?? "", calendarIdentifier: event.calendar.calendarIdentifier,
              calendarTitle: event.calendar.title, title: event.title ?? "", notes: event.notes,
              startDate: iso8601(event.startDate), endDate: iso8601(event.endDate), isAllDay: event.isAllDay,
              lastModifiedDate: event.lastModifiedDate.map(iso8601))
    }

    /// 将提醒事项投影为稳定 DTO。
    private static func reminderItem(_ reminder: EKReminder) -> BoneReminderItem {
        let date = reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
        return .init(identifier: reminder.calendarItemIdentifier, listIdentifier: reminder.calendar.calendarIdentifier,
                     listTitle: reminder.calendar.title, title: reminder.title ?? "", notes: reminder.notes,
                     dueDate: date.map(iso8601), isCompleted: reminder.isCompleted)
    }

    /// 生成统一的 ISO 8601 输出。
    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
