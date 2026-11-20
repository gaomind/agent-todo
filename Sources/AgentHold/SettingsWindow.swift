import AppKit
import SwiftUI

private enum SettingsPane: String, CaseIterable {
    case connection, about

    var identifier: NSToolbarItem.Identifier { .init(rawValue: rawValue) }

    var title: String {
        switch self {
        case .connection: "连接与测试"
        case .about: "关于"
        }
    }

    var symbol: String {
        switch self {
        case .connection: "link"
        case .about: "info.circle"
        }
    }
}

@MainActor
private final class SettingsSelection: ObservableObject {
    @Published var pane = SettingsPane.connection
    @Published var provider = HoldProvider.codex
}

@MainActor
final class SettingsWindowController: NSObject, NSToolbarDelegate {
    private var controller: NSWindowController?
    private let selection = SettingsSelection()

    func show(capture: CodexCapture, connection: CodexConnection, liveProbe: CodexLiveProbe) {
        if controller == nil {
            let size = NSSize(width: 580, height: 410)
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Agent Todo 设置"
            window.isReleasedWhenClosed = false

            let toolbar = NSToolbar(identifier: "AgentHold.Settings")
            toolbar.delegate = self
            toolbar.displayMode = .iconAndLabel
            window.toolbarStyle = .preference
            window.toolbar = toolbar
            toolbar.selectedItemIdentifier = selection.pane.identifier

            // Let the AppKit window size the scroll viewport.
            let host = NSHostingView(
                rootView: SettingsView(
                    capture: capture, connection: connection, liveProbe: liveProbe, selection: selection
                )
            )
            host.sizingOptions = []
            host.translatesAutoresizingMaskIntoConstraints = false
            let content = NSView(frame: NSRect(origin: .zero, size: size))
            content.addSubview(host)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                host.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                host.topAnchor.constraint(equalTo: content.topAnchor),
                host.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
            window.contentView = content
            window.contentMinSize = NSSize(width: 410, height: 220)
            window.setContentSize(size)

            let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
                ?? NSScreen.main
            if let visible = screen?.visibleFrame {
                let frame = window.frame
                window.setFrameOrigin(NSPoint(
                    x: visible.midX - frame.width / 2,
                    y: visible.midY - frame.height / 2
                ))
            } else {
                window.center()
            }
            controller = NSWindowController(window: window)
        }

        guard let window = controller?.window else { return }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace] + toolbarSelectableItemIdentifiers(toolbar) + [.flexibleSpace]
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsPane.allCases.map(\.identifier)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let pane = SettingsPane(rawValue: identifier.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = pane.title
        item.paletteLabel = pane.title
        item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
        item.target = self
        item.action = #selector(selectPane(_:))
        return item
    }

    @objc private func selectPane(_ sender: NSToolbarItem) {
        guard let pane = SettingsPane(rawValue: sender.itemIdentifier.rawValue) else { return }
        select(pane)
    }

    private func select(_ pane: SettingsPane) {
        selection.pane = pane
        controller?.window?.toolbar?.selectedItemIdentifier = pane.identifier
    }
}

private struct SettingsView: View {
    @ObservedObject var capture: CodexCapture
    @ObservedObject var connection: CodexConnection
    @ObservedObject var liveProbe: CodexLiveProbe
    @ObservedObject var selection: SettingsSelection
    @StateObject private var claudeConnection = ClaudeConnection()
    @StateObject private var grokConnection = GrokConnection()
    @StateObject private var antigravityConnection = AntigravityConnection()

