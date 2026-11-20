import Foundation

enum PromptBaseChoice: String, CaseIterable, Identifiable {
    case inherit = "继承"
    case replace = "替换"
    case clear = "清空"
    var id: Self { self }
}

struct PromptLabDraft: Equatable {
    var choice: PromptBaseChoice = .replace
    var base = "你是一个帮助检查执行流程的助手。"
    var replacement = "用简短中文说明工具执行的实际结果。"
    var append = "结果未知时先停止，不重复调用工具。"
    var fact = "本次运行处于 planning 模式。"
}

struct PromptLabResult {
    let composition: DemoPromptComposition
    let requestCount: Int
    let visibleToolIDs: [String]
    let userText: String

    var systemText: String {
        composition.systemMessages.compactMap(\.content).joined(separator: "\n\n")
    }

    var report: String {
        let metrics = [
            "System 字节：\(composition.systemUTF8ByteCount)",
            "User 数据字节：\(composition.runtimeUTF8ByteCount)",
            "模型请求：\(requestCount)",
            "可见工具：\(visibleToolIDs.isEmpty ? "无" : visibleToolIDs.joined(separator: ", "))"
        ]
        let sections = composition.sectionIDs.enumerated().map { "\($0.offset + 1). \($0.element)" }
        return (["Prompt 组装结果", "结果：组装与执行通过", "", "验证指标（UTF-8）："]
                + metrics + ["", "System 生效顺序："] + sections
                + ["", "实际 System：", systemText.isEmpty ? "（未生成 System 消息）" : systemText,
                   "", "实际 User：", userText,
                   "", "模型响应由脚本给出。本次验证消息组装与执行路径，不验证模型是否理解了这些指令。"])
            .joined(separator: "\n")
    }
}
