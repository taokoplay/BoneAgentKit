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
- [ ] ParsingBook Debug / Release Simulator 构建通过。
- [ ] 公开 API baseline 无意外删除。
- [ ] ParsingBook compatibility、角色提取、任务和持久化专项通过。
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

- [x] 当前私有预发布采用仓库根目录的 proprietary `LICENSE`；任何开源许可切换必须另行批准。
- [ ] `NOTICE.md` 中所有第三方实质代码和资产条目已核实。
- [ ] Runtime 不内置第三方 Provider 品牌图标；Host 自行负责所用素材的来源、权利状态和商标用途。
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
