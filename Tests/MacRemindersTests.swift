import CoreData
import Darwin
import Foundation
import XCTest
@testable import LetsDo

@MainActor
private final class ReminderSourceStub: MacReminderSource {
    var authorized = true
    var canRequestPermission: Bool { !authorized && permissionRequests == 0 }
    var permissionRequests = 0
    let scope = MacReminderScope(sourceID: "test-account", listID: "test-inbox")
    var available = true
    var otherLists: [MacReminderList] = []
    var listReads = 0
    var sends = 0
    var updates = 0
    var removes = 0
    var createAttempts = 0
    var updateAttempts = 0
    var removeAttempts = 0
    var lastReminderDue: ReminderDue?
    var lastDue: Day? {
        if case let .day(day) = lastReminderDue { return day }
        return nil
    }
    var failCreate = false
    var failUpdate = false
    var failRemove = false
    var failFetch = false
    var unreadableScopes: Set<MacReminderScope> = []
    var failBeforeSave = false
    var failAfterSave = false

    var items: [MacReminderCandidate] = []
    var beforeFetch: (@MainActor () async -> Void)?

    func requestAccess() async throws { permissionRequests += 1; authorized = true }
    func lists() -> [MacReminderList] {
        listReads += 1
        return (available ? [.init(scope: scope, title: "收集箱", sourceTitle: "测试账户")] : []) + otherLists
    }
    func reminders(in scope: MacReminderScope, includingCompleted: Bool) async throws -> [MacReminderCandidate] {
        let fetched = items.filter { $0.scope == scope && (includingCompleted || !$0.completed) }
        await beforeFetch?()
        if failFetch || unreadableScopes.contains(scope) { throw AppError.unavailable("simulated fetch failure") }
        return fetched
    }
    func create(title: String, due: ReminderDue?, marker: URL, in scope: MacReminderScope) throws -> MacReminderCandidate {
        createAttempts += 1
        if failCreate || failBeforeSave { throw AppError.unavailable("simulated interruption before system save") }
        guard authorized, lists().contains(where: { $0.scope == scope }) else {
            throw AppError.unavailable("unwritable list")
        }
        sends += 1
        lastReminderDue = due
        let saved = item("local-\(sends)", external: "external-\(sends)", title: title, notes: "",
                         due: due, marker: marker, in: scope)
        items.append(saved)
        if failAfterSave { throw AppError.unavailable("simulated ambiguous save") }
        return saved
    }

    func update(_ localID: String, expecting scope: MacReminderScope, marker: URL?, externalID: String,
                _ patch: ReminderPatch) throws -> MacReminderCandidate {
        updateAttempts += 1
        guard !failUpdate, let index = items.firstIndex(where: { $0.id == localID }),
              authorized, lists().contains(where: { $0.scope == scope }) else {
            throw AppError.unavailable("unwritable reminder")
        }
        let old = items[index]
        guard old.scope == scope, old.externalID == externalID, old.marker == marker else {
            throw AppError.unavailable("changed reminder identity")
        }
        var saved = replacing(old, title: patch.title, completed: patch.completed)
        if let marker = patch.marker { saved.marker = marker }
        if let due = patch.due {
            lastReminderDue = due
            setDue(due, on: &saved)
        }
        items[index] = saved
        updates += 1
        return saved
    }

    func remove(_ localID: String, expecting scope: MacReminderScope, marker: URL, externalID: String) throws {
        removeAttempts += 1
        guard !failRemove, authorized, lists().contains(where: { $0.scope == scope }) else {
            throw AppError.unavailable("unwritable reminder")
        }
        guard let index = items.firstIndex(where: { $0.id == localID }) else { return }
        let old = items[index]
        guard old.scope == scope, old.marker == marker, old.externalID == externalID else {
            throw AppError.unavailable("changed reminder identity")
        }
        items.remove(at: index)
        removes += 1
    }

    private func setDue(_ due: ReminderDue?, on item: inout MacReminderCandidate) {
        switch due {
        case nil:
            item.dueLabel = nil
            item.dueDay = nil
        case .day(let day):
            item.dueLabel = day.rawValue
            item.dueDay = day
        case let .time(date, zoneID):
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: zoneID) ?? .gmt
            var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            components.timeZone = calendar.timeZone
            item.dueLabel = MacReminderCandidate.dueLabel(for: components)
            item.dueDay = Day(date: date, timeZone: calendar.timeZone)
        }
    }

    func replacing(_ item: MacReminderCandidate, title: String? = nil, completed: Bool? = nil) -> MacReminderCandidate {
        var result = MacReminderCandidate(id: item.id, externalID: item.externalID, scope: item.scope,
                                          title: title ?? item.title, notes: item.notes, completed: completed ?? item.completed)
        result.marker = item.marker
        result.dueLabel = item.dueLabel
        result.dueDay = item.dueDay
        result.recurring = item.recurring
        return result
    }

    func markCompleted(_ item: MacReminderCandidate) {
        items = items.map { $0.id == item.id ? replacing($0, completed: true) : $0 }
    }

    func current(_ id: String) -> MacReminderCandidate? { items.first { $0.id == id } }

    func item(_ local: String, external: String, title: String = "待安排", notes: String = "源备注",
              due: ReminderDue? = nil, marker: URL? = nil, recurring: Bool = false,
              in list: MacReminderScope? = nil) -> MacReminderCandidate {
        var result = MacReminderCandidate(id: local, externalID: external, scope: list ?? scope, title: title,
                                          notes: notes, completed: false, marker: marker)
        result.recurring = recurring
        setDue(due, on: &result)
        return result
    }

    func assertWrites(sends: Int, updates: Int, removes: Int,
                      failedCreates: Int = 0, failedUpdates: Int = 0, failedRemoves: Int = 0,
                      file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(self.sends, sends, "creates", file: file, line: line)
        XCTAssertEqual(self.updates, updates, "updates", file: file, line: line)
        XCTAssertEqual(self.removes, removes, "removes", file: file, line: line)
        XCTAssertEqual(createAttempts, sends + failedCreates, "create attempts", file: file, line: line)
        XCTAssertEqual(updateAttempts, updates + failedUpdates, "update attempts", file: file, line: line)
        XCTAssertEqual(removeAttempts, removes + failedRemoves, "remove attempts", file: file, line: line)
    }
}

final class MacRemindersTests: XCTestCase {
    func testDueLabelKeepsDateOnlyAndOriginalWallClock() {
        var date = DateComponents(year: 2026, month: 11, day: 11)
        XCTAssertEqual(MacReminderCandidate.dueLabel(for: date), "2026-11-11")
        date.hour = 0
        date.minute = 30
        date.timeZone = TimeZone(identifier: "America/New_York")
        XCTAssertEqual(MacReminderCandidate.dueLabel(for: date), "2026-11-11 00:30 America/New_York")
    }

