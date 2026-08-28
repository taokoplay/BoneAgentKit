# AIProviderKit 终态 Contract 接管矩阵

## 基线与方法

删除前历史基线为 `111 tests, 0 failures`。本矩阵按行为类别接管仍有终态价值的 Contract，**不一对一复制**旧 XCTest 的源码、命名、Fixture 或旧 Adapter API。旧 Kit 是 Bone 自有历史行为来源；新实现保持 clean-room 边界，以 BoneInference 的公开领域契约和新 Harness 作为事实源。

自动 Harness 证明协议、资源与安全边界，但不替代 **真实 Provider / 真机**验收。OpenAI、Anthropic、Gemini、图片 Provider、Package Resource 和角色单章 Smoke 仍需在 App 沙箱显式执行。

## Contract 映射

| 类别 | 终态 Contract | 新证据 |
| --- | --- | --- |
| Catalog | Package 私有资源、版本、排序、继承独立身份、Provider/model 唯一性、Discovery 限制、HTTPS、能力、协议变体、图片元数据、生成参数 | `ProviderCatalogTests/main.swift`；SwiftPM `ProviderCatalogTests.swift` |
| Model Discovery | OpenAI/wrapped、Anthropic、Google、MiniMax；绝对 endpoint；无正文 GET；Anthropic 固定版本 Header；Raw GET/POST；不猜能力；15 秒上限 | `ModelDiscoveryTests/main.swift` |
| Endpoint Security | 内置 HTTPS；自定义 localhost、RFC1918、链路本地、IPv6 loopback/ULA；拒绝公网 HTTP；绝对 operation endpoint 再验证；拒绝 Base URL query/fragment | `ProviderInfrastructureTests/main.swift` |
| Header Policy | 认证、Cookie、Host、Content-Length/Type 和固定协议 Header 不可覆盖；大小写、空白及 CRLF 门禁；业务 Header 保留 | `ProviderInfrastructureTests/main.swift`；`TextInferenceTests/main.swift`；`ModelDiscoveryTests/main.swift` |
| Retry | 仅幂等模型发现 GET 对 502/503/504 和有限网络错误重试一次；timeout、取消、非临时错误不重试；POST 永不重试；Retry-After 秒数/日期有界 | `ProviderInfrastructureTests/main.swift`；`ModelDiscoveryTests/main.swift` |
| HTTP Transport | URLSession 可注入、响应容量先于 JSON、Header/metrics 元数据、取消强类型、网络诊断只保留稳定域/码和有界底层链 | `ProviderInfrastructureTests/main.swift`；App Health Reporting Harness |
| EventStream | LF/CRLF、多 data、注释、UTF-8 跨块、尾部完整事件、截断拒绝、容量、首事件/idle watchdog、取消、非 2xx | `EventStreamTests/main.swift` |
| Text Provider | OpenAI、Anthropic/MiniMax、Gemini 请求映射、鉴权、参数、动态/full endpoint、明确 text parts；OpenAI `[DONE]` 与 Anthropic `message_stop` 完整终态；失败不返回部分文本 | `TextInferenceTests/main.swift` |
| Image Provider | OpenAI URL/Base64、Gemini inlineData、Imagen predict、MiniMax URL/Base64、Agnes 原生档位；数量/尺寸/MIME/Base64/载荷边界 | `ImageInferenceTests/main.swift`；Core Harness |
| Error / Safety | 401/403、402、404、429、普通状态稳定映射；结构化 safety code / Gemini block 映射；成功正文含 safety 词不误判；错误不携带原始响应 | `TextInferenceTests/main.swift`；`ImageInferenceTests/main.swift`；App Mapper/Privacy Harness |

## 不迁移的旧实现细节

以下内容不属于终态 Contract：

- 旧 `AIProviderAdapter` existential、Registry 或 `AIProviderConfiguration` API 形状；
- 旧错误 case 名称、旧 `validatedData`/`fetchModelListData` 函数签名；
- 旧 Fixture、注释、测试函数命名和逐 Provider 重复样例；
- 旧 Kit 内部 HTTP client、metrics 字典或 adapter 分派方式；
- 远程模型按名称猜测能力或与 Registry 隐式合并。

相同行为由统一 BoneInference Client、Transport、Provider Engine 和 App Host 显式投影完成。

## 删除门禁

删除 `Frameworks/AIProviderKit` 前必须同时满足：

1. 生产 `import AIProviderKit = 0`、`AIProviderKit.* = 0`、Bridge 不存在；
2. 本矩阵引用的 Catalog、Discovery、Provider Infrastructure、EventStream、Text、Image 和隐私 Harness 全绿；
3. Xcode 只保留 `Frameworks/BoneAgentKit` Local Package/Product/Framework；
4. Simulator build 成功；
5. 独立审查 `Critical = 0`、`Important = 0`。

真实 Provider / 真机 Smoke 是发布验收门禁，不因自动 Harness 通过而自动完成。
