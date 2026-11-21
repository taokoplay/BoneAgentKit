import Foundation
import BoneAgentKit
import BoneAgentTools

struct DemoBuiltInToolAssembly {
    /// 兼容测试和旧 Host 的参数顺序，将文件资源授权显式放在工具交互前。
    /// - Returns: 与主装配入口一致的内置工具列表。
    static func make(settings: DemoLiveChatSettings, resources: DemoTextResourceStore?,
                     fileResources: DemoFileResourceStore?, fileResourceAccess: DemoFileResourceAccess?,
                     handlers: DemoToolInteractionHandlers, searchAPIKey: String,
                     appleTools: DemoAppleToolHandlers = .unavailable) throws -> [BoneAnyAgentTool] {
        try make(settings: settings, resources: resources, fileResources: fileResources, handlers: handlers,
                 searchAPIKey: searchAPIKey, fileResourceAccess: fileResourceAccess, appleTools: appleTools)
    }

    static func make(settings: DemoLiveChatSettings, resources: DemoTextResourceStore?,
                     fileResources: DemoFileResourceStore? = nil,
                     handlers: DemoToolInteractionHandlers, searchAPIKey: String,
                     webTransport: (any BoneWebHTTPTransport)? = nil,
                     browserSearch: DemoBrowserSearchHandler? = nil,
                     resourceAccess: DemoTextResourceAccess? = nil,
                     fileResourceAccess: DemoFileResourceAccess? = nil,
                     appleTools: DemoAppleToolHandlers = .unavailable,
                     calculationObserver: (@Sendable (Double) async -> Void)? = nil,
                     failureObserver: @escaping DemoToolFailureObserver = { _ in }) throws -> [BoneAnyAgentTool] {
        var tools: [BoneAnyAgentTool] = []
        if settings.enablesCalculator {
            if let calculationObserver {
                tools.append(BoneAnyAgentTool(DemoDiagnosedTool(DemoObservedCalculatorTool(observe: calculationObserver), observe: failureObserver)))
            } else { tools.append(BoneAnyAgentTool(DemoDiagnosedTool(BoneCalculatorTool<BoneAgentEmptyContext>(), observe: failureObserver))) }
        }
        if settings.enablesDateTime {
            tools.append(BoneAnyAgentTool(DemoDiagnosedTool(BoneDateTimeTool<BoneAgentEmptyContext>(), observe: failureObserver)))
        }
        if let resources, settings.enablesTextResources {
            tools.append(BoneAnyAgentTool(DemoDiagnosedTool(DemoResourcePageTool(store: resources, access: resourceAccess), observe: failureObserver)))
            tools.append(contentsOf: resources.makeQueryTools(access: resourceAccess, failureObserver: failureObserver))
        }
        if let fileResources, settings.enablesTextResources {
            let access = fileResourceAccess ?? DemoFileResourceAccess()
            let authorizer = BoneFileResourceAuthorizer<BoneAgentEmptyContext> { reference, _ in
                guard await access.permits(reference) else { throw BoneFileResourceError.accessDenied }
            }
            let inspect = BoneFileResourceToolFactory.makeInspectTool(authorizer: authorizer) { input, _ in
                try await fileResources.inspect(input.reference)
            }
            let detectFormat = BoneFileResourceToolFactory.makeDetectFormatTool(authorizer: authorizer) { input, _ in
                .init(reference: input.reference, format: try await fileResources.detectFormat(input.reference))
            }
            let readWindow = BoneFileResourceToolFactory.makeReadWindowTool(authorizer: authorizer) { input, _ in
                do {
                    return try await fileResources.readWindow(input)
                } catch let error as BoneFileResourceError
                    where input.kind == .pdfPage && (error == .passwordRequired || error == .invalidPassword) {
                    // 密码只在当前 PDF 工具调用内存中传递，工具参数和诊断不记录密码。
                    let password = try await handlers.requestPDFPassword(.init(
                        id: UUID(), title: "输入 PDF 密码", detail: "文件“\(input.reference.id)”受密码保护，请输入本次读取使用的密码。"
                    ))
                    return try await fileResources.readWindow(input, password: password)
                }
            }
            let readOffice = BoneFileResourceToolFactory.makeReadOfficeTool(authorizer: authorizer) { input, _ in
                try await fileResources.readOffice(input)
            }
            let listEntries = BoneFileResourceToolFactory.makeListEntriesTool(authorizer: authorizer) { input, _ in
                .init(reference: input.reference, entries: try await fileResources.listEntries(input.reference))
            }
            let readBytes = BoneFileResourceToolFactory.makeReadBytesTool(authorizer: authorizer) { input, _ in
                try await fileResources.readBytes(input)
            }
            let readPDFLayout = BoneFileResourceToolFactory.makePDFLayoutTool(authorizer: authorizer) { input, _ in
                do {
                    return try await fileResources.readPDFLayout(input)
                } catch let error as BoneFileResourceError
                    where error == .passwordRequired || error == .invalidPassword {
                    // 只允许 PDF 布局读取触发密码请求，错误细节不会回传到 UI 或模型。
                    let password = try await handlers.requestPDFPassword(.init(
                        id: UUID(), title: "输入 PDF 密码", detail: "文件“\(input.reference.id)”受密码保护，请输入本次布局读取使用的密码。"
                    ))
                    return try await fileResources.readPDFLayout(input, password: password)
                }
            }
            let ocr = BoneFileResourceToolFactory.makeOCRTool(authorizer: authorizer) { input, _ in
                do {
                    return try await fileResources.ocr(input)
                } catch let error as BoneFileResourceError
                    where error == .passwordRequired || error == .invalidPassword {
                    // OCR 与布局读取共用一次性密码交互，但不会持久化密码。
                    let password = try await handlers.requestPDFPassword(.init(
                        id: UUID(), title: "输入 PDF 密码", detail: "文件“\(input.reference.id)”受密码保护，请输入本次 OCR 读取使用的密码。"
                    ))
                    return try await fileResources.ocr(input, password: password)
                }
            }
            tools.append(BoneAnyAgentTool(DemoDiagnosedTool(inspect, observe: failureObserver)))
            tools.append(BoneAnyAgentTool(DemoDiagnosedTool(detectFormat, observe: failureObserver)))
            tools.append(BoneAnyAgentTool(DemoDiagnosedTool(readWindow, observe: failureObserver)))
            tools.append(BoneAnyAgentTool(DemoDiagnosedTool(readOffice, observe: failureObserver)))
            tools.append(BoneAnyAgentTool(DemoDiagnosedTool(listEntries, observe: failureObserver)))
            tools.append(BoneAnyAgentTool(DemoDiagnosedTool(readBytes, observe: failureObserver)))
            tools.append(BoneAnyAgentTool(DemoDiagnosedTool(readPDFLayout, observe: failureObserver)))
            tools.append(BoneAnyAgentTool(DemoDiagnosedTool(ocr, observe: failureObserver)))
        }
        if settings.enablesCalendar {
            let tool = BoneCalendarTool<BoneAgentEmptyContext> { input, _ in try await appleTools.calendar(input) }
            tools.append(BoneAnyAgentTool(DemoDiagnosedTool(tool, observe: failureObserver)))
        }
        if settings.enablesReminders {
            let tool = BoneReminderTool<BoneAgentEmptyContext> { input, _ in try await appleTools.reminders(input) }
            tools.append(BoneAnyAgentTool(DemoDiagnosedTool(tool, observe: failureObserver)))
        }
        if settings.enablesNotifications {
            let tool = BoneNotificationTool<BoneAgentEmptyContext> { input, _ in try await appleTools.notifications(input) }
            tools.append(BoneAnyAgentTool(DemoDiagnosedTool(tool, observe: failureObserver)))
        }
        if settings.enablesPhotos {
            let tool = BonePhotoTool<BoneAgentEmptyContext> { input, _ in try await appleTools.photos(input) }
            tools.append(BoneAnyAgentTool(DemoDiagnosedTool(tool, observe: failureObserver)))
        }
        if settings.enablesContacts {
            let tool = BoneContactTool<BoneAgentEmptyContext> { input, _ in try await appleTools.contacts(input) }
            tools.append(BoneAnyAgentTool(DemoDiagnosedTool(tool, observe: failureObserver)))
        }
        if settings.enablesAskUser {
            let tool = BoneAskUserTool<BoneAgentEmptyContext> { question, _ in try await handlers.ask(question) }
            tools.append(BoneAnyAgentTool(DemoDiagnosedTool(tool, observe: failureObserver)))
        }
        if settings.enablesWebFetch {
            let policy = try BoneWebHostPolicy(allowedHosts: settings.webHostNames)
            let client = try BoneWebFetchHTTPClient(policy: policy,
                transport: webTransport ?? BoneURLSessionWebTransport())
            let tool = BoneWebFetchTool<BoneAgentEmptyContext>(client: client) { input, _ in
                _ = try DemoWebFetchNavigationPolicy.validate(url: input.url, policy: policy)
            }
            tools.append(BoneAnyAgentTool(DemoDiagnosedTool(tool, observe: failureObserver)))
        }
        if settings.enablesWebSearch {
            let route = DemoSearchRouter(configuration: settings.search, apiKey: searchAPIKey, transport: webTransport,
                                         browserSearch: browserSearch)
            let tool = BoneWebSearchTool<BoneAgentEmptyContext> { input, _ in
                do { return try await route.search(input) }
                catch {
                    // The SDK sanitizes unknown client errors; preserve the Host's fixed cause first.
                    if let failure = DemoToolFailure.classify(error, toolID: "web.search") { await failureObserver(failure) }
                    throw error
                }
            }
            tools.append(BoneAnyAgentTool(DemoDiagnosedTool(tool, observe: failureObserver)))
        }
        return tools
    }