    @MainActor
    private func withStore(_ test: @MainActor (TaskStore) async throws -> Void) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ReminderTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try TaskStore(directory: url)
        defer { try? store.close() }
        try await test(store)
    }

    @MainActor
    func testImportsOnlyAfterSelectionAndDoesNotReimportRenumberedOrTrashedTask() async throws {
        try await withStore { store in
            let source = ReminderSourceStub()
            let first = source.item("on-this-mac", external: "remote-1")
            source.items = [first]
            let tool = MacReminders(source: source)
            tool.attach(store)
            await tool.refresh()
            XCTAssertNil(tool.selectedListID)
            XCTAssertTrue(tool.candidates.isEmpty)
            XCTAssertEqual(source.permissionRequests, 0)
            await tool.selectList(source.scope.listID)
            XCTAssertEqual(tool.candidates, [first])
            tool.importCandidate(first)
            let task = try XCTUnwrap(store.snapshots().first)
            XCTAssertEqual(task.title, first.title)
            XCTAssertEqual(task.currentNote?.body, first.notes)
            XCTAssertEqual(task.schedule, .none)
            try store.moveToTrash(id: task.id)
            source.items = [source.item("after-full-sync", external: first.externalID)]
            let reopened = MacReminders(source: source)
            reopened.attach(store)
            await reopened.refresh()
            XCTAssertEqual(reopened.selectedListID, source.scope.listID)
            XCTAssertTrue(reopened.candidates.isEmpty)
            XCTAssertEqual(try store.snapshots().count, 1)
            XCTAssertNotNil(try XCTUnwrap(store.snapshots().first).deletedAt)
            source.assertWrites(sends: 0, updates: 0, removes: 0)
        }
    }

    @MainActor
    func testRetryOfReservationAfterTaskCommitIsIdempotent() async throws {
        try await withStore { store in
            let source = ReminderSourceStub()
            let first = source.item("local-1", external: "remote-1")
            source.items = [first]
            let tool = MacReminders(source: source)
            tool.attach(store)
            await tool.refresh()
            await tool.selectList(source.scope.listID)
            let id = try replayInterruptedImport(first, using: tool, in: store)
            let reopened = MacReminders(source: source)
            reopened.attach(store)
            await reopened.refresh()
            reopened.importCandidate(first)
            XCTAssertEqual(try store.snapshots().map(\.id), [id])
            XCTAssertTrue(reopened.candidates.isEmpty)
            source.assertWrites(sends: 0, updates: 0, removes: 0)
        }
    }

    @MainActor
    func testRejectsAmbiguityRevokedAccessMissingListAndInvalidMetadata() async throws {
        try await withStore { store in
            let source = ReminderSourceStub()
            let first = source.item("1", external: "a")
            source.items = [first, source.item("2", external: "b"), source.item("3", external: "b"),
                            source.item("4", external: "")]
            let tool = MacReminders(source: source)
            source.authorized = false
            tool.attach(store)
            await tool.refresh()
            XCTAssertEqual(source.permissionRequests, 0)
            await tool.requestPermission()
            XCTAssertEqual(source.permissionRequests, 1)
            await tool.selectList(source.scope.listID)
            XCTAssertEqual(tool.candidates, [first])
            source.authorized = false
            tool.importCandidate(first)
            source.authorized = true
            source.available = false
            tool.importCandidate(first)
            XCTAssertTrue(try store.snapshots().isEmpty)
            source.available = true
            let sidecar = store.directory.appendingPathComponent("reminders-links.json")
            let damaged = Data("invalid".utf8)
            try damaged.write(to: sidecar)
            tool.importCandidate(first)
            XCTAssertTrue(try store.snapshots().isEmpty)
            XCTAssertEqual(try Data(contentsOf: sidecar), damaged)
            source.assertWrites(sends: 0, updates: 0, removes: 0)
        }
    }

    @MainActor
    func testHandoffCanCompleteFromPreviouslySelectedListWithoutResendingOrEchoImport() async throws {
        try await withStore { store in
            let source = ReminderSourceStub()
            let other = MacReminderList(scope: .init(sourceID: "other-account", listID: "another-list"),
                                        title: "另一张清单", sourceTitle: "另一个账户")
            source.otherLists = [other]
            let tool = MacReminders(source: source)
            tool.attach(store)
            await tool.refreshIfConnected()
            XCTAssertEqual(source.listReads, 0)
            await tool.refresh()
            await tool.selectList(source.scope.listID)
            let id = UUID(), monday = try Day("2026-11-09"), due = try Day("2026-11-13")
            try store.createTask(id: id, title: "本周安排", schedule: .week(start: monday), body: "私有笔记")
            await tool.sendTask(id, due: due)
            let remote = try XCTUnwrap(source.items.first)
            XCTAssertEqual(source.lastDue, due)
            XCTAssertTrue(remote.notes.isEmpty)
            XCTAssertEqual(tool.handoffStatus(for: id), .sent)
            await tool.refresh()
            XCTAssertTrue(tool.candidates.isEmpty)
            await tool.selectList(other.id)
            source.markCompleted(remote)
            await tool.refreshIfConnected()
            let local = try XCTUnwrap(store.snapshots().first)
            XCTAssertTrue(local.isCompleted)
            XCTAssertEqual(local.schedule, .week(start: monday))
            XCTAssertEqual(local.currentNote?.body, "私有笔记")
            try store.setCompleted(id: id, completed: false)
            await tool.refresh()
            XCTAssertFalse(try XCTUnwrap(store.snapshots().first).isCompleted)
            source.items = []
            await tool.refresh()
            XCTAssertEqual(tool.handoffStatus(for: id), .needsReview)
            await tool.sendTask(id, due: nil)
            XCTAssertEqual(source.sends, 1)
            source.assertWrites(sends: 1, updates: 0, removes: 0)
        }
    }

    @MainActor
    func testAmbiguousSaveAndCopiedOrStrippedMarkerNeverDuplicateOrApplyWrongCompletion() async throws {
        try await withStore { store in
            let source = ReminderSourceStub(), id = UUID()
            let tool = MacReminders(source: source)
            tool.attach(store)
            await tool.refresh()
            await tool.selectList(source.scope.listID)
            try store.createTask(id: id, title: "仍为本机原件")
            source.failAfterSave = true
            await tool.sendTask(id, due: nil)
            let original = try XCTUnwrap(source.items.first)
            XCTAssertEqual(tool.handoffStatus(for: id), .needsReview)
            let reopened = MacReminders(source: source)
            reopened.attach(store)
            await reopened.sendTask(id, due: nil)
            XCTAssertEqual(source.sends, 1)
            await reopened.refresh()
            XCTAssertEqual(reopened.handoffStatus(for: id), .sent)
            source.markCompleted(original)
            let copy = MacReminderCandidate(id: "copy", externalID: "copy-remote", scope: source.scope,
                                            title: original.title, notes: "", completed: true, marker: original.marker)
            source.items.append(copy)
            await reopened.refresh()
            XCTAssertEqual(reopened.handoffStatus(for: id), .needsReview)
            XCTAssertFalse(try XCTUnwrap(store.snapshots().first).isCompleted)
            source.items = [copy]
            await reopened.refresh()
            XCTAssertFalse(try XCTUnwrap(store.snapshots().first).isCompleted)
            source.items = [.init(id: original.id, externalID: original.externalID, scope: original.scope,
                                  title: original.title, notes: "", completed: true)]
            await reopened.refresh()
            XCTAssertFalse(try XCTUnwrap(store.snapshots().first).isCompleted)
            XCTAssertEqual(source.sends, 1)
            source.assertWrites(sends: 1, updates: 0, removes: 0)
        }
    }

    @MainActor
    func testExplicitRetryRetainsOriginalDueAndListAndNeverRecreatesConfirmedItem() async throws {
        try await withStore { store in
            let source = ReminderSourceStub(), id = UUID(), originalDue = try Day("2026-11-22")
            let second = MacReminderList(scope: .init(sourceID: "account-B", listID: "B"),
                                        title: "第二张清单", sourceTitle: "账户 B")
            source.otherLists = [second]
            let tool = MacReminders(source: source)
            tool.attach(store)
            await tool.refresh()
            await tool.selectList(source.scope.listID)
            try store.createTask(id: id, title: "待重试的发送")
            source.failBeforeSave = true
            await tool.sendTask(id, due: originalDue)
            XCTAssertTrue(tool.canRetryHandoff(for: id))
            source.failBeforeSave = false
            await tool.selectList(second.id)
            XCTAssertEqual(tool.handoffListLabel(for: id), "测试账户 · 收集箱")
            await tool.refreshIfConnected()
            XCTAssertEqual(source.sends, 0)
            await tool.retryHandoff(id, due: nil)
            XCTAssertEqual(source.items.first?.scope, source.scope)
            XCTAssertEqual(source.lastDue, originalDue)
            XCTAssertFalse(tool.canRetryHandoff(for: id))
            let sent = try XCTUnwrap(source.items.first)
            source.items = [.init(id: sent.id, externalID: sent.externalID, scope: sent.scope,
                                  title: sent.title, notes: "", completed: false)]
            await tool.selectList(source.scope.listID)
            XCTAssertTrue(tool.candidates.isEmpty)
            XCTAssertEqual(tool.handoffStatus(for: id), .needsReview)
            source.items = []
            await tool.refresh()
            await tool.retryHandoff(id, due: nil)
            XCTAssertEqual(source.sends, 1)
            source.assertWrites(sends: 1, updates: 0, removes: 0, failedCreates: 1)
        }
    }

    @MainActor
    func testExplicitRetryFindsPreviouslyWrittenReminderWithoutSecondWrite() async throws {
        try await withStore { store in
            let source = ReminderSourceStub(), id = UUID()
            let tool = MacReminders(source: source)
            tool.attach(store)
            await tool.refresh()
            await tool.selectList(source.scope.listID)
            try store.createTask(id: id, title: "事件库已提交")
            source.failAfterSave = true
            await tool.sendTask(id, due: nil)
            let original = try XCTUnwrap(source.items.first)
            var copy = source.item("unrelated-copy", external: "copy")
            copy.marker = original.marker
            source.items.append(copy)
            await tool.retryHandoff(id, due: nil)
            XCTAssertEqual(source.sends, 1)
            XCTAssertEqual(tool.handoffStatus(for: id), .needsReview)
            source.items.removeLast()
            await tool.retryHandoff(id, due: nil)
            XCTAssertEqual(source.sends, 1)
            XCTAssertEqual(tool.handoffStatus(for: id), .sent)
            source.assertWrites(sends: 1, updates: 0, removes: 0)
        }
    }

    @MainActor
    func testRefreshInAnotherHostCannotReplayConsumedCompletion() async throws {
        try await withStore { store in
            let source = ReminderSourceStub(), id = UUID()
            let first = MacReminders(source: source), second = MacReminders(source: source)
            first.attach(store)
            await first.refresh()
            await first.selectList(source.scope.listID)
            try store.createTask(id: id, title: "保留较新的本机状态")
            await first.sendTask(id, due: nil)
            source.markCompleted(try XCTUnwrap(source.items.first))
            let secondStore = try TaskStore(directory: store.directory)
            defer { try? secondStore.close() }
            second.attach(secondStore)
            source.beforeFetch = {
                source.beforeFetch = nil
                await second.refreshIfConnected()
                do {
                    XCTAssertTrue(try XCTUnwrap(store.snapshots().first).isCompleted)
                    try store.setCompleted(id: id, completed: false)
                } catch { XCTFail(error.localizedDescription) }
            }
            await first.refreshIfConnected()
            XCTAssertFalse(try XCTUnwrap(store.snapshots().first).isCompleted)
            source.assertWrites(sends: 1, updates: 0, removes: 0)
        }
    }

    @MainActor
    func testInterruptionBeforeCompletionReceiptDoesNotRecompleteReopenedTask() async throws {
        for alreadyCompleted in [false, true] {
            try await withStore { store in
                let source = ReminderSourceStub(), id = UUID()
                let tool = MacReminders(source: source)
                tool.attach(store)
                await tool.refresh()
                await tool.selectList(source.scope.listID)
                try store.createTask(id: id, title: "不要覆盖重开")
                await tool.sendTask(id, due: nil)
                if alreadyCompleted { try store.setCompleted(id: id, completed: true) }
                source.markCompleted(try XCTUnwrap(source.items.first))
                let file = store.directory.appendingPathComponent("reminders-links.json")
                var pending = Data()
                store.onChange = { pending = (try? Data(contentsOf: file)) ?? Data() }
                await tool.refresh()
                store.onChange = nil
                XCTAssertFalse(pending.isEmpty)
                XCTAssertTrue(try XCTUnwrap(store.snapshots().first).isCompleted)
                try pending.write(to: file, options: .atomic)
                try store.setCompleted(id: id, completed: false)
                try store.consumeHistory()
                try store.close()
                let reopenedStore = try TaskStore(directory: store.directory)
                defer { try? reopenedStore.close() }
                let reopened = MacReminders(source: source)
                reopened.attach(reopenedStore)
                await reopened.refresh()
                XCTAssertFalse(try XCTUnwrap(reopenedStore.snapshots().first).isCompleted)
                source.assertWrites(sends: 1, updates: 0, removes: 0)
            }
        }
    }

    @MainActor
    func testFailedCompletionRetriesAfterUnrelatedTaskEdits() async throws {
        try await withStore { store in
            let source = ReminderSourceStub(), id = UUID()
            let tool = MacReminders(source: source)
            tool.attach(store)
            await tool.refresh()
            await tool.selectList(source.scope.listID)
            try store.createTask(id: id, title: "原标题", body: "原正文")
            await tool.sendTask(id, due: nil)
            source.markCompleted(try XCTUnwrap(source.items.first))
            do {
                let lock = try StoreFileLock(url: store.directory.appendingPathComponent("write.lock"), mode: LOCK_EX)
                defer { withExtendedLifetime(lock) {} }
                await tool.refresh()
                XCTAssertFalse(try XCTUnwrap(store.snapshots().first).isCompleted)
                XCTAssertEqual(tool.message, AppError.busy.localizedDescription)
            }
            let schedule = TaskSchedule.week(start: try Day("2026-11-09"))
            try store.updateTitle(id: id, title: "改过的标题")
            try store.scheduleTask(id: id, schedule: schedule)
            try store.saveNoteRevision(taskID: id, id: UUID(), body: "改过的正文", parentIDs: [id])
            await tool.refresh()
            let task = try XCTUnwrap(store.snapshots().first)
            XCTAssertTrue(task.isCompleted)
            XCTAssertEqual(task.title, "改过的标题")
            XCTAssertEqual(task.schedule, schedule)
            XCTAssertEqual(task.currentNote?.body, "改过的正文")
            try store.setCompleted(id: id, completed: false)
            await tool.refresh()
            XCTAssertFalse(try XCTUnwrap(store.snapshots().first).isCompleted)
            source.assertWrites(sends: 1, updates: 0, removes: 0)
        }
    }

    @MainActor
    func testLegacyInterruptedCompletionRequiresReviewWithoutConsumingOrReclosing() async throws {
        try await withStore { store in
            let source = ReminderSourceStub(), id = UUID()
            let tool = MacReminders(source: source)
            tool.attach(store)
            await tool.refresh()
            await tool.selectList(source.scope.listID)
            try store.createTask(id: id, title: "保留旧版中断状态")
            await tool.sendTask(id, due: nil)
            source.markCompleted(try XCTUnwrap(source.items.first))
            let file = store.directory.appendingPathComponent("reminders-links.json")
            var state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            var exports = try XCTUnwrap(state["exports"] as? [Any])
            let index = try XCTUnwrap(exports.firstIndex { ($0 as? String) == id.uuidString }) + 1
            var link = try XCTUnwrap(exports[index] as? [String: Any])
            link["pendingCompletionBaseline"] = try XCTUnwrap(store.snapshots().first).updatedAt.timeIntervalSinceReferenceDate
            exports[index] = link
            state["exports"] = exports
            try JSONSerialization.data(withJSONObject: state).write(to: file, options: .atomic)
            await tool.refresh()
            XCTAssertEqual(tool.handoffStatus(for: id), .needsReview)
            XCTAssertTrue(tool.message?.contains("旧版完成回收曾中断") == true)
            XCTAssertFalse(try XCTUnwrap(store.snapshots().first).isCompleted)
            try store.updateTitle(id: id, title: "只改标题")
            let reopened = MacReminders(source: source)
            reopened.attach(store)
            await reopened.refresh()
            XCTAssertEqual(reopened.handoffStatus(for: id), .needsReview)
            XCTAssertFalse(try XCTUnwrap(store.snapshots().first).isCompleted)
            let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            let savedExports = try XCTUnwrap(saved["exports"] as? [Any])
            let savedLink = try XCTUnwrap(savedExports[index] as? [String: Any])
            XCTAssertEqual(savedLink["completionApplied"] as? Bool, false)
            XCTAssertNotNil(savedLink["pendingCompletionBaseline"])
            XCTAssertNil(savedLink["pendingCompletionActionID"])
            source.assertWrites(sends: 1, updates: 0, removes: 0)
        }
    }

    @MainActor
    func testChangingStoreDuringFetchDiscardsOldListAndCandidates() async throws {
        try await withStore { old in
            try await withStore { new in
                let source = ReminderSourceStub()
                source.items = [source.item("1", external: "a")]
                let tool = MacReminders(source: source)
                tool.attach(old)
                await tool.refresh()
                source.beforeFetch = { tool.attach(new) }
                await tool.selectList(source.scope.listID)
                XCTAssertNil(tool.selectedListID)
                XCTAssertTrue(tool.candidates.isEmpty)
                XCTAssertFalse(tool.busy)
                XCTAssertTrue(try new.snapshots().isEmpty)
                source.assertWrites(sends: 0, updates: 0, removes: 0)
            }
        }
    }
}

