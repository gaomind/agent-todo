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

    func show(capture: CodexCapture, captureTest: CaptureSelfTest,
              connection: CodexConnection, liveProbe: CodexLiveProbe) {
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
                    capture: capture, captureTest: captureTest,
                    connection: connection, liveProbe: liveProbe, selection: selection
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
    let captureTest: CaptureSelfTest
    @ObservedObject var connection: CodexConnection
    @ObservedObject var liveProbe: CodexLiveProbe
    @ObservedObject var selection: SettingsSelection
    @StateObject private var claudeConnection = ClaudeConnection()
    @StateObject private var grokConnection = GrokConnection()
    @StateObject private var geminiConnection = GeminiConnection()
    @State private var showsCaptureTest = false

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
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 14) {
            settingRow("来源") {
                ViewThatFits(in: .horizontal) {
                    providerPicker
                        .pickerStyle(.segmented)
                        .fixedSize(horizontal: true, vertical: false)
                    providerPicker.pickerStyle(.menu)
                }
                .labelsHidden()
            }
            settingRow("最近收件") {
                if let lastReceivedAt = capture.lastReceivedAt(for: selection.provider) {
                    Text(lastReceivedAt, format: .dateTime.year().month().day().hour().minute().second())
                        .foregroundStyle(.secondary)
                } else {
                    Text("本次启动后尚未收到此来源的普通对话回复。")
                        .foregroundStyle(.secondary)
                }
            }
            settingRow("\(hookName) Hook") {
                connectionControls
                    .disabled(liveProbe.activeProvider == selection.provider)
            }
            if capture.statusMessage.hasPrefix("回复队列读取失败") {
                settingRow("回复队列") {
                    Text(capture.statusMessage).foregroundStyle(.red)
                }
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            settingRow("真实连接验证") {
                liveTestControls
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            DisclosureGroup("本地模拟采集", isExpanded: $showsCaptureTest) {
                CaptureTestControls(test: captureTest)
                    .padding(.top, 7)
            }
        }
        .frame(maxWidth: 500)
    }

    private var providerPicker: some View {
        Picker("来源", selection: $selection.provider) {
            ForEach([HoldProvider.codex, .claude, .grok, .gemini], id: \.self) { source in
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
        case .gemini:
            GeminiConnectionControls(connection: geminiConnection)
        case .unknown:
            EmptyView()
        }
    }

    private var hookName: String {
        selection.provider == .gemini ? "AfterAgent" : "Stop"
    }

    private var cliURL: URL? {
        switch selection.provider {
        case .codex: connection.cliURL
        case .claude: claudeConnection.cliURL
        case .grok: grokConnection.cliURL
        case .gemini: geminiConnection.cliURL
        case .unknown: nil
        }
    }

    private var probeConfiguration: URL? {
        switch selection.provider {
        case .codex, .unknown: nil
        case .claude: claudeConnection.probeConfiguration
        case .grok: grokConnection.probeConfiguration
        case .gemini: geminiConnection.probeConfiguration
        }
    }

    private var setupInstructions: String {
        switch selection.provider {
        case .codex:
            "请先在本页配置并检查 Codex，按提示确认信任 Stop Hook。"
        case .claude:
            "请先在本页检查 Claude Code 配置，按提示启用 Stop Hook。"
        case .grok:
            "请先在本页检查 Grok 配置，按提示启用 Grok 采集。"
        case .gemini:
            "请先在本页检查 Gemini CLI 配置，按提示启用 Gemini CLI 采集或手动合并 AfterAgent Hook 后重新检查。"
        case .unknown:
            "请先选择一个来源。"
        }
    }

    private var liveTestControls: some View {
        let provider = selection.provider
        let state = liveProbe.state(for: provider)
        return VStack(alignment: .leading, spacing: 7) {
            Text(provider == .grok
                 ? "点击发送后，使用当前 Grok 登录发送一条测试消息。Grok 可能额外调用模型生成会话标题，额度以 Grok CLI 记录为准。"
                 : "点击发送后，使用当前 \(provider.name) 登录发送一条测试消息，可能消耗模型额度。")
                .foregroundStyle(.secondary)

            switch state {
            case .idle:
                EmptyView()
            case .running:
                HStack {
                    ProgressView().controlSize(.small)
                    Text("等待本次测试的 \(hookName) Hook 回执…")
                }
            case .passed:
                Text("验证通过。已收到本次测试的 \(hookName) Hook 回执。")
            case .failed(let message):
                Text("验证失败。\(message)").foregroundStyle(.red).textSelection(.enabled)
            case .cancelled:
                Text("已取消验证。").foregroundStyle(.secondary)
            }

            if liveProbe.activeProvider == provider {
                Button("取消验证") { liveProbe.cancel() }
            } else {
                if cliURL == nil {
                    Text(setupInstructions).foregroundStyle(.secondary)
                }
                if let active = liveProbe.activeProvider {
                    Text("\(active.name) 正在验证，完成后可发送新的测试消息。")
                        .foregroundStyle(.secondary)
                    Button("查看 \(active.name) 验证") { selection.provider = active }
                }
                Button(sendTitle(for: state)) {
                    guard let cliURL else { return }
                    liveProbe.start(provider: provider, cli: cliURL, configuration: probeConfiguration)
                }
                .disabled(cliURL == nil || liveProbe.activeProvider != nil)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func sendTitle(for state: CodexLiveProbe.State) -> String {
        if case .failed = state { return "重试发送一条测试消息" }
        return "发送一条测试消息"
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

    private func settingRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        GridRow(alignment: .top) {
            Text(label)
                .fontWeight(.medium)
                .fixedSize()
                .gridColumnAlignment(.trailing)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct CaptureTestControls: View {
    @ObservedObject var test: CaptureSelfTest

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("用模拟回复检查 Agent Todo 的本地采集流程，无需调用模型。")
                .foregroundStyle(.secondary)
            feedback
                .accessibilityElement(children: .combine)
            switch test.state {
            case .running:
                Button("取消测试") { test.cancel() }
            case .cancelling:
                ProgressView().controlSize(.small)
            default:
                Button("运行模拟采集") { test.start() }
            }
        }
    }

    @ViewBuilder
    private var feedback: some View {
        switch test.state {
        case .idle:
            EmptyView()
        case .running:
            Text("正在测试 Hook、识别和保存…").foregroundStyle(.secondary)
        case .cancelling:
            Text("正在清理测试数据…").foregroundStyle(.secondary)
        case .passed(let condition):
            Text("本地测试通过 · \(condition)")
                .textSelection(.enabled)
        case .failed(let message):
            Text("本地测试失败。\(message)")
                .foregroundStyle(.red)
                .help(message)
        case .cancelled:
            Text("已取消本地测试。").foregroundStyle(.secondary)
        }
    }
}
