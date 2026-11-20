import AppKit
import SwiftUI

private enum SettingsPane: String, CaseIterable {
    case connection, testing, about

    var identifier: NSToolbarItem.Identifier { .init(rawValue: rawValue) }

    var title: String {
        switch self {
        case .connection: "连接"
        case .testing: "测试"
        case .about: "关于"
        }
    }

    var symbol: String {
        switch self {
        case .connection: "link"
        case .testing: "checkmark.circle"
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
            let size = NSSize(width: 580, height: 350)
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Agent 待办设置"
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
                ) { [weak self] in
                    self?.selection.provider = .codex
                    self?.select(.connection)
                }
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
    let connection: CodexConnection
    let liveProbe: CodexLiveProbe
    @ObservedObject var selection: SettingsSelection
    let showCodexConnection: () -> Void
    @StateObject private var claudeConnection = ClaudeConnection()
    @StateObject private var grokConnection = GrokConnection()
    @StateObject private var geminiConnection = GeminiConnection()

    var body: some View {
        ScrollView {
            Group {
                switch selection.pane {
                case .connection: connectionPane
                case .testing: testingPane
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
            settingRow(selection.provider == .gemini ? "AfterAgent Hook" : "Stop Hook") {
                connectionControls
            }
            if capture.statusMessage.hasPrefix("回复队列读取失败") {
                settingRow("回复队列") {
                    Text(capture.statusMessage).foregroundStyle(.red)
                }
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
            CodexConnectionControls(connection: connection, probe: liveProbe)
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

    private var testingPane: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 16) {
            settingRow("本地采集") {
                CaptureTestControls(test: captureTest)
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            settingRow("Codex 真实连接") {
                CodexLiveTestControls(connection: connection, probe: liveProbe,
                                      showConnection: showCodexConnection)
            }
        }
        .frame(maxWidth: 500)
    }

    private var aboutPane: some View {
        VStack(spacing: 9) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 80, height: 80)
                .accessibilityHidden(true)
            Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Agent 待办")
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
            feedback
                .accessibilityElement(children: .combine)
            switch test.state {
            case .running:
                Button("取消测试") { test.cancel() }
            case .cancelling:
                ProgressView().controlSize(.small)
            default:
                Button("测试采集") { test.start() }
            }
        }
    }

    @ViewBuilder
    private var feedback: some View {
        switch test.state {
        case .idle:
            Text("使用模拟回复测试本地采集").foregroundStyle(.secondary)
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
