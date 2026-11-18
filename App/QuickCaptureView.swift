#if os(macOS)
import Carbon.HIToolbox
import SwiftUI

struct QuickCaptureView: View {
    @ObservedObject var model: PrototypeModel
    @ObservedObject private var draft: CaptureDraft
    @Environment(\.dismissWindow) private var dismissWindow

    init(model: PrototypeModel) {
        self.model = model
        draft = model.capture
    }

    var body: some View {
        CaptureSheet(content: $draft.content, plan: $draft.plan, draftStatus: draft.status, loaded: model.loaded,
                     cancel: { dismissWindow(id: "capture") }, save: {
            if draft.save(using: model) { dismissWindow(id: "capture") }
        })
        .onAppear { draft.mainWindowID = nil }
        .task { if !model.loaded { await model.start() } }
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

/// A system-wide shortcut that opens the quick capture window from any app while
/// Let’s Do is running. Carbon hot keys need no Accessibility permission.
@MainActor
final class GlobalCaptureHotKey: ObservableObject {
    static let shared = GlobalCaptureHotKey()
    static let enabledKey = "GlobalCaptureHotKeyEnabled"
    static let shortcut = "⌃⌥N"

    @Published private(set) var failure: String?
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var action: (() -> Void)?

    var isEnabled: Bool { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }

    func install(_ action: @escaping () -> Void) {
        self.action = action
        update()
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        update()
    }

    private func update() {
        guard isEnabled, action != nil else {
            if let hotKey { UnregisterEventHotKey(hotKey) }
            hotKey = nil
            failure = nil
            return
        }
        guard hotKey == nil else { return }
        if handler == nil {
            var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                Task { @MainActor in GlobalCaptureHotKey.shared.action?() }
                return noErr
            }, 1, &event, nil, &handler)
        }
        let id = EventHotKeyID(signature: OSType(0x4C44_4F51), id: 1) // "LDOQ"
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_N), UInt32(controlKey | optionKey), id,
                                         GetApplicationEventTarget(), 0, &hotKey)
        if status != noErr { hotKey = nil }
        failure = status == noErr ? nil : "\(Self.shortcut) 已被其他应用占用，暂时无法使用。"
    }
}
#endif