@MainActor
extension MacRemindersTests {
    private func withList(_ test: @MainActor (TaskStore, ReminderSourceStub, MacReminders) async throws -> Void) async throws {
        try await withStore { store in
            let source = ReminderSourceStub()
            let tool = MacReminders(source: source)
            tool.attach(store)
            await tool.refresh()
            await tool.selectList(source.scope.listID)
            XCTAssertEqual(tool.selectedListID, source.scope.listID)
            XCTAssertFalse(tool.autoSync)
            try await test(store, source, tool)
        }
    }

    // Restore the sidecar exactly as it was when the task committed but the import was not yet acknowledged.
    private func replayInterruptedImport(_ item: MacReminderCandidate, using tool: MacReminders, in store: TaskStore) throws -> UUID {
        let file = store.directory.appendingPathComponent("reminders-links.json")
        var pending: Data?
        store.onChange = { pending = try? Data(contentsOf: file) }
        tool.importCandidate(item)
        store.onChange = nil
        let id = try XCTUnwrap(store.snapshots().first?.id)
        let interrupted = try XCTUnwrap(pending)
        XCTAssertFalse(interrupted.isEmpty)
        try interrupted.write(to: file, options: .atomic)
        return id
    }

    private func refreshWithoutTaskWrites(_ tool: MacReminders, store: TaskStore,
                                          file: StaticString = #filePath, line: UInt = #line) async throws {
        // A redundant completion attempt would fail with .busy even if its receipt was already consumed.
        let lock = try StoreFileLock(url: store.directory.appendingPathComponent("write.lock"), mode: LOCK_EX)
        defer { withExtendedLifetime(lock) {} }
        await tool.refresh()
        XCTAssertNil(tool.message, file: file, line: line)
    }

    private struct StoredExport: Decodable {
        struct State: Decodable {
            let title: String
            let due: ReminderDue?
            let completed: Bool
        }
        let externalID: String?
        let completionApplied: Bool
        let synced: State?
    }

