import SwiftUI

struct CodexConnectionControls: View {
    @ObservedObject var connection: CodexConnection

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            switch connection.phase {
            case .idle:
                Text("配置 Codex 后，Agent Todo 就能从新回复里找出待办。首次配置会修改 Codex 设置。")
                    .foregroundStyle(.secondary)
                Button("配置 Codex") { connection.prepare() }
            case .checking:
                HStack {
                    ProgressView().controlSize(.small)
                    Text("正在检查 Codex 设置…")
                    Spacer()
                    Button("取消") { connection.reset() }
                }
            case .needsApproval(let review):
                Text("尚未允许读取回复。请核对以下命令。信任后，Codex 会在回复结束时运行它，让 Agent Todo 读取回复。")
                ConnectionReviewDetails(file: review.sourcePath, command: review.command,
                                        workingDirectory: review.workingDirectory)
                HStack {
                    Button("信任此命令") { connection.approve() }
                    Button("取消") { connection.reset() }
                }
            case .ready:
                Text("已允许读取回复。已有的 Codex 会话请重新打开，或新建一个会话。")
                    .foregroundStyle(.secondary)
                Button("重新检查设置") { connection.prepare() }
            case .failed(let message):
                Text("未能完成 Codex 的设置。请查看原因后重试。")
                    .foregroundStyle(.red)
                ConnectionErrorDetails(message: message)
                Text("重试时会补写缺少的 Codex 设置。")
                    .foregroundStyle(.secondary)
                Button("重试配置 Codex") { connection.prepare() }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct ConnectionReviewDetails: View {
    let file: String
    let command: String
    var workingDirectory: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ConnectionDetail(label: "配置文件", value: file)
            if let workingDirectory {
                ConnectionDetail(label: "核对信任的工作目录", value: workingDirectory)
            }
            ConnectionDetail(label: "完整命令", value: command)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(6)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 5))
    }
}

struct ConnectionDetail: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).foregroundStyle(.secondary)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct ConnectionErrorDetails: View {
    let message: String

    var body: some View {
        DisclosureGroup("查看原因") {
            Text(message)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
    }
}
