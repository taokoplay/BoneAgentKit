import Foundation
import BoneAgentKit
import BoneAgentTools

/// Diagnostics contain only known identities and fixed categories.
/// Never retain arguments, arbitrary error strings, network responses or resource content.
struct DemoToolFailure: Codable, Equatable, Sendable {
    enum Tool: String, Codable, CaseIterable, Sendable {
        case calculator = "math.calculate"
        case dateTime = "time.query"
        case resourceList = "resource.list"
        case resourceSearch = "resource.search"
        case resourceRead = "resource.readText"
        case resourceInspect = "resource.inspect"
        case resourceDetectFormat = "resource.detectFormat"
        case resourceReadWindow = "resource.readWindow"
        case resourceReadOffice = "resource.readOffice"
        case resourceListEntries = "resource.listEntries"
        case resourceReadBytes = "resource.readBytes"
        case resourceReadPDFLayout = "resource.readPDFLayout"
        case resourceOCR = "resource.ocr"
        case webFetch = "web.fetch"
        case webSearch = "web.search"
        case askUser = "user.ask"

        var title: String {
            switch self {
            case .calculator: "计算器"
            case .dateTime: "日期与时间"
            case .resourceList: "资料列表"
            case .resourceSearch: "资料检索"
            case .resourceRead: "资料读取"
            case .resourceInspect: "文件资源检查"
            case .resourceDetectFormat: "文件格式探测"
            case .resourceReadWindow: "文件窗口读取"
            case .resourceReadOffice: "Office 结构读取"
            case .resourceListEntries: "压缩包条目"
            case .resourceReadBytes: "原始字节读取"
            case .resourceReadPDFLayout: "PDF 布局还原"
            case .resourceOCR: "PDF OCR"
            case .webFetch: "网页正文读取"
            case .webSearch: "自动搜索"
            case .askUser: "询问用户"
            }
        }
    }
    enum Reason: String, Codable, Equatable, Sendable {
        case invalidArguments, hostNotAllowed, invalidURL, notAuthorized, configuration
        case network, httpFailure, invalidResponse, limitExceeded, unsupportedContent
        case resourceUnavailable, calculationFailed, dateFailed, interactionUnavailable
        case unregisteredTool, outcomeUnconfirmed, unknown
        case redirectNotAllowed, manualSearchRequired
        case browserVerification, browserTimeout, browserNavigation, browserUnavailable

        var message: String {
            switch self {
            case .invalidArguments: "模型提供的工具参数不符合要求。"
            case .hostNotAllowed: "目标网站不在允许读取的域名中，已阻止继续读取。"
            case .invalidURL: "网页地址不符合安全 HTTPS 地址要求，已阻止继续读取。"
            case .notAuthorized: "本次工具授权未完成，未获得执行许可。"
            case .configuration: "所需服务配置不可用，请检查工具和搜索设置。"
            case .network: "工具的网络请求失败，请检查连接或稍后再试。"
            case .httpFailure: "目标网站或搜索服务返回了失败状态。"
            case .invalidResponse: "工具收到的响应无法使用。"
            case .redirectNotAllowed: "网页要求跳转，当前正文读取未跟随跳转。请在搜索页手动打开页面并选取内容，或使用获准的最终网页地址。"
            case .manualSearchRequired: DemoSearchError.manualSearchRequired.message
            case .browserVerification: DemoBrowserSearchError.verificationRequired.message
            case .browserTimeout: DemoBrowserSearchError.timedOut.message
            case .browserNavigation: DemoBrowserSearchError.navigationChanged.message
            case .browserUnavailable: DemoBrowserSearchError.unavailable.message
            case .limitExceeded: "工具输入或结果超过了允许的大小或运算范围。"
            case .unsupportedContent: "网页内容类型暂不支持正文读取。"
            case .resourceUnavailable: "资料引用已失效或当前不可读取，请重新导入所需资料。"
            case .calculationFailed: "表达式无法计算，请检查运算格式、除零或数值范围。"
            case .dateFailed: "日期、时区或日期运算范围不符合要求。"
            case .interactionUnavailable: "本次询问未能取得可用回答，请重新检查问题或选项。"
            case .unregisteredTool: "模型请求了本次未注册的工具，请检查工具选择。"
            case .outcomeUnconfirmed: "工具结果未能确认提交，请检查已发生的操作后再决定下一步。"
            case .unknown: "工具执行未完成，现有信息无法确定具体原因。"
            }
        }
    }
    let tool: Tool?
    let reason: Reason
    var requiresOutcomeReview = false
    var resourceIssue: DemoResourceReadIssue? = nil
    var title: String {
        if tool == .resourceRead && reason == .invalidArguments { return "资料读取参数有误" }
        return tool.map { "\($0.title)未完成" } ?? "工具调用未完成"
    }
    var message: String {
        if let resourceIssue { return resourceIssue.message }
        if tool == .resourceRead && reason == .invalidArguments {
            return "模型给出的读取参数不符合要求。原问题与文件仍保留，可点附件本机预览，或重试原任务；调整回复 Token 上限不会修正读取参数。"
        }
        return reason.message
    }
    var offersSearch: Bool { tool == .webFetch || tool == .webSearch || tool == nil }
    var needsNetworkSettings: Bool {
        (tool == .webFetch && (reason == .hostNotAllowed || reason == .configuration || reason == .manualSearchRequired)) ||
        (tool == .webSearch && reason == .configuration)
    }

