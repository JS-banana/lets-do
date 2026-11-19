import Carbon.HIToolbox
import SwiftUI

struct QuickCaptureView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var draft: CaptureDraft
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow

    init(model: AppModel) {
        self.model = model
        draft = model.capture
    }

    var body: some View {
        CaptureSheet(content: $draft.content, plan: $draft.plan, draftStatus: draft.status, loaded: model.loaded,
                     cancel: { dismissWindow(id: "capture") }, save: {
            if draft.save(using: model) { dismissWindow(id: "capture") }
        })
        .onAppear { draft.mainWindowID = nil }
        .task {
            // A launch from the widget's quick capture opens only this window.
            GlobalCaptureHotKey.shared.install { [openWindow, model] in model.openQuickCapture(openWindow) }
            if !model.loaded { await model.start() }
        }
        .onOpenURL { url in
            guard case .capture(let schedule)? = AppDestination(url: url) else { return }
            draft.mainWindowID = nil
            draft.begin(schedule: schedule)
        }
        .onDisappear { draft.persist() }
        .alert("未能保存", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("知道了") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .handlesExternalEvents(preferring: ["\(AppDestination.scheme)://capture"], allowing: ["\(AppDestination.scheme)://capture"])
    }
}

struct CaptureSheet: View {
    @Binding var content: TaskWriting
    @Binding var plan: ScheduleForm
    let draftStatus: String
    let loaded: Bool
    let cancel: () -> Void
    let save: () -> Void
    var embedded = false
    var outsideDismiss: (() -> Bool)? = nil
    @Environment(\.colorScheme) private var colorScheme
    @State private var showingDate = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("添加任务").font(.headline)
                Spacer()
                Button { TaskWritingEditor.finishEditing(); cancel() } label: { Image(systemName: "xmark") }
                    .frame(width: 28, height: 28)
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("收起并保留草稿")
                    .accessibilityLabel("收起并保留草稿")
                    .keyboardShortcut(outsideDismiss == nil ? .cancelAction : nil)
            }.padding(.horizontal, 20).padding(.vertical, 16)
            WorkspaceScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TaskWritingEditor(content: $content, autofocus: true, editable: loaded, minimumHeight: 100,
                                      placeholder: "任务标题")
                    Divider()
                    Button { TaskWritingEditor.finishEditing(); showingDate = true } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "calendar").font(.system(size: 16)).frame(width: 24)
                            Text(AppStyle.scheduleLabel(plan.schedule)).foregroundStyle(plan.schedule == .none ? Color.secondary : .primary)
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.down").font(.system(size: 10, weight: .medium))
                        }.foregroundStyle(.secondary).frame(minHeight: 40)
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(!loaded).accessibilityIdentifier("captureDate")
                        .popover(isPresented: $showingDate) {
                            TaskDatePopover(schedule: plan.schedule, apply: {
                                plan = ScheduleForm(schedule: $0); return true
                            }, close: { showingDate = false })
                        }
                    if let error = plan.error { Text(error).font(.caption).foregroundStyle(.red) }
                    if !draftStatus.isEmpty {
                        Text(draftStatus).font(.caption).foregroundStyle(draftStatus.contains("失败") || draftStatus.contains("未能") ? Color.red : Color.secondary)
                    }
                }.padding(.horizontal, 20).padding(.bottom, 24)
            }
            Divider().padding(.horizontal, 20)
            HStack {
                Text("换行添加备注").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("添加任务", action: save).font(.body.weight(.semibold))
                    .buttonStyle(.borderedProminent).tint(AppStyle.accent)
                    .disabled(!loaded || content.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || plan.error != nil)
                    .accessibilityIdentifier("captureSave").keyboardShortcut(.return, modifiers: .command)
            }.padding(20)
        }
        .background(embedded ? Color.clear : AppStyle.canvas(colorScheme))
        .tint(AppStyle.accentText(colorScheme))
        .environment(\.locale, Locale(identifier: "zh_CN"))
        .background {
            if let outsideDismiss {
                InspectorDismissal(enabled: !showingDate, dismiss: outsideDismiss)
            }
        }
        .frame(minWidth: embedded ? 0 : 380, maxWidth: embedded ? .infinity : 420,
               minHeight: embedded ? 0 : 380, maxHeight: embedded ? .infinity : 480)
    }
}

extension AppModel {
    /// The menu and the global shortcut open capture like the widget's quick capture: unscheduled.
    func openQuickCapture(_ openWindow: OpenWindowAction) {
        capture.mainWindowID = nil
        capture.begin(schedule: .none)
        openWindow(id: "capture", value: "capture")
        NSApp.activate()
    }
}

/// A system-wide shortcut that opens the quick capture window from any app while
/// Let’s Do is running. Carbon hot keys need no Accessibility permission.
@MainActor
final class GlobalCaptureHotKey: ObservableObject {
    static let shared = GlobalCaptureHotKey()
    static let enabledKey = "GlobalCaptureHotKeyEnabled"
    static let shortcut = "⌃⌥N"

    @Published private(set) var failure: String?
    @Published private(set) var enabled = UserDefaults.standard.object(forKey: GlobalCaptureHotKey.enabledKey) as? Bool ?? true
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var action: (() -> Void)?

    func install(_ action: @escaping () -> Void) {
        self.action = action
        update()
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        self.enabled = enabled
        update()
    }

    private func update() {
        guard enabled, action != nil else {
            if let hotKey { UnregisterEventHotKey(hotKey) }
            hotKey = nil
            failure = nil
            return
        }
        guard hotKey == nil else { return }
        if handler == nil {
            var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                Task { @MainActor in GlobalCaptureHotKey.shared.action?() }
                return noErr
            }, 1, &event, nil, &handler)
            guard installed == noErr else {
                handler = nil
                failure = "无法启用 \(Self.shortcut)，请重新打开应用后再试。"
                return
            }
        }
        let id = EventHotKeyID(signature: OSType(0x4C44_4F51), id: 1) // "LDOQ"
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_N), UInt32(controlKey | optionKey), id,
                                         GetApplicationEventTarget(), 0, &hotKey)
        if status != noErr { hotKey = nil }
        failure = status == noErr ? nil : "\(Self.shortcut) 已被其他应用占用，暂时无法使用。"
    }
}
