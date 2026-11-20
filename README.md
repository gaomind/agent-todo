# Agent 待办

Agent 待办是一个 macOS 菜单栏应用。它从 CLI 助手的回复中识别等待事项和恢复条件，例如“恢复条件：等审批通过后继续”，并把条件和来源回复保存在本机。条件满足后，可以把待办复制回 CLI，接着处理原来的工作。

## 安装

1. 从 [GitHub Releases](https://github.com/gaomind/agent-hold/releases) 下载 `AgentHold-0.0.1-macOS.dmg`。需要 macOS 13 或更新版本，支持 Apple 芯片与 Intel Mac。
2. 打开 DMG，把「Agent 待办」拖到「应用程序」，再从那里启动。
3. 首发版本采用临时签名（ad hoc），未经 Apple 公证。如果 macOS 拦截首次启动，确认 DMG 来自本仓库的 Release 后，可在「系统设置」→「隐私与安全性」中选择「仍要打开」。

## 启用采集

在菜单栏右键或按住 Control 点击清单图标，选择「设置…」→「连接」。在「来源」中选择已安装的 CLI，按界面提示检查配置并确认启用。Codex 需要确认信任界面显示的 Hook 命令。

| CLI | 采集 Hook |
| --- | --- |
| Codex CLI | `Stop` |
| Claude Code | `Stop` |
| Grok CLI | `Stop` |
| Gemini CLI | `AfterAgent` |

可以在「设置…」→「测试」运行「测试采集」，用模拟回复验证本地采集。

## 查看和恢复待办

左键点击菜单栏图标即可查看等待、完成或忽略的事项。每项都有来源 CLI 标记。展开后可查看会话信息和完整的当前恢复条件，也可以编辑条件。条件与原始摘录不同时，展开区会同时显示摘录。

用「复制续接命令」在终端重新打开原会话。确认恢复条件已满足后，可以把「复制待办」得到的内容粘贴到会话中继续，其中包含来源 CLI、会话信息、恢复条件和本机保存的来源回复或摘录。

待办、来源回复和待处理的回复队列保存在本机的 `~/Library/Application Support/AgentHold/`。备份或恢复时，先退出应用，再复制或还原整个目录。

## 从源码构建

在 macOS 上安装支持 Swift 6 的 Xcode 或 Command Line Tools，然后在仓库根目录运行。

```sh
swift test
scripts/build-app.sh
scripts/build-dmg.sh
```

应用和 DMG 默认写入 `dist/`。