    private func exports(in store: TaskStore) throws -> [UUID: StoredExport] {
        struct Links: Decodable { let exports: [UUID: StoredExport]? }
        let url = store.directory.appendingPathComponent("reminders-links.json")
        return try JSONDecoder().decode(Links.self, from: Data(contentsOf: url)).exports ?? [:]
    }

    private func record(_ id: UUID, in store: TaskStore) throws -> NSManagedObject {
        let request = NSFetchRequest<NSManagedObject>(entityName: "TaskItem")
        request.predicate = NSPredicate(format: "id == %@", id as NSUUID)
        return try XCTUnwrap(store.container?.viewContext.fetch(request).first)
    }

    private var otherList: MacReminderList {
        MacReminderList(scope: .init(sourceID: "other-account", listID: "other-list"), title: "第二清单", sourceTitle: "测试")
    }

    func testAutomaticDueUsesOnlyConcreteStartDatesAndTimes() throws {
        let source = ReminderSourceStub()
        let monday = try Day("2026-11-16")
        let start = monday.date(in: .gmt).addingTimeInterval(15 * 3600)
        XCTAssertNil(MacReminders.reminderDue(for: .none))
        XCTAssertNil(MacReminders.reminderDue(for: .week(start: monday)))
        XCTAssertEqual(MacReminders.reminderDue(for: .allDay(start: monday, endExclusive: monday.adding(days: 3))), .day(monday))
        let timed = TaskSchedule.timed(start: start, end: start.addingTimeInterval(86400), timeZoneID: "Asia/Taipei")
        let due = try XCTUnwrap(MacReminders.reminderDue(for: timed))
        XCTAssertEqual(due, .time(start, timeZoneID: "Asia/Taipei"))
        let wallClock = due.components
        XCTAssertEqual(wallClock.calendar?.identifier, .gregorian)
        XCTAssertEqual(wallClock.timeZone?.identifier, "Asia/Taipei")
        XCTAssertEqual(MacReminderCandidate.dueLabel(for: wallClock), "2026-11-16 23:00 Asia/Taipei")
        let allDay = ReminderDue.day(monday).components
        XCTAssertEqual(allDay.calendar?.timeZone.secondsFromGMT(), 0)
        XCTAssertNil(allDay.hour)
        XCTAssertEqual(MacReminderCandidate.dueLabel(for: allDay), monday.rawValue)
        source.assertWrites(sends: 0, updates: 0, removes: 0)
    }

    func testEnableBackfillsOnlyActiveTasksThenPicksUpNewTaskOnce() async throws {
        try await withList { store, source, tool in
            let completed = UUID(), trashed = UUID()
            let active = [UUID(), UUID(), UUID()]
            for id in active + [completed, trashed] { try store.createTask(id: id, title: id.uuidString) }
            try store.setCompleted(id: completed, completed: true)
            try store.moveToTrash(id: trashed)
            let preview = tool.syncPreview()
            XCTAssertEqual(preview.push, 3)
            XCTAssertEqual(preview.importCount, 0)

            await tool.setAutoSync(true)
            XCTAssertTrue(tool.autoSync)
            XCTAssertEqual(Set(source.items.compactMap(\.marker)), Set(active.map { AppDestination.task($0).url }))
            XCTAssertEqual(tool.syncSummary.synced, 3)
            XCTAssertEqual(tool.syncSummary.needsReview, 0)
            source.assertWrites(sends: 3, updates: 0, removes: 0)
            await tool.refresh()
            await tool.refresh()
            source.assertWrites(sends: 3, updates: 0, removes: 0)

            let newID = UUID()
            try store.createTask(id: newID, title: "后来新建")
            await tool.refresh()
            XCTAssertEqual(tool.handoffStatus(for: newID), .sent)
            await tool.refresh()
            source.assertWrites(sends: 4, updates: 0, removes: 0)
        }
    }

    func testOnlyChangedMacFieldsOverwriteAPhoneEdit() async throws {
        try await withList { store, source, tool in
            let id = UUID(), day = try Day("2026-11-20")
            try store.createTask(id: id, title: "原名")
            await tool.setAutoSync(true)
            try store.updateTitle(id: id, title: "Mac 改名")
            await tool.refresh()
            let sent = try XCTUnwrap(source.items.first)
            XCTAssertEqual(sent.title, "Mac 改名")
            source.assertWrites(sends: 1, updates: 1, removes: 0)

            let phone = source.item(sent.id, external: sent.externalID, title: "手机改名", notes: "",
                                    due: .day(day), marker: sent.marker)
            source.items = [phone]
            await tool.refresh()
            XCTAssertEqual(source.items, [phone])
            let local = try XCTUnwrap(store.snapshots().first)
            XCTAssertEqual(local.title, "Mac 改名")
            XCTAssertEqual(local.schedule, .none)
            source.assertWrites(sends: 1, updates: 1, removes: 0)

            try store.updateTitle(id: id, title: "Mac 再改名")
            await tool.refresh()
            XCTAssertEqual(source.items.first?.title, "Mac 再改名")
            XCTAssertEqual(source.items.first?.dueDay, day)
            source.assertWrites(sends: 1, updates: 2, removes: 0)
        }
    }

    func testAutomaticSchedulePatchesSetTimedAndClearDue() async throws {
        try await withList { store, source, tool in
            let id = UUID(), monday = try Day("2026-11-16")
            let time = monday.date(in: .gmt).addingTimeInterval(22 * 3600)
            try store.createTask(id: id, title: "改安排")
            await tool.setAutoSync(true)
            XCTAssertNil(try XCTUnwrap(source.items.first).dueDay)
            source.assertWrites(sends: 1, updates: 0, removes: 0)
            let schedules: [(TaskSchedule, ReminderDue?)] = [
                (.allDay(start: monday, endExclusive: monday.adding(days: 2)), .day(monday)),
                (.timed(start: time, end: time.addingTimeInterval(3600), timeZoneID: "Asia/Taipei"),
                 .time(time, timeZoneID: "Asia/Taipei")),
                (.week(start: monday), nil)
            ]
            for (index, pair) in schedules.enumerated() {
                try store.scheduleTask(id: id, schedule: pair.0)
                await tool.refresh()
                XCTAssertEqual(source.lastReminderDue, pair.1)
                source.assertWrites(sends: 1, updates: index + 1, removes: 0)
            }
            XCTAssertNil(try XCTUnwrap(source.items.first).dueLabel)
            await tool.refresh()
            source.assertWrites(sends: 1, updates: 3, removes: 0)
        }
    }

    func testMacCompletionAndReopenResetReceiptForNextPhoneCompletion() async throws {
        try await withList { store, source, tool in
            let id = UUID()
            try store.createTask(id: id, title: "两端完成")
            await tool.setAutoSync(true)
            try store.setCompleted(id: id, completed: true)
            await tool.refresh()
            XCTAssertTrue(try XCTUnwrap(source.items.first).completed)
            XCTAssertTrue(try XCTUnwrap(exports(in: store)[id]).completionApplied)
            source.assertWrites(sends: 1, updates: 1, removes: 0)

            try await refreshWithoutTaskWrites(tool, store: store)
            try store.setCompleted(id: id, completed: false)
            await tool.refresh()
            let open = try XCTUnwrap(source.items.first)
            XCTAssertFalse(open.completed)
            XCTAssertFalse(try XCTUnwrap(exports(in: store)[id]).completionApplied)
            source.assertWrites(sends: 1, updates: 2, removes: 0)

            source.markCompleted(open)
            await tool.refresh()
            XCTAssertTrue(try XCTUnwrap(store.snapshots().first).isCompleted)
            XCTAssertEqual(try exports(in: store)[id]?.synced?.completed, true)
            source.assertWrites(sends: 1, updates: 2, removes: 0)
        }
    }

    func testPhoneCompletionIsPulledOnceAndPhoneReopenIsIgnored() async throws {
        try await withList { store, source, tool in
            let id = UUID()
            try store.createTask(id: id, title: "手机上勾选")
            await tool.setAutoSync(true)
            source.markCompleted(try XCTUnwrap(source.items.first))
            await tool.refresh()
            XCTAssertTrue(try XCTUnwrap(store.snapshots().first).isCompleted)
            try await refreshWithoutTaskWrites(tool, store: store)
            XCTAssertTrue(try XCTUnwrap(source.items.first).completed)
            source.assertWrites(sends: 1, updates: 0, removes: 0)

            source.items = [source.replacing(try XCTUnwrap(source.items.first), completed: false)]
            try await refreshWithoutTaskWrites(tool, store: store)
            XCTAssertTrue(try XCTUnwrap(store.snapshots().first).isCompleted)
            XCTAssertFalse(try XCTUnwrap(source.items.first).completed)
            source.assertWrites(sends: 1, updates: 0, removes: 0)
        }
    }

