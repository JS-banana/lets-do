#if os(macOS)
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
#endif
