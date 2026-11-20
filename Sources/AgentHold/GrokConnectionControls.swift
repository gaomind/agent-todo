import SwiftUI

struct GrokConnectionControls: View {
    @ObservedObject var connection: GrokConnection

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            switch connection.phase {
            case .idle:
                Text("连接后，Agent Todo 会从 Grok 的新回复里找出待办。")
                    .foregroundStyle(.secondary)
                Button("检查 Grok 设置") { connection.check() }
            case .checking:
                HStack {
                    ProgressView().controlSize(.small)
                    Text("正在检查 Grok 的设置…")
                    Spacer()
                    Button("取消") { connection.cancel() }
                }
            case .needsInstallation(let configuration):
                Text("尚未允许读取回复。确认后会更新 Grok 的设置，Agent Todo 就能从新回复中识别待办。")
                DisclosureGroup("查看将写入的配置") {
                    ConnectionReviewDetails(file: configuration.file.path, command: configuration.command)
                }
                HStack {
                    Button("允许读取回复") { connection.install(configuration) }
                    Button("取消") { connection.cancel() }
                }
            case .ready:
                Text("已允许读取回复。已有的 Grok 会话请重新打开。")
                    .foregroundStyle(.secondary)
                Button("重新检查设置") { connection.check() }
            case .failed(let message):
                Text("未能完成 Grok 的设置。请查看原因后重新检查。")
                    .foregroundStyle(.red)
                ConnectionErrorDetails(message: message)
                Button("重新检查设置") { connection.check() }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
