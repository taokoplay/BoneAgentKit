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

真实 Smoke 会产生外部请求和潜在费用，必须由签发负责人在隔离环境明确授权，并使用低权限、低额度凭据。Runner 仅接受严格参数集合；`--live`、`--confirm-network-and-costs`、Provider、精确模型、次数和调用模式均须显式提供，不能与 `--dry-run` 混用。

```bash
swift run BoneAgentLiveProviderSmoke --live --confirm-network-and-costs \
  --provider openai --model '<exact-model-id>' --iterations 100 \
  --invocation non-streaming
```

输出不得包含 Prompt、响应、Header、完整 URL 或凭据。发布前需分别验证 OpenAI、Anthropic、Gemini 的非流式和流式请求。脱敏报告保存 provider、精确 model、稳定执行身份、调用模式、次数、固定失败分类、聚合耗时和 UTC 日期；签发流程在报告外绑定被审核的提交 SHA。真实报告仍只是候选证据，经审核并达到阈值后才能更新 bundled Profile。
