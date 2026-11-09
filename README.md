# ContextWeave

本地优先的 macOS 应用，帮助不同 AI Agent 接续项目工作。应用使用 SwiftUI，业务核心独立为 Swift 模块。

## 开发

需要 macOS 13 或更高版本及 Swift 6 工具链。推荐安装完整 Xcode，以获得 XCTest 和完整的开发调试工具。

```sh
./scripts/swift-local.sh build
./scripts/swift-local.sh test
./scripts/swift-local.sh run ContextWeave
```

生成本机调试用应用包并打开：

```sh
./scripts/build-app.sh
open dist/ContextWeave.app
```

该应用包未签名或公证，供本机开发使用；正式分发需要配置签名、公证和应用标识。当前骨架包含欢迎界面、独立核心模块与会话模型，采集、存储、MCP 和后台服务尚未实现。详见 [架构说明](docs/architecture.md)。

本机部分 Command Line Tools 安装可能残留旧版 Swift Package 接口；`swift-local.sh` 会在检测到该问题时使用项目内的临时副本，不修改系统文件。XCTest 需要可用的 Xcode 测试框架。

## 参与贡献

参见 [贡献指南](CONTRIBUTING.md)。项目使用 [MIT 许可证](LICENSE)。
