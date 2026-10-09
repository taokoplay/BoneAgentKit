# models.dev 双入口与 BoneAgentKit 核对记录

核对日期：2026-10-09，Asia/Shanghai；最终交叉核对截至 14:32。

用户要求：对照 `https://models.dev/api.json` 与 `https://github.com/anomalyco/models.dev`，并记住供今后核对更新使用。本记录保存项目证据；用户协作偏好另存 DutyDeck 工作区 memory，不重复维护 AGENTS.md。

## 1. 结论

**GitHub 与发布 API 本次语义一致。** GitHub 是 models.dev API 的源数据库，两者不是独立的模型能力证据。对照时先展开源数据继承、渠道覆盖与省略规则，再比较发布结果。

| 检查范围 | GitHub 展开结果 | 在线接口 | 比较结果 |
|---|---:|---:|---|
| 提供商 | 225 | 225 | 所有提供商字段一致 |
| 默认渠道—模型记录 | 8,467 | 8,467 | 全部记录逐字段一致，新增/缺失/字段差异均 0 |
| 全类型渠道—模型记录 | 8,480 | 8,480 | 与 `api.json?type=all` 一致 |
| 提供商无关模型元数据 | 451 | 451 | 与 `models.json?type=all` 一致 |

这里“一致”指 JSON 结构和值一致，不要求键顺序或序列化字节一致。本轮没有执行上游仓库脚本、依赖安装或完整 Zod 校验；使用 Python 标准库 TOML 解析，按实际读过的 TypeScript 生成器规则重现数据变换并比较。模型调用能力、部署端点与供应商可用性未做线上实测。

## 2. 固定版本与快照

- 仓库：<https://github.com/anomalyco/models.dev>
- 分支：本次读取 `dev`。
- 固定提交：`c849cd11adf999db2203b20d3ab1fa8e58852e63`。
- 提交时间：`2026-10-09T05:32:36Z`（北京时间 13:32:36）。
- 提交内容：`chore(sync): update OpenRouter model catalog (#9209)`。
- 默认 API：<https://models.dev/api.json>。
- 默认 API 本轮及上一轮快照 SHA-256 均为：`9d0280a6a7399f7bb123046217979890fcab2e18d5f0f681b6cf4ad819ea116c`。
- 本地项目 HEAD：`05bcd952ac17155e570f002cda45d9a544819522`。
- 本地目录基线：`Sources/BoneAgentKit/Resources/AIProviderDefaults.json`，schemaVersion=1、原 catalogVersion=7、原 verifiedAt=2026-08-28；本轮实施后 catalogVersion=8，顶层 verifiedAt=2026-10-09，未核验的逐模型官方日期保持原值。

日期、条目数、分支 HEAD 和模型状态都会变化；今后必须重新抓取，不能沿用本记录的数值当作实时信息。

## 3. 数据入口与转换规则

### 数据职责

- `models/<lab>/<model>.toml`：模型本身的元数据，包括能力默认值、模态、token 默认限制、日期、许可证、权重和 benchmarks。
- `providers/<provider>/provider.toml`：提供商名称、API 地址、SDK 类型与凭据环境变量名称等。
- `providers/<provider>/models/**/*.toml`：渠道的模型 ID、价格、思考选项、interleaved、状态及渠道覆盖。
- `api.json`：按提供商展开的发布结果。
- `models.json`：提供商无关模型元数据，不能替代具体渠道限制。
- `catalog.json`：同时包含 models 与 providers 的发布入口；本轮读过发布规则，没有额外下载该组合接口。

### 本次按源码确认的规则

