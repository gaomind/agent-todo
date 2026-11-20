import SwiftUI

struct ClaudeConnectionControls: View {
    @ObservedObject var connection: ClaudeConnection

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            switch connection.phase {
            case .idle:
                Text("连接后，Agent Todo 会从 Claude Code 的新回复里找出待办。")
                    .foregroundStyle(.secondary)
                Button("检查 Claude Code 设置") { connection.prepare() }
            case .needsApproval(let review):
                Text("尚未允许读取回复。确认后会更新 Claude Code 的设置，Agent Todo 就能从新回复中识别待办。")
                DisclosureGroup("查看将写入的配置") {
                    ConnectionReviewDetails(file: review.configuration.path, command: review.command)
                }
                HStack {
                    Button("允许读取回复") { connection.approve() }
                    Button("取消") { connection.reset() }
                }
            case .ready:
                Text("已允许读取回复。请在已信任的工作区新开一个 Claude Code 会话。")
                    .foregroundStyle(.secondary)
                Button("重新检查设置") { connection.prepare() }
            case .failed(let message):
                Text("未能完成 Claude Code 的设置。请查看原因后重新检查。")
                    .foregroundStyle(.red)
                ConnectionErrorDetails(message: message)
                Button("重新检查设置") { connection.prepare() }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
