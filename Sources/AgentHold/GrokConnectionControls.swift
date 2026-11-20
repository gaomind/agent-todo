import SwiftUI

struct GrokConnectionControls: View {
    @ObservedObject var connection: GrokConnection

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            switch connection.phase {
            case .idle:
                Text("检查 Grok Build CLI 的个人 Stop Hook 设置。")
                    .foregroundStyle(.secondary)
                Button("检查 Grok 配置") { connection.check() }
            case .checking:
                HStack {
                    ProgressView().controlSize(.small)
                    Text("正在检查 Grok 配置…")
                    Spacer()
                    Button("取消") { connection.cancel() }
                }
            case .needsInstallation(let configuration):
                Text("启用后，使用此 Grok 配置的会话会在每轮回复结束时运行下面的命令。")
                VStack(alignment: .leading, spacing: 7) {
                    detail("配置文件", configuration.file.path)
                    detail("完整命令", configuration.command)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 5))
                HStack {
                    Button("启用 Grok 采集") { connection.install(configuration) }
                    Button("取消") { connection.cancel() }
                }
            case .ready:
                Text("Grok 已识别 Agent 待办的 Stop Hook。请重新打开现有 Grok 会话以加载配置。")
                    .foregroundStyle(.secondary)
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
