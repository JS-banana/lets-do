import Foundation
import XCTest
@testable import TodoM0

final class StoreSessionTests: XCTestCase {
    func testDistributionHostAndWidgetResolveOneIsolatedLibraryRoot() throws {
        let home = URL(fileURLWithPath: "/isolated-home/example", isDirectory: true)
        let appID = "com.example.probe.mac"
        let widgetID = appID + ".widget"
        let widgetSupport = home.appendingPathComponent("Library/Containers/\(widgetID)/Data/Library/Application Support", isDirectory: true)
        let host = try StoreSession.distributionBaseURL(
            bundleIdentifier: appID, appIdentifier: appID, widgetIdentifier: widgetID,
            applicationSupport: home.appendingPathComponent("Library/Application Support", isDirectory: true), userHome: home)
        let widget = try StoreSession.distributionBaseURL(
            bundleIdentifier: widgetID, appIdentifier: appID, widgetIdentifier: widgetID,
            applicationSupport: widgetSupport, userHome: widgetSupport.deletingLastPathComponent().deletingLastPathComponent())

        XCTAssertEqual(host, widget)
        XCTAssertEqual(host, widgetSupport.appendingPathComponent("TodoM0/MacDistribution", isDirectory: true))
        XCTAssertFalse(host.path.contains("Group Containers"))
    }

    func testDistributionStorageRejectsUnrelatedOrMalformedIdentities() {
        let home = URL(fileURLWithPath: "/isolated-home/example", isDirectory: true)
        let appID = "com.example.probe.mac"
        for (bundle, app, widget) in [
            (nil, appID, appID + ".widget"),
            ("com.other.app", appID, appID + ".widget"),
            (appID, nil, appID + ".widget"),
            (appID, appID, nil),
            (appID, appID, appID),
            (appID, appID, "com.other.widget"),
            ("../app", "../app", "../app.widget"),
            ("com..app", "com..app", "com..app.widget"),
            (appID + "\n", appID + "\n", appID + "\n.widget"),
            ("$(M0_APP_ID)", "$(M0_APP_ID)", "$(M0_APP_ID).widget")
        ] as [(String?, String?, String?)] {
            XCTAssertThrowsError(try StoreSession.distributionBaseURL(
                bundleIdentifier: bundle, appIdentifier: app, widgetIdentifier: widget,
                applicationSupport: home, userHome: home))
        }
    }

    func testDistributionRunNameRejectsAmbiguousArgumentsAndKeepsColdLaunchSelection() throws {
        XCTAssertNil(try StoreSession.distributionRunName(arguments: ["app"]))
        for valid in ["a", "capture-01", String(repeating: "a", count: 70)] {
            XCTAssertEqual(try StoreSession.distributionRunName(arguments: ["app", "-M0Run", valid]), valid)
        }
        for invalid in [
            ["app", "-M0Run"], ["app", "-M0Run", ""], ["app", "-M0Run", "../manual"],
            ["app", "-M0Run", "-NSDocumentRevisionsDebugMode", "YES"],
            ["app", "-M0Run", String(repeating: "a", count: 71)],
            ["app", "-M0Run", "one", "-M0Run", "one"],
            ["app", "-M0Run", "one", "-M0Run", "two"], ["app", "-M0Run=one"],
            ["app", "-M0Run", "one\n"], ["app", "-M0Run", "manual"],
            ["app", "-M0Run", "MANUAL"], ["app", "-M0Run", "mAnUaL"]
        ] {
            XCTAssertThrowsError(try StoreSession.distributionRunName(arguments: invalid))
        }
        let previous = StoreSession(modelVersion: StoreSession.modelVersion, namespace: "dist-capture-01", ready: true)
        XCTAssertEqual(try StoreSession.distributionNamespace(run: StoreSession.distributionRunName(arguments: ["app"]), previous: previous), previous.namespace)
    }

