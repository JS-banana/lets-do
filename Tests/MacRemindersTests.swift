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
    var items: [MacReminderCandidate] = []
    var beforeFetch: (() async -> Void)?

    func requestAccess() async throws { permissionRequests += 1; authorized = true }
    func lists() -> [MacReminderList] {
        available ? [.init(scope: scope, title: "收集箱", sourceTitle: "测试账户")] : []
    }
    func reminders(in scope: MacReminderScope) async throws -> [MacReminderCandidate] {
        await beforeFetch?()
        return items.filter { $0.scope == scope }
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
