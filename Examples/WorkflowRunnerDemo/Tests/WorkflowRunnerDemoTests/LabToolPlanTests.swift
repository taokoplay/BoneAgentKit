import Foundation
import Testing
import BoneAgentTools
@testable import WorkflowRunnerDemo

struct LabToolPlanTests {
    @Test func applyingSelectionChangesOnlyToolFlags() throws {
        var original = DemoLiveChatSettings()
        original.systemPrompt = "保留原始指令"
        original.preservesConversation = true
        original.enablesCalculator = true
        let plan = DemoLabToolPlan(groups: [.dateTime, .resources, .askUser])
        let applied = plan.applying(to: original)
        #expect(!applied.enablesCalculator && applied.enablesDateTime && applied.enablesTextResources && applied.enablesAskUser)
        #expect(!applied.enablesWebFetch && !applied.enablesWebSearch)
        #expect(applied.provider == original.provider && applied.baseURL == original.baseURL && applied.modelID == original.modelID)
        #expect(applied.systemPrompt == original.systemPrompt && applied.preservesConversation)
        #expect(applied.maximumOutputTokens == original.maximumOutputTokens && applied.visionBindingID == original.visionBindingID)
        #expect(DemoLabToolPlan(settings: applied) == plan)
    }

    @Test func researchSelectionRetainsAllToolsAndReportsEachMissingDependency() {
        let plan = DemoLabToolPlan(groups: Set(BoneBuiltInToolPreset.research.groups))
        #expect(plan.groups.count == 6 && plan.toolCount == 14)
        let requirements = plan.requirements(settings: .init(), hasModelKey: false, hasSearchKey: false)
        #expect(requirements.map(\.kind) == [.model, .webHosts, .searchKey])
        #expect(plan.groups.contains(.webFetch) && plan.groups.contains(.webSearch))
        #expect(requirements.allSatisfy { !$0.message.isEmpty && !$0.actionTitle.isEmpty })
    }

    @Test func readyConfigurationRemovesNetworkBlockersWithoutChangingSelection() {
        var settings = DemoLiveChatSettings()
        settings.webAllowedHosts = "example.com\ndeveloper.apple.com"
        var search = settings.search; search.braveEnabled = true; settings.search = search
        let plan = DemoLabToolPlan(groups: [.webFetch, .webSearch])
        #expect(plan.requirements(settings: settings, hasModelKey: true, hasSearchKey: true).isEmpty)
        #expect(plan.toolCount == 2)
        settings.webAllowedHosts = "127.0.0.1"
        #expect(plan.requirements(settings: settings, hasModelKey: true, hasSearchKey: true).map(\.kind) == [.webHosts])
    }

    @Test func pendingMaterialsRequireTheirMatchingInputRules() {
        let plan = DemoLabToolPlan(groups: [.calculator])
        let requirements = plan.requirements(settings: .init(), hasModelKey: true, hasSearchKey: false,
                                             pendingTexts: 1, pendingImages: 1)
        #expect(requirements.map(\.kind) == [.resources, .vision])
        var settings = DemoLiveChatSettings()
        settings.visionPolicy = .customLinear; settings.visionTokenBase = 100; settings.visionTokensPerMegapixel = 100
        settings.bindVisionToCurrentModel()
        let ready = DemoLabToolPlan(groups: [.resources])
        #expect(ready.requirements(settings: settings, hasModelKey: true, hasSearchKey: false,
                                   pendingTexts: 1, pendingImages: 1).isEmpty)
    }

    @Test func selectionIsSerializableAndUnknownGroupsAreRejected() throws {
        let plan = DemoLabToolPlan(groups: [.calculator, .askUser])
        #expect(try JSONDecoder().decode(DemoLabToolPlan.self, from: JSONEncoder().encode(plan)) == plan)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(DemoLabToolPlan.self, from: Data(#"{"groups":["unknown-tool"]}"#.utf8))
        }
        #expect(DemoLabToolPlan(groups: []).toolCount == 0)
        #expect(DemoLabToolPlan(groups: []).summary == "纯模型对话")
    }

    @Test(arguments: BoneBuiltInToolGroup.allCases)
    func everyToolHasAnActionableGuide(group: BoneBuiltInToolGroup) {
        let guide = DemoToolUsage.guide(for: group)
        #expect(guide.group == group && !guide.symbol.isEmpty && !guide.purpose.isEmpty)
        #expect(!guide.preparation.isEmpty && guide.steps.count == 3)
        #expect(!guide.example.isEmpty && guide.example.utf8.count <= DemoLiveChatSession.maximumUserMessageBytes)
    }
}