    func testDistributionLegacyMappingNeverSelectsManualForAnExplicitRun() throws {
        let support = URL(fileURLWithPath: "/isolated-home/Library/Application Support", isDirectory: true)
        let isolated = StoreSession(modelVersion: StoreSession.modelVersion, namespace: "dist-capture-01", ready: true)
        let manual = StoreSession(modelVersion: StoreSession.modelVersion, namespace: "dist-manual", ready: true)
        XCTAssertEqual(try isolated.legacyLocalDirectory(applicationSupport: support, arguments: ["app", "-M0Run", "capture-01"]),
                       support.appendingPathComponent("TodoM0/Local/local-capture-01", isDirectory: true))
        XCTAssertEqual(try isolated.legacyLocalDirectory(applicationSupport: support, arguments: ["app"]).lastPathComponent, "local-capture-01")
        XCTAssertEqual(try manual.legacyLocalDirectory(applicationSupport: support, arguments: ["app"]).lastPathComponent, "local-manual")
        XCTAssertThrowsError(try manual.legacyLocalDirectory(applicationSupport: support, arguments: ["app", "-M0Run", "capture-01"]))
        XCTAssertThrowsError(try isolated.legacyLocalDirectory(applicationSupport: support, arguments: ["app", "-M0Run"]))
        for reserved in ["manual", "MANUAL", "mAnUaL"] {
            XCTAssertThrowsError(try manual.legacyLocalDirectory(applicationSupport: support, arguments: ["app", "-M0Run", reserved]))
        }
        let ambiguous = StoreSession(modelVersion: StoreSession.modelVersion, namespace: "dist-MANUAL", ready: true)
        XCTAssertThrowsError(try ambiguous.legacyLocalDirectory(applicationSupport: support, arguments: ["app"]))
    }

    @MainActor
    func testSessionSwitchPreservesLibrariesDraftsAndBlocksOldWriters() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("TodoM0Modes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let local = StoreSession(modelVersion: StoreSession.modelVersion, namespace: "dist-first", ready: true)
        let other = StoreSession(modelVersion: StoreSession.modelVersion, namespace: "dist-second", ready: true)
        let gate = base.appendingPathComponent("session.json")
        try JSONEncoder().encode(local).write(to: gate, options: .atomic)
        let localStore = try TaskStore(directory: base.appendingPathComponent(local.namespace), session: local)
        defer { try? localStore.close() }
        let localID = UUID(), otherID = UUID(), draftID = UUID()
        try localStore.createTask(id: localID, title: "只在本机", body: "本机正文")
        try localStore.saveDraft(.init(formatVersion: 1, id: draftID, taskID: localID, kind: .editor,
                                      title: "只在本机", body: "本机未提交文字", parentIDs: [localID], updatedAt: Date()))
        let blocked = StoreSession(modelVersion: StoreSession.modelVersion, namespace: "blocked", ready: false)
        try JSONEncoder().encode(blocked).write(to: gate, options: .atomic)
        XCTAssertThrowsError(try localStore.createTask(id: UUID(), title: "旧入口不得写入"))
        XCTAssertThrowsError(try localStore.snapshots())
        try localStore.close()

        try JSONEncoder().encode(other).write(to: gate, options: .atomic)
        let otherStore = try TaskStore(directory: base.appendingPathComponent(other.namespace), session: other)
        defer { try? otherStore.close() }
        XCTAssertTrue(try otherStore.snapshots().isEmpty)
        XCTAssertTrue(try otherStore.drafts().isEmpty)
        try otherStore.createTask(id: otherID, title: "另一个库的任务", body: "另一个库的正文")
        try JSONEncoder().encode(local).write(to: gate, options: .atomic)
        XCTAssertThrowsError(try otherStore.setCompleted(id: otherID, completed: true))
        try otherStore.close()

        let reopenedLocal = try TaskStore(directory: localStore.directory, session: local)
        defer { try? reopenedLocal.close() }
        XCTAssertEqual(try reopenedLocal.snapshots().map(\.id), [localID])
        XCTAssertEqual(try reopenedLocal.snapshots().first?.currentNote?.body, "本机正文")
        XCTAssertEqual(try reopenedLocal.drafts().first?.id, draftID)
        XCTAssertEqual(try reopenedLocal.drafts().first?.body, "本机未提交文字")
        try reopenedLocal.close()
        try JSONEncoder().encode(other).write(to: gate, options: .atomic)
        let reopenedOther = try TaskStore(directory: otherStore.directory, session: other)
        defer { try? reopenedOther.close() }
        XCTAssertEqual(try reopenedOther.snapshots().map(\.id), [otherID])
        XCTAssertEqual(try reopenedOther.snapshots().first?.currentNote?.body, "另一个库的正文")
    }
}
