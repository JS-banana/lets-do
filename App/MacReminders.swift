#if os(macOS)
import Combine
import Darwin
@preconcurrency import EventKit
import Foundation

struct MacReminderScope: Codable, Equatable, Sendable {
    let sourceID: String
    let listID: String
}

struct MacReminderList: Identifiable, Equatable, Sendable {
    let scope: MacReminderScope
    let title: String
    let sourceTitle: String
    var id: String { scope.listID }
}

struct MacReminderCandidate: Identifiable, Equatable, Sendable {
    let id: String
    let externalID: String
    let scope: MacReminderScope
    let title: String
    let notes: String
    let completed: Bool
    var dueLabel: String? = nil

    static func dueLabel(for components: DateComponents?) -> String? {
        guard let components, let year = components.year, let month = components.month, let day = components.day else { return nil }
        let date = String(format: "%04d-%02d-%02d", year, month, day)
        guard let hour = components.hour else { return date }
        let clock = String(format: "%02d:%02d", hour, components.minute ?? 0)
        let zone = components.timeZone ?? components.calendar?.timeZone
        return [date, clock, zone?.identifier].compactMap { $0 }.joined(separator: " ")
    }
}

@MainActor
protocol MacReminderSource {
    var authorized: Bool { get }
    var canRequestPermission: Bool { get }
    func requestAccess() async throws
    func lists() -> [MacReminderList]
    func reminders(in scope: MacReminderScope) async throws -> [MacReminderCandidate]
    func current(_ id: String) -> MacReminderCandidate?
}

@MainActor
private final class SystemReminderSource: MacReminderSource {
    private let events = EKEventStore()
    var authorized: Bool { EKEventStore.authorizationStatus(for: .reminder) == .fullAccess }
    var canRequestPermission: Bool { EKEventStore.authorizationStatus(for: .reminder) == .notDetermined }

    func requestAccess() async throws {
        let _: Bool = try await withCheckedThrowingContinuation { continuation in
            events.requestFullAccessToReminders { @Sendable granted, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: granted) }
            }
        }
    }

    func lists() -> [MacReminderList] {
        events.calendars(for: .reminder).filter(\.allowsContentModifications).map {
            MacReminderList(scope: Self.scope($0), title: $0.title, sourceTitle: $0.source.title)
        }.sorted {
            ($0.sourceTitle, $0.title, $0.id) < ($1.sourceTitle, $1.title, $1.id)
        }
    }

    private nonisolated static func scope(_ calendar: EKCalendar) -> MacReminderScope {
        MacReminderScope(sourceID: calendar.source.sourceIdentifier, listID: calendar.calendarIdentifier)
    }

    private nonisolated static func candidate(_ reminder: EKReminder) -> MacReminderCandidate? {
        guard let calendar = reminder.calendar else { return nil }
        return MacReminderCandidate(id: reminder.calendarItemIdentifier,
                                    externalID: reminder.calendarItemExternalIdentifier ?? "",
                                    scope: scope(calendar), title: reminder.title ?? "",
                                    notes: reminder.notes ?? "", completed: reminder.isCompleted,
                                    dueLabel: MacReminderCandidate.dueLabel(for: reminder.dueDateComponents))
    }

    func current(_ id: String) -> MacReminderCandidate? {
        guard authorized, let reminder = events.calendarItem(withIdentifier: id) as? EKReminder else { return nil }
        return Self.candidate(reminder)
    }

    func reminders(in scope: MacReminderScope) async throws -> [MacReminderCandidate] {
        guard authorized, let list = events.calendar(withIdentifier: scope.listID),
              list.allowsContentModifications, Self.scope(list) == scope else {
            throw PrototypeError.unavailable("提醒事项清单不可用，请重新选择。")
        }
        let predicate = events.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: [list])
        return try await withCheckedThrowingContinuation { continuation in
            events.fetchReminders(matching: predicate) { @Sendable reminders in
                guard let reminders else {
                    continuation.resume(throwing: PrototypeError.unavailable("读取提醒事项失败，请稍后刷新。"))
                    return
                }
                continuation.resume(returning: reminders.compactMap(Self.candidate))
            }
        }
    }
}

private struct ReminderImport: Codable {
    let scope: MacReminderScope
    let externalID: String
    let taskID: UUID
    var committed = false

    func matches(_ item: MacReminderCandidate) -> Bool {
        scope == item.scope && externalID == item.externalID
    }
}

// This file contains only associations and the chosen list, never task contents.
// Reserve the task UUID before committing to Core Data so a retry after a crash uses the same UUID.
private struct ReminderLinks: Codable {
    var selected: MacReminderScope?
    var imports: [ReminderImport] = []

    static func read(from directory: URL) throws -> Self {
        let url = directory.appendingPathComponent("reminders-links.json")
        do { return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return Self() }
    }

    static func update<T>(in directory: URL, _ body: (inout Self) throws -> T) throws -> T {
        let lock = try StoreFileLock(url: directory.appendingPathComponent("reminders-links.lock"), mode: LOCK_EX)
        defer { withExtendedLifetime(lock) {} }
        var state = try read(from: directory)
        let result = try body(&state)
        try JSONEncoder().encode(state).write(to: directory.appendingPathComponent("reminders-links.json"), options: .atomic)
        return result
    }
}

