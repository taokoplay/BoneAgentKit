# ResourceReadingDemo

一个独立的 macOS 命令行 Demo，使用本仓库的公开 `BoneAgentKit` API 演示：

**大文本预览 → 长任务上下文压缩 → 按固定版本引用回读 → 独立结果验收。**

无需 API Key，运行期间不联网、不产生模型费用。Agent、工具执行、分页、预算、压缩与校验器都是真实 SDK 实现；模型和摘要决策是确定性替身，用实际工具返回值计算结果。它验证执行机制，不验证真实模型的自主规划能力。

## 运行一次 Demo

环境：macOS 13+，Swift 5.9+；自动验收另需 Python 3 和 Bash。依赖仅为仓库根目录的本地 SDK，没有外部包下载。

从仓库根目录执行：

```bash
swift run --package-path Examples/ResourceReadingDemo ResourceReadingDemo
```

默认场景是 `compressed`。程序在内存中建立超过 1 MiB 的合成文本，真实数值只位于末尾的 `VALUES` 行。初次工具仅返回64字节预览；中间交互触发压缩后，再用摘要保留的引用读取末尾512字节，计算并验证 `[17,23,60]` 的合计为100。

输出包括真实执行步骤、原文/预览/读取字节数、业务推理和摘要次数、实际答案、任务结局和行为验收。Token 减少量是 SDK 估算，不是厂商 Usage 或实际费用。

## 切换场景和输入

```bash
# 不压缩，直接通过预览中的引用回读
swift run --package-path Examples/ResourceReadingDemo ResourceReadingDemo --scenario preview

# 换一组源数据；预期合计5，排除只会输出默认答案的演示
swift run --package-path Examples/ResourceReadingDemo ResourceReadingDemo --values '3,4,-2'

# 故意让模型算错，独立验收必须拒绝；此命令预期退出码2
swift run --package-path Examples/ResourceReadingDemo ResourceReadingDemo --scenario wrong-answer

# 跑全部场景并显示执行步骤
swift run --package-path Examples/ResourceReadingDemo ResourceReadingDemo --self-test
```

`--values` 接受1～32个逗号分隔的整数，每个在 -100000～100000 之间。模型替身只从资源回读结果解析数值，不读取传给验收器的预期答案。

| 场景 | 任务预期结果 | 行为验收检查 |
| --- | --- | --- |
| `preview` | accepted | 预览后回读，正确交付，无摘要请求 |
| `compressed` | accepted | 旧预览被移除，引用从摘要恢复，回读后正确交付 |
| `expired` | blocked | 预览签发后资源过期，回读不交付正文 |
| `denied` | blocked | 回读时资源级权限拒绝，不能用旧预览绕过 |
| `wrong-answer` | rejected | Agent 已结束但答案不正确，最终验收拒绝 |
| `lost-reference` | blocked | 摘要丢失引用，无法回读时明确失败 |

`--self-test` 的通过表示六个场景符合预期，**其中只有两个场景交付成功**；不能把被拒绝或阻止的任务计作成功交付，更不能换算为真实模型成功率。

## 一键自动验收

```bash
bash Scripts/check-resource-demo.sh
```

脚本会构建并实际运行 Demo，使用独立 Python 程序核对报告，验证：

1. 六个场景的任务状态、实际答案、推理/回读/摘要次数。
2. 更换输入后的结果，合法与非法参数。
3. 单场景退出码：错误答案为2、读取被阻止为3、参数错误为64。
4. JSON 报告实际写入后重新读取，并且再次写入同一路径会失败、原报告保持不变。
5. 保持 `allChecksPassed=true`、只篡改答案时，独立验收器仍必须拒绝。

默认报告保存在 session scratch 或系统临时目录的唯一子目录，脚本会打印完整位置。也可以指定报告父目录：

```bash
bash Scripts/check-resource-demo.sh /path/to/demo-reports
```

构建缓存默认位于 Demo 的 `.build`；可通过 `BONE_DEMO_BUILD_DIR` 指定外部构建目录。脚本可在 CI 中直接执行，任何未达到预期的结果都会返回非零退出码。无需重跑整个 SDK 测试套件即可检查 Demo；完整 SDK 测试仍见 [Testing](../../Documentation/Testing.md)。

## JSON 与退出码

```bash
# 只向 stdout 输出 JSON，编译日志留在 stderr
swift run --package-path Examples/ResourceReadingDemo ResourceReadingDemo --self-test --json

# 保存报告到显式指定的新文件；不会覆盖已有文件
swift run --package-path Examples/ResourceReadingDemo ResourceReadingDemo --report /path/to/new-report.json

# 单独核对一份六场景报告
python3 Scripts/verify-resource-demo.py /path/to/suite.json

# 核对单场景及自定义输入
python3 Scripts/verify-resource-demo.py /path/to/report.json --single compressed --values '3,4,-2'
```

JSON 固定包含 `schemaVersion=1`、`modelMode=offline-deterministic` 和 `liveProvider=false`，以及各场景观察值。单场景结果位于 `scenarios` 数组中；`actualTotal` 等不存在的结果不补造。`checks`/`allChecksPassed` 只是内置检查，自动验收器会重新核对结果与调用计数。

| 退出码 | 含义 |
| --- | --- |
| 0 | 单场景交付成功，或全部场景的预期行为验收通过 |
| 1 | 运行、检查或报告写入出现非预期失败 |
| 2 | 单场景最终答案被验收拒绝 |
| 3 | 单场景读取或引用被阻止 |
| 64 | 命令行参数错误 |

## 文件与扩展位置

- `Sources/ResourceReadingDemo/DemoMain.swift`：命令行、步骤显示、JSON报告与退出码。
- `DemoScenario.swift`：真实 Agent 装配、预算、压缩、结果验收与行为检查。
- `DemoRuntime.swift`：合成资源、只读工具、请求驱动模型和摘要替身。
- [自动验收脚本](../../Scripts/check-resource-demo.sh) 与 [独立报告验收器](../../Scripts/verify-resource-demo.py)。

需要接入真实模型时，应另行提供 Provider、精确模型、费用上限和真实任务提示词，并保留独立结果验收；当前 Demo 没有隐藏的联网开关，不读取凭据。合成资源、权限策略和数据模型都只位于 Examples 包，不进入 SDK，也不修改任何接入方仓库。

## 本次验证记录

2026-11-06，在 Apple Swift 6.4 上完成默认语言模式的严格并发/warnings-as-errors 构建、一键自动验收，以及显式 Swift 6 严格构建和六场景报告核对；全部通过。自定义输入 `[3,4,-2]` 得到合计5，篡改答案且保留成功标记的报告被独立验收器拒绝。最低 Swift 5.9 工具链和真实模型未实测。
