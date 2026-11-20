import AppKit
import Combine
import SwiftUI

@main
@MainActor
struct AgentHoldApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AgentHoldDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AgentHoldDelegate: NSObject, NSApplicationDelegate {
    private let store = HoldStore()
    private let captureTest = CaptureSelfTest()
    private let connection = CodexConnection()
    private let liveProbe = CodexLiveProbe()
    private let settings = SettingsWindowController()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var waitingCount: AnyCancellable?
    private var quitting = false

    private lazy var capture: CodexCapture = {
        let store = self.store
        return CodexCapture(consumeProbe: liveProbe.accept) { reply, conditions in
            store.ingest(reply, conditions: conditions)
        }
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        if let button = item.button {
            let image = NSImage(systemSymbolName: "checklist", accessibilityDescription: nil)
            image?.isTemplate = true
            button.image = image
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            waitingCount = store.$items
                .map { $0.filter { $0.status == .waiting }.count }
                .removeDuplicates()
                .sink { [weak button] count in
                    button?.setAccessibilityLabel("Agent 待办（\(count) 项等待）")
                }
        }
        popover.behavior = .transient
        capture.start()
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp
            || (event?.type == .leftMouseUp && event?.modifierFlags.contains(.control) == true) {
            showContextMenu(at: sender)
        } else if popover.isShown {
            popover.performClose(nil)
        } else {
            openPanel()
        }
    }

