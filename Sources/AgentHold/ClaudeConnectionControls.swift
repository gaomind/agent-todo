import SwiftUI

struct ClaudeConnectionControls: View {
    @ObservedObject var connection: ClaudeConnection

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            switch connection.phase {
            case .idle:
                Text("启用 Stop Hook 后，Agent Todo 会在 Claude Code 回复结束时读取回复并识别待办。")
                    .foregroundStyle(.secondary)
                Button("检查 Claude Code 配置") { connection.prepare() }
            case .needsApproval(let review):
                Text("确认后会向 Claude Code 的用户配置加入这条 Stop Hook。")
                VStack(alignment: .leading, spacing: 7) {
                    detail("配置文件", review.configuration.path)
                    detail("完整命令", review.command)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 5))
                HStack {
                    Button("启用 Stop Hook") { connection.approve() }
                    Button("取消") { connection.reset() }
                }
            case .ready(let configuration):
                Text("已配置 Claude Code Stop Hook。请在已信任的工作区开启新会话，确认后续回复可以进入 Agent Todo。")
                    .foregroundStyle(.secondary)
                detail("配置文件", configuration.path)
                Button("重新检查配置") { connection.prepare() }
            case .failed(let message):
                Text(message).foregroundStyle(.red)
                Button("重新检查配置") { connection.prepare() }
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