1. 模型 ID 来自相对于 models 目录的文件路径，可包含 `/`；不能只取 basename。
2. `base_model` 指向 `models/` 的 lab/model 元数据；渠道覆盖优先。
3. 普通对象递归合并，数组和标量替换；随后应用 `base_model_omit` 点路径删除，并清理空父对象。
4. `id`、`benchmarks`、`license`、`links`、`weights` 不作为基础模型字段继承到渠道记录。
5. 使用 `base_model` 的渠道输出增加 `canonical_model_id`，不能用名字猜测原厂归属。
6. effort 值的 TOML 字符串 `"null"` 转成 JSON `null`。
7. 成本 tier 的 type 默认 `context`。当且仅当一个 context tier 且阈值 ≥200000，生成遗留 `context_over_200k`。该兼容字段名称不代表真实阈值一定是 200000，精确阈值以 `cost.tiers[].tier.size` 为准。
8. 默认接口排除 `type=decision`，未标记 type 的记录按 chat 处理；`type=all` 不过滤。当前 13 条被默认过滤，之前把 8467 称作“全量”仅适用于默认接口响应，不适用于所有类型。
9. 模型目录有符号链接。本轮安全解析了 138 个有效 TOML 链接，并记录 33 个指向不存在源文件的链接，均位于 `siliconflow-cn`。不凭空补造目标，也不把失效链接算作可用记录；对应 API 未收录，最终可解析数据与 API 一致。未运行上游生成器，不能据此断言其遇失效链接时一定成功或失败。

### 核对过的固定源码

