import AppKit
import SwiftUI

struct AntigravityConnectionControls: View {
    @ObservedObject var connection: AntigravityConnection

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            switch connection.phase {
            case .idle:
                Text("首次使用，请在终端运行 agy 并按提示登录。")
                    .foregroundStyle(.secondary)
                Button("检查 Antigravity CLI 设置") { connection.check() }
                DisclosureGroup("查看官方安装命令") { installation }
            case .missingCLI:
                Text("找不到 agy。请在终端运行官方安装命令，再运行 agy 登录。")
                installation
                Button("重新检查设置") { connection.check() }
            case .needsApproval(let configuration):
                Text("确认后，Agent Todo 会在 Google 产品共享的 Hook 文件中加入自己的条目，只读取 Antigravity CLI 的新回复。")
                DisclosureGroup("查看将写入的配置") {
                    ConnectionReviewDetails(file: configuration.file.path, command: configuration.command)
                }
                HStack {
                    Button("允许读取回复") { connection.approve() }
                    Button("取消") { connection.reset() }
                }
            case .ready:
                Text("已允许读取回复。请重新打开 Antigravity CLI 会话。")
                    .foregroundStyle(.secondary)
                Button("重新检查设置") { connection.check() }
            case .failed(let message):
                Text("未能完成 Antigravity CLI 的设置。")
                    .foregroundStyle(.red)
                ConnectionErrorDetails(message: message)
                Button("重新检查设置") { connection.check() }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var installation: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(AntigravityHookConfiguration.installCommand)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
            Button("复制安装命令") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(AntigravityHookConfiguration.installCommand, forType: .string)
            }
        }
    }
}
