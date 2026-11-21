import Foundation
import Testing
import BoneAgentKit
import BoneAgentTools
@testable import WorkflowRunnerDemo

struct AppleToolContractTests {
    @Test func appleToolGroupsExposeStableToolIDsAndSettingsRoundTrip() throws {
        let expectedGroups: [BoneBuiltInToolGroup] = [.calendar, .reminders, .notifications, .photos, .contacts, .location, .share, .compose]
        #expect(expectedGroups.allSatisfy { !$0.toolIDs.isEmpty })
        #expect(BoneBuiltInToolGroup.calendar.toolIDs == ["calendar.manage"])
        #expect(BoneBuiltInToolGroup.reminders.toolIDs == ["reminder.manage"])
        #expect(BoneBuiltInToolGroup.notifications.toolIDs == ["notification.manage"])
        #expect(BoneBuiltInToolGroup.photos.toolIDs == ["photo.manage"])
        #expect(BoneBuiltInToolGroup.contacts.toolIDs == ["contact.manage"])
        #expect(BoneBuiltInToolGroup.location.toolIDs == ["location.lookup"])
        #expect(BoneBuiltInToolGroup.share.toolIDs == ["share.present"])
        #expect(BoneBuiltInToolGroup.compose.toolIDs == ["compose.present"])

        var settings = DemoLiveChatSettings()
        settings.enablesCalendar = true
        settings.enablesReminders = true
        settings.enablesNotifications = true
        settings.enablesPhotos = true
        settings.enablesContacts = true
        settings.enablesLocation = true
        settings.enablesShare = true
        settings.enablesCompose = true
        let restored = try JSONDecoder().decode(DemoLiveChatSettings.self,
            from: JSONEncoder().encode(settings))
        #expect(restored == settings)
    }