    var body: some View {
        ScrollView {
            Group {
                switch selection.pane {
                case .connection: connectionPane
                case .about: aboutPane
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .id(selection.pane)
    }

    private var connectionPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Text("来源").fontWeight(.medium)
                ViewThatFits(in: .horizontal) {
                    providerPicker
                        .pickerStyle(.segmented)
                        .fixedSize(horizontal: true, vertical: false)
                    providerPicker.pickerStyle(.menu)
                }
                .labelsHidden()
            }
            Divider()
            settingsStep("1. 允许读取回复") {
                connectionControls
                    .disabled(liveProbe.activeProvider == selection.provider)
            }
            Divider()
            settingsStep("2. 验证连接") {
                liveTestControls
            }
            Divider()
            ordinaryReceipt
            if capture.statusMessage.hasPrefix("回复队列读取失败") {
                Text("暂时无法读取新回复。请检查 Agent Todo 的本地存储权限。")
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: 500, alignment: .leading)
    }

    private var ordinaryReceipt: some View {
        let provider = selection.provider
        return Group {
            if let lastReceivedAt = capture.lastReceivedAt(for: provider) {
                let date = lastReceivedAt.formatted(.dateTime.year().month().day().hour().minute().second())
                Text("最近一次收到 \(provider.name) 的对话回复：\(date)")
            } else {
                Text("本次打开 Agent Todo 后，还没收到 \(provider.name) 的对话回复。")
            }
        }
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var providerPicker: some View {
        Picker("来源", selection: $selection.provider) {
            ForEach([HoldProvider.codex, .claude, .grok, .antigravity], id: \.self) { source in
                Text(source.name).tag(source)
            }
        }
    }

    @ViewBuilder
    private var connectionControls: some View {
        switch selection.provider {
        case .codex:
            CodexConnectionControls(connection: connection)
        case .claude:
            ClaudeConnectionControls(connection: claudeConnection)
        case .grok:
            GrokConnectionControls(connection: grokConnection)
        case .antigravity:
            AntigravityConnectionControls(connection: antigravityConnection)
        case .gemini, .unknown:
            EmptyView()
        }
    }

    private var cliURL: URL? {
        switch selection.provider {
        case .codex: connection.cliURL
        case .claude: claudeConnection.cliURL
        case .grok: grokConnection.cliURL
        case .antigravity: antigravityConnection.cliURL
        case .gemini, .unknown: nil
        }
    }

    private var probeConfiguration: URL? {
        switch selection.provider {
        case .codex, .gemini, .unknown: nil
        case .claude: claudeConnection.probeConfiguration
        case .grok: grokConnection.probeConfiguration
        case .antigravity: antigravityConnection.probeConfiguration
        }
    }

    private var liveTestControls: some View {
        let provider = selection.provider
        let state = liveProbe.state(for: provider)
        return VStack(alignment: .leading, spacing: 7) {
            switch state {
            case .idle:
                EmptyView()
            case .running:
                HStack {
                    ProgressView().controlSize(.small)
                    Text("正在用 \(provider.name) 发消息并等待回复…")
                }
            case .passed:
                Text("\(provider.name) 验证通过。Agent Todo 已收到测试回复。")
            case .failed(let message):
                Text("\(provider.name) 验证失败。\(message)")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            case .cancelled:
                Text("已取消 \(provider.name) 的连接验证。").foregroundStyle(.secondary)
            }

            if liveProbe.activeProvider == provider {
                Button("取消验证") { liveProbe.cancel() }
            } else {
                if cliURL == nil {
                    Text("完成第 1 步后即可发送测试消息。")
                        .foregroundStyle(.secondary)
                } else {
                    Text("使用当前的 \(provider.name) 登录发送一条消息，可能消耗模型额度。")
                        .foregroundStyle(.secondary)
                    if provider == .grok {
                        Text("Grok 可能另外调用模型生成会话标题，额度以 Grok CLI 的记录为准。")
                            .foregroundStyle(.secondary)
                    }
                }
                if let active = liveProbe.activeProvider {
                    Text("请等 \(active.name) 的验证结束后再发送。")
                        .foregroundStyle(.secondary)
                    Button("查看 \(active.name) 的验证") { selection.provider = active }
                }
                Button(sendTitle(for: state, provider: provider)) {
                    guard let cliURL else { return }
                    liveProbe.start(provider: provider, cli: cliURL, configuration: probeConfiguration)
                }
                .disabled(cliURL == nil || liveProbe.activeProvider != nil)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func sendTitle(for state: CodexLiveProbe.State, provider: HoldProvider) -> String {
        if case .failed = state { return "重新向 \(provider.name) 发送测试消息" }
        return "向 \(provider.name) 发送测试消息"
    }

    private var aboutPane: some View {
        VStack(spacing: 9) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 80, height: 80)
                .accessibilityHidden(true)
            Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Agent Todo")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                Text("版本 \(version)").foregroundStyle(.secondary)
            }
            Text("从 CLI 助手的回复中识别待办和恢复条件。")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 16)
    }

    private func settingsStep<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }
}
