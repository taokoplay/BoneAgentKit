import Foundation
import Testing
import BoneAgentKit
import BoneAgentTools
@testable import WorkflowRunnerDemo

struct AppleToolContractTests {
    @Test func appleToolGroupsExposeStableToolIDsAndSettingsRoundTrip() throws {
        let expectedGroups: [BoneBuiltInToolGroup] = [.calendar, .reminders, .notifications, .photos, .contacts]
        #expect(expectedGroups.allSatisfy { !$0.toolIDs.isEmpty })
        #expect(BoneBuiltInToolGroup.calendar.toolIDs == ["calendar.manage"])
        #expect(BoneBuiltInToolGroup.reminders.toolIDs == ["reminder.manage"])
        #expect(BoneBuiltInToolGroup.notifications.toolIDs == ["notification.manage"])
        #expect(BoneBuiltInToolGroup.photos.toolIDs == ["photo.manage"])
        #expect(BoneBuiltInToolGroup.contacts.toolIDs == ["contact.manage"])

        var settings = DemoLiveChatSettings()
        settings.enablesCalendar = true
        settings.enablesReminders = true
        settings.enablesNotifications = true
        settings.enablesPhotos = true
        settings.enablesContacts = true
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

    @Test func appleToolAssemblyRegistersSelectedTools() throws {
        var settings = DemoLiveChatSettings()
        settings.enablesCalendar = true
        settings.enablesReminders = true
        settings.enablesNotifications = true
        settings.enablesPhotos = true
        settings.enablesContacts = true
        let tools = try DemoBuiltInToolAssembly.make(settings: settings, resources: nil, handlers: .unavailable, searchAPIKey: "")
        #expect(Set(tools.map(\.definition.id)) == [
            "calendar.manage", "reminder.manage", "notification.manage", "photo.manage", "contact.manage"
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

    @Test func appleToolDefinitionsDeclarePrivateDataAndStateImpact() throws {
        let definitions = [
            BoneCalendarTool<BoneAgentEmptyContext>.definition,
            BoneReminderTool<BoneAgentEmptyContext>.definition,
            BoneNotificationTool<BoneAgentEmptyContext>.definition,
            BonePhotoTool<BoneAgentEmptyContext>.definition,
            BoneContactTool<BoneAgentEmptyContext>.definition
        ]
        for definition in definitions {
            let validated = try definition.validatedForModelExposure()
            let impact = try validated.requiredImpact()
            #expect(impact.dataAccess == .userPrivate)
            #expect(impact.permissionChange == .grantsAccess)
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
