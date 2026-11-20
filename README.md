# Agent Todo

Agent Todo 是一个 macOS 菜单栏应用。它从 CLI 助手的回复中识别等待事项和恢复条件，例如“恢复条件：等审批通过后继续”，并把条件和来源回复保存在本机。条件满足后，可以把待办复制回 CLI，接着处理原来的工作。

## 安装

1. 从 [GitHub Releases](https://github.com/gaomind/agent-todo/releases) 下载 `agent-todo-0.0.2-macOS-Finder.zip`，在 Finder 里双击解压，解出的 DMG 会显示 Agent Todo 图标。也可以直接下载 `agent-todo-0.0.2-macOS.dmg`，其文件使用系统磁盘映像图标，打开后挂载的卷会显示 Agent Todo 图标。需要 macOS 13 或更新版本，支持 Apple 芯片与 Intel Mac。
2. 打开 DMG，把「Agent Todo」拖到「应用程序」，再从那里启动。
3. 应用使用临时签名（ad hoc），未经 Apple 公证。如果 macOS 拦截首次启动，确认 DMG 来自本仓库的 Release 后，可在「系统设置」→「隐私与安全性」中选择「仍要打开」。

## 从 v0.0.1 升级

1. 退出旧版，安装并打开 `Agent Todo.app`。旧版待办、来源回复和待处理的回复队列会从原有的本机目录继续加载。
2. 在「设置…」→「连接与测试」依次检查之前启用的来源。Codex CLI 和 Claude Code 可按界面提示更新 Hook 路径，Codex 还需要确认信任新命令。
3. 如果 Grok CLI 提示 Hook 路径不匹配，先确认 `~/.grok/hooks/agent-hold.json`（设置了 `GROK_HOME` 时为 `$GROK_HOME/hooks/agent-hold.json`）由旧版生成，再将该文件移出 `hooks` 目录并通过设置重新启用 Grok 采集。
4. 重新打开各来源的 CLI 会话，确认后续回复可以进入 Agent Todo，再移除旧版应用。

## 允许读取回复并验证连接

右键或按住 Control 点击菜单栏的清单图标，选择「设置…」→「连接与测试」，再选择 Codex、Claude Code、Grok 或 Antigravity CLI。

1. 在「允许读取回复」下检查设置。如果还没允许，按提示确认。Codex 首次使用时需点击「配置 Codex」，并确认信任界面上显示的命令。设置完成后，请按界面提示重新打开已有会话。
2. 如要确认连接，点击对应的发送按钮，例如「向 Antigravity CLI 发送测试消息」。应用会用该 CLI 的当前登录发一条消息，可能消耗模型额度。Grok 可能另外调用模型生成会话标题。Agent Todo 收到本次测试回复后会显示验证通过。

页面会显示所选来源最近一次对话回复的接收时间。

### Google Antigravity CLI

用 Google 的官方命令安装 Antigravity CLI 后，在终端运行 `agy` 并按提示登录。

```sh
curl -fsSL https://antigravity.google/cli/install.sh | bash
```

回到 Agent Todo 检查设置，确认允许读取回复，再重新打开 Antigravity CLI 会话。Agent Todo 会将 `agent-todo` 条目加入 Google 产品共享的 `~/.gemini/config/hooks.json`，保留其他条目，采集仅限 Antigravity CLI 回复。

已有 Gemini CLI 待办仍可查看和续接。

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

应用、DMG 和保留 DMG 自定义图标的 Finder ZIP 默认写入 `dist/`。
