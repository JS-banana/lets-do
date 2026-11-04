import AppIntents
import Foundation
import WidgetKit

struct SetTaskCompletedIntent: AppIntent {
    static var title: LocalizedStringResource { "设置任务完成状态" }
    static var description: IntentDescription { "更新任务的完成状态，并刷新小组件。" }

    @Parameter(title: "任务 UUID") var taskID: String
    @Parameter(title: "目标完成状态") var completed: Bool
    @Parameter(title: "存储会话") var namespace: String

    init() { taskID = ""; completed = true; namespace = "" }
    init(taskID: UUID, completed: Bool, namespace: String) {
        self.taskID = taskID.uuidString; self.completed = completed; self.namespace = namespace
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        do {
            guard let id = UUID(uuidString: taskID) else { throw PrototypeError.invalid("无效的任务 UUID。") }
            let session = try await StoreSession.forExtension()
            guard !namespace.isEmpty, session.namespace == namespace else {
                throw PrototypeError.unavailable("任务库已变化，请刷新小组件后重试。")
            }
            let store = try TaskStore(directory: session.directory(), isExtension: true, session: session)
            defer { try? store.close() }
            let actionID = try store.setCompleted(id: id, completed: completed)
            store.record("intent.complete", id: id, actionID: actionID,
                         outcome: session.cloudEnabled ? "local-committed-open-app-to-sync" : "desktop-local-committed")
            WidgetCenter.shared.reloadAllTimelines()
            return .result(dialog: IntentDialog(stringLiteral: session.cloudEnabled
                ? "已保存在此设备。打开 Let’s Do 后与 iCloud 交换。" : "已保存在这台设备。"))
        } catch {
            WidgetCenter.shared.reloadAllTimelines()
            return .result(dialog: IntentDialog(stringLiteral: "未完成：\(error.localizedDescription)"))
        }
    }
}