- [生成器 generate.ts](https://github.com/anomalyco/models.dev/blob/c849cd11adf999db2203b20d3ab1fa8e58852e63/packages/core/src/generate.ts)
- [类型 schema.ts](https://github.com/anomalyco/models.dev/blob/c849cd11adf999db2203b20d3ab1fa8e58852e63/packages/core/src/schema.ts)
- [过滤 filter.ts](https://github.com/anomalyco/models.dev/blob/c849cd11adf999db2203b20d3ab1fa8e58852e63/packages/core/src/filter.ts)
- [构建 build.ts](https://github.com/anomalyco/models.dev/blob/c849cd11adf999db2203b20d3ab1fa8e58852e63/packages/web/script/build.ts)
- [发布路由 worker.ts](https://github.com/anomalyco/models.dev/blob/c849cd11adf999db2203b20d3ab1fa8e58852e63/packages/function/src/worker.ts)
- `packages/web/src/render.tsx`：通过 generateCatalog 导出 Models/Providers。

## 4. 对项目上一轮结论的影响

两份上游完全一致，因此不是 GitHub 与 API 发布偏差造成项目差异。

- 项目 21 个渠道条目、44 条直接模型声明，MiMoTokenPlan 继承后共 49 条。
- 按渠道、地区、套餐和精确 ID 匹配：33 条匹配，16 条在对应上游渠道未收录。GitHub 的匹配情况与 API 完全相同。
- 13 条 token 数值差异、6 条弃用状态差异仍成立。
- 匹配的 31 条 chat 记录均 `tool_call=true`，未发现这批记录工具开关直接冲突；细粒度能力元数据尚未填入内置模型 profile。
- `reasoning`、`reasoning_options`、`interleaved` 缺完整目录映射；思考文本展示不等于生成策略，读取思考不等于能在工具多轮中回传。
- 项目通用生成参数仅有 temperature 与 maximumOutputTokens；明确服务端思考控制仅 Agnes 已核验开启路径。不能说所有服务端默认思考都不可用。
- OpenAI/Anthropic 的 thinking continuation 有范围限制；Gemini 已有 thoughtSignature 的有界多轮续接。
- models.dev 的 `temperature` 是是否支持温度控制，项目 temperature 是具体数值，不能机械映射。
- `structured_output=true` 不等于 SDK 的 verified constrainedOutput；保持验证身份边界。
- tokenLimits 缺项、价格/模态/日期/模型身份元数据缺项，以及弃用状态差异需要按供应商具体协议进一步验证。

### 数值差异摘要

| 渠道 / 模型 | 字段 | 本地 | 两份上游 |
|---|---|---:|---:|
| DeepSeek V4 Pro、Flash | 最大输出 | 384000 | 393216 |
| Kimi K2.6 | 上下文 | 256000 | 262144 |
| 智谱 GLM-5.2、5.1 | 最大输出 | 128000 | 131072 |
| Qwen3 Coder Plus | 上下文 | 1000000 | 1048576 |
| MiMo V2.5 Pro、V2 Pro、V2.5 | 上下文 | 1000000 | 1048576 |
| MiMo V2 Omni | 上下文 | 256000 | 262144 |
| MiMo Token Plan 的 V2.5 Pro、V2 Pro、V2.5 | 上下文 | 1000000 | 1048576 |

弃用差异：OpenAI/gpt-image-1、DeepSeek/deepseek-v4-flash、MiMo/mimo-v2-pro、MiMo/mimo-v2-omni、MiMo/mimo-v2-flash、MiMoTokenPlan/mimo-v2-pro。本地 deprecated=false，上游 status=deprecated；没有实测这些服务已下线。

## 5. 今后核对更新的方法

1. 固定本地 Git 状态、目录版本及核验日期；先保留用户改动。
2. 同期获取默认 API、必要时的 `type=all`、GitHub 当前默认分支提交 SHA；记录抓取日期、哈希和公开 URL。
3. 先读当前 schema/generator/filter，确认规则没有变化，不直接套用旧版脚本。
4. 按 `provider + modelID + 地区/套餐 + 实际协议入口` 做显式映射。canonical_model_id 只解释来源，不能覆盖渠道差异。
5. 展开继承、覆盖、omit、类型过滤与成本规范化后，比 GitHub 与 API 的新增、缺失、字段和值；差异存在时调查发布时间/缓存/源版本，不选择“看起来较新”的一份静默覆盖。
6. 再对照项目的思考、工具、结构化输出、温度支持、附件/输入输出模态、token 限制、状态和价格，并检查 SDK 实际编码/解码/续接能力。
7. 区分三类：数据值不一致、项目字段尚未表达、实现不支持；未知不等于 false，未收录不等于不可用。
8. 涉及实质配置更新，依据官方模型文档和实际渠道契约复核，不将第三方目录伪标为 official、providerSmoke 或已验证执行能力。不盲改 API 域名、不迁移凭据、不因目录 true 放行高级能力。
9. 输出变更建议、受影响调用方、回归测试和尚未验收边界。只有用户授权执行更新时才修改模型配置；核对或记忆授权不包含自动变更。

## 6. 证据位置与执行边界

原始快照和辅助脚本留在会话工作台，不向项目提交整个第三方仓库：

`/Users/xutaoyu/.proma/agent-workspaces/boneagentkit/8939ec6e-0bde-4bef-be8c-865365a6d7e0/models-dev-audit/`

- `api.json`：上一轮默认 API。
- `comparison.json`、`compare.py`、`report.md`：项目与默认 API 的逐条对照。
- `tests.log`：上一轮 29 项合成测试通过的记录；这些测试不验证线上能力或目录实时性。
- `github/commit.json`、`source.tar.gz`：固定提交元数据和源归档。
- `github/api-current.json`、`api-all.json`、`models-all.json`：本轮接口快照。
- `github/compare_source.py`：不运行上游代码的只读转换/对比脚本。
- `github/comparison-source-api.json`：全部范围的差异结果及 49 条项目关联记录。
- `github/symlink-audit.json`：有效/失效链接证据。

本轮实施后更新：目录 `catalogVersion` 已从 7 升为 8，并将 models.dev 的 33 条精确渠道—模型声明纳入 `BoneModelMetadata`；这些声明仍标记为 `modelsDev`，不授予运行能力。只对有官方渠道证据的限制/状态做本地更新：DeepSeek V4 `1048576/393216`、Kimi K2.6 `262144` 上下文、GLM-5.2/5.1 `131072` API 输出、MiMo V2 Omni `262144` 上下文、OpenAI `gpt-image-1` 与 DeepSeek Flash 旧 ID 的 deprecated 标记；Qwen Coder Plus、MiMo Token Plan 与未证实 MiMo 状态保留本地值。

SDK 已增加模型元数据、显式 reasoning options/profile、OpenAI/Anthropic/Gemini 固定 wire 映射及 fail-closed 预检；OpenAI `reasoning_content`、Anthropic thinking/redacted thinking 完整块的有界 opaque continuation 已接入非流式、缓冲 SSE、事件入口和上下文重绑定。Anthropic 流式工具参数统一 canonical JSON；停止块后 delta、结构化输出冲突等边界均在本地测试中拒绝。新增测试与接入文档，未调用真实付费模型、未提交 Git、未推送代码。
