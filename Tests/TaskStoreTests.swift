import CoreData
import Darwin
import XCTest
@testable import TodoM0

final class TaskStoreTests: XCTestCase {
    @MainActor
    func testWeeklyPlanSurvivesDraftRestartArchiveAndDateAssignment() throws {
        try withStore { store in
            let id = UUID(), monday = try Day("2026-10-26")
            let plan = TaskSchedule.week(start: monday)
            try store.createTask(id: id, title: "本周交付", schedule: plan, body: "保持同一条任务")
            try store.close()
            let reopened = try TaskStore(directory: store.directory)
            defer { try? reopened.close() }
            XCTAssertEqual(try reopened.snapshots().first?.schedule, plan)
            let archive = try TaskArchive.decode(reopened.archive().encoded())
            XCTAssertEqual(archive.tasks.first?.schedule, plan)
            try reopened.scheduleTask(id: id, schedule: plan.moved(to: monday.adding(days: 3), displayTimeZone: .current))
            XCTAssertEqual(try reopened.snapshots().count, 1)
            XCTAssertEqual(try reopened.snapshots().first?.id, id)
            XCTAssertEqual(try reopened.snapshots().first?.currentNote?.body, "保持同一条任务")
        }
    }

    @MainActor
    func testSharedCaptureRecoversWeeklyDraftAndPreservesNamespace() throws {
        try withStore { first in
            let draft = CaptureDraft()
            let plan = TaskSchedule.week(start: try Day("2026-10-26"))
            draft.begin(schedule: plan)
            draft.attach(to: first, tasks: [])
            draft.content = TaskWriting(title: "灵感", body: "不要丢失")
            let id = draft.id
            XCTAssertEqual(try first.drafts().first?.captureSchedule, plan)
            draft.detach()
            let recovered = CaptureDraft()
            recovered.attach(to: first, tasks: [])
            XCTAssertEqual(recovered.id, id)
            XCTAssertEqual(recovered.content.body, "不要丢失")
            XCTAssertEqual(recovered.plan.schedule, plan)
            recovered.detach()
            try withStore { second in
                recovered.attach(to: second, tasks: [])
                XCTAssertFalse(recovered.content.hasText)
                XCTAssertEqual(recovered.plan.schedule, .none)
                XCTAssertTrue(try second.drafts().isEmpty)
                XCTAssertEqual(try first.drafts().first?.id, id)
                recovered.detach()
            }
        }
    }

    @MainActor
    func testCaptureKeepsExplicitDateBeforeTypingAcrossEntryPoints() throws {
        try withStore { store in
            let draft = CaptureDraft()
            draft.attach(to: store, tasks: [])
            let today = TaskSchedule.allDay(start: try Day("2026-11-02"), endExclusive: try Day("2026-11-03"))
            let tomorrow = TaskSchedule.allDay(start: try Day("2026-11-03"), endExclusive: try Day("2026-11-04"))
            draft.begin(schedule: today)
            draft.plan = ScheduleForm(schedule: tomorrow)
            draft.begin(schedule: today)
            XCTAssertEqual(draft.plan.schedule, tomorrow)
            draft.plan = ScheduleForm(schedule: .none)
            draft.begin(schedule: today)
            XCTAssertEqual(draft.plan.schedule, .none)
            draft.content = TaskWriting(title: "保留草稿", body: "编辑入口切换不改变日期")
            let id = draft.id
            draft.detach()
            let recovered = CaptureDraft()
            recovered.attach(to: store, tasks: [])
            recovered.begin(schedule: today)
            XCTAssertEqual(recovered.id, id)
            XCTAssertEqual(recovered.plan.schedule, .none)
            XCTAssertEqual(recovered.content.body, "编辑入口切换不改变日期")
            recovered.detach()
            try withStore { other in
                recovered.attach(to: other, tasks: [])
                recovered.begin(schedule: today)
                XCTAssertEqual(recovered.plan.schedule, today)
                recovered.detach()
            }
        }
    }

    @MainActor
    func testCaptureTitleDateYieldsToExplicitChoicesAndSurvivesRestart() throws {
        try withStore { store in
            let wednesday = try Day("2026-11-18")
            let today = TaskSchedule.singleDay(wednesday)
            let tomorrow = TaskSchedule.singleDay(wednesday.adding(days: 1))
            let draft = CaptureDraft()
            draft.today = { wednesday }
            draft.attach(to: store, tasks: [])
            draft.begin(schedule: .none)
            // Any entry edits `content`; the full editor changes the whole value at once.
            draft.content.title = "明天买菜"
            XCTAssertEqual(draft.plan.schedule, tomorrow)
            XCTAssertTrue(draft.dateFromTitle)
            XCTAssertEqual(try store.drafts().first?.captureSchedule, tomorrow)
            XCTAssertEqual(try store.drafts().first?.captureScheduleFromTitle, true)
            draft.content = TaskWriting(title: "买菜", body: "完整编辑器")
            XCTAssertEqual(draft.plan.schedule, .none)
            XCTAssertFalse(draft.dateFromTitle)

            // A restored suggestion is still a suggestion.
            draft.content.title = "明天买菜"
            draft.detach()
            let restored = CaptureDraft()
            restored.today = { wednesday }
            restored.attach(to: store, tasks: [])
            restored.begin(schedule: .none)
            XCTAssertEqual(restored.plan.schedule, tomorrow)
            restored.content.title = "买菜"
            XCTAssertEqual(restored.plan.schedule, .none)

            // Declining applies to this draft only.
            restored.begin(schedule: today)
            restored.content.title = "周五买菜"
            restored.ignoreTitleDate()
            XCTAssertEqual(restored.plan.schedule, today)
            restored.content.title = "周五买菜 明天"
            XCTAssertEqual(restored.plan.schedule, today)
            restored.content = TaskWriting()
            restored.begin(schedule: today)
            restored.content.title = "后天交报告"
            XCTAssertEqual(restored.plan.schedule, .singleDay(wednesday.adding(days: 2)))

            // A date the user picked wins over the title, before or after typing.
            restored.content = TaskWriting()
            restored.plan = ScheduleForm(schedule: .none)
            restored.content.title = "后天交报告"
            XCTAssertEqual(restored.plan.schedule, .none)
            restored.content.title = "明天交报告"
            restored.plan = ScheduleForm(schedule: today)
            restored.content.title = "后天交报告"
            XCTAssertEqual(restored.plan.schedule, today)
            restored.detach()
        }
    }

    @MainActor
    func testCaptureRefreshesImplicitDateBeforeTypingAndThenKeepsTheDraftDate() throws {
        try withStore { store in
            let draft = CaptureDraft()
            draft.attach(to: store, tasks: [])
            let yesterday = try Day("2026-11-02")
            let today = yesterday.adding(days: 1)
            let tomorrow = today.adding(days: 1)
            draft.begin(schedule: .allDay(start: yesterday, endExclusive: today))
            let id = draft.id

            // First input can arrive after midnight without a new focus event.
            draft.begin(schedule: .allDay(start: today, endExclusive: tomorrow))
            draft.content.title = "午夜后开始记录"
            XCTAssertEqual(draft.id, id)
            XCTAssertEqual(draft.plan.schedule, .allDay(start: today, endExclusive: tomorrow))
            XCTAssertEqual(try store.drafts().first?.captureSchedule, draft.plan.schedule)

            draft.begin(schedule: .allDay(start: tomorrow, endExclusive: tomorrow.adding(days: 1)))
            draft.content.title += "，继续输入"
            XCTAssertEqual(draft.plan.schedule, .allDay(start: today, endExclusive: tomorrow))
            XCTAssertEqual(try store.drafts().first?.id, id)

            draft.content = TaskWriting()
            draft.plan = ScheduleForm(schedule: .none)
            draft.begin(schedule: .allDay(start: tomorrow, endExclusive: tomorrow.adding(days: 1)))
            draft.content.title = "明确不安排日期"
            XCTAssertEqual(draft.plan.schedule, .none)
            XCTAssertEqual(try store.drafts().first?.captureSchedule, TaskSchedule.none)
            draft.detach()
        }
    }

    @MainActor
    func testWritingCaptureKeepsBodyFormattingAndDraftAcrossRestart() throws {
        try withStore { store in
            let id = UUID()
            let body = "重点\n1. Prepare\n2. Review"
            let formatting = NoteFormatting(bold: [.init(location: 0, length: 2)])
            let draft = LocalDraft(formatVersion: 1, id: id, taskID: id, kind: .capture, title: "评审",
                                   body: body, parentIDs: [], updatedAt: Date(), formatting: formatting)
            try store.saveDraft(draft)
            try store.close()
            let reopened = try TaskStore(directory: store.directory)
            defer { try? reopened.close() }
            let recovered = try XCTUnwrap(reopened.drafts().first)
            XCTAssertEqual(recovered.body, body)
            XCTAssertEqual(recovered.formatting, formatting)
            try reopened.createTask(id: id, title: recovered.title, body: recovered.body, formatting: recovered.formatting)
            try reopened.createTask(id: id, title: "retry", body: "must not replace")
            let task = try XCTUnwrap(reopened.snapshots().first)
            XCTAssertEqual(task.title, "评审")
            XCTAssertEqual(task.currentNote?.body, body)
            XCTAssertEqual(task.currentNote?.formatting, formatting)
            XCTAssertEqual(task.revisions.count, 1)
            XCTAssertEqual(task.currentNote?.id, id)
            try reopened.removeDraft(id: recovered.id)
            XCTAssertTrue(try reopened.drafts().isEmpty)
        }
    }

