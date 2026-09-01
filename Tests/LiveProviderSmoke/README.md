# Live Provider Smoke

## Dry-run

```bash
swift run --package-path Frameworks/BoneAgentKit BoneAgentLiveProviderSmoke --dry-run
```

该模式：

- 构造 OpenAI、Anthropic、Gemini Engine 和最小请求；
- 解析请求级能力快照；
- 使用拒绝所有发送的 Transport；
- 不读取环境变量、钥匙串或配置文件；
- 不发起网络请求；
- 只输出 provider、model、`dry-run` 状态。

## 真实联网 Smoke

当前 executable 故意不实现真实联网模式。真实 Smoke 会产生外部请求和潜在费用，必须由签发负责人在隔离环境明确授权，并使用低权限、低额度凭据。输出不得包含 Prompt、响应、Header、URL query 或凭据。

发布前需分别验证 OpenAI、Anthropic、Gemini 的最小非流式和流式请求；证据只保存 provider、model、status、latency、时间与签发提交 SHA。
