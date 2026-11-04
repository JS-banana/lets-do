import Foundation
import XCTest
@testable import TodoM0

final class StoreSessionTests: XCTestCase {
    func testCloudModesKeepTheLocalInboxSeparateFromEachAccount() throws {
        let firstHash = String(repeating: "a", count: 64)
        let secondHash = String(repeating: "b", count: 64)
        let local = try StoreSession.cloudSession(syncEnabled: false, accountHash: firstHash)
        let signedOut = try StoreSession.cloudSession(syncEnabled: true, accountHash: nil)
        let first = try StoreSession.cloudSession(syncEnabled: true, accountHash: firstHash)
        let second = try StoreSession.cloudSession(syncEnabled: true, accountHash: secondHash)

        XCTAssertEqual(local, signedOut)
        XCTAssertFalse(local.cloudEnabled)
        XCTAssertNil(local.accountHash)
        XCTAssertEqual(local.namespace, "local-inbox")
        XCTAssertTrue(first.cloudEnabled)
        XCTAssertEqual(first.namespace, "account-\(firstHash)")
        XCTAssertNotEqual(first.namespace, second.namespace)
        XCTAssertEqual(try StoreSession.cloudSession(syncEnabled: true, accountHash: firstHash), first)
    }

    func testCloudAccountIdentityMustBeAConfirmedHash() {
        for invalid in ["", "../other", String(repeating: "a", count: 63), String(repeating: "a", count: 65),
                        String(repeating: "A", count: 64), String(repeating: "g", count: 64), "raw-account-name"] {
            XCTAssertThrowsError(try StoreSession.cloudSession(syncEnabled: true, accountHash: invalid))
        }
    }

    @MainActor
    func testModeSwitchPreservesLibrariesDraftsAndBlocksOldWriters() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("TodoM0Modes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let local = try StoreSession.cloudSession(syncEnabled: false, accountHash: nil)
        let cloud = try StoreSession.cloudSession(syncEnabled: true, accountHash: String(repeating: "a", count: 64))
        let gate = base.appendingPathComponent("session.json")
        try JSONEncoder().encode(local).write(to: gate, options: .atomic)
        let localStore = try TaskStore(directory: base.appendingPathComponent(local.namespace), session: local)
        defer { try? localStore.close() }
        let localID = UUID(), cloudID = UUID(), draftID = UUID()
        try localStore.createTask(id: localID, title: "只在本机", body: "本机正文")
        try localStore.saveDraft(.init(formatVersion: 1, id: draftID, taskID: localID, kind: .editor,
                                      title: "只在本机", body: "本机未提交文字", parentIDs: [localID], updatedAt: Date()))
        let blocked = StoreSession(modelVersion: StoreSession.modelVersion, namespace: "blocked",
                                   accountHash: nil, cloudEnabled: false, ready: false)
        try JSONEncoder().encode(blocked).write(to: gate, options: .atomic)
        XCTAssertThrowsError(try localStore.createTask(id: UUID(), title: "旧入口不得写入"))
        XCTAssertThrowsError(try localStore.snapshots())
        try localStore.close()

        // Exercise the real local session gate without creating a CloudKit mirror.
        try JSONEncoder().encode(cloud).write(to: gate, options: .atomic)
        let cloudStore = try TaskStore(directory: base.appendingPathComponent(cloud.namespace), session: cloud)
        defer { try? cloudStore.close() }
        XCTAssertTrue(try cloudStore.snapshots().isEmpty)
        XCTAssertTrue(try cloudStore.drafts().isEmpty)
        try cloudStore.createTask(id: cloudID, title: "账户任务", body: "账户正文")
        try JSONEncoder().encode(local).write(to: gate, options: .atomic)
        XCTAssertThrowsError(try cloudStore.setCompleted(id: cloudID, completed: true))
        try cloudStore.close()

        let reopenedLocal = try TaskStore(directory: localStore.directory, session: local)
        defer { try? reopenedLocal.close() }
        XCTAssertEqual(try reopenedLocal.snapshots().map(\.id), [localID])
        XCTAssertEqual(try reopenedLocal.snapshots().first?.currentNote?.body, "本机正文")
        XCTAssertEqual(try reopenedLocal.drafts().first?.id, draftID)
        XCTAssertEqual(try reopenedLocal.drafts().first?.body, "本机未提交文字")
        try reopenedLocal.close()
        try JSONEncoder().encode(cloud).write(to: gate, options: .atomic)
        let reopenedCloud = try TaskStore(directory: cloudStore.directory, session: cloud)
        defer { try? reopenedCloud.close() }
        XCTAssertEqual(try reopenedCloud.snapshots().map(\.id), [cloudID])
        XCTAssertEqual(try reopenedCloud.snapshots().first?.currentNote?.body, "账户正文")
    }
}
