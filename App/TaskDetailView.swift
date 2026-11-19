import SwiftUI
import AppKit

struct TaskDetail: View {
    @ObservedObject var model: AppModel
    let task: TaskSnapshot
    var inDrawer = false
    private let editingStore: TaskStore?
    @Environment(\.colorScheme) private var colorScheme
    @State private var writing = TaskWriting()
    @State private var parents: [UUID] = []
    @State private var baselineWriting = TaskWriting()
    @State private var baselineParents: [UUID] = []
    @State private var noteDraftID = UUID()
    @State private var initialized = false
    @State private var showingSchedule = false
    @State private var showingHistory = false
    @State private var showingReminderHandoff = false
    @State private var needsDraftTitleChoice = false
    @State private var showingDraftTitleChoice = false
    @State private var draftStatus = ""
    @State private var otherDrafts: [LocalDraft] = []

    init(model: AppModel, task: TaskSnapshot, inDrawer: Bool = false) {
        self.model = model
        self.task = task
        self.inDrawer = inDrawer
        editingStore = model.store
        _writing = State(initialValue: TaskWriting(title: task.title, body: task.currentNote?.body ?? "", formatting: task.currentNote?.formatting))
        _parents = State(initialValue: task.currentNote.map { [$0.id] } ?? [])
        _baselineWriting = State(initialValue: TaskWriting(title: task.title, body: task.currentNote?.body ?? "", formatting: task.currentNote?.formatting))
        _baselineParents = State(initialValue: task.currentNote.map { [$0.id] } ?? [])
    }

