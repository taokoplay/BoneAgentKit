# Swift Package 接入

## 当前形态

BoneAgentKit 通过独立 Git 仓库中的 Swift Package 分发。调用方应使用明确版本或精确 revision，并只链接实际需要的 Product。

```swift
.package(
    url: "https://github.com/taokoplay/BoneAgentKit.git",
    exact: "<approved-version>"
)
```

基础调用方只需依赖 `BoneAgentKit`；本地模型基础设施和 Adapter 是独立 Product，不会因基础依赖自动启用。

Git Tag 是 SwiftPM 依赖解析的版本事实源。`BoneAgentKitVersion.current` 是供日志、诊断和兼容检查使用的运行时镜像，不会替代或自动创建 Tag；每次发布必须同步更新源码常量、README、CHANGELOG 与 Tag。当前预发布版本为 `0.2.0-alpha.10`。

从 `0.2.0-alpha.5` 升级时，使用方的 `BoneLlamaRuntime` 实现必须适配新的真实 Token 容量契约：增加 `tokenize(prompt:)`，并将旧 `generate(prompt:options:)` 改为 `generate(prompt:executionPlan:options:)`。Runtime 必须按 `executionPlan.prefillRanges` 对完整 Prompt 的 Token IDs 分批 prefill；完整迁移要求见 [LocalModels.md](LocalModels.md#从-alpha5-迁移到-alpha6)。只使用云 Provider 或未链接 `BoneAgentLlama` 的调用方不受该协议变更影响。

当前预发布开发线提供完整的本地 Constraint Runtime 闭环。Alpha.9 已删除 `promptEncoder` / `toolCalling` 旧初始化入口；调用方必须使用 `conversationRenderer` + `toolEnvelope`。Native Template Runtime 必须通过 `nativeTemplateCapabilities()` 声明 reasoning mode 与 add-generation-prompt 支持。Stop-only 可继续实现 `BoneLlamaControlledGenerationRuntime`；请求级 Constraint 和受约束 Tool Envelope 必须实现 `BoneLlamaConstraintGenerationRuntime`，并把 SDK 的 compiled artifact 接入实际 Grammar Sampler。用于高级 Smoke 身份时还应实现 `BoneLlamaRuntimeVerificationIdentifying`。未实现对应协议时必须失败关闭，不会静默降级。

同一开发线也为官方 OpenAI、Gemini 和 Anthropic 增加请求级原生 Output Constraint seam。调用方只设置 `BoneInferenceRequest.outputConstraint`，不得同时设置 structured `responseFormat` 或非空 Tools。Engine 只有在精确模型的 `.providerSmoke` Profile 包含与当前 Provider、Endpoint 摘要、API、Mapper/Decoder、Constraint 方言和调用模式完全匹配的 `BoneProviderCapabilityVerificationIdentity` 时才启用；Bundled Catalog 当前没有此类真实 Smoke 身份，因此默认不会自动授权。普通云调用方无需接入 Llama Renderer、Tokenizer 或 Runtime 身份。

## 依赖方向

```text
UI ───────────────→ Business Service
Agent Adapter ────→ Business Service
Package ✕────────→ App Business Service
```

Package 不引用 Host 数据库、UI 框架、凭据存储或业务 Service。Provider Catalog JSON 与渠道图片是 Package 静态资源；用户密钥、自定义 Provider 和运行结果不进入 Resources。

正确的可退出性是：删除 Adapter 后，业务 Service 不受影响。如果删除 Adapter 会迫使数据库或业务领域重写，说明 Host 逻辑已经泄漏进 Package，必须先移回项目层。

## 接入门禁

1. 固定已审核版本，不跟随不稳定分支自动更新；
2. 在干净环境验证网络解析、构建和资源加载；
3. 保持公共 API baseline 和兼容策略；
4. 测试不得依赖任一 Host 的业务类型或本地目录；
5. 对新增第三方代码、资源、模型或 Binary 执行许可、来源和安全审计。