    static func classify(_ error: any Error, toolID: String) -> Self? {
        if error is CancellationError || Task.isCancelled { return nil }
        if let error = error as? URLError, error.code == .cancelled { return nil }
        let tool = Tool(rawValue: toolID)
        let reason: Reason
        if let error = error as? BoneWebError {
            switch error {
            case .hostNotAllowed: reason = .hostNotAllowed
            case .invalidURL: reason = .invalidURL
            case .invalidInput: reason = .invalidArguments
            case .invalidConfiguration: reason = .configuration
            case .scopeDenied: reason = .notAuthorized
            case .requestFailed: reason = .network
            case .httpFailure: reason = .httpFailure
            case .responseTooLarge: reason = .limitExceeded
            case .unsupportedContentType: reason = .unsupportedContent
            case .redirectNotAllowed: reason = .redirectNotAllowed
            case .invalidResponse: reason = .invalidResponse
            }
        } else if error is BoneAuthorizationError {
            reason = .notAuthorized
        } else if let error = error as? DemoSearchError {
            switch error {
            case .invalidQuery, .unsupportedPage: reason = .invalidArguments
            case .disabled, .missingKey, .browserUnavailable: reason = .configuration
            case .manualSearchRequired: reason = .manualSearchRequired
            default: reason = .invalidResponse
            }
        } else if let error = error as? DemoBrowserSearchError {
            switch error {
            case .unsupportedPage: reason = .invalidArguments
            case .verificationRequired: reason = .browserVerification
            case .timedOut: reason = .browserTimeout
            case .navigationChanged: reason = .browserNavigation
            case .unavailable, .busy: reason = .browserUnavailable
            case .invalidSnapshot: reason = .invalidResponse
            }
        } else if let error = error as? BoneCalculatorError {
            switch error {
            case .invalidArguments: reason = .invalidArguments
            case .expressionTooLong, .tokenLimitExceeded, .depthLimitExceeded, .operationLimitExceeded:
                reason = .limitExceeded
            default: reason = .calculationFailed
            }
        } else if error is BoneDateTimeError {
            reason = .dateFailed
        } else if let error = error as? BoneToolTextResourceError {
            switch error {
            case .unavailable, .expired, .referenceMismatch, .accessDenied: reason = .resourceUnavailable
            default: reason = .invalidArguments
            }
        } else if let error = error as? BoneFileResourceError {
            switch error {
            case .accessDenied, .expired, .unavailable, .referenceMismatch: reason = .resourceUnavailable
            case .capacityExceeded, .archiveLimitExceeded: reason = .limitExceeded
            case .unsupportedFormat, .unsupportedEncoding, .protectedContent: reason = .unsupportedContent
            case .passwordRequired, .invalidPassword: reason = .notAuthorized
            case .invalidReference, .invalidRequest, .invalidName, .invalidEncoding, .notRegularFile,
                 .parseFailed, .archiveUnsafe: reason = .invalidArguments
            }
        } else if error is DemoResourcePageError {
            reason = .invalidArguments
        } else if error is BoneAskUserError {
            reason = .interactionUnavailable
        } else if error is DecodingError || error is BoneAgentToolError {
            reason = .invalidArguments
        } else if error is URLError {
            reason = .network
        } else {
            reason = .unknown
        }
        return .init(tool: tool, reason: reason, resourceIssue: tool == .resourceRead ? DemoResourceReadIssue.classify(error) : nil)
    }
}

typealias DemoToolFailureObserver = @Sendable (DemoToolFailure) async -> Void

/// Keeps the original definition, types, output and throwing behavior intact.
struct DemoDiagnosedTool<Base: BoneAgentTool>: BoneAgentTool {
    typealias Input = Base.Input
    typealias Output = Base.Output
    typealias Context = Base.Context
    static var definition: BoneAgentToolDefinition { Base.definition }
    let base: Base
    let observe: DemoToolFailureObserver

    init(_ base: Base, observe: @escaping DemoToolFailureObserver) {
        self.base = base; self.observe = observe
    }

    func execute(input: Input, context: Context) async throws -> Output {
        do { return try await base.execute(input: input, context: context) }
        catch {
            if let failure = DemoToolFailure.classify(error, toolID: Self.definition.id) {
                await observe(failure)
            }
            throw error
        }
    }
}
