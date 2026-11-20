import SwiftUI

struct CodexConnectionControls: View {
    @ObservedObject var connection: CodexConnection

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
                Text("已确认 Agent Todo Stop Hook 的信任状态。")
                    .foregroundStyle(.secondary)
                Text("首次启用前已打开的会话可能仍沿用旧配置。请新建会话，或让承载该会话的 Codex 后台重新加载配置。采集从后续回复开始。")
                    .foregroundStyle(.secondary)
                Button("重新检查配置") { connection.prepare() }
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
