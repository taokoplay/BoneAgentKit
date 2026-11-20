import Foundation
import BoneAgentKit

/// User consent lasts for one send. Exact call grants remain the effect store's responsibility.
actor DemoNetworkConsent {
    struct Scope: Sendable {
        let webHosts: Set<String>
        let searchChannel: DemoSearchChannel?

        init(settings: DemoLiveChatSettings) {
            webHosts = settings.enablesWebFetch ? Set(settings.webHostNames) : []
            searchChannel = settings.enablesWebSearch ? settings.search.automaticChannel : nil
        }

        var explanation: String {
            var lines = ["仅在本次任务内有效，结束、失败或停止后失效。后续联网操作不再重复询问。"]
            if !webHosts.isEmpty { lines.append("可读取的网站：" + webHosts.sorted().joined(separator: "、")) }
            if let searchChannel {
                if searchChannel == .baiduWeb {
                    lines.append("百度网页搜索无需搜索 API Key。查询会发送到百度，并读取临时未登录页面中的有限公开结果；结果与来源会发送给当前模型。模型调用仍按你的模型账户计费。遇到登录或安全验证即停止。")
                } else {
                    lines.append("可使用的搜索服务：\(searchChannel.title)。查询会发送到该服务，可能计费。")
                }
            }
            lines.append("本次任务所有工具合计最多 \(DemoLiveChatSession.maximumToolCalls) 次调用，主推理最多 \(DemoLiveChatSession.maximumInferenceSteps) 次，最长 \(Int(DemoLiveChatSession.maximumRunSeconds)) 秒。网站请求会发送至目标网站。")
            return lines.joined(separator: "\n\n")
        }
    }

    private struct Active {
        let id: UUID
        let scope: Scope
        var approved = false
        var denied = false
        var pending: Task<Bool, any Error>?
        var prompts = 0
    }
    private var active: Active?
    private var usesRunScopes = false

    func begin(scope: Scope, id: UUID) {
        active?.pending?.cancel()
        usesRunScopes = true
        active = Active(id: id, scope: scope)
    }

    @discardableResult
    func end(id: UUID) -> Int {
        guard let active, active.id == id else { return 0 }
        active.pending?.cancel()
        self.active = nil
        return active.prompts
    }

    func authorize(tool: DemoToolFailure.Tool, target: String, webHost: String?,
                   fallbackTitle: String, searchProvider: String,
                   handlers: DemoToolInteractionHandlers) async throws {
        try Task.checkCancellation()
        guard let current = active else {
            guard !usesRunScopes else { throw CancellationError() }
            // Standalone callers without a Run keep explicit per-call consent.
            let detail: String
            if tool == .webFetch {
                detail = "允许本次读取以下网页？\n\(target)\n\n请求会发送到该网站。"
            } else if searchProvider == DemoSearchChannel.baiduWeb.title {
                detail = "允许百度网页查询以下内容？\n\(target)\n\n使用临时未登录页面读取有限公开结果；结果与来源可在运行任务时发送给当前模型。百度搜索无需搜索 Key，模型调用按你的模型账户计费。登录或安全验证会停止读取。"
            } else {
                detail = "允许通过 \(searchProvider) 查询以下内容？\n\(target)\n\n查询会发送至该搜索服务，可能计费。"
            }
            guard try await handlers.authorize(.init(id: UUID(), title: fallbackTitle, detail: detail)) else {
                throw BoneAuthorizationError.denied
            }
            return
        }
        switch tool {
        case .webFetch:
            guard let webHost, current.scope.webHosts.contains(webHost.lowercased()) else { throw BoneAuthorizationError.denied }
        case .webSearch:
            guard let channel = current.scope.searchChannel, channel.supportsAutomaticSearch,
                  channel.title == searchProvider else { throw BoneAuthorizationError.denied }
        default: throw BoneAuthorizationError.denied
        }
        if current.approved { return }
        guard !current.denied else { throw BoneAuthorizationError.denied }
        let pending: Task<Bool, any Error>
        if let existing = current.pending {
            pending = existing
        } else {
            let request = DemoToolAuthorizationRequest(id: UUID(), title: "允许本次任务联网？",
                detail: "首次操作：\(tool.title)\n\(target)\n\n" + current.scope.explanation)
            pending = Task { try await handlers.authorize(request) }
            active?.pending = pending
            active?.prompts += 1
        }
        do {
            let approved = try await withTaskCancellationHandler {
                try await pending.value
            } onCancel: { pending.cancel() }
            try Task.checkCancellation()
            guard !pending.isCancelled else { throw CancellationError() }
            // An old prompt cannot authorize a replacement Run after suspension.
            guard active?.id == current.id else { throw CancellationError() }
            active?.pending = nil
            active?.approved = approved
            active?.denied = !approved
            guard approved else { throw BoneAuthorizationError.denied }
        } catch {
            if active?.id == current.id {
                active?.pending = nil
                active?.denied = true
            }
            throw error
        }
    }
}