    @MainActor
    func testWritingRejectsInvalidFormattingAndRollsBackEntireCaptureOrEdit() throws {
        try withStore { store in
            let id = UUID()
            let invalid = NoteFormatting(bold: [.init(location: 0, length: Int.max)])
            XCTAssertThrowsError(try store.createTask(id: id, title: "invalid", body: "body", formatting: invalid))
            XCTAssertTrue(try store.snapshots().isEmpty)
            // A global revision UUID collision must roll back an already inserted task.
            let other = UUID()
            try store.createTask(id: other, title: "first")
            try store.saveNoteRevision(taskID: other, id: id, body: "existing", parentIDs: [])
            XCTAssertThrowsError(try store.createTask(id: id, title: "second", body: "new"))
            XCTAssertEqual(try store.snapshots().count, 1)
            XCTAssertThrowsError(try store.updateContent(id: other, title: "changed", revisionID: UUID(), body: "body", formatting: invalid, parentIDs: [id]))
            XCTAssertEqual(try store.snapshots().first?.title, "first")
            XCTAssertEqual(try store.snapshots().first?.currentNote?.body, "existing")
        }
    }

    @MainActor
    func testWritingVersionsPreserveFormattingAndTitleOnlyEditKeepsRemoteHead() throws {
        try withStore { store in
            let id = UUID(), remote = UUID(), edited = UUID()
            let firstStyle = NoteFormatting(bold: [.init(location: 0, length: 4)])
            try store.createTask(id: id, title: "original", body: "body", formatting: firstStyle)
            try store.saveNoteRevision(taskID: id, id: remote, body: "remote", parentIDs: [id])
            try store.updateContent(id: id, title: "title only", revisionID: edited, body: "body", formatting: firstStyle, parentIDs: [id])
            var task = try XCTUnwrap(store.snapshots().first)
            XCTAssertEqual(task.title, "title only")
            XCTAssertEqual(task.currentRevisionID, remote)
            XCTAssertEqual(task.revisions.count, 2)
            // A formatting-only change is a real immutable revision.
            try store.updateContent(id: id, title: "formatted", revisionID: edited, body: "body", formatting: nil, parentIDs: [id])
            task = try XCTUnwrap(store.snapshots().first)
            XCTAssertEqual(task.currentRevisionID, edited)
            XCTAssertNil(task.currentNote?.formatting)
            XCTAssertEqual(task.revisions.first { $0.id == id }?.formatting, firstStyle)
            XCTAssertEqual(Set(task.heads.map(\.id)), [remote, edited])
            XCTAssertThrowsError(try store.saveNoteRevision(taskID: id, id: edited, body: "body", parentIDs: [id], formatting: firstStyle))
            try store.moveToTrash(id: id)
            XCTAssertThrowsError(try store.updateContent(id: id, title: "stale", revisionID: UUID(), body: "stale", formatting: nil, parentIDs: [edited]))
            XCTAssertEqual(try store.snapshots().first?.revisions.count, 3)
        }
    }

    @MainActor
    func testBodyOnlyEditAndRestoredDraftKeepAConcurrentTitleChange() throws {
        try withStore { store in
            let id = UUID()
            try store.createTask(id: id, title: "原始标题", body: "原始正文")
            let original = try XCTUnwrap(store.snapshots().first)
            let draft = LocalDraft(formatVersion: 1, id: UUID(), taskID: id, kind: .editor,
                                   title: original.title, body: "本机新正文", parentIDs: [id], updatedAt: Date(),
                                   originalTitle: original.title)
            try store.saveDraft(draft)
            try store.updateTitle(id: id, title: "另一端改的标题")
            let change = TaskStore.titleChange(draft.title, from: original.title)
            XCTAssertNil(change)
            try store.updateContent(id: id, title: change, revisionID: draft.id, body: draft.body,
                                    formatting: nil, parentIDs: draft.parentIDs)
            let edited = try XCTUnwrap(store.snapshots().first)
            XCTAssertEqual(edited.title, "另一端改的标题")
            XCTAssertEqual(edited.currentNote?.body, draft.body)

            let recovered = try XCTUnwrap(store.drafts().first)
            XCTAssertEqual(recovered.originalTitle, original.title)
            let title = recovered.editorTitle(current: edited.title)
            XCTAssertEqual(title.text, edited.title)
            XCTAssertNil(TaskStore.titleChange(title.text, from: title.baseline))
            XCTAssertFalse(title.needsChoice)
            XCTAssertNil(TaskStore.titleChange(" 原始标题 ", from: original.title))
            try store.updateContent(id: id, title: TaskStore.titleChange("本机改名", from: title.baseline),
                                    revisionID: UUID(), body: draft.body, formatting: nil, parentIDs: [draft.id])
            XCTAssertEqual(try store.snapshots().first?.title, "本机改名")
        }
    }

    @MainActor
    func testCommittedDraftResidueIsRecognisedOnlyWhenTextAndTitleMatch() throws {
        try withStore { store in
            let id = UUID(), revision = UUID()
            try store.createTask(id: id, title: "甲")
            try store.updateContent(id: id, title: "乙", revisionID: revision, body: "正文", formatting: nil, parentIDs: [])
            var draft = LocalDraft(formatVersion: 1, id: revision, taskID: id, kind: .editor, title: "乙", body: "正文",
                                   parentIDs: [], updatedAt: Date(), originalTitle: "甲")
            XCTAssertTrue(draft.isCommitted(in: try XCTUnwrap(store.snapshots().first)))
            try store.updateTitle(id: id, title: "丙")
            // A later rename means the leftover title is no longer known to be committed.
            XCTAssertFalse(draft.isCommitted(in: try XCTUnwrap(store.snapshots().first)))
            draft = LocalDraft(formatVersion: 1, id: revision, taskID: id, kind: .editor, title: "丙", body: "另一个窗口的正文",
                               parentIDs: [], updatedAt: Date())
            XCTAssertFalse(draft.isCommitted(in: try XCTUnwrap(store.snapshots().first)))
            draft = LocalDraft(formatVersion: 1, id: UUID(), taskID: id, kind: .editor, title: "丙", body: "正文",
                               parentIDs: [revision], updatedAt: Date())
            XCTAssertFalse(draft.isCommitted(in: try XCTUnwrap(store.snapshots().first)))
        }
    }

    func testRestoringRenamedAndLegacyDraftTitlesPreservesBothChoices() throws {
        var draft = LocalDraft(formatVersion: 1, id: UUID(), taskID: UUID(), kind: .editor,
                               title: "草稿标题", body: "编辑中", parentIDs: [], updatedAt: Date())
        // Old draft JSON has no title baseline; never infer a rename from a mismatch.
        let legacy = try JSONDecoder().decode(LocalDraft.self, from: JSONEncoder().encode(draft))
        let ambiguous = legacy.editorTitle(current: "当前标题")
        XCTAssertNil(legacy.originalTitle)
        XCTAssertTrue(ambiguous.needsChoice)
        XCTAssertEqual(ambiguous.text, draft.title)
        XCTAssertEqual(ambiguous.baseline, "当前标题")
        XCTAssertFalse(legacy.editorTitle(current: draft.title).needsChoice)
        draft.originalTitle = "原始标题"
        let renamed = draft.editorTitle(current: "当前标题")
        XCTAssertEqual(renamed.text, draft.title)
        XCTAssertEqual(TaskStore.titleChange(renamed.text, from: renamed.baseline), draft.title)
        XCTAssertFalse(renamed.needsChoice)
    }