    func testTrashingRemovesVerifiedReminderAndRestoringCreatesOnce() async throws {
        try await withList { store, source, tool in
            let id = UUID()
            try store.createTask(id: id, title: "恢复任务")
            await tool.setAutoSync(true)
            let original = try XCTUnwrap(source.items.first)
            try store.moveToTrash(id: id)
            await tool.refresh()
            XCTAssertTrue(source.items.isEmpty)
            XCTAssertNil(try exports(in: store)[id])
            source.assertWrites(sends: 1, updates: 0, removes: 1)
            try store.restoreTask(id: id)
            await tool.refresh()
            await tool.refresh()
            let restored = try XCTUnwrap(source.items.first)
            XCTAssertNotEqual(restored.externalID, original.externalID)
            XCTAssertEqual(restored.marker, original.marker)
            source.assertWrites(sends: 2, updates: 0, removes: 1)
        }
    }
}

@MainActor
extension MacRemindersTests {
    func testMissingTaskRequiresReviewAndKeepsReminder() async throws {
        try await withList { store, source, tool in
            let id = UUID()
            try store.createTask(id: id, title: "本机记录尚未读到")
            await tool.setAutoSync(true)
            XCTAssertFalse(tool.syncNeedsAttention)
            source.authorized = false
            await tool.refresh()
            XCTAssertTrue(tool.autoSync)
            XCTAssertTrue(tool.syncNeedsAttention)
            source.authorized = true
            await tool.refresh()
            XCTAssertFalse(tool.syncNeedsAttention)
            let reminder = try XCTUnwrap(source.items.first)
            let context = try XCTUnwrap(store.container).viewContext
            context.delete(try record(id, in: store))
            try context.save()
            await tool.refresh()
            XCTAssertEqual(tool.handoffStatus(for: id), .needsReview)
            XCTAssertEqual(tool.syncSummary.needsReview, 1)
            XCTAssertTrue(tool.syncNeedsAttention)
            XCTAssertEqual(source.items, [reminder])
            source.assertWrites(sends: 1, updates: 0, removes: 0)
        }
    }

    func testUnreadableTaskInSameListDoesNotBlockHealthyCompletionOrDeleteItsReminder() async throws {
        try await withList { store, source, tool in
            let broken = UUID(), healthy = UUID()
            try store.createTask(id: broken, title: "损坏的计划")
            try store.createTask(id: healthy, title: "正常任务")
            await tool.setAutoSync(true)
            try store.moveToTrash(id: broken)
            try record(broken, in: store).setValue("invalid", forKey: "scheduleJSON")
            try XCTUnwrap(store.container).viewContext.save()
            let read = try store.readableSnapshots()
            XCTAssertEqual(read.unreadableIDs, [broken])
            let healthyItem = try XCTUnwrap(source.items.first { $0.marker == AppDestination.task(healthy).url })
            source.markCompleted(healthyItem)
            await tool.refresh()
            XCTAssertEqual(try store.readableSnapshots().tasks.first { $0.id == healthy }?.isCompleted, true)
            XCTAssertNotNil(try exports(in: store)[broken])
            source.assertWrites(sends: 2, updates: 0, removes: 0)
        }
    }

    func testAmbiguousMarkerAndCopiedMarkerCannotUpdateOrDelete() async throws {
        for keepOriginal in [true, false] {
            try await withList { store, source, tool in
                let id = UUID()
                try store.createTask(id: id, title: "源任务")
                await tool.setAutoSync(true)
                let original = try XCTUnwrap(source.items.first)
                let copy = source.item("copy", external: "copy-external", marker: original.marker)
                source.items = keepOriginal ? [original, copy] : [copy]
                try store.updateTitle(id: id, title: "只改本机")
                await tool.refresh()
                XCTAssertEqual(tool.handoffStatus(for: id), .needsReview)
                source.assertWrites(sends: 1, updates: 0, removes: 0)
                try store.moveToTrash(id: id)
                await tool.refresh()
                XCTAssertEqual(source.items, keepOriginal ? [original, copy] : [copy])
                XCTAssertNotNil(try exports(in: store)[id])
                source.assertWrites(sends: 1, updates: 0, removes: 0)
            }
        }
    }

    func testPreviewExcludesUnconfirmedImportWhoseTaskIsAlreadyPresentOrUnreadable() async throws {
        try await withList { store, source, tool in
            let phone = source.item("phone", external: "phone")
            source.items = [phone]
            await tool.refresh()
            XCTAssertEqual(tool.syncPreview().importCount, 1)
            let id = try replayInterruptedImport(phone, using: tool, in: store)
            let reopened = MacReminders(source: source)
            reopened.attach(store)
            await reopened.refresh(forPreview: true)
            XCTAssertEqual(reopened.syncPreview().importCount, 0)
            XCTAssertEqual(try store.readableSnapshots().tasks.map(\.id), [id])

            try record(id, in: store).setValue("invalid", forKey: "scheduleJSON")
            try XCTUnwrap(store.container).viewContext.save()
            await reopened.refresh(forPreview: true)
            XCTAssertEqual(try store.readableSnapshots().unreadableIDs, [id])
            XCTAssertEqual(reopened.syncPreview().importCount, 0)
            source.assertWrites(sends: 0, updates: 0, removes: 0)
        }
    }

    func testCannotResetLinkIntoNewListWhileOriginalListCannotBeRead() async throws {
        try await withList { store, source, tool in
            let id = UUID()
            source.otherLists = [otherList]
            try store.createTask(id: id, title: "留在原清单")
            await tool.setAutoSync(true)
            let original = try XCTUnwrap(source.items.first)
            source.items = []
            await tool.refresh()
            XCTAssertEqual(tool.handoffStatus(for: id), .needsReview)

            // The reminder may have returned while the original list was inaccessible.
            source.items = [original]
            source.unreadableScopes = [source.scope]
            await tool.selectList(otherList.id)
            await tool.setAutoSync(true)
            XCTAssertEqual(tool.selectedListID, otherList.id)
            XCTAssertTrue(tool.autoSync)
            for originalListAvailable in [true, false] {
                source.available = originalListAvailable
                await tool.refresh()
                XCTAssertFalse(tool.canResetHandoff(for: id))
                await tool.resetHandoff(id)
                XCTAssertEqual(try exports(in: store)[id]?.externalID, original.externalID)
                XCTAssertEqual(source.items, [original])
                source.assertWrites(sends: 1, updates: 0, removes: 0)
            }
        }
    }

    func testStaleEmptyFetchCannotDiscardAnotherHostsReplacementLinkWhenTaskIsTrashed() async throws {
        try await withList { store, source, first in
            let id = UUID()
            try store.createTask(id: id, title: "别的实例稍后重建")
            await first.setAutoSync(true)
            let original = try XCTUnwrap(source.items.first)
            source.items = []
            await first.refresh()
            let secondStore = try TaskStore(directory: store.directory)
            defer { try? secondStore.close() }
            let second = MacReminders(source: source)
            second.attach(secondStore)
            await second.refresh()
            XCTAssertTrue(second.canResetHandoff(for: id))
            source.beforeFetch = {
                // The first host has already captured an empty list. Replace the export before it resumes.
                source.beforeFetch = nil
                await second.resetHandoff(id)
                XCTAssertEqual(second.handoffStatus(for: id), .sent)
                do { try secondStore.moveToTrash(id: id) }
                catch { XCTFail(error.localizedDescription) }
            }
            await first.refresh()
            let replacement = try XCTUnwrap(source.items.first)
            XCTAssertNotEqual(original.externalID, replacement.externalID)
            XCTAssertEqual(try exports(in: store)[id]?.externalID, replacement.externalID)
            XCTAssertEqual(first.handoffStatus(for: id), .sent)
            source.assertWrites(sends: 2, updates: 0, removes: 0)
            await first.refresh()
            XCTAssertNil(try exports(in: store)[id])
            XCTAssertTrue(source.items.isEmpty)
            source.assertWrites(sends: 2, updates: 0, removes: 1)
        }
    }

    func testFailedSelectedListFetchSkipsImportsAndPushAndKeepsConfirmedState() async throws {
        try await withList { store, source, tool in
            let linked = UUID(), new = UUID()
            try store.createTask(id: linked, title: "原关联")
            await tool.setAutoSync(true)
            source.failFetch = true
            source.items.append(source.item("phone", external: "phone-external"))
            try store.createTask(id: new, title: "尚未发送")
            try store.updateTitle(id: linked, title: "下次再写")
            await tool.refresh()
            XCTAssertEqual(tool.handoffStatus(for: linked), .sent)
            XCTAssertEqual(tool.handoffStatus(for: new), .notSent)
            XCTAssertEqual(try store.snapshots().count, 2)
            XCTAssertNotNil(tool.message)
            source.assertWrites(sends: 1, updates: 0, removes: 0)
        }
    }

