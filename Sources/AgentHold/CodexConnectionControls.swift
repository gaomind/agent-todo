import SwiftUI

struct CodexConnectionControls: View {
    @ObservedObject var connection: CodexConnection
    @ObservedObject var probe: CodexLiveProbe

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            switch connection.phase {
            case .idle:
                Text("首次配置会将 Stop Hook 写入本机 Codex 配置，再核对信任状态。")
                    .foregroundStyle(.secondary)
                Button("配置并检查 Codex") { connection.prepare() }
            case .checking:
                HStack {
                    ProgressView().controlSize(.small)
                    Text("正在检查 Codex 与 Hook 信任状态…")
                    Spacer()
                    Button("取消") { connection.reset() }
                }
            case .needsApproval(let review):
                Text("请核对下列 Stop Hook。信任后，使用此默认配置的 Codex 会话可在回复结束时运行该命令。")
                VStack(alignment: .leading, spacing: 7) {
                    detail("配置文件", review.sourcePath)
                    detail("核对信任的工作目录", review.workingDirectory)
                    detail("完整命令", review.command)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 5))
                HStack {
                    Button("信任此命令") { connection.approve() }
                    Button("取消") { connection.reset() }
                }
            case .ready:
                Text("已确认 Agent 待办 Stop Hook 的信任状态。")
                    .foregroundStyle(.secondary)
                Text("首次启用前已打开的会话可能仍沿用旧配置。请新建会话，或让承载该会话的 Codex 后台重新加载配置。采集从后续回复开始。")
                    .foregroundStyle(.secondary)
                Button("重新检查配置") { connection.prepare() }
                    .disabled(probe.isRunning)
            case .failed(let message):
                Text(message).foregroundStyle(.red)
                Text("重试时若缺少 Stop Hook，会先写入本机 Codex 配置，再核对信任状态。")
                    .foregroundStyle(.secondary)
                Button("重试配置并检查") { connection.prepare() }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func detail(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).foregroundStyle(.secondary)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

}

struct CodexLiveTestControls: View {
    @ObservedObject var connection: CodexConnection
    @ObservedObject var probe: CodexLiveProbe
    let showConnection: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("使用当前 Codex 登录发送一条测试消息，消耗一次模型额度。")
                .foregroundStyle(.secondary)

            switch probe.state {
            case .running:
                HStack {
                    ProgressView().controlSize(.small)
                    Text("等待本次测试消息的 Stop 回复…")
                }
                Button("取消验证") { probe.cancel() }
            case .passed:
                Text("真实连接验证通过。已收到验证会话的 Stop 回复。")
                sendControls
            case .failed(let message):
                Text("真实连接验证失败。\(message)").foregroundStyle(.red)
                sendControls
            case .cancelled:
                Text("已取消验证。")
                sendControls
            case .idle:
                sendControls
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var sendControls: some View {
        if case .ready(let cli) = connection.phase {
            Button("发送一条测试消息") { probe.start(cli: cli) }
        } else {
            Text("请先在「连接」中确认 Codex Stop Hook 的信任状态。")
                .foregroundStyle(.secondary)
            Button("前往 Codex 连接", action: showConnection)
        }
    }
}

private extension CodexLiveProbe {
    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }
}