@MainActor
final class MacReminders: ObservableObject {
    @Published private(set) var authorized = false
    @Published private(set) var canRequestPermission = false
    @Published private(set) var lists: [MacReminderList] = []
    @Published private(set) var selectedListID: String?
    @Published private(set) var candidates: [MacReminderCandidate] = []
    @Published private(set) var busy = false
    @Published private(set) var message: String?

    private let source: any MacReminderSource
    private weak var store: TaskStore?
    private var generation = UUID()

    init() { source = SystemReminderSource() }
    init(source: any MacReminderSource) { self.source = source }

    private func updateAuthorization() {
        authorized = source.authorized
        canRequestPermission = source.canRequestPermission
    }

    func attach(_ newStore: TaskStore?) {
        guard store !== newStore || newStore == nil else { return }
        generation = UUID()
        store = newStore
        lists = []
        candidates = []
        selectedListID = nil
        busy = false
        message = nil
        updateAuthorization()
        guard let newStore else { return }
        do { selectedListID = try ReminderLinks.read(from: newStore.directory).selected?.listID }
        catch { message = error.localizedDescription }
    }

    func requestPermission() async {
        guard store != nil, !busy else { return }
        guard source.canRequestPermission else { await refresh(); return }
        let token = UUID()
        generation = token
        busy = true
        do {
            try await source.requestAccess()
            guard generation == token else { return }
            await refresh()
            if !authorized { message = "未获得提醒事项权限，可在系统设置的隐私与安全性中授权。" }
        } catch {
            guard generation == token else { return }
            busy = false
            updateAuthorization()
            message = error.localizedDescription
        }
    }

    func selectList(_ id: String?) async {
        guard let store, store.container != nil else { return }
        let selected = id.flatMap { wanted in lists.first { $0.id == wanted } }
        guard id == nil || (source.authorized && selected != nil && source.lists().contains(where: { $0.scope == selected?.scope })) else {
            await refresh()
            return
        }
        do {
            try ReminderLinks.update(in: store.directory) { $0.selected = selected?.scope }
            await refresh()
        } catch { message = error.localizedDescription }
    }

    func refresh() async {
        let token = UUID()
        generation = token
        busy = true
        defer { if generation == token { busy = false } }
        candidates = []
        message = nil
        updateAuthorization()
        guard let store, store.container != nil, authorized else {
            lists = []
            selectedListID = nil
            return
        }
        do {
            lists = source.lists()
            let links = try ReminderLinks.read(from: store.directory)
            guard let scope = links.selected else { selectedListID = nil; return }
            guard lists.contains(where: { $0.scope == scope }) else {
                selectedListID = nil
                message = "原清单已不可用，请重新选择。"
                return
            }
            selectedListID = scope.listID
            let items = try await source.reminders(in: scope)
            guard generation == token, self.store === store, store.container != nil else { return }
            guard source.authorized, source.lists().contains(where: { $0.scope == scope }) else {
                updateAuthorization()
                lists = authorized ? source.lists() : []
                selectedListID = nil
                message = "清单或授权已变化，请重新检查。"
                return
            }
            let current = try ReminderLinks.read(from: store.directory)
            guard current.selected == scope else { selectedListID = nil; return }
            let scoped = items.filter { $0.scope == scope && !$0.completed }
            let groups = Dictionary(grouping: scoped, by: \.externalID)
            candidates = scoped.filter { item in
                !item.externalID.isEmpty && groups[item.externalID]?.count == 1 &&
                    !current.imports.contains { $0.committed && $0.matches(item) }
            }.sorted { ($0.title, $0.id) < ($1.title, $1.id) }
            if groups.contains(where: { $0.key.isEmpty || $0.value.count > 1 }) {
                message = "有些提醒事项缺少唯一标识，已暂缓导入。"
            }
        } catch {
            guard generation == token else { return }
            message = error.localizedDescription
        }
    }

    func importCandidate(_ candidate: MacReminderCandidate) {
        guard !busy, let store, store.container != nil, candidates.contains(candidate),
              source.authorized, source.lists().contains(where: { $0.scope == candidate.scope }),
              source.current(candidate.id) == candidate else {
            message = "提醒事项或授权已变化，请刷新后重试。"
            return
        }
        do {
            _ = try TaskStore.validTitle(candidate.title)
            let taskID = try ReminderLinks.update(in: store.directory) { links in
                guard links.selected == candidate.scope else { throw PrototypeError.unavailable("清单已变化，请刷新。") }
                if let existing = links.imports.first(where: { $0.matches(candidate) }) { return existing.taskID }
                let id = UUID()
                links.imports.append(ReminderImport(scope: candidate.scope, externalID: candidate.externalID, taskID: id))
                return id
            }
            try store.createTask(id: taskID, title: candidate.title, body: candidate.notes)
            try ReminderLinks.update(in: store.directory) { links in
                guard let index = links.imports.firstIndex(where: { $0.taskID == taskID }) else {
                    throw PrototypeError.unavailable("导入关联不可用，请检查本机数据。")
                }
                links.imports[index].committed = true
            }
            candidates.removeAll { $0.id == candidate.id }
            message = "已加入收集箱。"
        } catch { message = error.localizedDescription }
    }
}
#endif
