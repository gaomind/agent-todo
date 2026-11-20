import SwiftUI

struct GeminiConnectionControls: View {
    @ObservedObject var connection: GeminiConnection

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            switch connection.phase {
            case .idle:
                Text("检查 Gemini CLI 用户设置中的 AfterAgent Hook。")
                    .foregroundStyle(.secondary)
                Button("检查 Gemini CLI 配置") { connection.check() }
            case .needsApproval(let configuration):
                Text("启用后，Gemini CLI 会在每轮回复结束时运行以下命令。")
                VStack(alignment: .leading, spacing: 7) {
                    detail("配置文件", configuration.file.path)
                    detail("完整命令", configuration.command)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 5))
                HStack {
                    Button("启用 Gemini CLI 采集") { connection.approve() }
                    Button("取消") { connection.reset() }
                }
            case .ready:
                Text("已配置 Gemini CLI 的 AfterAgent Hook。请重新打开会话，并在受信任且启用了 Hook 的工作区运行。")
                    .foregroundStyle(.secondary)
                Button("重新检查配置") { connection.check() }
            case .manual(let configuration):
                Text("设置含注释或有语法错误。请检查语法，再将下方的 AfterAgent 条目合并到现有 hooks。")
                detail("配置文件", configuration.file.path)
                detail("Hook 配置", configuration.snippet)
                Button("重新检查配置") { connection.check() }
            case .failed(let message):
                Text(message).foregroundStyle(.red).textSelection(.enabled)
                Button("重新检查配置") { connection.check() }
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
