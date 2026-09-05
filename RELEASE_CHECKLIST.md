# BoneAgentKit 发布检查清单

## 签发信息

- 签发负责人：发布前必须填写姓名或团队角色。
- 验证提交 SHA：发布前填写。
- Xcode / Swift 版本：当前最低 Swift 5.9；签发环境版本必须归档。
- 发布版本与 tag：发布前填写。

## 版本列车

1. `0.x-hardening`：只关闭正确性、并发、安全和分发阻断，不拆 Module，不切换默认行为。
2. `0.x-modularization`：只调整 Package target 和兼容转发，不启用新上下文或本地 Runtime 默认行为。
3. `1.0.0`：前两列车验证完成后才建立稳定 API 承诺。

行为切换、Package 拆分和本地 Runtime 不得混入同一个发布提交。

## 必须通过的技术门禁

- [ ] SwiftPM 默认测试全部通过。
- [ ] Swift 6 strict concurrency 与 warnings-as-errors 全部通过。
- [ ] 至少一个真实 Host 的 Debug / Release 构建通过。
- [ ] 公开 API baseline 无意外删除。
- [ ] Host compatibility、核心业务 Adapter、任务和持久化专项通过。
- [ ] `git diff --check` 通过且没有未审查生成物。

## Provider Smoke

- [ ] dry-run 验证 OpenAI、Anthropic、Gemini 配置可构造且不发网。
- [ ] 签发环境使用独立低权限凭据完成最小非流式与流式请求。
- [ ] Smoke 输出只含 provider、model、status、latency，不含 Prompt、响应、Header 或密钥。
- [ ] 真实请求可能产生费用，只有签发负责人明确批准后执行。

## 隐私与安全

- [ ] 日志与产物中无 API key、Authorization、书籍正文、角色正文和 Tool Result 正文。
- [ ] 自定义 endpoint 通过安全策略检查。
- [ ] Provider/model/origin 改变后旧授权不会被复用。
- [ ] checkpoint 只保存允许的数据分类或 Host opaque reference。

## 许可证和资源

- [x] 自 `0.2.0-alpha.2` 起，源码和文档采用 `AGPL-3.0-only`；更早 tag 保持签发时的 proprietary 许可。
- [ ] `NOTICE.md` 中所有第三方实质代码和资产条目已核实。
- [ ] `BoneAgentKit` 内部资源 Target 的 42 个渠道 PNG 与 14 个 `iconID`、三档 scale 一致。
- [ ] Provider PNG 与第三方商标不属于 AGPL 授权范围；公开或再分发前逐项核实来源、权利状态和商标用途。
- [ ] 发布页面和 Package 元数据不得将 Provider PNG 错误表述为 AGPL 资产。
- [ ] 不声称任何 Provider 官方背书。

## 迁移

- [ ] `import BoneAgentKit` 与 `BoneAgentTesting` 兼容 fixture 通过。
- [ ] CHANGELOG 包含用户可见变化、弃用和迁移说明。
- [ ] 旧 checkpoint 的读取、重启或人工决策语义有明确说明。

## 回滚

1. 停止签发或撤回未发布 tag，不重写已经公开的 tag。
2. 回滚到最后一个完整通过发布门禁的提交。
3. 保持旧 checkpoint decoder 与兼容 Product；禁止用数据迁移掩盖代码回滚。
4. 真实 Provider 故障时关闭对应灰度入口，不删除用户任务或持久化记录。
5. 保存失败门禁名称、脱敏日志、提交 SHA 和处置结论。

## 本地硬化验证快照（2026-09-05）

本快照对应 `9e247440` 后尚未提交的第三、四阶段工作树，不是发布签发。Xcode 26.0 / Swift 6.2；未运行最低 Swift 5.9 工具链。

- 默认、完整严格并发与显式 Swift 6 严格模式均为 349 项测试通过。
- macOS Release 严格构建与三 Provider 无网络 dry-run 通过。
- 四个库 Product 的 iOS Simulator Release SDK 构建通过，保持 iOS 13 deployment 声明；不是 iOS 13 真机执行证据。
- README 版本与 `BoneAgentKitVersion.current` 一致性、公开文档与 diff 门禁通过。
- GitHub Actions 配置已建立，未推送、未远端运行，不能当作已绿的远端 CI。

签发前仍必须补：真实 Host Debug/Release、真实 Store lease expiry/事务/跨进程恢复、真机 Runtime/内存/取消、授权后的 Provider 非流式与流式测试、最低工具链、许可证和资产权利核验，以及最终已提交 SHA。以上未完成前不宣称生产验收或发布准入通过。
