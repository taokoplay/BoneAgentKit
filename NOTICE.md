# BoneAgentKit Notice

## 生产代码

当前 BoneAgentKit 生产源码是本仓库内的 clean-room 实现。当前 Package 未声明或链接第三方 Swift Package、C/C++ binary target 或模型权重。

## Provider 渠道图片

`BoneAgentKit` Product 内置 42 个 Provider 渠道 PNG，用于在配置和选择界面识别渠道；图片由内部资源 Target 管理。Catalog 中的 `iconID` 是这些资源的稳定语义标识。

这些渠道图片不表示相应商标权利人赞助、认可或官方背书本项目，也不得被解释为独立的品牌资产授权。BoneAgentKit 当前为私有 Package；任何对外公开分发前仍须逐项复核图片来源、许可与商标使用要求。

## 许可与待决事项

BoneAgentKit 当前依据仓库根目录的 proprietary `LICENSE` 私有维护。仓库可见性或访问权限不构成开源授权，也不自动授予复制、修改或再分发权利。

- 对外开源或改变许可前，必须由仓库所有者重新审核并明确批准。
- 后续引入第三方实质代码、资产、binary target 或模型权重时，必须在本文件追加真实版权、许可证和来源信息。