    func testChangingOrClearingSelectedListPausesBeforeAnyImport() async throws {
        for clearSelection in [false, true] {
            try await withList { store, source, tool in
                source.otherLists = [otherList]
                source.items = [source.item("other", external: "other-external", in: otherList.scope)]
                await tool.setAutoSync(true)
                XCTAssertTrue(tool.autoSync)
                await tool.selectList(clearSelection ? nil : otherList.id)
                XCTAssertFalse(tool.autoSync)
                XCTAssertNotNil(tool.message)
                let reopened = MacReminders(source: source)
                reopened.attach(store)
                await reopened.refresh()
                XCTAssertFalse(reopened.autoSync)
                XCTAssertTrue(try store.snapshots().isEmpty)
                source.assertWrites(sends: 0, updates: 0, removes: 0)
            }
        }
    }

    func testSecondHostEnablingDuringFetchCannotDuplicateWrites() async throws {
        try await withList { store, source, first in
            let ids = [UUID(), UUID(), UUID()]
            for id in ids { try store.createTask(id: id, title: id.uuidString) }
            let secondStore = try TaskStore(directory: store.directory)
            defer { try? secondStore.close() }
            let second = MacReminders(source: source)
            second.attach(secondStore)
            source.beforeFetch = {
                source.beforeFetch = nil
                await second.setAutoSync(true)
            }
            await first.setAutoSync(true)
            await second.refresh()
            await first.refresh()
            XCTAssertTrue(first.autoSync)
            XCTAssertTrue(second.autoSync)
            XCTAssertEqual(Set(source.items.compactMap(\.marker)), Set(ids.map { AppDestination.task($0).url }))
            XCTAssertTrue(ids.allSatisfy { first.handoffStatus(for: $0) == .sent })
            source.assertWrites(sends: ids.count, updates: 0, removes: 0)
        }
    }

    func testDisablingDuringFetchCancelsImportsAndPushInThatPass() async throws {
        try await withList { store, source, tool in
            await tool.setAutoSync(true)
            source.items = [source.item("phone", external: "phone")]
            let id = UUID()
            try store.createTask(id: id, title: "留在本机")
            source.beforeFetch = {
                source.beforeFetch = nil
                await tool.setAutoSync(false)
            }
            await tool.refresh()
            XCTAssertFalse(tool.autoSync)
            XCTAssertEqual(try store.snapshots().map(\.id), [id])
            XCTAssertNil(source.items.first?.marker)
            XCTAssertTrue(try exports(in: store).isEmpty)
            source.assertWrites(sends: 0, updates: 0, removes: 0)
        }
    }

    func testSwitchingStoresDuringAutomaticFetchDiscardsBothDirections() async throws {
        try await withList { old, source, tool in
            try await withStore { new in
                await tool.setAutoSync(true)
                let oldID = UUID(), newID = UUID()
                try old.createTask(id: oldID, title: "旧库任务")
                try new.createTask(id: newID, title: "新库任务")
                source.items = [source.item("phone", external: "phone")]
                source.beforeFetch = {
                    source.beforeFetch = nil
                    tool.attach(new)
                }
                await tool.refresh()
                XCTAssertFalse(tool.autoSync)
                XCTAssertNil(tool.selectedListID)
                XCTAssertEqual(try old.snapshots().map(\.id), [oldID])
                XCTAssertEqual(try new.snapshots().map(\.id), [newID])
                XCTAssertTrue(try exports(in: old).isEmpty)
                XCTAssertFalse(FileManager.default.fileExists(atPath: new.directory.appendingPathComponent("reminders-links.json").path))
                source.assertWrites(sends: 0, updates: 0, removes: 0)
            }
        }
    }

    func testLegacySidecarWithoutSyncFieldsAttachesAndPullsCompletion() async throws {
        try await withStore { store in
            let source = ReminderSourceStub(), id = UUID()
            let marker = AppDestination.task(id).url
            let scope: [String: String] = ["sourceID": source.scope.sourceID, "listID": source.scope.listID]
            let oldExport: [String: Any] = ["scope": scope, "marker": marker.absoluteString, "status": "sent",
                                            "externalID": "legacy", "completionApplied": false]
            let legacy: [String: Any] = ["selected": scope, "imports": [], "exports": [id.uuidString, oldExport] as [Any]]
            let url = store.directory.appendingPathComponent("reminders-links.json")
            try JSONSerialization.data(withJSONObject: legacy).write(to: url, options: .atomic)
            try store.createTask(id: id, title: "旧记录")
            source.items = [source.replacing(source.item("phone", external: "legacy", marker: marker), completed: true)]
            let tool = MacReminders(source: source)
            tool.attach(store)
            XCTAssertFalse(tool.autoSync)
            XCTAssertEqual(tool.handoffStatus(for: id), .sent)
            await tool.refresh()
            XCTAssertFalse(tool.autoSync)
            XCTAssertTrue(try XCTUnwrap(store.snapshots().first).isCompleted)
            XCTAssertEqual(tool.selectedListID, source.scope.listID)
            source.assertWrites(sends: 0, updates: 0, removes: 0)
        }
    }
}

@MainActor
extension MacRemindersTests {
    func testPreviouslyImportedReminderIsAdoptedWithItsOriginalDue() async throws {
        try await withList { store, source, tool in
            let due = ReminderDue.day(try Day("2026-11-20"))
            let item = source.item("original", external: "original-external", due: due)
            source.items = [item]
            await tool.refresh()
            tool.importCandidate(item)
            let task = try XCTUnwrap(store.snapshots().first)
            XCTAssertEqual(task.schedule, .none)
            await tool.setAutoSync(true)
            XCTAssertEqual(tool.handoffStatus(for: task.id), .sent)
            XCTAssertEqual(source.items.first?.marker, AppDestination.task(task.id).url)
            XCTAssertEqual(source.items.first?.dueLabel, item.dueLabel)
            await tool.refresh()
            source.assertWrites(sends: 0, updates: 1, removes: 0)
        }
    }

    func testMissingOrCompletedImportOriginalCreatesOneReplacement() async throws {
        for originalIsMissing in [false, true] {
            try await withList { store, source, tool in
                let item = source.item("original", external: "original-external")
                source.items = [item]
                await tool.refresh()
                tool.importCandidate(item)
                let id = try XCTUnwrap(store.snapshots().first?.id)
                source.items = originalIsMissing ? [] : [source.replacing(item, completed: true)]
                await tool.setAutoSync(true)
                await tool.refresh()
                XCTAssertFalse(try XCTUnwrap(store.snapshots().first).isCompleted)
                XCTAssertTrue(source.items.contains { $0.marker == AppDestination.task(id).url && !$0.completed })
                XCTAssertNotEqual(try XCTUnwrap(exports(in: store)[id]).externalID, item.externalID)
                source.assertWrites(sends: 1, updates: 0, removes: 0)
            }
        }
    }

    func testImportedExternalLinkOrDuplicateExternalIdentityIsLeftAlone() async throws {
        for ambiguous in [false, true] {
            try await withList { store, source, tool in
                let externalURL = try XCTUnwrap(URL(string: "https://example.invalid/source"))
                let item = source.item("original", external: "external", marker: ambiguous ? nil : externalURL)
                source.items = [item]
                await tool.refresh()
                tool.importCandidate(item)
                if ambiguous { source.items.append(source.item("other", external: item.externalID)) }
                let originals = source.items
                await tool.setAutoSync(true)
                let task = try XCTUnwrap(store.snapshots().first)
                XCTAssertEqual(tool.handoffStatus(for: task.id), .notSent)
                XCTAssertEqual(tool.syncSummary.unlinked, 1)
                XCTAssertEqual(source.items, originals)
                source.assertWrites(sends: 0, updates: 0, removes: 0)
            }
        }
    }

    func testLinkedReminderConvertedToASeriesIsNeverUpdatedOrDeleted() async throws {
        try await withList { store, source, tool in
            let id = UUID()
            try store.createTask(id: id, title: "原提醒")
            await tool.setAutoSync(true)
            var series = try XCTUnwrap(source.items.first)
            series.recurring = true
            source.items = [series]
            try store.updateTitle(id: id, title: "仅本机改名")
            await tool.refresh()
            XCTAssertEqual(source.items, [series])
            source.assertWrites(sends: 1, updates: 0, removes: 0)
            try store.moveToTrash(id: id)
            await tool.refresh()
            XCTAssertEqual(source.items, [series])
            source.assertWrites(sends: 1, updates: 0, removes: 0)
        }
    }

    func testOversizedNoteExcludedFromPreviewAndNeighborStillImports() async throws {
        try await withList { store, source, tool in
            let oversized = source.item("oversized", external: "oversized", title: "A",
                                        notes: String(repeating: "a", count: 1_000_001))
            let regular = source.item("regular", external: "regular", title: "B")
            source.items = [oversized, regular]
            await tool.refresh()
            XCTAssertEqual(tool.syncPreview().importCount, 1)
            await tool.setAutoSync(true)
            let tasks = try store.snapshots()
            XCTAssertEqual(tasks.map(\.title), [regular.title])
            let id = try XCTUnwrap(tasks.first?.id)
            XCTAssertEqual(source.current(regular.id)?.marker, AppDestination.task(id).url)
            XCTAssertNil(source.current(oversized.id)?.marker)
            XCTAssertNotNil(tool.message)
            await tool.refresh()
            source.assertWrites(sends: 0, updates: 1, removes: 0)
        }
    }

