import SwiftUI

@main
struct TodoApp: App {
    @StateObject private var model = PrototypeModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup("Let’s Do", id: "main") {
            PrototypeView(model: model)
                .task { if !model.loaded { await model.start() } }
                #if os(macOS)
                .frame(minWidth: 680, minHeight: 560)
                .handlesExternalEvents(preferring: ["\(AppDestination.scheme)://task", "\(AppDestination.scheme)://calendar", "\(AppDestination.scheme)://open"],
                                      allowing: ["\(AppDestination.scheme)://task", "\(AppDestination.scheme)://calendar", "\(AppDestination.scheme)://open"])
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 1160, height: 800)
        .handlesExternalEvents(matching: ["\(AppDestination.scheme)://task", "\(AppDestination.scheme)://calendar", "\(AppDestination.scheme)://open"])
        .commands { TaskCommands() }
        #endif
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && model.loaded {
                Task { await model.checkAccountAndStorage() }
            }
        }
        #if os(macOS)
        WindowGroup("添加任务", id: "capture", for: String.self) { _ in
            QuickCaptureView(model: model)
        } defaultValue: { "capture" }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commandsRemoved()
        .handlesExternalEvents(matching: ["\(AppDestination.scheme)://capture"])
        #endif
    }
}

#if os(macOS)
private struct NewTaskActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var newTask: (() -> Void)? {
        get { self[NewTaskActionKey.self] }
        set { self[NewTaskActionKey.self] = newValue }
    }
}

private struct TaskCommands: Commands {
    @FocusedValue(\.newTask) private var newTask
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新建任务") { newTask?() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(newTask == nil)
            Button("新建窗口") { openWindow(id: "main") }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }
    }
}
#endif