    private func showContextMenu(at button: NSStatusBarButton) {
        popover.performClose(nil)
        let menu = NSMenu()
        for (title, action, shortcut) in [
            ("打开待办", #selector(openPanel), ""),
            ("设置…", #selector(openSettings), ","),
            ("退出 Agent 待办", #selector(quit), "q"),
        ] {
            if action == #selector(quit) { menu.addItem(.separator()) }
            menu.addItem(withTitle: title, action: action, keyEquivalent: shortcut).target = self
        }
        let bottom = button.isFlipped ? button.bounds.maxY : button.bounds.minY
        menu.popUp(positioning: nil, at: NSPoint(x: button.bounds.minX, y: bottom), in: button)
    }

    @objc private func openPanel() {
        guard let button = statusItem?.button, !popover.isShown else { return }
        if popover.contentViewController == nil {
            let host = NSHostingController(rootView: HoldMenu(
                store: store,
                onSettings: { [weak self] in self?.openSettings() },
                onQuit: { [weak self] in self?.quit() },
                onScreenHeight: { [weak self] in self?.sizePanel(for: $0) }
            ))
            host.sizingOptions = []
            popover.contentViewController = host
        }
        sizePanel(for: button.window?.screen?.visibleFrame.height)
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func sizePanel(for visibleHeight: CGFloat?) {
        let height = visibleHeight.map { min(356, max(136, $0 - 32)) } ?? 356
        let size = NSSize(width: 400, height: height)
        if popover.contentSize != size { popover.contentSize = size }
    }

    @objc private func openSettings() {
        popover.performClose(nil)
        settings.show(capture: capture, captureTest: captureTest,
                      connection: connection, liveProbe: liveProbe)
    }

    @objc private func quit() {
        guard !quitting else { return }
        quitting = true
        popover.performClose(nil)
        Task {
            async let connectionCleanup: Void = connection.resetAndWait()
            async let localCleanup: Void = captureTest.cancelAndWait()
            async let liveCleanup: Void = liveProbe.cancelAndWait()
            _ = await (connectionCleanup, localCleanup, liveCleanup)
            NSApp.terminate(nil)
        }
    }
}

private struct HoldMenu: View {
    let store: HoldStore
    let onSettings: () -> Void
    let onQuit: () -> Void
    let onScreenHeight: (CGFloat) -> Void
    @State private var selectedStatus = HoldStatus.waiting

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HoldItemsPage(store: store, selectedStatus: $selectedStatus)
        }
        .background(PanelScreen(onVisibleHeight: onScreenHeight))
    }

    private var header: some View {
        HStack {
            Text("Agent 待办")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button("设置…", action: onSettings)
                .keyboardShortcut(",", modifiers: .command)
            Button("退出", action: onQuit)
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct HoldItemsPage: View {
    @ObservedObject var store: HoldStore
    @Binding var selectedStatus: HoldStatus

    var body: some View {
        let grouped = Dictionary(grouping: store.items.reversed(), by: \.status)
        let items = grouped[selectedStatus] ?? []
        VStack(spacing: 0) {
            Picker("待办状态", selection: $selectedStatus) {
                ForEach(HoldStatus.allCases) { status in
                    Text("\(status.label) \(grouped[status]?.count ?? 0)")
                        .tag(status)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.top, 9)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if let errorMessage = store.errorMessage {
                        Text(errorMessage).font(.caption).foregroundStyle(.red)
                    }
                    if let capacityMessage = store.capacityMessage {
                        Text(capacityMessage).font(.caption).foregroundStyle(.orange)
                    }
                    if items.isEmpty {
                        Text("暂无\(selectedStatus.label)事项")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 3)
                    }
                    ForEach(items) { item in
                        HoldRow(
                            item: item,
                            onStatus: { store.changeStatus(of: item.id, to: $0) },
                            onCondition: { store.changeCondition(of: item.id, to: $0) },
                            sourceContext: { store.sourceContext(for: item) },
                            onCopy: copy
                        )
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(selectedStatus)
        }
    }

    private func copy(_ text: String) -> Bool {
        let clipboard = NSPasteboard.general
        clipboard.clearContents()
        return clipboard.setString(text, forType: .string)
    }
}

struct HoldRow: View {
    let item: HoldItem
    let onStatus: (HoldStatus) -> Void
    let onCondition: (String) -> Bool
    var sourceContext: () -> (text: String, isTruncated: Bool)? = { nil }
    let onCopy: (String) -> Bool
    @State private var conditionDraft: String?
    @State private var conditionCopySucceeded: Bool?
    @State private var conditionCopyFeedbackTask: Task<Void, Never>?
    @State private var detailCopyMessage: String?

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            disclosure
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                showConditionCopyFeedback()
            } label: {
                Text(conditionCopyFeedback ?? "复制待办")
                    .foregroundStyle(conditionCopySucceeded == false ? .red : .primary)
                    .frame(minWidth: 44)
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
            .accessibilityLabel("复制待办")
            .accessibilityValue(conditionCopyFeedback ?? "")
            .help("复制恢复条件、来源回复和会话信息")
        }
        .padding(9)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 7))
        .onChange(of: item.condition) { _ in clearConditionCopyFeedback() }
        .onDisappear { clearConditionCopyFeedback() }
    }

    private var conditionCopyFeedback: String? {
        conditionCopySucceeded.map { $0 ? "已复制" : "复制失败" }
    }

    func copyCondition() -> Bool {
        onCopy(item.copyText(sourceContext: sourceContext()))
    }

    private func showConditionCopyFeedback() {
        conditionCopyFeedbackTask?.cancel()
        conditionCopySucceeded = copyCondition()
        conditionCopyFeedbackTask = Task {
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            clearConditionCopyFeedback()
        }
    }

    private func clearConditionCopyFeedback() {
        conditionCopyFeedbackTask?.cancel()
        conditionCopyFeedbackTask = nil
        conditionCopySucceeded = nil
    }

    private var disclosure: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                if let cwd = item.cwd {
                    Text(cwd)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Text("\(item.provider.name) 会话 \(item.sessionID.uuidString.lowercased())")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if let conditionDraft {
                    TextField(
                        "恢复条件",
                        text: Binding(get: { self.conditionDraft ?? "" }, set: { self.conditionDraft = $0 }),
                        axis: .vertical
                    )
                    .lineLimit(2...4)
                    HStack {
                        Button("保存条件") {
                            if onCondition(conditionDraft) {
                                self.conditionDraft = nil
                            }
                        }
                        .disabled(conditionDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("取消") { self.conditionDraft = nil }
                    }
                } else {
                    Text("当前恢复条件")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(item.condition)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Button("编辑恢复条件") { conditionDraft = item.condition }
                }
                if item.evidence != item.condition {
                    Text("原始摘录：\(item.evidence)")
                        .font(.caption)
                        .textSelection(.enabled)
                }

                HStack {
                    if item.provider != .unknown {
                        Button("复制续接命令") {
                            detailCopyMessage = onCopy(item.resumeCommand) ? "已复制续接命令" : "复制失败"
                        }
                    }
                    Button("复制恢复提示") {
                        detailCopyMessage = onCopy(item.resumeContext) ? "已复制恢复提示" : "复制失败"
                    }
                    Menu("更改状态") {
                        ForEach(HoldStatus.allCases.filter { $0 != item.status }) { status in
                            Button(status.label) { onStatus(status) }
                        }
                    }
                }
                if let detailCopyMessage {
                    Text(detailCopyMessage).font(.caption)
                }
            }
            .padding(.top, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.actionTitle)
                    .lineLimit(1)
                HStack {
                    Text(item.provider.label)
                        .fixedSize()
                    Text(item.project)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(item.detectedAt, format: .dateTime.month().day().hour().minute())
                        .fixedSize()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}