    func testInterruptedAdoptionRecoversAlreadyWrittenMarker() async throws {
        try await withList { store, source, tool in
            let original = source.item("original", external: "external")
            source.items = [original]
            await tool.refresh()
            tool.importCandidate(original)
            let id = try XCTUnwrap(store.snapshots().first?.id)
            source.items[0].marker = AppDestination.task(id).url
            await tool.setAutoSync(true)
            XCTAssertEqual(try exports(in: store)[id]?.externalID, original.externalID)
            XCTAssertEqual(tool.handoffStatus(for: id), .sent)
            await tool.refresh()
            source.assertWrites(sends: 0, updates: 0, removes: 0)
        }
    }

    func testImportedTaskWaitsForItsOriginalListAndAdoptsThere() async throws {
        try await withList { store, source, tool in
            source.otherLists = [otherList]
            let original = source.item("from-A", external: "original")
            source.items = [original]
            await tool.refresh()
            tool.importCandidate(original)
            let id = try XCTUnwrap(store.snapshots().first?.id)
            await tool.selectList(otherList.id)
            source.unreadableScopes = [source.scope]
            await tool.setAutoSync(true)
            XCTAssertEqual(tool.handoffStatus(for: id), .notSent)
            source.assertWrites(sends: 0, updates: 0, removes: 0)
            source.unreadableScopes = []
            await tool.refresh()
            XCTAssertEqual(tool.handoffStatus(for: id), .sent)
            XCTAssertEqual(source.items.first?.scope, source.scope)
            XCTAssertEqual(source.items.first?.marker, AppDestination.task(id).url)
            XCTAssertEqual(tool.handoffListLabel(for: id), "测试账户 · 收集箱")
            source.assertWrites(sends: 0, updates: 1, removes: 0)
        }
    }

    func testSinglePreexistingTaskMarkerRecoversLostExportEvenWhenCompleted() async throws {
        for completed in [false, true] {
            try await withList { store, source, tool in
                let id = UUID()
                try store.createTask(id: id, title: "已在手机")
                let original = source.item("original", external: "external", title: "已在手机", marker: AppDestination.task(id).url)
                source.items = [source.replacing(original, completed: completed)]
                await tool.setAutoSync(true)
                XCTAssertEqual(try exports(in: store)[id]?.externalID, original.externalID)
                await tool.refresh()
                XCTAssertEqual(try XCTUnwrap(store.snapshots().first).isCompleted, completed)
                source.assertWrites(sends: 0, updates: 0, removes: 0)
            }
        }
    }

    func testAutomaticImportMapsLocalDaySkipsLinksAndRecurrencesAndKeepsTimeUntilRescheduled() async throws {
        try await withList { store, source, tool in
            let day = try Day("2026-11-20"), zone = try XCTUnwrap(TimeZone(identifier: "Pacific/Pago_Pago"))
            let start = day.date(in: zone).addingTimeInterval(14 * 3600)
            let dated = source.item("dated", external: "a", title: "有时刻", due: .time(start, timeZoneID: zone.identifier))
            let undated = source.item("undated", external: "b", title: "无日期")
            let linked = source.item("linked", external: "c", marker: try XCTUnwrap(URL(string: "https://example.invalid/item")))
            let recurring = source.item("recurring", external: "d", recurring: true)
            source.items = [dated, undated, linked, recurring]
            await tool.refresh()
            let preview = tool.syncPreview()
            XCTAssertEqual(preview.push, 0)
            XCTAssertEqual(preview.importCount, 2)
            await tool.setAutoSync(true)
            let tasks = try store.snapshots()
            XCTAssertEqual(tasks.count, 2)
            let withDate = try XCTUnwrap(tasks.first { $0.title == dated.title })
            let withoutDate = try XCTUnwrap(tasks.first { $0.title == undated.title })
            XCTAssertEqual(withDate.schedule, .allDay(start: day, endExclusive: day.adding(days: 1)))
            XCTAssertEqual(withoutDate.schedule, .none)
            XCTAssertEqual(withDate.currentNote?.body, dated.notes)
            XCTAssertEqual(source.current(dated.id)?.marker, AppDestination.task(withDate.id).url)
            XCTAssertEqual(source.current(undated.id)?.marker, AppDestination.task(withoutDate.id).url)
            XCTAssertEqual(source.current(dated.id)?.dueLabel, dated.dueLabel)
            XCTAssertEqual(tool.syncSummary.synced, 2)
            XCTAssertEqual(tool.syncSummary.unlinked, 2)
            XCTAssertEqual(Set(tool.candidates.map(\.id)), [linked.id, recurring.id])
            source.assertWrites(sends: 0, updates: 2, removes: 0)
            await tool.refresh()
            await tool.refresh()
            XCTAssertEqual(Set(try store.snapshots().map(\.id)), Set(tasks.map(\.id)))
            XCTAssertEqual(source.current(dated.id)?.dueLabel, dated.dueLabel)
            source.assertWrites(sends: 0, updates: 2, removes: 0)

            let next = day.adding(days: 1)
            try store.scheduleTask(id: withDate.id, schedule: .allDay(start: next, endExclusive: next.adding(days: 1)))
            await tool.refresh()
            XCTAssertEqual(source.current(dated.id)?.dueLabel, next.rawValue)
            XCTAssertEqual(source.current(linked.id), linked)
            XCTAssertEqual(source.current(recurring.id), recurring)
            source.assertWrites(sends: 0, updates: 3, removes: 0)
        }
    }

    func testAutomaticImportHandlesMaximumDayAndInvalidTitleWithoutBlockingOthers() async throws {
        try await withList { store, source, tool in
            let day = try Day("9999-12-31")
            let valid = source.item("max-day", external: "max-day", title: "最大日期", due: .day(day))
            let empty = source.item("blank-title", external: "blank-title", title: "   ")
            source.items = [empty, valid]
            await tool.setAutoSync(true)
            let tasks = try store.snapshots()
            XCTAssertEqual(tasks.count, 1)
            XCTAssertEqual(tasks.first?.title, valid.title)
            XCTAssertEqual(try XCTUnwrap(tasks.first).schedule, .none)
            XCTAssertEqual(source.current(valid.id)?.dueDay, day)
            XCTAssertNil(source.current(empty.id)?.marker)
            XCTAssertNotNil(tool.message)
            source.assertWrites(sends: 0, updates: 1, removes: 0)
        }
    }

    func testImmediatelyTrashingAnAutomaticImportDeletesOriginalAndPreventsReimportAfterRelaunch() async throws {
        try await withList { store, source, tool in
            let original = source.item("phone", external: "phone-external")
            source.items = [original]
            await tool.setAutoSync(true)
            let id = try XCTUnwrap(store.snapshots().first?.id)
            XCTAssertEqual(try exports(in: store)[id]?.externalID, original.externalID)
            try store.moveToTrash(id: id)
            await tool.refresh()
            XCTAssertTrue(source.items.isEmpty)
            XCTAssertNil(try exports(in: store)[id])
            let reopened = MacReminders(source: source)
            reopened.attach(store)
            await reopened.refresh()
            let tasks = try store.snapshots()
            XCTAssertEqual(tasks.map(\.id), [id])
            XCTAssertNotNil(tasks.first?.deletedAt)
            source.assertWrites(sends: 0, updates: 1, removes: 1)
        }
    }

    func testManualImportOfRecurringReminderOnlyCopiesTaskWithoutWritingSeries() async throws {
        try await withList { store, source, tool in
            let day = try Day("2026-11-20")
            let recurring = source.item("series", external: "series", due: .day(day), recurring: true)
            source.items = [recurring]
            await tool.setAutoSync(true)
            XCTAssertEqual(tool.candidates, [recurring])
            tool.importCandidate(recurring)
            let task = try XCTUnwrap(store.snapshots().first)
            XCTAssertEqual(task.schedule, .none)
            await tool.refresh()
            try store.updateTitle(id: task.id, title: "单独的本机任务")
            try store.setCompleted(id: task.id, completed: true)
            await tool.refresh()
            try store.moveToTrash(id: task.id)
            await tool.refresh()
            XCTAssertEqual(source.items, [recurring])
            XCTAssertEqual(tool.handoffStatus(for: task.id), .notSent)
            source.assertWrites(sends: 0, updates: 0, removes: 0)
        }
    }
}

@MainActor
extension MacRemindersTests {
    func testOldManualSendPushesChangedTitleAndCompletionWhilePreservingChosenDue() async throws {
        try await withList { store, source, tool in
            let id = UUID(), chosen = try Day("2026-11-24"), start = try Day("2026-11-19")
            try store.createTask(id: id, title: "手动发送", schedule: .allDay(start: start, endExclusive: start.adding(days: 2)))
            await tool.sendTask(id, due: chosen)
            try store.updateTitle(id: id, title: "已改名")
            try store.setCompleted(id: id, completed: true)
            await tool.setAutoSync(true)
            let updated = try XCTUnwrap(source.items.first)
            XCTAssertEqual(updated.title, "已改名")
            XCTAssertTrue(updated.completed)
            XCTAssertEqual(updated.dueDay, chosen)
            let link = try XCTUnwrap(exports(in: store)[id])
            XCTAssertEqual(link.synced?.due, .day(start))
            XCTAssertEqual(link.synced?.completed, true)
            XCTAssertTrue(link.completionApplied)
            await tool.refresh()
            source.assertWrites(sends: 1, updates: 1, removes: 0)
        }
    }

