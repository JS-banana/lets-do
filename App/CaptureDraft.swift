import Foundation
import SwiftUI

/// The main sheet and quick window edit one recoverable capture draft.
@MainActor
final class CaptureDraft: ObservableObject {
    @Published var content = TaskWriting() { didSet { persist() } }
    @Published var plan = ScheduleForm() { didSet { if !restoring { explicitDate = true }; persist() } }
    @Published private(set) var status = ""
    @Published var mainWindowID: UUID?
    private(set) var id = UUID()
    private weak var store: TaskStore?
    private var path: String?
    private var restoring = false
    private var explicitDate = false
    private var pendingSchedule: TaskSchedule?

    func begin(schedule: TaskSchedule = .none) {
        guard store != nil else { pendingSchedule = schedule; return }
        if !content.hasText && !explicitDate {
            plan = ScheduleForm(schedule: schedule)
            explicitDate = false
        }
    }

    func attach(to store: TaskStore, tasks: [TaskSnapshot]) {
        self.store = store
        if path != store.directory.path {
            restoring = true
            mainWindowID = nil
            path = store.directory.path
            content = TaskWriting(); plan = ScheduleForm(); id = UUID(); status = ""; explicitDate = false
            do {
                for draft in try store.drafts().filter({ $0.kind == .capture }) {
                    if tasks.contains(where: { $0.id == draft.taskID }) { try store.removeDraft(id: draft.id) }
                    else {
                        id = draft.id
                        content = TaskWriting(title: draft.title, body: draft.body, formatting: draft.formatting)
                        plan = ScheduleForm(schedule: draft.captureSchedule ?? .none)
                        explicitDate = draft.captureSchedule != nil
                        status = "已恢复上次的输入草稿"
                        break
                    }
                }
            } catch { status = "草稿恢复失败，原文件保留：\(error.localizedDescription)" }
            restoring = false
        }
        if let schedule = pendingSchedule { pendingSchedule = nil; begin(schedule: schedule) }
    }

    func detach() {
        TaskWritingEditor.finishEditing()
        persist()
        store = nil
    }

    func persist() {
        guard !restoring, let store else { return }
        do {
            if !content.hasText { try store.removeDraft(id: id); status = "" }
            else {
                try store.saveDraft(LocalDraft(formatVersion: 1, id: id, taskID: id, kind: .capture,
                    title: content.title, body: content.body, parentIDs: [], updatedAt: Date(),
                    captureSchedule: plan.schedule, formatting: content.formatting))
                status = "草稿已保存在此设备"
            }
        } catch { status = "草稿未能保存：\(error.localizedDescription)" }
    }

    func save(using model: PrototypeModel) -> Bool {
        TaskWritingEditor.finishEditing()
        let savedID = id
        guard model.create(title: content.title, id: savedID, schedule: plan.schedule,
                           body: content.body, formatting: content.formatting) else { return false }
        var cleanupMessage = ""
        do { try store?.removeDraft(id: savedID) }
        catch { cleanupMessage = "任务已保存；草稿清理失败，重启会按 UUID 核对。" }
        restoring = true
        content = TaskWriting(); plan = ScheduleForm(); id = UUID(); status = cleanupMessage; explicitDate = false
        restoring = false
        return true
    }
}