    @MainActor
    func testWritingArchiveAndLegacyDraftRetainPlainTextAndFormatting() throws {
        try withStore { source in
            let id = UUID(), style = NoteFormatting(bold: [.init(location: 0, length: 2)])
            try source.createTask(id: id, title: "archive", body: "正文", formatting: style)
            let archive = try TaskArchive.decode(source.archive().encoded())
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TodoM0WritingRestore-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let restored = try TaskStore(directory: directory)
            defer { try? restored.close() }
            try restored.restoreIntoEmptyLocalStore(archive)
            XCTAssertEqual(try restored.snapshots(), archive.tasks)
            let draft = LocalDraft(formatVersion: 1, id: UUID(), taskID: id, kind: .editor,
                                   title: "legacy", body: "**literal**", parentIDs: [], updatedAt: Date())
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(draft)) as? [String: Any])
            json.removeValue(forKey: "formatting")
            let old = try JSONDecoder().decode(LocalDraft.self, from: JSONSerialization.data(withJSONObject: json))
            XCTAssertEqual(old.body, "**literal**")
            XCTAssertNil(old.formatting)
            let legacyArchive = TaskArchive(formatVersion: 1, modelVersion: 1, exportedAt: Date(), tasks: [])
            XCTAssertNoThrow(try TaskArchive.decode(legacyArchive.encoded()))
        }
    }

    @MainActor
    func testModelV1MigratesWithoutLosingPlainNotesAndExtensionDoesNotMigrate() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TodoM0V1Migration-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let modelFolder = try XCTUnwrap(Bundle.main.url(forResource: "Model", withExtension: "momd"))
        let model = try XCTUnwrap(NSManagedObjectModel(contentsOf: modelFolder.appendingPathComponent("ModelV1.mom")))
        let old = NSPersistentContainer(name: "ModelV1", managedObjectModel: model)
        let url = directory.appendingPathComponent("tasks.sqlite")
        let description = NSPersistentStoreDescription(url: url)
        description.shouldAddStoreAsynchronously = false
        old.persistentStoreDescriptions = [description]
        var loadError: Error?
        old.loadPersistentStores { _, error in loadError = error }
        if let loadError { throw loadError }
        let taskID = UUID(), noteID = UUID(), now = Date()
        let task = NSEntityDescription.insertNewObject(forEntityName: "TaskItem", into: old.viewContext)
        for (key, value) in ["id": taskID, "recordKey": UUID().uuidString, "title": "V1 original", "createdAt": now, "updatedAt": now, "scheduleJSON": "{\"none\":{}}", "currentRevisionID": noteID] as [String: Any] { task.setValue(value, forKey: key) }
        let note = NSEntityDescription.insertNewObject(forEntityName: "TaskNoteRevision", into: old.viewContext)
        for (key, value) in ["id": noteID, "taskID": taskID, "body": "**literal V1**", "parentIDsJSON": "[]", "createdAt": now, "task": task] as [String: Any] { note.setValue(value, forKey: key) }
        try old.viewContext.save()
        old.viewContext.reset()
        for store in old.persistentStoreCoordinator.persistentStores { try old.persistentStoreCoordinator.remove(store) }
        let before = try Data(contentsOf: url)
        XCTAssertThrowsError(try TaskStore(directory: directory, isExtension: true))
        XCTAssertEqual(try Data(contentsOf: url), before)
        let upgraded = try TaskStore(directory: directory)
        var snapshot = try XCTUnwrap(upgraded.snapshots().first)
        XCTAssertEqual(snapshot.id, taskID)
        XCTAssertEqual(snapshot.currentNote?.body, "**literal V1**")
        XCTAssertNil(snapshot.currentNote?.formatting)
        XCTAssertEqual(snapshot.revisions.count, 1)
        try upgraded.saveNoteRevision(taskID: taskID, id: UUID(), body: "new", parentIDs: [noteID], formatting: NoteFormatting(bold: [.init(location: 0, length: 3)]))
        snapshot = try XCTUnwrap(upgraded.snapshots().first)
        XCTAssertEqual(snapshot.revisions.count, 2)
        let archive = try upgraded.archive()
        try upgraded.close()
        let extensionStore = try TaskStore(directory: directory, isExtension: true)
        defer { try? extensionStore.close() }
        XCTAssertEqual(try extensionStore.snapshots(), archive.tasks)
    }

    @MainActor
    private func withStore(_ body: (TaskStore) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TodoM0Tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TaskStore(directory: directory)
        defer { try? store.close() }
        try body(store)
    }

    @MainActor
    func testCaptureValidatesAndIsIdempotentAcrossRestart() throws {
        try withStore { store in
            let id = UUID()
            XCTAssertThrowsError(try store.createTask(id: id, title: " \n "))
            try store.createTask(id: id, title: "  M0 中文捕获  ")
            try store.createTask(id: id, title: "不能覆盖首次内容")
            XCTAssertEqual(try store.snapshots().count, 1)
            XCTAssertEqual(try store.snapshots().first?.title, "M0 中文捕获")
            try store.close()
            let reopened = try TaskStore(directory: store.directory)
            defer { try? reopened.close() }
            XCTAssertEqual(try reopened.snapshots().first?.id, id)
            XCTAssertEqual(try reopened.snapshots().first?.title, "M0 中文捕获")
        }
    }

    @MainActor
    func testSuccessfulWritePublishesCommittedSnapshotBeforeReturning() throws {
        try withStore { store in
            let id = UUID(), revisionID = UUID()
            var published: [TaskSnapshot] = []
            store.onChange = { [weak store] in
                do {
                    published.append(try XCTUnwrap(store?.snapshots().first))
                } catch { XCTFail("Committed snapshot was not readable: \(error)") }
            }

            try store.createTask(id: id, title: "created")
            XCTAssertEqual(published.map(\.title), ["created"])
            try store.updateContent(id: id, title: "edited", revisionID: revisionID,
                                    body: "body", formatting: nil, parentIDs: [])
            XCTAssertEqual(published.map(\.title), ["created", "edited"])
            XCTAssertEqual(published.last?.currentNote?.id, revisionID)

            XCTAssertThrowsError(try store.updateContent(id: id, title: "rolled back", revisionID: revisionID,
                                                        body: "conflicting body", formatting: nil, parentIDs: []))
            XCTAssertEqual(published.count, 2)
            XCTAssertEqual(try store.snapshots().first?.title, "edited")
        }
    }

    @MainActor
    func testScheduledCaptureIsAtomicAndRetryDoesNotOverwrite() throws {
        try withStore { store in
            let id = UUID()
            let first = try TaskSchedule.allDay(start: Day("2026-10-29"), endExclusive: Day("2026-10-30"))
            let invalid = try TaskSchedule.allDay(start: Day("2026-10-29"), endExclusive: Day("2026-10-28"))
            XCTAssertThrowsError(try store.createTask(id: id, title: "invalid", schedule: invalid))
            XCTAssertTrue(try store.snapshots().isEmpty)
            try store.createTask(id: id, title: "planned", schedule: first)
            try store.createTask(id: id, title: "retry", schedule: .none)
            XCTAssertEqual(try store.snapshots().first?.title, "planned")
            XCTAssertEqual(try store.snapshots().first?.schedule, first)
            try store.moveToTrash(id: id)
            try store.createTask(id: id, title: "retry after trash", schedule: .none)
            XCTAssertNotNil(try store.snapshots().first?.deletedAt)
            try store.close()
            let reopened = try TaskStore(directory: store.directory)
            defer { try? reopened.close() }
            XCTAssertEqual(try reopened.snapshots().first?.schedule, first)
            XCTAssertEqual(try reopened.snapshots().count, 1)
        }
    }

    @MainActor
    func testCaptureScheduleDraftRecoversAndOldDraftStillDecodes() throws {
        try withStore { store in
            let id = UUID()
            let schedule = try TaskSchedule.allDay(start: Day("2026-10-29"), endExclusive: Day("2026-11-01"))
            let draft = LocalDraft(formatVersion: 1, id: id, taskID: id, kind: .capture, title: "planned draft",
                                   body: "", parentIDs: [], updatedAt: Date(), captureSchedule: schedule)
            var oldJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(draft)) as? [String: Any])
            oldJSON.removeValue(forKey: "captureSchedule")
            let old = try JSONDecoder().decode(LocalDraft.self, from: JSONSerialization.data(withJSONObject: oldJSON))
            XCTAssertNil(old.captureSchedule)
            XCTAssertEqual(old.id, id)
            try store.saveDraft(draft)
            try store.close()
            let reopened = try TaskStore(directory: store.directory)
            defer { try? reopened.close() }
            let recovered = try XCTUnwrap(reopened.drafts().first)
            XCTAssertEqual(recovered.captureSchedule, schedule)
            try reopened.createTask(id: recovered.id, title: recovered.title, schedule: try XCTUnwrap(recovered.captureSchedule))
            XCTAssertEqual(try reopened.snapshots().first?.id, id)
            XCTAssertEqual(try reopened.snapshots().first?.schedule, schedule)
        }
    }

    @MainActor
    func testIndependentFieldUpdatesPreserveScheduleAndNote() throws {
        try withStore { store in
            let id = UUID(), revision = UUID()
            try store.createTask(id: id, title: "old")
            let schedule = try TaskSchedule.allDay(start: Day("2026-10-19"), endExclusive: Day("2026-10-22"))
            try store.scheduleTask(id: id, schedule: schedule)
            try store.saveNoteRevision(taskID: id, id: revision, body: "正文保留", parentIDs: [])
            try store.updateTitle(id: id, title: "new")
            let task = try XCTUnwrap(store.snapshots().first)
            XCTAssertEqual(task.schedule, schedule)
            XCTAssertEqual(task.currentNote?.body, "正文保留")
            XCTAssertEqual(task.title, "new")
        }
    }

    @MainActor
    func testCompletionSetsTargetAndRepeatedIntentDoesNotToggle() throws {
        try withStore { store in
            let id = UUID()
            try store.createTask(id: id, title: "M0")
            try store.setCompleted(id: id, completed: true)
            let first = try store.snapshots().first?.completedAt
            try store.setCompleted(id: id, completed: true)
            XCTAssertEqual(try store.snapshots().first?.completedAt, first)
            try store.setCompleted(id: id, completed: false)
            XCTAssertNil(try store.snapshots().first?.completedAt)
            XCTAssertThrowsError(try store.setCompleted(id: UUID(), completed: true))
            XCTAssertEqual(try store.snapshots().count, 1)
        }
    }

    @MainActor
    func testParallelNoteBranchesAndRecoveryPreserveAllBodies() throws {
        try withStore { store in
            let taskID = UUID(), baseline = UUID(), phone = UUID(), mac = UUID(), merge = UUID()
            try store.createTask(id: taskID, title: "M0 branches")
            try store.saveNoteRevision(taskID: taskID, id: baseline, body: "共同基线", parentIDs: [])
            try store.saveNoteRevision(taskID: taskID, id: phone, body: "手机离线补充", parentIDs: [baseline])
            try store.saveNoteRevision(taskID: taskID, id: mac, body: "电脑离线补充", parentIDs: [baseline])
            let task = try XCTUnwrap(store.snapshots().first)
            XCTAssertEqual(Set(task.heads.map(\.id)), [phone, mac])
            try store.saveNoteRevision(taskID: taskID, id: merge, body: "选择手机文字", parentIDs: task.heads.map(\.id))
            let restored = try XCTUnwrap(store.snapshots().first)
            XCTAssertEqual(restored.heads.map(\.id), [merge])
            XCTAssertEqual(Set(restored.revisions.map(\.body)), ["共同基线", "手机离线补充", "电脑离线补充", "选择手机文字"])
            XCTAssertThrowsError(try store.saveNoteRevision(taskID: taskID, id: phone, body: "试图覆盖", parentIDs: [baseline]))
            try store.saveNoteRevision(taskID: taskID, id: phone, body: "手机离线补充", parentIDs: [baseline])
            XCTAssertEqual(try store.snapshots().first?.revisions.count, 4)
        }
    }

    @MainActor
    func testNoteArrivingBeforeItsParentIsRetained() throws {
        try withStore { store in
            let id = UUID(), later = UUID(), missing = UUID()
            try store.createTask(id: id, title: "M0 out of order")
            try store.saveNoteRevision(taskID: id, id: later, body: "后到父版本", parentIDs: [missing])
            XCTAssertEqual(try store.snapshots().first?.heads.map(\.id), [later])
            try store.saveNoteRevision(taskID: id, id: missing, body: "父版本", parentIDs: [])
            XCTAssertEqual(try store.snapshots().first?.revisions.count, 2)
            XCTAssertEqual(try store.snapshots().first?.heads.map(\.id), [later])
        }
    }

    @MainActor
    func testTrashRejectsStaleEditsUntilExplicitRestore() throws {
        try withStore { store in
            let id = UUID()
            try store.createTask(id: id, title: "M0 delete")
            try store.moveToTrash(id: id)
            XCTAssertThrowsError(try store.updateTitle(id: id, title: "stale edit"))
            XCTAssertThrowsError(try store.setCompleted(id: id, completed: true))
            XCTAssertThrowsError(try store.saveNoteRevision(taskID: id, id: UUID(), body: "stale note", parentIDs: []))
            XCTAssertNotNil(try store.snapshots().first?.deletedAt)
            try store.restoreTask(id: id)
            try store.updateTitle(id: id, title: "restored")
            XCTAssertNil(try store.snapshots().first?.deletedAt)
        }
    }

    @MainActor
    func testExtensionLocalWriteIsVisibleAfterHistoryConsumption() throws {
        try withStore { app in
            let id = UUID()
            try app.createTask(id: id, title: "M0 shared store")
            let widget = try TaskStore(directory: app.directory, isExtension: true)
            defer { try? widget.close() }
            try widget.setCompleted(id: id, completed: true)
            try widget.consumeHistory()
            try app.consumeHistory()
            XCTAssertTrue(try XCTUnwrap(app.snapshots().first).isCompleted)
            XCTAssertTrue(FileManager.default.fileExists(atPath: app.directory.appendingPathComponent("history-widget.token").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: app.directory.appendingPathComponent("history-app.token").path))
            XCTAssertTrue(type(of: try XCTUnwrap(widget.container)) == NSPersistentContainer.self)
        }
    }

    @MainActor
    func testCompletionHistoryQueryDistinguishesMissingAndCommittedActions() throws {
        try withStore { store in
            let id = UUID()
            try store.createTask(id: id, title: "核对真实历史查询结果")
            let context = try XCTUnwrap(store.container?.viewContext)
            func history(for actionID: UUID) throws -> NSPersistentHistoryResult {
                let transactions = NSFetchRequest<NSFetchRequestResult>()
                transactions.entity = try XCTUnwrap(NSPersistentHistoryTransaction.entityDescription(with: context))
                transactions.predicate = NSPredicate(format: "author IN %@", ["app:\(actionID.uuidString)", "widget:\(actionID.uuidString)"])
                transactions.fetchLimit = 1
                let request = NSPersistentHistoryChangeRequest.fetchHistory(after: nil as NSPersistentHistoryToken?)
                request.fetchRequest = transactions
                request.resultType = .transactionsOnly
                return try XCTUnwrap(context.execute(request) as? NSPersistentHistoryResult)
            }
            let missing = try history(for: UUID())
            XCTAssertEqual(missing.resultType, .transactionsOnly)
            XCTAssertTrue(try XCTUnwrap(missing.result as? [NSPersistentHistoryTransaction]).isEmpty)
            XCTContext.runActivity(named: "Core Data no-match history result") { activity in
                let evidence = XCTAttachment(string: "resultType: \(missing.resultType.rawValue); payload: \(String(reflecting: missing.result))")
                evidence.lifetime = .keepAlways
                activity.add(evidence)
            }
            let actionID = try store.setCompleted(id: id, completed: true)
            let committed = try history(for: actionID)
            let transactions = try XCTUnwrap(committed.result as? [NSPersistentHistoryTransaction])
            XCTAssertEqual(committed.resultType, .transactionsOnly)
            XCTAssertEqual(transactions.count, 1)
            XCTAssertEqual(transactions.first?.author, "app:\(actionID.uuidString)")
        }
    }

    @MainActor
    func testCompletionActionIsIdempotentAcrossWritersHistoryConsumptionAndRestart() throws {
        try withStore { app in
            let id = UUID(), actionID = UUID()
            try app.createTask(id: id, title: "完成凭据与任务一同提交")
            try app.setCompleted(id: id, completed: true, actionID: actionID)
            XCTAssertTrue(try XCTUnwrap(app.snapshots().first).isCompleted)
            try app.consumeHistory()
            let widget = try TaskStore(directory: app.directory, isExtension: true)
            try widget.setCompleted(id: id, completed: false)
            try widget.setCompleted(id: id, completed: true, actionID: actionID)
            XCTAssertFalse(try XCTUnwrap(widget.snapshots().first).isCompleted)
            try widget.consumeHistory()
            try widget.close()
            try app.close()
            let reopened = try TaskStore(directory: app.directory)
            defer { try? reopened.close() }
            try reopened.setCompleted(id: id, completed: true, actionID: actionID)
            XCTAssertFalse(try XCTUnwrap(reopened.snapshots().first).isCompleted)
        }
    }

    @MainActor
    func testSharedWriterLockRejectsContentionWithoutPartialTask() throws {
        try withStore { store in
            let descriptor = open(store.directory.appendingPathComponent("write.lock").path, O_CREAT | O_RDWR, 0o600)
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            defer { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
            XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
            XCTAssertThrowsError(try store.createTask(id: UUID(), title: "M0 locked"))
            XCTAssertEqual(try store.snapshots().count, 0)
        }
    }

    @MainActor
    func testDuplicatePhysicalUUIDIsProjectedOnceAndTrashWins() throws {
        try withStore { store in
            let id = UUID(), note = UUID()
            try store.createTask(id: id, title: "M0 original")
            try store.saveNoteRevision(taskID: id, id: note, body: "保留正文", parentIDs: [])
            let context = try XCTUnwrap(store.container).viewContext
            let duplicate = NSEntityDescription.insertNewObject(forEntityName: "TaskItem", into: context)
            duplicate.setValue(id, forKey: "id")
            duplicate.setValue("000", forKey: "recordKey")
            duplicate.setValue("M0 canonical", forKey: "title")
            duplicate.setValue(Date(), forKey: "createdAt")
            duplicate.setValue(Date(), forKey: "updatedAt")
            duplicate.setValue(Date(), forKey: "deletedAt")
            duplicate.setValue(String(data: try JSONEncoder().encode(TaskSchedule.none), encoding: .utf8), forKey: "scheduleJSON")
            try context.save()
            XCTAssertEqual(try store.snapshots().count, 1)
            XCTAssertNotNil(try store.snapshots().first?.deletedAt)
            XCTAssertEqual(try store.snapshots().first?.revisions.first?.body, "保留正文")
            XCTAssertThrowsError(try store.updateTitle(id: id, title: "no resurrection"))
            try store.restoreTask(id: id)
            try store.updateTitle(id: id, title: "explicit restored")
            XCTAssertEqual(try store.snapshots().first?.title, "explicit restored")
        }
    }

    @MainActor
    func testArchiveRoundTripRetainsIDsRevisionsScheduleAndTrash() throws {
        try withStore { source in
            let id = UUID(), version = UUID()
            try source.createTask(id: id, title: "M0 独立备份")
            try source.scheduleTask(id: id, schedule: .allDay(start: Day("2026-12-30"), endExclusive: Day("2027-01-03")))
            try source.saveNoteRevision(taskID: id, id: version, body: "恢复文字", parentIDs: [])
            try source.setCompleted(id: id, completed: true)
            try source.moveToTrash(id: id)
            let archive = try TaskArchive.decode(source.archive().encoded())
            try withStore { target in
                try target.restoreIntoEmptyLocalStore(archive)
                let restored = try XCTUnwrap(target.snapshots().first)
                XCTAssertEqual(restored.id, id)
                XCTAssertEqual(restored.revisions.first?.id, version)
                XCTAssertEqual(restored.currentNote?.body, "恢复文字")
                XCTAssertEqual(restored.schedule, archive.tasks.first?.schedule)
                XCTAssertTrue(restored.isCompleted)
                XCTAssertNotNil(restored.deletedAt)
                XCTAssertThrowsError(try target.restoreIntoEmptyLocalStore(archive))
                XCTAssertEqual(try target.snapshots().count, 1)
            }
        }
    }

    func testExportAndImportShareTheArchiveByteLimit() throws {
        let taskID = UUID(), now = Date()
        let body = String(repeating: "x", count: 1_000_000)
        let notes = (0..<20).map { _ in
            NoteRevision(id: UUID(), taskID: taskID, body: body, parentIDs: [], createdAt: now)
        }
        let task = TaskSnapshot(id: taskID, title: "历史", createdAt: now, updatedAt: now, completedAt: nil,
                                deletedAt: nil, schedule: .none, currentRevisionID: notes.last?.id, revisions: notes)
        let archive = TaskArchive(formatVersion: 1, modelVersion: 1, exportedAt: now, tasks: [task])
        XCTAssertThrowsError(try archive.encoded()) { XCTAssertTrue($0.localizedDescription.contains("20 MB")) }
        let oldEncoder = JSONEncoder()
        oldEncoder.dateEncodingStrategy = .millisecondsSince1970
        let oldExport = try oldEncoder.encode(archive)
        XCTAssertGreaterThan(oldExport.count, 20_000_000)
        XCTAssertThrowsError(try TaskArchive.decode(oldExport)) { XCTAssertTrue($0.localizedDescription.contains("20 MB")) }
    }

    @MainActor
    func testArchiveVersionAndInvalidScheduleFailBeforeWriting() throws {
        try withStore { store in
            let invalid = TaskSnapshot(id: UUID(), title: "M0 invalid", createdAt: Date(), updatedAt: Date(), completedAt: nil,
                                       deletedAt: nil, schedule: .allDay(start: try Day("2026-10-22"), endExclusive: try Day("2026-10-19")),
                                       currentRevisionID: nil, revisions: [])
            let archive = TaskArchive(formatVersion: 1, modelVersion: 1, exportedAt: Date(), tasks: [invalid])
            XCTAssertThrowsError(try store.restoreIntoEmptyLocalStore(archive))
            XCTAssertEqual(try store.snapshots().count, 0)
            XCTAssertThrowsError(try TaskArchive.decode(TaskArchive(formatVersion: 99, modelVersion: 1, exportedAt: Date(), tasks: []).encoded()))
        }
    }

    @MainActor
    func testExtensionDoesNotCreateOrReplaceAnInvalidStore() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TodoM0Invalid-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertThrowsError(try TaskStore(directory: directory, isExtension: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = Data("M0 invalid sqlite original bytes".utf8)
        let url = directory.appendingPathComponent("tasks.sqlite")
        try original.write(to: url)
        XCTAssertThrowsError(try TaskStore(directory: directory, isExtension: true))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    @MainActor
    func testModelUsesCloudKitCompatibleRulesAndEncryptedText() throws {
        try withStore { store in
            for entity in try XCTUnwrap(store.container).managedObjectModel.entities {
                XCTAssertTrue(entity.uniquenessConstraints.isEmpty)
                for property in entity.properties {
                    XCTAssertTrue(property.isOptional)
                    if let relationship = property as? NSRelationshipDescription {
                        XCTAssertNotNil(relationship.inverseRelationship)
                        XCTAssertFalse(relationship.isOrdered)
                        XCTAssertNotEqual(relationship.deleteRule, .denyDeleteRule)
                    }
                }
            }
            let title = try XCTUnwrap(store.container?.managedObjectModel.entitiesByName["TaskItem"]?.attributesByName["title"])
            let body = try XCTUnwrap(store.container?.managedObjectModel.entitiesByName["TaskNoteRevision"]?.attributesByName["body"])
            XCTAssertTrue(title.allowsCloudEncryption)
            XCTAssertTrue(body.allowsCloudEncryption)
        }
    }

    @MainActor
    func testEvidenceDoesNotContainPrivateTextAndRecordsCommittedActions() throws {
        try withStore { store in
            let id = UUID()
            try store.createTask(id: id, title: "PRIVATE-TITLE-M0-1029")
            try store.createTask(id: id, title: "PRIVATE-TITLE-M0-1029")
            try store.saveNoteRevision(taskID: id, id: UUID(), body: "PRIVATE-BODY-M0-8871", parentIDs: [])
            let events = try String(contentsOf: store.directory.appendingPathComponent("events.jsonl"), encoding: .utf8)
            XCTAssertFalse(events.contains("PRIVATE-TITLE"))
            XCTAssertFalse(events.contains("PRIVATE-BODY"))
            XCTAssertTrue(events.contains(id.uuidString))
            XCTAssertTrue(events.contains("committed"))
            let entries = try events.split(separator: "\n").map {
                try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
            }
            let captures = entries.filter { $0["action"] as? String == "task.create" }
            XCTAssertEqual(captures.count, 2)
            XCTAssertTrue(captures.allSatisfy { $0["subjectID"] as? String == id.uuidString })
            let actionIDs = captures.compactMap { $0["actionID"] as? String }.compactMap(UUID.init(uuidString:))
            XCTAssertEqual(Set(actionIDs).count, 2)
            XCTAssertTrue(entries.allSatisfy { ($0["eventFormatVersion"] as? Int) == 2 && $0["eventID"] as? String != nil })
        }
    }

    func testNamespaceRejectsTraversalAndUnsupportedModelVersion() {
        XCTAssertThrowsError(try StoreSession(modelVersion: StoreSession.modelVersion, namespace: "../other", ready: true).directory())
        XCTAssertThrowsError(try StoreSession(modelVersion: 99, namespace: "local-test", ready: true).directory())
    }

    func testDistributionColdLaunchKeepsLibraryAndRejectsInvalidPublishedSelection() throws {
        let previous = StoreSession(modelVersion: StoreSession.modelVersion, namespace: "dist-capture-a", ready: false)
        XCTAssertEqual(try StoreSession.distributionNamespace(run: nil, previous: nil), "dist-manual")
        XCTAssertEqual(try StoreSession.distributionNamespace(run: nil, previous: previous), previous.namespace)
        XCTAssertEqual(try StoreSession.distributionNamespace(run: "capture-b", previous: previous), "dist-capture-b")
        XCTAssertThrowsError(try StoreSession.distributionNamespace(run: "../other", previous: nil))
        let invalid = [
            StoreSession(modelVersion: 99, namespace: previous.namespace, ready: true),
            StoreSession(modelVersion: 2, namespace: "local-manual", ready: true),
            StoreSession(modelVersion: 2, namespace: "desktop-manual", ready: true),
            StoreSession(modelVersion: 2, namespace: "dist-../other", ready: true),
        ]
        for session in invalid {
            XCTAssertThrowsError(try StoreSession.distributionNamespace(run: nil, previous: session))
        }
    }

    @MainActor
    func testDraftSurvivesRestartWithOriginalBaselineAndIsNotInCoreDataModel() throws {
        try withStore { store in
            let id = UUID(), baseline = UUID(), draftID = UUID()
            try store.createTask(id: id, title: "M0 草稿")
            try store.saveNoteRevision(taskID: id, id: baseline, body: "基线", parentIDs: [])
            let draft = LocalDraft(formatVersion: 1, id: draftID, taskID: id, kind: .editor, title: "M0 草稿",
                                   body: "尚未提交的中文输入", parentIDs: [baseline], updatedAt: Date())
            try store.saveDraft(draft)
            XCTAssertEqual(try store.snapshots().first?.revisions.count, 1)
            XCTAssertNil(store.container?.managedObjectModel.entitiesByName["LocalDraft"])
            try store.close()
            let reopened = try TaskStore(directory: store.directory)
            defer { try? reopened.close() }
            let recovered = try XCTUnwrap(reopened.drafts().first)
            XCTAssertEqual(recovered.body, draft.body)
            XCTAssertEqual(recovered.parentIDs, [baseline])
            try reopened.saveNoteRevision(taskID: id, id: recovered.id, body: recovered.body, parentIDs: recovered.parentIDs)
            try reopened.saveNoteRevision(taskID: id, id: recovered.id, body: recovered.body, parentIDs: recovered.parentIDs)
            try reopened.removeDraft(id: recovered.id)
            XCTAssertEqual(try reopened.snapshots().first?.revisions.count, 2)
            XCTAssertTrue(try reopened.drafts().isEmpty)
        }
    }

    @MainActor
    func testLateParentCannotCreateRevisionCycle() throws {
        try withStore { store in
            let id = UUID(), first = UUID(), second = UUID()
            try store.createTask(id: id, title: "M0 cycle")
            try store.saveNoteRevision(taskID: id, id: first, body: "first", parentIDs: [second])
            XCTAssertThrowsError(try store.saveNoteRevision(taskID: id, id: second, body: "second", parentIDs: [first]))
            XCTAssertEqual(try store.snapshots().first?.revisions.count, 1)
        }
    }

    @MainActor
    func testRepeatedRevisionCannotSilentlyChangeParents() throws {
        try withStore { store in
            let id = UUID(), revision = UUID()
            try store.createTask(id: id, title: "M0 immutable")
            try store.saveNoteRevision(taskID: id, id: revision, body: "body", parentIDs: [])
            XCTAssertThrowsError(try store.saveNoteRevision(taskID: id, id: revision, body: "body", parentIDs: [UUID()]))
        }
    }

    @MainActor
    func testCompetingScheduleSnapshotsAlwaysSaveOneValidWholeRange() throws {
        try withStore { app in
            let id = UUID()
            try app.createTask(id: id, title: "M0 reschedule")
            let secondWriter = try TaskStore(directory: app.directory, isExtension: true)
            defer { try? secondWriter.close() }
            let first = try TaskSchedule.allDay(start: Day("2026-10-19"), endExclusive: Day("2026-10-22"))
            let second = try TaskSchedule.allDay(start: Day("2026-11-01"), endExclusive: Day("2026-11-03"))
            try app.scheduleTask(id: id, schedule: first)
            try secondWriter.scheduleTask(id: id, schedule: second)
            XCTAssertEqual(try app.snapshots().first?.schedule, second)
            XCTAssertEqual(try secondWriter.snapshots().first?.schedule, second)
            XCTAssertThrowsError(try app.scheduleTask(id: id, schedule: .allDay(start: Day("2026-12-01"), endExclusive: Day("2026-11-01"))))
            XCTAssertEqual(try app.snapshots().first?.schedule, second)
        }
    }

    @MainActor
    func testOpeningStoreHonorsWriterLockAndCloseReleasesModelLease() throws {
        try withStore { store in
            let writer = try StoreFileLock(url: store.directory.appendingPathComponent("write.lock"), mode: LOCK_EX)
            do {
                defer { withExtendedLifetime(writer) {} }
                XCTAssertThrowsError(try TaskStore(directory: store.directory, isExtension: true))
                XCTAssertThrowsError(try StoreFileLock(url: store.directory.appendingPathComponent("model.lock"), mode: LOCK_EX))
            }
            try store.close()
            let exclusive = try StoreFileLock(url: store.directory.appendingPathComponent("model.lock"), mode: LOCK_EX)
            defer { withExtendedLifetime(exclusive) {} }
            XCTAssertThrowsError(try store.createTask(id: UUID(), title: "closed"))
        }
    }

    @MainActor
    func testIncompatibleModelIsPreservedAndCannotMigrateWithOpenLease() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TodoM0OldModel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let oldModel = NSManagedObjectModel()
        let entity = NSEntityDescription()
        entity.name = "LegacyFixture"
        entity.managedObjectClassName = "NSManagedObject"
        let title = NSAttributeDescription()
        title.name = "text"; title.attributeType = .stringAttributeType; title.isOptional = true
        entity.properties = [title]; oldModel.entities = [entity]
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: oldModel)
        let url = directory.appendingPathComponent("tasks.sqlite")
        let oldStore = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url)
        try coordinator.remove(oldStore)
        let original = try Data(contentsOf: url)
        let lease = try StoreFileLock(url: directory.appendingPathComponent("model.lock"), mode: LOCK_SH)
        defer { withExtendedLifetime(lease) {} }
        XCTAssertThrowsError(try TaskStore(directory: directory, isExtension: true))
        XCTAssertThrowsError(try TaskStore(directory: directory)) { error in
            guard case PrototypeError.busy = error else { return XCTFail("Expected model lease contention, got \(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    @MainActor
    func testSessionGateBlocksOldReadsWritesAndDraftsWithoutCrossLibraryCopy() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("TodoM0Sessions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let first = StoreSession(modelVersion: StoreSession.modelVersion, namespace: "dist-fixture-a", ready: true)
        let second = StoreSession(modelVersion: StoreSession.modelVersion, namespace: "dist-fixture-b", ready: true)
        let gate = base.appendingPathComponent("session.json")
        try JSONEncoder().encode(first).write(to: gate, options: .atomic)
        let store = try TaskStore(directory: base.appendingPathComponent(first.namespace), session: first)
        defer { try? store.close() }
        let id = UUID(), draftID = UUID()
        try store.createTask(id: id, title: "M0 任务库 A 隔离内容")
        let draft = LocalDraft(formatVersion: 1, id: draftID, taskID: id, kind: .editor,
                               title: "A", body: "A 的输入", parentIDs: [], updatedAt: Date())
        try store.saveDraft(draft)
        try JSONEncoder().encode(second).write(to: gate, options: .atomic)
        XCTAssertThrowsError(try store.snapshots())
        XCTAssertThrowsError(try store.readableSnapshots())
        XCTAssertThrowsError(try store.createTask(id: UUID(), title: "must not write"))
        XCTAssertThrowsError(try store.saveDraft(draft))
        XCTAssertThrowsError(try store.drafts())
        XCTAssertThrowsError(try store.removeDraft(id: draftID))
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent(second.namespace).path))
        try JSONEncoder().encode(first).write(to: gate, options: .atomic)
        XCTAssertEqual(try store.snapshots().map(\.id), [id])
        XCTAssertEqual(try store.drafts(), [draft])
        let changing = try StoreFileLock(url: base.appendingPathComponent("session.lock"), mode: LOCK_EX)
        defer { withExtendedLifetime(changing) {} }
        XCTAssertThrowsError(try store.snapshots())
        XCTAssertThrowsError(try store.setCompleted(id: id, completed: true))
    }

    @MainActor
    func testDuplicateRevisionWithDifferentParentsDoesNotSilentlyMerge() throws {
        try withStore { store in
            let id = UUID(), revision = UUID()
            try store.createTask(id: id, title: "M0 duplicate note")
            try store.saveNoteRevision(taskID: id, id: revision, body: "same body", parentIDs: [])
            let context = try XCTUnwrap(store.container).viewContext
            let duplicate = NSEntityDescription.insertNewObject(forEntityName: "TaskNoteRevision", into: context)
            duplicate.setValue(revision, forKey: "id"); duplicate.setValue(id, forKey: "taskID")
            duplicate.setValue("same body", forKey: "body"); duplicate.setValue(Date(), forKey: "createdAt")
            duplicate.setValue(String(data: try JSONEncoder().encode([UUID()]), encoding: .utf8), forKey: "parentIDsJSON")
            try context.save()
            XCTAssertThrowsError(try store.snapshots())
            XCTAssertEqual(try context.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: "TaskNoteRevision")), 2)
        }
    }

    /// Every attribute of every record, read through a separate context.
    @MainActor
    private func rawRecords(_ store: TaskStore) throws -> [String] {
        let container = try XCTUnwrap(store.container)
        let context = container.newBackgroundContext()
        return try context.performAndWait {
            var lines: [String] = []
            for entity in ["TaskItem", "TaskNoteRevision"] {
                for object in try context.fetch(NSFetchRequest<NSManagedObject>(entityName: entity)) {
                    let keys = object.entity.attributesByName.keys.sorted()
                    lines.append(entity + ":" + keys.map { key in
                        let value = object.value(forKey: key)
                        return "\(key)=\((value as? UUID)?.uuidString ?? String(describing: value))"
                    }.joined(separator: ","))
                }
            }
            return lines.sorted()
        }
    }

    @MainActor
    func testReadableSnapshotsSkipEachKindOfUnreadableTaskWithoutTouchingRecords() throws {
        typealias Damage = (TaskStore, NSManagedObjectContext) throws -> Set<UUID>
        func insertNote(_ context: NSManagedObjectContext, id: UUID, task: UUID?, body: String) {
            let note = NSEntityDescription.insertNewObject(forEntityName: "TaskNoteRevision", into: context)
            note.setValue(id, forKey: "id"); note.setValue(task, forKey: "taskID")
            note.setValue(body, forKey: "body"); note.setValue(Date(), forKey: "createdAt")
            note.setValue("[]", forKey: "parentIDsJSON")
        }
        func task(_ context: NSManagedObjectContext, _ id: UUID) throws -> NSManagedObject {
            let request = NSFetchRequest<NSManagedObject>(entityName: "TaskItem")
            request.predicate = NSPredicate(format: "id == %@", id as NSUUID)
            return try XCTUnwrap(context.fetch(request).first)
        }
        let cases: [(String, anonymous: Int, Damage)] = [
            ("正文同版本冲突", 0, { store, context in
                let id = UUID(), revision = UUID()
                try store.createTask(id: id, title: "冲突")
                try store.saveNoteRevision(taskID: id, id: revision, body: "same", parentIDs: [])
                insertNote(context, id: revision, task: id, body: "different")
                return [id]
            }),
            ("计划无法解码", 0, { store, context in
                let id = UUID()
                try store.createTask(id: id, title: "计划损坏")
                try task(context, id).setValue("{\"unknown\":{}}", forKey: "scheduleJSON")
                return [id]
            }),
            ("任务缺身份", 1, { _, context in
                NSEntityDescription.insertNewObject(forEntityName: "TaskItem", into: context).setValue("身份未到达", forKey: "title")
                return []
            }),
            ("正文缺 taskID，只剩关系", 0, { store, context in
                let id = UUID()
                try store.createTask(id: id, title: "正文身份缺失", body: "旧正文")
                let request = NSFetchRequest<NSManagedObject>(entityName: "TaskNoteRevision")
                request.predicate = NSPredicate(format: "taskID == %@", id as NSUUID)
                try XCTUnwrap(context.fetch(request).first).setValue(nil, forKey: "taskID")
                return [id]
            }),
            ("跨任务的父版本环", 0, { store, _ in
                let first = UUID(), second = UUID(), a = UUID(), b = UUID()
                try store.createTask(id: first, title: "环 A")
                try store.createTask(id: second, title: "环 B")
                try store.saveNoteRevision(taskID: first, id: a, body: "a", parentIDs: [b])
                try store.saveNoteRevision(taskID: second, id: b, body: "b", parentIDs: [a])
                return [first, second]
            }),
            ("无归属的孤儿正文", 0, { _, context in
                insertNote(context, id: UUID(), task: nil, body: "无主")
                return []
            })
        ]
        for (name, anonymous, damage) in cases {
            try withStore { store in
                let good = UUID()
                try store.createTask(id: good, title: "仍可读取", body: "正文")
                let context = try XCTUnwrap(store.container).viewContext
                let hidden = try damage(store, context)
                try context.save()
                let before = try rawRecords(store)

                XCTAssertThrowsError(try store.snapshots(), name)
                XCTAssertThrowsError(try store.archive(), name)
                let read = try store.readableSnapshots()
                XCTAssertEqual(read.tasks.map(\.id), [good], name)
                XCTAssertEqual(read.tasks.first?.currentNote?.body, "正文", name)
                XCTAssertEqual(read.unreadableIDs, hidden, name)
                XCTAssertEqual(read.anonymousTasks, anonymous, name)
                XCTAssertEqual(try rawRecords(store), before, "\(name)：读取不得改动任何记录")
            }
        }
    }

    @MainActor
    func testLocalUpgradePreservesPhysicalRecordsRevisionsDraftsHistoryAndIsIdempotent() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("TodoM0Upgrade-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("Local/local-isolated"), target = base.appendingPathComponent("Distribution/dist-isolated")
        let original = try TaskStore(directory: source)
        let id = UUID(), parent = UUID(), child = UUID(), completionTaskID = UUID(), completionActionID = UUID()
        try original.createTask(id: id, title: "完整升级")
        try original.saveNoteRevision(taskID: id, id: parent, body: "父版本", parentIDs: [])
        let format = NoteFormatting(bold: [.init(location: 0, length: 3)])
        try original.saveNoteRevision(taskID: id, id: child, body: "子版本", parentIDs: [parent], formatting: format)
        try original.setCompleted(id: id, completed: true)
        try original.moveToTrash(id: id)
        try original.createTask(id: completionTaskID, title: "升级前已重开的任务")
        try original.setCompleted(id: completionTaskID, completed: true, actionID: completionActionID)
        try original.setCompleted(id: completionTaskID, completed: false)
        let capture = LocalDraft(formatVersion: 1, id: UUID(), taskID: UUID(), kind: .capture,
                                 title: "收集草稿", body: "尚未创建任务", parentIDs: [], updatedAt: Date())
        let editor = LocalDraft(formatVersion: 1, id: UUID(), taskID: id, kind: .editor,
                                title: "编辑草稿", body: "保留输入", parentIDs: [child], updatedAt: Date())
        try original.saveDraft(capture); try original.saveDraft(editor)
        let links = Data(#"{"imports":[]}"#.utf8)
        try links.write(to: source.appendingPathComponent("reminders-links.json"))
        try original.consumeHistory()
        let snapshots = try original.snapshots(), drafts = try original.drafts()
        let physicalTask = NSFetchRequest<NSManagedObject>(entityName: "TaskItem")
        physicalTask.predicate = NSPredicate(format: "id == %@", id as NSUUID)
        let recordKey = try XCTUnwrap(original.container?.viewContext.fetch(physicalTask).first?.value(forKey: "recordKey") as? String)
        let history = NSPersistentHistoryChangeRequest.fetchHistory(after: nil as NSPersistentHistoryToken?)
        let originalTransactions = try XCTUnwrap(original.container?.viewContext.execute(history) as? NSPersistentHistoryResult).result as? [NSPersistentHistoryTransaction]
        XCTAssertFalse(try XCTUnwrap(originalTransactions).isEmpty)
        try original.close()

        try LocalLibraryUpgrade.prepare(source: source, target: target)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: source.path), target.path)
        let receiptURL = target.deletingLastPathComponent().appendingPathComponent(".dist-isolated.upgrade.json")
        let receipt = try JSONDecoder().decode(LocalLibraryUpgrade.Receipt.self, from: Data(contentsOf: receiptURL))
        let backup = source.deletingLastPathComponent().appendingPathComponent(receipt.backupName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.appendingPathComponent("history-app.token").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("history-app.token").path))
        let upgraded = try TaskStore(directory: target)
        XCTAssertEqual(try upgraded.snapshots(), snapshots)
        XCTAssertEqual(try upgraded.drafts(), drafts)
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("reminders-links.json")), links)
        let upgradedPhysicalTask = NSFetchRequest<NSManagedObject>(entityName: "TaskItem")
        upgradedPhysicalTask.predicate = NSPredicate(format: "id == %@", id as NSUUID)
        XCTAssertEqual(try upgraded.container?.viewContext.fetch(upgradedPhysicalTask).first?.value(forKey: "recordKey") as? String, recordKey)
        let copiedTransactions = try XCTUnwrap(upgraded.container?.viewContext.execute(history) as? NSPersistentHistoryResult).result as? [NSPersistentHistoryTransaction]
        XCTAssertEqual(copiedTransactions?.count, originalTransactions?.count)
        try upgraded.setCompleted(id: completionTaskID, completed: true, actionID: completionActionID)
        XCTAssertEqual(try upgraded.snapshots(), snapshots)
        try upgraded.close()
        try LocalLibraryUpgrade.prepare(source: source, target: target)
        XCTAssertEqual(try JSONDecoder().decode(LocalLibraryUpgrade.Receipt.self, from: Data(contentsOf: receiptURL)), receipt)
    }

    @MainActor
    func testLocalUpgradeRejectsOpenSourceAndWriterContentionWithoutChangingData() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("TodoM0UpgradeLocks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("Local/local-isolated"), target = base.appendingPathComponent("Distribution/dist-isolated")
        let original = try TaskStore(directory: source)
        let id = UUID()
        try original.createTask(id: id, title: "旧应用仍打开")
        XCTAssertThrowsError(try LocalLibraryUpgrade.prepare(source: source, target: target))
        XCTAssertEqual(try original.snapshots().map(\.id), [id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        try original.close()
        do {
            let writer = try StoreFileLock(url: source.appendingPathComponent("write.lock"), mode: LOCK_EX)
            defer { withExtendedLifetime(writer) {} }
            XCTAssertThrowsError(try LocalLibraryUpgrade.prepare(source: source, target: target))
        }
        let reopened = try TaskStore(directory: source)
        XCTAssertEqual(try reopened.snapshots().map(\.id), [id])
        try reopened.close()
    }

    @MainActor
    func testLocalUpgradeRecoversPreparedAndCommittedDiskStatesWithoutOverwritingNewWrites() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("TodoM0UpgradeRecovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("Local/local-isolated"), target = base.appendingPathComponent("Distribution/dist-isolated")
        let original = try TaskStore(directory: source), first = UUID(), afterPrepared = UUID(), afterCommit = UUID()
        try original.createTask(id: first, title: "原始任务")
        try original.close()
        try LocalLibraryUpgrade.prepare(source: source, target: target)
        let receiptURL = target.deletingLastPathComponent().appendingPathComponent(".dist-isolated.upgrade.json")
        let receipt = try JSONDecoder().decode(LocalLibraryUpgrade.Receipt.self, from: Data(contentsOf: receiptURL))
        let backup = source.deletingLastPathComponent().appendingPathComponent(receipt.backupName)
        // Reconstruct the on-disk state immediately before the atomic exchange.
        XCTAssertEqual(renameatx_np(AT_FDCWD, source.path, AT_FDCWD, backup.path, UInt32(RENAME_SWAP)), 0)
        let oldApp = try TaskStore(directory: source)
        try oldApp.createTask(id: afterPrepared, title: "准备后旧应用又写入")
        try oldApp.close()
        try LocalLibraryUpgrade.prepare(source: source, target: target)
        let newApp = try TaskStore(directory: target)
        XCTAssertEqual(Set(try newApp.snapshots().map(\.id)), Set([first, afterPrepared]))
        try newApp.createTask(id: afterCommit, title: "交换后新库写入")
        try newApp.close()
        // Receipt deliberately has no phase flag: the exact source alias is
        // the commit fact, including a crash immediately after the swap.
        try LocalLibraryUpgrade.prepare(source: source, target: target)
        let recovered = try TaskStore(directory: target)
        XCTAssertEqual(Set(try recovered.snapshots().map(\.id)), Set([first, afterPrepared, afterCommit]))
        try recovered.close()
        let retained = try TaskStore(directory: backup)
        XCTAssertEqual(Set(try retained.snapshots().map(\.id)), Set([first, afterPrepared]))
        try retained.close()
    }

    @MainActor
    func testLocalUpgradeAliasSharesLocksAndWidgetWritesWithTarget() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("TodoM0UpgradeAlias-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("Local/local-isolated"), target = base.appendingPathComponent("Distribution/dist-isolated")
        let original = try TaskStore(directory: source), id = UUID()
        try original.createTask(id: id, title: "同一事实源")
        try original.close()
        try LocalLibraryUpgrade.prepare(source: source, target: target)
        let oldApp = try TaskStore(directory: source), widget = try TaskStore(directory: target, isExtension: true)
        defer { try? oldApp.close(); try? widget.close() }
        try widget.setCompleted(id: id, completed: true)
        try oldApp.consumeHistory()
        XCTAssertTrue(try XCTUnwrap(oldApp.snapshots().first).isCompleted)
        do {
            let writer = try StoreFileLock(url: target.appendingPathComponent("write.lock"), mode: LOCK_EX)
            defer { withExtendedLifetime(writer) {} }
            XCTAssertThrowsError(try oldApp.updateTitle(id: id, title: "被同一把锁阻断"))
        }
        XCTAssertThrowsError(try StoreFileLock(url: target.appendingPathComponent("model.lock"), mode: LOCK_EX))
    }

    @MainActor
    func testLocalUpgradeRejectsTargetsInsideSourceThroughAnAncestorSymlink() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("TodoM0UpgradeAncestor-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: base) }
        let source = base.appendingPathComponent("Local/local-a")
        let original = try TaskStore(directory: source), id = UUID()
        try original.createTask(id: id, title: "祖先链接不能把源变成环")
        try original.close()
        let sqlite = source.appendingPathComponent("tasks.sqlite")
        let bytes = try Data(contentsOf: sqlite)
        let alias = base.appendingPathComponent("Container")
        try fm.createSymbolicLink(atPath: alias.path, withDestinationPath: source.path)
        let existing = source.appendingPathComponent("Distribution", isDirectory: true)
        try fm.createDirectory(at: existing, withIntermediateDirectories: false)
        for target in [alias, alias.appendingPathComponent("Distribution/dist-a"),
                       alias.appendingPathComponent("NotCreated/dist-a")] {
            XCTAssertThrowsError(try LocalLibraryUpgrade.prepare(source: source, target: target))
            XCTAssertEqual(try Data(contentsOf: sqlite), bytes)
            XCTAssertThrowsError(try fm.destinationOfSymbolicLink(atPath: source.path))
        }
        XCTAssertTrue(try fm.contentsOfDirectory(atPath: existing.path).isEmpty)
        XCTAssertFalse(fm.fileExists(atPath: source.appendingPathComponent("NotCreated").path))
        let reopened = try TaskStore(directory: source)
        XCTAssertEqual(try reopened.snapshots().map(\.id), [id])
        try reopened.close()
    }

    @MainActor
    func testLocalUpgradeRejectsUnownedTargetsUnknownAliasesAndInvalidReceipts() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("TodoM0UpgradeInvalid-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("Local/local-isolated"), target = base.appendingPathComponent("Distribution/dist-isolated")
        let original = try TaskStore(directory: source), existing = try TaskStore(directory: target)
        let oldID = UUID(), targetID = UUID()
        try original.createTask(id: oldID, title: "旧任务")
        try existing.createTask(id: targetID, title: "不能覆盖的新库")
        try original.close(); try existing.close()
        XCTAssertThrowsError(try LocalLibraryUpgrade.prepare(source: source, target: target))
        let retained = try TaskStore(directory: target)
        XCTAssertEqual(try retained.snapshots().map(\.id), [targetID])
        try retained.close()
        let receiptURL = target.deletingLastPathComponent().appendingPathComponent(".dist-isolated.upgrade.json")
        try Data("not a receipt".utf8).write(to: receiptURL)
        XCTAssertThrowsError(try LocalLibraryUpgrade.prepare(source: source, target: target))
        let future = LocalLibraryUpgrade.Receipt(version: 2, id: UUID(), source: source.path, target: target.path, storeUUID: "future")
        try JSONEncoder().encode(future).write(to: receiptURL)
        XCTAssertThrowsError(try LocalLibraryUpgrade.prepare(source: source, target: target))
        try FileManager.default.removeItem(at: receiptURL)
        try FileManager.default.moveItem(at: source, to: source.appendingPathExtension("retained"))
        try FileManager.default.createSymbolicLink(atPath: source.path, withDestinationPath: target.path)
        XCTAssertThrowsError(try LocalLibraryUpgrade.prepare(source: source, target: target))
    }

    @MainActor
    func testLocalCapturePerformanceBaseline() throws {
        try withStore { store in
            // Real SQLite commits on this Mac; no UI callback or network changes.
            for index in 0..<100 { try store.createTask(id: UUID(), title: "M0 性能样例 \(index)") }
            let lines = try String(contentsOf: store.directory.appendingPathComponent("events.jsonl"), encoding: .utf8).split(separator: "\n")
            let samples = try lines.compactMap { line -> Double? in
                let entry = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
                return entry?["action"] as? String == "task.create" ? entry?["milliseconds"] as? Double : nil
            }
            XCTAssertEqual(samples.count, 100)
            let warm = Array(samples.dropFirst()), sorted = warm.sorted()
            let metrics: [String: Any] = [
                "condition": "Local ad-hoc XCTest host on physical Mac; new SQLite store; 100 sequential captures; no UI callbacks; timing includes lock/refresh/save and excludes evidence append; network unchanged",
                "hostOS": ProcessInfo.processInfo.operatingSystemVersionString,
                "initialTaskCount": 0, "finalTaskCount": 100, "coldFirstMS": samples[0], "warmSampleCount": warm.count,
                "warmSamplesMS": warm, "warmP50MS": sorted[Int(ceil(Double(sorted.count) * 0.50)) - 1],
                "warmP95MS": sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1], "warmMaxMS": sorted.last!,
                "targetP95MS": 100, "targetMet": sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1] <= 100,
                "boundary": "Storage baseline only; not capture-to-visible, calendar FPS, Widget latency or cross-device sync"
            ]
            let data = try JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys])
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = "M0 Local capture storage baseline"; attachment.lifetime = .keepAlways
            add(attachment)
            print("M0_LOCAL_CAPTURE_METRICS " + String(decoding: data, as: UTF8.self))
        }
    }
}