    /// Run the SDK's own decoders before erasure loses typed input errors.
    /// This performs no tool operation and does not grant access to resources.
    static func validateLocalInput(_ call: BoneInferenceToolCall, definition: BoneAgentToolDefinition? = nil) throws {
        let decoder = JSONDecoder()
        switch DemoToolFailure.Tool(rawValue: call.toolID) {
        case .calculator: _ = try decoder.decode(BoneCalculatorTool<BoneAgentEmptyContext>.Input.self, from: call.arguments)
        case .dateTime: _ = try decoder.decode(BoneDateTimeTool<BoneAgentEmptyContext>.Input.self, from: call.arguments)
        case .resourceList: _ = try decoder.decode(BoneTextResourceListRequest.self, from: call.arguments)
        case .resourceSearch: _ = try decoder.decode(BoneTextResourceSearchRequest.self, from: call.arguments)
        case .resourceRead:
            if definition?.schemaVersion == DemoResourcePageTool.definition.schemaVersion {
                _ = try decoder.decode(DemoResourcePageInput.self, from: call.arguments)
            } else { _ = try decoder.decode(BoneToolTextResourceReadRequest.self, from: call.arguments) }
        case .resourceInspect: _ = try decoder.decode(BoneFileResourceInspectRequest.self, from: call.arguments)
        case .resourceDetectFormat: _ = try decoder.decode(BoneFileResourceDetectFormatRequest.self, from: call.arguments)
        case .resourceReadWindow: _ = try decoder.decode(BoneFileResourceWindowRequest.self, from: call.arguments)
        case .resourceReadOffice: _ = try decoder.decode(BoneFileResourceOfficeStructureRequest.self, from: call.arguments)
        case .resourceListEntries: _ = try decoder.decode(BoneFileResourceListEntriesRequest.self, from: call.arguments)
        case .resourceReadBytes: _ = try decoder.decode(BoneFileResourceByteReadRequest.self, from: call.arguments)
        case .resourceReadPDFLayout: _ = try decoder.decode(BoneFileResourcePDFLayoutRequest.self, from: call.arguments)
        case .resourceOCR: _ = try decoder.decode(BoneFileResourceOCRRequest.self, from: call.arguments)
        case .calendar: _ = try decoder.decode(BoneCalendarRequest.self, from: call.arguments)
        case .reminder: _ = try decoder.decode(BoneReminderRequest.self, from: call.arguments)
        case .notification: _ = try decoder.decode(BoneNotificationRequest.self, from: call.arguments)
        case .photo: _ = try decoder.decode(BonePhotoRequest.self, from: call.arguments)
        case .contact: _ = try decoder.decode(BoneContactRequest.self, from: call.arguments)
        case .askUser: try decoder.decode(BoneUserQuestion.self, from: call.arguments).validated()
        case .webFetch, .webSearch, nil: break // Network inputs are checked with the exact Host policy.
        }
    }