    func testOldManualSendTrashedBeforeEnableLeavesReminderAndDropsExport() async throws {
        try await withList { store, source, tool in
            let id = UUID()
            try store.createTask(id: id, title: "旧手动项")
            await tool.sendTask(id, due: nil)
            let old = try XCTUnwrap(source.items.first)
            try store.moveToTrash(id: id)
            await tool.setAutoSync(true)
            XCTAssertEqual(source.items, [old])
            XCTAssertEqual(tool.handoffStatus(for: id), .notSent)
            XCTAssertNil(try exports(in: store)[id])
            source.assertWrites(sends: 1, updates: 0, removes: 0)
        }
    }

    func testFailedUpdateKeepsBaselineAndRetriesExactlyOnce() async throws {
        try await withList { store, source, tool in
            let id = UUID()
            try store.createTask(id: id, title: "已写入")
            await tool.setAutoSync(true)
            try store.updateTitle(id: id, title: "待重试")
            source.failUpdate = true
            await tool.refresh()
            XCTAssertEqual(try exports(in: store)[id]?.synced?.title, "已写入")
            XCTAssertEqual(tool.handoffStatus(for: id), .needsReview)
            XCTAssertNotNil(tool.message)
            XCTAssertEqual(source.items.first?.title, "已写入")
            source.assertWrites(sends: 1, updates: 0, removes: 0, failedUpdates: 1)

            source.failUpdate = false
            await tool.refresh()
            XCTAssertEqual(try exports(in: store)[id]?.synced?.title, "待重试")
            XCTAssertEqual(tool.handoffStatus(for: id), .sent)
            XCTAssertEqual(source.items.first?.title, "待重试")
            await tool.refresh()
            source.assertWrites(sends: 1, updates: 1, removes: 0, failedUpdates: 1)
        }
    }

    func testFailedCreateStopsBatchAndExplicitResetUsesTaskSchedule() async throws {
        try await withList { store, source, tool in
            let ids = [UUID(), UUID(), UUID()]
            let day = try Day("2026-11-20")
            for id in ids {
                try store.createTask(id: id, title: id.uuidString, schedule: .allDay(start: day, endExclusive: day.adding(days: 2)))
            }
            source.failCreate = true
            await tool.setAutoSync(true)
            let pending = try exports(in: store)
            XCTAssertEqual(pending.count, 1)
            let failedID = try XCTUnwrap(pending.keys.first)
            XCTAssertTrue(ids.contains(failedID))
            XCTAssertEqual(tool.handoffStatus(for: failedID), .needsReview)
            source.assertWrites(sends: 0, updates: 0, removes: 0, failedCreates: 1)

            source.failCreate = false
            await tool.refresh()
            await tool.refresh()
            XCTAssertEqual(tool.handoffStatus(for: failedID), .needsReview)
            XCTAssertFalse(source.items.contains { $0.marker == AppDestination.task(failedID).url })
            source.assertWrites(sends: 2, updates: 0, removes: 0, failedCreates: 1)
            await tool.resetHandoff(failedID)
            XCTAssertEqual(tool.handoffStatus(for: failedID), .sent)
            XCTAssertEqual(source.items.first { $0.marker == AppDestination.task(failedID).url }?.dueDay, day)
            await tool.refresh()
            source.assertWrites(sends: 3, updates: 0, removes: 0, failedCreates: 1)
        }
    }

    func testTrashingAfterAmbiguousAutomaticCreateDeletesVerifiedReminderOnce() async throws {
        try await withList { store, source, tool in
            let id = UUID()
            try store.createTask(id: id, title: "已写入但未确认")
            source.failAfterSave = true
            await tool.setAutoSync(true)
            XCTAssertEqual(source.items.compactMap(\.marker), [AppDestination.task(id).url])
            XCTAssertEqual(tool.handoffStatus(for: id), .needsReview)
            XCTAssertNil(try XCTUnwrap(exports(in: store)[id]).externalID)
            source.assertWrites(sends: 1, updates: 0, removes: 0)

            source.failAfterSave = false
            try store.moveToTrash(id: id)
            let reopened = MacReminders(source: source)
            reopened.attach(store)
            await reopened.refresh()
            XCTAssertTrue(source.items.isEmpty)
            XCTAssertNil(try exports(in: store)[id])
            XCTAssertEqual(reopened.handoffStatus(for: id), .notSent)
            source.assertWrites(sends: 1, updates: 0, removes: 1)
            await reopened.refresh()
            source.assertWrites(sends: 1, updates: 0, removes: 1)
        }
    }

    func testMissingRemoteWhileTrashedOnlyDropsExport() async throws {
        try await withList { store, source, tool in
            let id = UUID()
            try store.createTask(id: id, title: "已从手机删除")
            await tool.setAutoSync(true)
            source.items = []
            await tool.refresh()
            XCTAssertEqual(tool.handoffStatus(for: id), .needsReview)
            XCTAssertNil(try XCTUnwrap(store.snapshots().first).deletedAt)
            source.assertWrites(sends: 1, updates: 0, removes: 0)
            try store.moveToTrash(id: id)
            await tool.refresh()
            XCTAssertEqual(tool.handoffStatus(for: id), .notSent)
            XCTAssertNil(try exports(in: store)[id])
            source.assertWrites(sends: 1, updates: 0, removes: 0)
        }
    }

    func testFailedRemoveRetainsExportUntilConfirmed() async throws {
        try await withList { store, source, tool in
            let id = UUID()
            try store.createTask(id: id, title: "稍后再删除")
            await tool.setAutoSync(true)
            let reminder = try XCTUnwrap(source.items.first)
            try store.moveToTrash(id: id)
            source.failRemove = true
            await tool.refresh()
            XCTAssertNotNil(tool.message)
            XCTAssertNotNil(try exports(in: store)[id])
            XCTAssertEqual(source.items, [reminder])
            source.assertWrites(sends: 1, updates: 0, removes: 0, failedRemoves: 1)
            source.failRemove = false
            await tool.refresh()
            await tool.refresh()
            XCTAssertTrue(source.items.isEmpty)
            XCTAssertNil(try exports(in: store)[id])
            source.assertWrites(sends: 1, updates: 0, removes: 1, failedRemoves: 1)
        }
    }

    func testDisablingLeavesExistingLinkPullsCompletionAndSkipsPushAndImport() async throws {
        try await withList { store, source, tool in
            let id = UUID()
            try store.createTask(id: id, title: "原名")
            await tool.setAutoSync(true)
            await tool.setAutoSync(false)
            try store.updateTitle(id: id, title: "新名")
            let sent = try XCTUnwrap(source.items.first)
            source.markCompleted(sent)
            source.items.append(source.item("phone", external: "another", title: "只在手机"))
            let reopened = MacReminders(source: source)
            reopened.attach(store)
            await reopened.refresh()
            XCTAssertFalse(reopened.autoSync)
            XCTAssertEqual(reopened.handoffStatus(for: id), .sent)
            let tasks = try store.snapshots()
            XCTAssertEqual(tasks.map(\.id), [id])
            XCTAssertEqual(tasks.first?.title, "新名")
            XCTAssertEqual(tasks.first?.isCompleted, true)
            XCTAssertEqual(source.current(sent.id)?.title, sent.title)
            XCTAssertEqual(reopened.candidates.map(\.id), ["phone"])
            source.assertWrites(sends: 1, updates: 0, removes: 0)
        }
    }

    func testHandoffLockContentionDefersBothDirectionsUntilNextRefresh() async throws {
        try await withList { store, source, tool in
            await tool.setAutoSync(true)
            let macID = UUID()
            try store.createTask(id: macID, title: "Mac 项")
            source.items = [source.item("phone", external: "phone", title: "手机项")]
            do {
                let lock = try StoreFileLock(url: store.directory.appendingPathComponent("reminders-handoff.lock"), mode: LOCK_EX)
                defer { withExtendedLifetime(lock) {} }
                await tool.refresh()
                XCTAssertNil(tool.message)
                XCTAssertTrue(try exports(in: store).isEmpty)
                XCTAssertEqual(try store.snapshots().map(\.id), [macID])
                source.assertWrites(sends: 0, updates: 0, removes: 0)
            }
            await tool.refresh()
            XCTAssertEqual(try store.snapshots().count, 2)
            XCTAssertEqual(tool.syncSummary.synced, 2)
            source.assertWrites(sends: 1, updates: 1, removes: 0)
        }
    }
}
