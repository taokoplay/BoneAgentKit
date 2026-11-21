import Foundation
import BoneAgentKit
import BoneAgentTools

/// Only constructed by explicit UI-testing mode. Never a fallback for a real request.
struct LiveToolsUITestWebTransport: BoneWebHTTPTransport {
    func send(request: URLRequest, maximumResponseBytes: Int) async throws -> BoneWebHTTPResponse {
        try Task.checkCancellation()
        guard let url = request.url else { throw BoneWebError.invalidURL }
        if url.host == "api.search.brave.com" {
            return .init(url: url, statusCode: 200, headers: ["Content-Type": "application/json"],
                body: Data(#"{"type":"search","query":{"more_results_available":false},"web":{"results":[{"title":"离线搜索测试","url":"https://example.com/article","description":"此结果来自 UI 测试替身，未联网。"}]}}"#.utf8))
        }
        if url.host == "api.deepseek.com", url.path == "/v1/tools/search", request.httpMethod == "POST" {
            return .init(url: url, statusCode: 200, headers: ["Content-Type": "application/json"],
                body: Data(#"{"results":[{"title":"DeepSeek 搜索界面测试","url":"https://example.com/article","snippet":"这条摘要来自 DeepSeek API 测试响应，未联网。"}]}"#.utf8))
        }
        guard url.host == "example.com" else { throw BoneWebError.hostNotAllowed }
        return .init(url: url, statusCode: 200, headers: ["Content-Type": "text/html; charset=utf-8"],
            body: Data("<html><title>离线网页测试</title><main>这段正文来自测试替身，未联网。</main></html>".utf8))
    }
}

enum LiveToolsUITestFixture {
    static func events(request: URLRequest, provider: DemoChatProvider) throws -> [BoneInferenceEventStreamEvent]? {
        guard ProcessInfo.processInfo.arguments.contains("--built-in-tools-ui-test"),
              let data = request.httpBody,
              let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messages = body["messages"] as? [[String: Any]], let last = messages.last,
              last["role"] as? String == "user" else { return nil }
        let text: String
        if let string = last["content"] as? String { text = string }
        else if let content = last["content"] as? [[String: Any]],
                !content.contains(where: { $0["type"] as? String == "tool_result" }) {
            text = content.compactMap { $0["text"] as? String }.joined()
        } else { return nil }
        let name: String
        let input: [String: Any]
        let task = text.components(separatedBy: "\n\nAttached text previews").first ?? text
        let marker: String
        if let group = BoneBuiltInToolGroup.allCases.first(where: { DemoToolUsage.guide(for: $0).example == task }) {
            switch group {
            case .calculator: marker = "tool-test:calculate"
            case .dateTime: marker = "tool-test:time"
            case .resources: marker = "tool-test:resources"
            case .calendar: marker = "tool-test:calendar"
            case .reminders: marker = "tool-test:reminders"
            case .notifications: marker = "tool-test:notifications"
            case .photos: marker = "tool-test:photos"
            case .contacts: marker = "tool-test:contacts"
            case .location: marker = "tool-test:location"
            case .share: marker = "tool-test:share"
            case .compose: marker = "tool-test:compose"
            case .webFetch: marker = "tool-test:fetch"
            case .webSearch: marker = "tool-test:search"
            case .askUser: marker = "tool-test:single"
            }
        } else { marker = task }
        switch marker {
        case "tool-test:single":
            name = "user_ask"; input = ["question": "请选择回答风格", "kind": "singleChoice",
                "options": [["id": "a", "label": "简洁"], ["id": "b", "label": "详细"]]]
        case "tool-test:multiple":
            name = "user_ask"; input = ["question": "请选择关注点", "kind": "multipleChoice",
                "options": [["id": "a", "label": "功能"], ["id": "b", "label": "设计"], ["id": "c", "label": "性能"]]]
        case "tool-test:text":
            name = "user_ask"; input = ["question": "请补充你的需求", "kind": "text", "options": []]
        case "tool-test:fetch":
            name = "web_fetch"; input = ["url": "https://example.com/article", "maximumTextBytes": 1_024]
        case "tool-test:blocked-fetch":
            name = "web_fetch"; input = ["url": "https://weather.example.org/forecast", "maximumTextBytes": 1_024]
        case "tool-test:search":
            name = "web_search"; input = ["query": "BoneAgentKit SDK", "count": 5, "page": 0]
        case "tool-test:calculate":
            name = "math_calculate"; input = ["expression": "128*36"]
        case "tool-test:time":
            name = "time_query"; input = ["action": "now"]
        case "tool-test:resources":
            name = "resource_list"; input = ["offset": 0, "limit": 20]
        case "tool-test:calendar":
            name = "calendar_manage"; input = ["action": "search", "limit": 10]
        case "tool-test:reminders":
            name = "reminder_manage"; input = ["action": "search", "limit": 10]
        case "tool-test:notifications":
            name = "notification_manage"; input = ["action": "list"]
        case "tool-test:photos":
            name = "photo_manage"; input = ["action": "save", "imageID": "ui-test-image"]
        case "tool-test:contacts":
            name = "contact_manage"; input = ["action": "search", "query": "张三", "limit": 10]
        default: return nil
        }
        func json(_ object: [String: Any]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
        }
        switch provider.kind {
        case .anthropic, .miniMax:
            return [
                .init(event: "message_start", data: #"{"type":"message_start","message":{"id":"ui-tool","type":"message","role":"assistant","content":[],"model":"ui-test","usage":{"input_tokens":3,"output_tokens":0}}}"#),
                .init(event: "content_block_start", data: try json(["type": "content_block_start", "index": 0,
                    "content_block": ["type": "tool_use", "id": "ui-tool-1", "name": name, "input": [:]]])),
                .init(event: "content_block_delta", data: try json(["type": "content_block_delta", "index": 0,
                    "delta": ["type": "input_json_delta", "partial_json": try json(input)]])),
                .init(event: "content_block_stop", data: #"{"type":"content_block_stop","index":0}"#),
                .init(event: "message_delta", data: #"{"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":null},"usage":{"output_tokens":2}}"#),
                .init(event: "message_stop", data: #"{"type":"message_stop"}"#)
            ]
        case .google: return nil
        default:
            return [
                .init(data: try json(["choices": [["index": 0, "delta": ["role": "assistant", "tool_calls": [
                    ["index": 0, "id": "ui-tool-1", "type": "function", "function": ["name": name, "arguments": try json(input)]]
                ]], "finish_reason": NSNull()]]])),
                .init(data: #"{"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":3,"completion_tokens":2}}"#),
                .init(data: "[DONE]")
            ]
        }
    }
}
