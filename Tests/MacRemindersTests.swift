#if os(macOS)
import Foundation
import XCTest
@testable import TodoM0

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
    var lastDue: Day?
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
        await beforeFetch?()
        return items.filter { $0.scope == scope && (includingCompleted || !$0.completed) }
    }
    func create(title: String, due: Day?, marker: URL, in scope: MacReminderScope) throws -> MacReminderCandidate {
        if failBeforeSave { throw PrototypeError.unavailable("simulated interruption before system save") }
        sends += 1
        lastDue = due
        let item = MacReminderCandidate(id: "local-\(sends)", externalID: "external-\(sends)", scope: scope,
                                        title: title, notes: "", completed: false, marker: marker)
        items.append(item)
        if failAfterSave { throw PrototypeError.unavailable("simulated ambiguous save") }
        return item
    }

    func markCompleted(_ item: MacReminderCandidate) {
        let replacement = MacReminderCandidate(id: item.id, externalID: item.externalID, scope: item.scope,
                                              title: item.title, notes: item.notes, completed: true, marker: item.marker)
        items = items.map { $0.id == item.id ? replacement : $0 }
    }
    func current(_ id: String) -> MacReminderCandidate? { items.first { $0.id == id } }
    func item(_ local: String, external: String, title: String = "待安排") -> MacReminderCandidate {
        .init(id: local, externalID: external, scope: scope, title: title, notes: "源备注", completed: false)
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
            // Simulate a process stopping after Core Data commits but before the sidecar acknowledges it.
            let file = store.directory.appendingPathComponent("reminders-links.json")
            var pending = Data()
            store.onChange = { pending = (try? Data(contentsOf: file)) ?? Data() }
            tool.importCandidate(first)
            store.onChange = nil
            XCTAssertFalse(pending.isEmpty)
            let id = try XCTUnwrap(store.snapshots().first?.id)
            try pending.write(to: file, options: .atomic)
            let reopened = MacReminders(source: source)
            reopened.attach(store)
            await reopened.refresh()
            reopened.importCandidate(first)
            XCTAssertEqual(try store.snapshots().map(\.id), [id])
            XCTAssertTrue(reopened.candidates.isEmpty)
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
            second.attach(store)
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
        }
    }

    @MainActor
    func testInterruptionBeforeCompletionReceiptDoesNotRecompleteReopenedTask() async throws {
        try await withStore { store in
            let source = ReminderSourceStub(), id = UUID()
            let tool = MacReminders(source: source)
            tool.attach(store)
            await tool.refresh()
            await tool.selectList(source.scope.listID)
            try store.createTask(id: id, title: "不要覆盖重开")
            await tool.sendTask(id, due: nil)
            source.markCompleted(try XCTUnwrap(source.items.first))
            let file = store.directory.appendingPathComponent("reminders-links.json")
            var pending = Data()
            store.onChange = { pending = (try? Data(contentsOf: file)) ?? Data() }
            await tool.refresh()
            store.onChange = nil
            XCTAssertFalse(pending.isEmpty)
            try pending.write(to: file, options: .atomic)
            try store.setCompleted(id: id, completed: false)
            let reopened = MacReminders(source: source)
            reopened.attach(store)
            await reopened.refresh()
            XCTAssertFalse(try XCTUnwrap(store.snapshots().first).isCompleted)
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
            }
        }
    }
}
#endif