    /// 判断 Apple 工具本次调用是否会改变系统状态，读取操作不重复弹出确认。
    /// - Parameters:
    ///   - call: 模型提交的原始工具调用。
    ///   - definition: 已注册的工具定义。
    /// - Returns: 写入、修改、删除或保存操作返回 true。
    static func requiresExplicitApproval(_ call: BoneInferenceToolCall, definition: BoneAgentToolDefinition) throws -> Bool {
        let decoder = JSONDecoder()
        switch definition.id {
        case "calendar.manage":
            let input = try decoder.decode(BoneCalendarRequest.self, from: call.arguments)
            return [.create, .update, .delete].contains(input.action)
        case "reminder.manage":
            let input = try decoder.decode(BoneReminderRequest.self, from: call.arguments)
            return [.create, .update, .complete, .delete].contains(input.action)
        case "notification.manage":
            let input = try decoder.decode(BoneNotificationRequest.self, from: call.arguments)
            return [.schedule, .cancel].contains(input.action)
        case "photo.manage":
            return true
        case "contact.manage":
            let input = try decoder.decode(BoneContactRequest.self, from: call.arguments)
            return [.create, .update, .delete].contains(input.action)
        default:
            return definition.id == "user.ask" || definition.id == "web.fetch" || definition.id == "web.search"
        }
    }

    static func impactPolicy(settings: DemoLiveChatSettings) -> BoneToolImpactPolicy {
        let userVisibleImpact: BoneToolUserVisibleImpact
        if settings.enablesPhotos {
            userVisibleImpact = .publication
        } else if settings.enablesAskUser || settings.enablesNotifications {
            userVisibleImpact = .notification
        } else {
            userVisibleImpact = .none
        }
        return .init(maximumAllowed: .init(dataAccess: settings.enablesTextResources || settings.enablesAskUser || settings.enablesAppleTools ? .userPrivate : .public,
            externalTransmission: settings.enablesWebFetch || settings.enablesWebSearch ? .arbitraryNetwork : .none,
            stateChange: settings.enablesAppleTools ? .reversible : .none,
            economic: settings.enablesWebSearch ? .metered : .none,
            userVisible: userVisibleImpact,
            permissionChange: settings.enablesAppleTools ? .grantsAccess : .none))
    }
}
