# ContextWeave 架构方向

ContextWeave 是以 macOS 为首要平台的本地优先应用，使用 SwiftUI 构建界面，使用独立的 Swift 核心承载业务逻辑。

## 当前结构

- `Sources/ContextWeaveApp`：SwiftUI 应用入口与欢迎界面。
- `Sources/ContextWeaveCore`：独立业务模块，目前包含会话数据类型。
- `Tests/ContextWeaveCoreTests`：核心行为测试。
- `scripts/build-app.sh`：生成本机调试用应用包。

## 后续设计原则

- 采集适配器只读来源，输出统一会话；来源游标与数据可靠提交。
- 原始资料、标准化消息和可重建的摘要与索引分层保存。
- 项目使用稳定标识，工作区路径与项目的关系显式管理。
- 记忆记录来源和确认状态，项目范围贯穿所有检索路径。
- 后台任务持久化并可重试；派生产物关联输入版本。
- 时间统一采用 UTC Unix 毫秒；外部模型调用由用户配置。
- 界面与 MCP 通过清晰的应用服务边界共享业务能力；后台生命周期和 macOS 文件权限需要在真实环境验证后确定。

首个业务闭环：实现 Codex 与 Claude Code 采集、SQLite 存储和项目范围搜索；随后实现 MCP 上下文交接和进度写回。优先验证重复采集、异常恢复、范围隔离和证据追溯。以上为目标，并非当前已实现功能。
