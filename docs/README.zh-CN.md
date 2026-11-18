# ContextWeave

ContextWeave 是一款本地优先的 macOS 应用，旨在让 AI Agent 之间延续项目上下文。界面使用 SwiftUI，核心使用独立的 Swift 模块。

项目处于早期开发阶段，已支持 Codex、DeepSeek Harness、Cursor、Antigravity 与 Claude Code 的本地会话采集、SQLite 存储、会话浏览、通过 MCP 双向交接项目上下文，以及原生设置窗口（数据源、Agent 接入、采集、外观与更新）。参阅[接入与使用说明](handoff.md)。已实现模型记忆提取、摘要覆盖进度与接续补齐。自动更新默认关闭，开启后默认积累 20 条新对话消息再提取，可选择 10/20/40 条；会话可跟随或覆盖 Agent 设置。全文搜索和跨设备同步仍在规划中。界面跟随系统语言，目前支持英语和简体中文。

构建、测试及贡献方式请参阅 [English README](../README.md)。
