# BoneAgentKit 公开文档排版设计

## 目标

将 README 从内部技术备忘录重构为清晰的开源 Swift SDK 门面，同时用独立文档索引承载完整资料。读者应能在首屏识别用途、平台、许可和 Product，并在五分钟内完成基础接入。

## 信息架构

README 顺序固定为：

1. 居中标题、简短定位和静态徽标；
2. 四个公开 Product 的职责表；
3. HTTPS + 精确版本安装；
4. 最小依赖与导入示例；
5. 核心能力和执行链；
6. App Host 与 Kit 边界；
7. 分类文档导航；
8. 验证命令、明确限制和许可。

完整资料进入 `Documentation/INDEX.md`，按“开始使用、核心概念、运行与治理、本地模型、维护者资料”分类。历史迁移、基线和实施计划只出现在维护者资料，不占据新调用方的主要阅读路径。

## 视觉与排版

- 使用 GitHub 支持的居中 HTML 标题和 shields.io 静态徽标，不依赖脚本或动态统计。
- 表格只用于 Product 与文档地图等结构化信息，避免把长段落塞入单元格。
- 每个二级标题只回答一个问题；代码块均声明语言。
- 首屏避免长段历史和迁移叙述；迁移背景下沉到专门文档。
- 中文为主，保留 Swift、Agent Runtime、Product、Host 等必要领域术语。

## 正确性与安全

- 安装示例使用 `https://github.com/taokoplay/BoneAgentKit.git` 和当前推荐 `0.2.0-alpha.3`。
- 明确 Product 数量为四个，并说明 `BoneAgentLlama` 不包含 llama.cpp Binary。
- 不出现任一调用项目名称、Host 专有业务实现或本机绝对路径。
- Provider PNG 与第三方商标的许可例外保持醒目但不打断首屏主路径。

## 验证

扩展公开文档门禁，检查：

- 禁止词和绝对路径；
- README 必须含四个 Product、HTTPS 安装地址、推荐版本和许可链接；
- 所有跟踪 Markdown 的相对链接目标存在；
- 每个 Markdown 只有一个一级标题，标题层级不跳级；
- Swift 6 strict 测试和 `git diff --check` 继续通过。