    @Test func calendarInputRejectsUnboundedSearchAndMissingCreateFields() throws {
        #expect(throws: BoneAppleToolError.invalidArguments) {
            _ = try BoneCalendarRequest(action: .search, query: String(repeating: "a", count: 257))
        }
        #expect(throws: BoneAppleToolError.invalidArguments) {
            _ = try BoneCalendarRequest(action: .create, title: "会议")
        }
    }

    @Test func notificationInputRejectsPastAndOversizedRequests() throws {
        #expect(throws: BoneAppleToolError.invalidArguments) {
            _ = try BoneNotificationRequest(
                action: .schedule, identifier: "agent-1", title: "提醒",
                body: nil, fireDate: "2000-01-01T00:00:00Z", repeats: false)
        }
        #expect(throws: BoneAppleToolError.invalidArguments) {
            _ = try BoneNotificationRequest(
                action: .schedule, identifier: String(repeating: "a", count: 129),
                title: "提醒", body: nil, fireDate: nil, repeats: false)
        }
    }

    @Test func locationInputRequiresValidCoordinatesOnlyForReverseGeocoding() throws {
        _ = try BoneLocationRequest(action: .current)
        _ = try BoneLocationRequest(action: .reverseGeocode, latitude: 31.2304, longitude: 121.4737)
        #expect(throws: BoneAppleToolError.invalidArguments) {
            _ = try BoneLocationRequest(action: .reverseGeocode, latitude: 91, longitude: 121)
        }
        #expect(throws: BoneAppleToolError.invalidArguments) {
            _ = try BoneLocationRequest(action: .current, latitude: 31, longitude: 121)
        }
    }

    @Test func shareAndComposeInputsRejectUnboundedOrIncompleteContent() throws {
        _ = try BoneShareRequest(contentType: .text, text: "分享内容")
        _ = try BoneShareRequest(contentType: .url, url: "https://example.com")
        #expect(throws: BoneAppleToolError.invalidArguments) {
            _ = try BoneShareRequest(contentType: .text)
        }
        #expect(throws: BoneAppleToolError.invalidArguments) {
            _ = try BoneComposeRequest(channel: .mail, recipients: [], subject: "主题", body: "正文")
        }
        #expect(throws: BoneAppleToolError.invalidArguments) {
            _ = try BoneComposeRequest(channel: .message, recipients: [String(repeating: "1", count: 2_049)], subject: nil, body: "正文")
        }
    }

    @Test func appleToolAssemblyRegistersSelectedTools() throws {
        var settings = DemoLiveChatSettings()
        settings.enablesCalendar = true
        settings.enablesReminders = true
        settings.enablesNotifications = true
        settings.enablesPhotos = true
        settings.enablesContacts = true
        settings.enablesLocation = true
        settings.enablesShare = true
        settings.enablesCompose = true
        let tools = try DemoBuiltInToolAssembly.make(settings: settings, resources: nil, handlers: .unavailable, searchAPIKey: "")
        #expect(Set(tools.map(\.definition.id)) == [
            "calendar.manage", "reminder.manage", "notification.manage", "photo.manage", "contact.manage",
            "location.lookup", "share.present", "compose.present"
        ])
    }

    @Test func appleToolImpactPolicyPreservesNotificationAndPublicationLevels() throws {
        var notificationSettings = DemoLiveChatSettings()
        notificationSettings.enablesNotifications = true
        let notificationImpact = DemoBuiltInToolAssembly.impactPolicy(settings: notificationSettings).maximumAllowed
        #expect(notificationImpact.userVisible == .notification)

        var photoSettings = DemoLiveChatSettings()
        photoSettings.enablesPhotos = true
        let photoImpact = DemoBuiltInToolAssembly.impactPolicy(settings: photoSettings).maximumAllowed
        #expect(photoImpact.userVisible == .publication)
    }

    @Test func contactInputRejectsUnboundedValuesAndEmptyCreate() throws {
        #expect(throws: BoneAppleToolError.invalidArguments) {
            _ = try BoneContactRequest(action: .create)
        }
        #expect(throws: BoneAppleToolError.invalidArguments) {
            _ = try BoneContactRequest(action: .create, givenName: "张三", phones: Array(repeating: "1", count: 9))
        }
        let request = try BoneContactRequest(action: .search, query: "张三")
        #expect(request.query == "张三")
    }

    @Test func contactReadsAvoidApprovalWhileWritesRequireIt() throws {
        let search = BoneInferenceToolCall(
            id: "contact-search",
            toolID: "contact.manage",
            arguments: try JSONEncoder().encode(BoneContactRequest(action: .search, query: "张三"))
        )
        let create = BoneInferenceToolCall(
            id: "contact-create",
            toolID: "contact.manage",
            arguments: try JSONEncoder().encode(BoneContactRequest(action: .create, givenName: "张三"))
        )
        let definition = BoneContactTool<BoneAgentEmptyContext>.definition
        #expect(try DemoBuiltInToolAssembly.requiresExplicitApproval(search, definition: definition) == false)
        #expect(try DemoBuiltInToolAssembly.requiresExplicitApproval(create, definition: definition) == true)
    }

    @Test func contactEffectStoreUsesAppleApprovalForWritesOnly() async throws {
        var settings = DemoLiveChatSettings()
        settings.enablesContacts = true
        let effects = DemoToolEffectStore()
        let runID = await effects.beginRun(scope: .init(settings: settings))
        let approvals = AppleApprovalProbe()
        let handlers = DemoToolInteractionHandlers(
            ask: { _ in throw BoneAskUserError.unavailable },
            authorize: { request in await approvals.record(request) }
        )
        let definition = BoneContactTool<BoneAgentEmptyContext>.definition
        let searchCall = BoneInferenceToolCall(
            id: "contact-search-effect",
            toolID: definition.id,
            arguments: try JSONEncoder().encode(BoneContactRequest(action: .search, query: "张三"))
        )
        let createCall = BoneInferenceToolCall(
            id: "contact-create-effect",
            toolID: definition.id,
            arguments: try JSONEncoder().encode(BoneContactRequest(action: .create, givenName: "张三"))
        )
        _ = try await effects.context(for: searchCall, definition: definition, handlers: handlers)
        _ = try await effects.context(for: createCall, definition: definition, handlers: handlers)
        #expect(await approvals.requests.count == 1)
        #expect(await approvals.requests.first?.detail.contains("系统通讯录") == true)
        #expect(await effects.endRun(id: runID) == 0)
    }

    @Test func locationReadsDoNotRequireApprovalButShareAndComposeDo() throws {
        let locationCall = BoneInferenceToolCall(
            id: "location-current",
            toolID: "location.lookup",
            arguments: try JSONEncoder().encode(BoneLocationRequest(action: .current))
        )
        let shareCall = BoneInferenceToolCall(
            id: "share-text",
            toolID: "share.present",
            arguments: try JSONEncoder().encode(BoneShareRequest(contentType: .text, text: "内容"))
        )
        let composeCall = BoneInferenceToolCall(
            id: "compose-mail",
            toolID: "compose.present",
            arguments: try JSONEncoder().encode(BoneComposeRequest(channel: .mail, recipients: ["user@example.com"], subject: "主题", body: "正文"))
        )
        #expect(try DemoBuiltInToolAssembly.requiresExplicitApproval(locationCall, definition: BoneLocationTool<BoneAgentEmptyContext>.definition) == false)
        #expect(try DemoBuiltInToolAssembly.requiresExplicitApproval(shareCall, definition: BoneShareTool<BoneAgentEmptyContext>.definition) == true)
        #expect(try DemoBuiltInToolAssembly.requiresExplicitApproval(composeCall, definition: BoneComposeTool<BoneAgentEmptyContext>.definition) == true)
    }

    @Test func appleToolDefinitionsDeclarePrivateDataAndStateImpact() throws {
        let definitions = [
            BoneCalendarTool<BoneAgentEmptyContext>.definition,
            BoneReminderTool<BoneAgentEmptyContext>.definition,
            BoneNotificationTool<BoneAgentEmptyContext>.definition,
            BonePhotoTool<BoneAgentEmptyContext>.definition,
            BoneContactTool<BoneAgentEmptyContext>.definition,
            BoneLocationTool<BoneAgentEmptyContext>.definition,
            BoneShareTool<BoneAgentEmptyContext>.definition,
            BoneComposeTool<BoneAgentEmptyContext>.definition
        ]
        for definition in definitions {
            let validated = try definition.validatedForModelExposure()
            let impact = try validated.requiredImpact()
            #expect(impact.dataAccess == .userPrivate)
            if ["calendar.manage", "reminder.manage", "notification.manage", "photo.manage", "contact.manage", "location.lookup"].contains(definition.id) {
                #expect(impact.permissionChange == .grantsAccess)
            } else {
                #expect(impact.permissionChange == .none)
            }
        }
    }
}


private actor AppleApprovalProbe {
    private(set) var requests: [DemoToolAuthorizationRequest] = []

    func record(_ request: DemoToolAuthorizationRequest) -> Bool {
        requests.append(request)
        return true
    }
}
