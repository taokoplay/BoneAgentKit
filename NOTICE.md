# BoneAgentKit Notice

## 生产代码

当前 BoneAgentKit 生产源码是本仓库内的 clean-room 实现。当前 Package 未声明或链接第三方 Swift Package、C/C++ binary target 或模型权重。

## Provider 品牌素材

BoneAgentKit Runtime 不内置第三方 Provider 品牌图标。Catalog 中的 `iconID` 只是供 Host 映射自有或经授权素材的稳定语义标识，不表示相应商标权利人赞助、认可或官方背书本项目。

ParsingBook 现有图标已经迁回 Host 工程，不属于 BoneAgentKit 独立 Package 的分发内容；其来源、许可和商标使用仍应由 ParsingBook 单独审计。

## 待决事项

- 仓库所有者尚未在本分支明确选择 BoneAgentKit 根许可证；不得由实现者代为推断。
- 后续引入第三方实质代码、资产、binary target 或模型权重时，必须在本文件追加真实版权、许可证和来源信息。