    var body: some View {
        VStack(spacing: 0) {
            if inDrawer {
                HStack {
                    Spacer()
                    Button { closeDetail() } label: {
                        Image(systemName: "xmark").frame(width: 28, height: 28)
                    }.buttonStyle(.borderless).foregroundStyle(.secondary).help("收起任务详情")
                        .accessibilityLabel("收起任务详情").accessibilityIdentifier("closeTaskDetail")
                }.padding(.horizontal, 16).padding(.top, 10)
            }
            WorkspaceScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    TaskWritingEditor(content: Binding(get: { writing }, set: {
                        if needsDraftTitleChoice && TaskStore.titleChange($0.title, from: writing.title) != nil {
                            baselineWriting.title = task.title
                            needsDraftTitleChoice = false
                        }
                        writing = $0
                        persistEditorDraft()
                    }), editable: task.deletedAt == nil, minimumHeight: 64)
                    if draftStatus.contains("失败") || draftStatus.contains("未能") {
                        Text(draftStatus).font(.caption).foregroundStyle(.red)
                    }
                    Divider()
                    Button { TaskWritingEditor.finishEditing(); showingSchedule = true } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "calendar").font(.system(size: 16)).frame(width: 24)
                            Text(dateTitle).font(.body)
                                .foregroundStyle(task.schedule == .none ? Color.secondary : Color.primary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.down").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                        }.foregroundStyle(.secondary).frame(minHeight: 40)
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(task.deletedAt != nil).help("安排日期").accessibilityIdentifier("editSchedule")
                        .popover(isPresented: $showingSchedule) {
                            TaskDatePopover(schedule: task.schedule, apply: { schedule in
                                model.perform { try $0.scheduleTask(id: task.id, schedule: schedule) }
                            }, close: { showingSchedule = false })
                        }
                    if task.heads.count > 1 || !otherDrafts.isEmpty {
                        Button { TaskWritingEditor.finishEditing(); showingHistory = true } label: {
                            Label(task.heads.count > 1 ? "有 \(task.heads.count) 个正文分支" : "查看其他本机草稿", systemImage: "arrow.triangle.branch")
                        }.font(.caption).buttonStyle(.borderless)
                    }
                    if task.deletedAt != nil {
                        Text("恢复任务后可以继续编辑。").font(.caption).foregroundStyle(.secondary)
                        Button("恢复任务") { model.perform { try $0.restoreTask(id: task.id) } }.buttonStyle(.bordered)
                    }
                }.padding(.horizontal, 20).padding(.top, inDrawer ? 0 : 16).padding(.bottom, 20)
            }.accessibilityIdentifier("detail-\(task.id.uuidString)")
            Divider().padding(.horizontal, 20)
            if contentChanged && task.deletedAt == nil {
                HStack {
                    Text(draftStatus.contains("失败") || draftStatus.contains("未能") ? "修改尚未保存"
                         : needsDraftTitleChoice ? "保存时选择保留哪个标题" : "收起时自动保存")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("保存", action: saveContent)
                        .buttonStyle(.borderless).accessibilityIdentifier("contentSave")
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(writing.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.padding(.horizontal, 20).padding(.top, 12)
            }
            HStack(spacing: 12) {
                if task.deletedAt == nil {
                    Button(role: .destructive) {
                        TaskWritingEditor.finishEditing()
                        guard persistEditorDraft(), hasCurrentStore else { return }
                        if model.perform({ try $0.moveToTrash(id: task.id) }) { model.selection = nil }
                    } label: {
                        Image(systemName: "trash").frame(width: 28, height: 28)
                    }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("移入回收站")
                        .accessibilityLabel("移入回收站").accessibilityIdentifier("trashTask")
                }
                Spacer()
                Text("创建于\(task.createdAt.formatted(.dateTime.year().month().day().locale(Locale(identifier: "zh_CN"))))")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button("版本记录（\(task.revisions.count)）") {
                        TaskWritingEditor.finishEditing(); showingHistory = true
                    }.disabled(task.revisions.isEmpty && otherDrafts.isEmpty)
                    if task.deletedAt == nil {
                        Button(task.isCompleted ? "标记为未完成" : "标记为完成") {
                            TaskWritingEditor.finishEditing()
                            guard hasCurrentStore else { return }
                            model.toggleCompletion(task)
                        }.accessibilityIdentifier("detailCompletion")
                        if !task.isCompleted {
                            Button("发送到提醒事项…") {
                                TaskWritingEditor.finishEditing()
                                guard persistEditorDraft(), hasCurrentStore else { return }
                                showingReminderHandoff = true
                            }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis").foregroundStyle(.secondary).frame(width: 28, height: 28)
                }
                .menuStyle(.borderlessButton)
                .fixedSize().help("版本记录与任务操作").accessibilityLabel("版本记录与任务操作")
                    .accessibilityIdentifier("taskMore")
            }.padding(.horizontal, 20).padding(.vertical, 12)
        }
        .background(inDrawer ? Color.clear : AppStyle.canvas(colorScheme))
        .background(InspectorDismissal(enabled: model.selection == task.id && !showingSchedule && !showingHistory
                                        && !showingReminderHandoff && !showingDraftTitleChoice) { closeDetail() })
        .sheet(isPresented: $showingReminderHandoff) {
            MacReminderHandoffView(reminders: model.reminders, task: task, isCurrent: { hasCurrentStore })
        }
        .onAppear {
            guard !initialized else { return }
            do {
                let drafts = try editingStore?.drafts().filter { $0.kind == .editor && $0.taskID == task.id } ?? []
                for draft in drafts {
                    // A committed leftover must not replay its old title or text.
                    if draft.isCommitted(in: task) { try? editingStore?.removeDraft(id: draft.id); continue }
                    loadDraft(draft)
                    break
                }
            } catch { draftStatus = "草稿恢复失败，原文件保留：\(error.localizedDescription)" }
            initialized = true
        }
        .onDisappear { commitIfChanged() }
        .sheet(isPresented: $showingHistory) { versionHistory }
        .confirmationDialog("旧草稿和当前任务的标题不同", isPresented: $showingDraftTitleChoice, titleVisibility: .visible) {
            Button("保留当前任务标题") { commitContent(title: nil) }
            Button("使用草稿标题") { commitContent(title: writing.title) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("当前任务：\(task.title)\n草稿：\(writing.title)")
        }
    }

    private var versionHistory: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("版本记录").font(.headline)
                Spacer()
                Button("关闭") { showingHistory = false }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(task.revisions.sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt }) { revision in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(revision.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                            Text(revision.body).font(.callout).textSelection(.enabled)
                            Button("恢复此文字，保留旧版本") {
                                TaskWritingEditor.finishEditing()
                                writing.body = revision.body; writing.formatting = revision.formatting
                                parents = task.heads.map(\.id); noteDraftID = UUID()
                                persistEditorDraft(); showingHistory = false
                            }.font(.caption).buttonStyle(.borderless)
                        }
                        Divider()
                    }
                    ForEach(otherDrafts) { draft in
                        Button(draft.updatedAt.formatted() + " · " + String(draft.body.prefix(24))) {
                            loadDraft(draft); showingHistory = false
                            persistEditorDraft()
                        }
                    }
                }
            }
        }.padding(24)
            .frame(width: 420, height: 440)
    }

    private var contentChanged: Bool {
        writing != baselineWriting || Set(parents) != Set(baselineParents)
    }

    private var dateTitle: String {
        let label = AppStyle.scheduleLabel(task.schedule)
        guard let days = task.schedule.dayRange(in: .current),
              days.upperBound == days.lowerBound.adding(days: 1) else { return label }
        let today = Day(date: Date(), timeZone: .current)
        if days.lowerBound == today { return "今天 · \(label)" }
        if days.lowerBound == today.adding(days: 1) { return "明天 · \(label)" }
        return "\(label) · \(AppStyle.weekdayLabel(days.lowerBound))"
    }

    private func saveContent() {
        TaskWritingEditor.finishEditing()
        guard hasCurrentStore else { return }
        if needsDraftTitleChoice {
            if TaskStore.titleChange(writing.title, from: task.title) == nil { commitContent(title: nil) }
            else { showingDraftTitleChoice = true }
            return
        }
        commitContent(title: TaskStore.titleChange(writing.title, from: baselineWriting.title))
    }

    /// Leaving the editor commits one revision. A restored draft whose title needs a
    /// choice, an empty title or a trashed task stays a local draft instead.
    private func commitIfChanged() {
        // Publish text the native editor has not handed over yet (for example, marked text).
        TaskWritingEditor.finishEditing()
        guard initialized, hasCurrentStore, contentChanged, !needsDraftTitleChoice,
              !writing.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              model.tasks.first(where: { $0.id == task.id })?.deletedAt == nil else { return }
        // Another window may have committed or cleaned the shared draft; a failed commit
        // writes this editor's text back so it can be recovered on the next opening.
        if !commitContent(title: TaskStore.titleChange(writing.title, from: baselineWriting.title)) {
            persistEditorDraft()
        }
    }

    @discardableResult
    private func commitContent(title: String?) -> Bool {
        guard hasCurrentStore else { return false }
        let savedID = noteDraftID
        guard model.perform({
            try $0.updateContent(id: task.id, title: title, revisionID: savedID,
                                 body: writing.body, formatting: writing.formatting, parentIDs: parents)
        }) else { return false }
        if let saved = model.tasks.first(where: { $0.id == task.id }) {
            writing = TaskWriting(title: saved.title, body: saved.currentNote?.body ?? "", formatting: saved.currentNote?.formatting)
            parents = saved.currentNote.map { [$0.id] } ?? []
        }
        baselineWriting = writing
        baselineParents = parents
        needsDraftTitleChoice = false
        noteDraftID = UUID()
        otherDrafts.removeAll { $0.id == savedID }
        do { try editingStore?.removeDraft(id: savedID); draftStatus = "" }
        catch { draftStatus = "任务已保存；草稿清理失败，原文件保留。" }
        return true
    }

    private func loadDraft(_ draft: LocalDraft) {
        guard hasCurrentStore else { return }
        TaskWritingEditor.finishEditing()
        let committed = task.revisions.contains { $0.id == draft.id }
        // Once its revision is committed, the draft's original title no longer tells whether
        // a different title is a pending rename or a stale copy; let the user choose on save.
        let title = committed
            ? (text: draft.title, baseline: task.title, needsChoice: TaskStore.titleChange(draft.title, from: task.title) != nil)
            : draft.editorTitle(current: task.title)
        writing = TaskWriting(title: title.text, body: draft.body, formatting: draft.formatting)
        baselineWriting.title = title.baseline
        needsDraftTitleChoice = title.needsChoice
        if committed {
            noteDraftID = UUID(); parents = [draft.id]
        } else { noteDraftID = draft.id; parents = draft.parentIDs }
        draftStatus = "已恢复本机草稿；远端更新不会替换正在输入的文字"
        do {
            otherDrafts = try editingStore?.drafts().filter { $0.kind == .editor && $0.taskID == task.id && $0.id != draft.id } ?? []
        } catch { draftStatus = "当前草稿已恢复，其他草稿读取失败：\(error.localizedDescription)" }
    }

    private var hasCurrentStore: Bool {
        model.loaded && editingStore != nil && model.store === editingStore
    }

    @discardableResult
    private func closeDetail() -> Bool {
        guard model.selection == task.id else { return true }
        TaskWritingEditor.finishEditing()
        // The draft must reach disk before closing; onDisappear then commits it. A failed
        // commit reports its error and keeps the draft for the next opening.
        guard persistEditorDraft() else { return false }
        model.selection = nil
        return true
    }

    @discardableResult
    private func persistEditorDraft() -> Bool {
        guard initialized, hasCurrentStore, let store = editingStore else { return false }
        do {
            let saved = model.tasks.first { $0.id == task.id } ?? task
            let savedParents = saved.currentNote.map { [$0.id] } ?? []
            if !contentChanged || (writing.title == saved.title && writing.body == (saved.currentNote?.body ?? "") && writing.formatting == saved.currentNote?.formatting && Set(parents) == Set(savedParents)) {
                try store.removeDraft(id: noteDraftID); draftStatus = ""
            } else {
                try store.saveDraft(LocalDraft(formatVersion: 1, id: noteDraftID, taskID: task.id, kind: .editor,
                                               title: writing.title, body: writing.body, parentIDs: parents, updatedAt: Date(),
                                               formatting: writing.formatting, originalTitle: needsDraftTitleChoice ? nil : baselineWriting.title))
                draftStatus = "修改已保存在此设备；点击保存后更新任务"
            }
            return true
        } catch {
            draftStatus = "草稿未能保存：\(error.localizedDescription)"
            return false
        }
    }
}

/// Observe clicks without placing a transparent hit target over the workspace.
struct InspectorDismissal: NSViewRepresentable {
    let enabled: Bool
    let dismiss: () -> Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { [weak view, coordinator = context.coordinator] event in
            guard coordinator.enabled, let view, let window = view.window, event.window === window else { return event }
            if event.type == .keyDown {
                guard event.keyCode == 53,
                      (window.firstResponder as? NSTextInputClient)?.hasMarkedText() != true else { return event }
                _ = coordinator.dismiss()
                return nil
            }
            guard !view.bounds.contains(view.convert(event.locationInWindow, from: nil)) else { return event }
            return coordinator.dismiss() ? event : nil
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.dismiss = dismiss
        context.coordinator.enabled = enabled
    }
    func makeCoordinator() -> Coordinator { Coordinator(enabled: enabled, dismiss: dismiss) }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
    }

    final class Coordinator {
        var dismiss: () -> Bool
        var enabled: Bool
        var monitor: Any?
        init(enabled: Bool, dismiss: @escaping () -> Bool) {
            self.enabled = enabled
            self.dismiss = dismiss
        }
    }
}
