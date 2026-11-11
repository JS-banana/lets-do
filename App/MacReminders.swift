#if os(macOS)
import Combine
import Darwin
@preconcurrency import EventKit
import Foundation

struct MacReminderScope: Codable, Hashable, Sendable {
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
    var marker: URL? = nil

    static func dueLabel(for components: DateComponents?) -> String? {
        guard let components, let year = components.year, let month = components.month, let day = components.day else { return nil }
        let date = String(format: "%04d-%02d-%02d", year, month, day)
        guard let hour = components.hour else { return date }
        let clock = String(format: "%02d:%02d", hour, components.minute ?? 0)
        let zone = components.timeZone
        return [date, clock, zone?.identifier].compactMap { $0 }.joined(separator: " ")
    }
}

@MainActor
protocol MacReminderSource {
    var authorized: Bool { get }
    var canRequestPermission: Bool { get }
    func requestAccess() async throws
    func lists() -> [MacReminderList]
    func reminders(in scope: MacReminderScope, includingCompleted: Bool) async throws -> [MacReminderCandidate]
    func current(_ id: String) -> MacReminderCandidate?
    func create(title: String, due: Day?, marker: URL, in scope: MacReminderScope) throws -> MacReminderCandidate
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
        events.calendars(for: .reminder).compactMap { calendar -> MacReminderList? in
            guard calendar.allowsContentModifications, let scope = Self.scope(calendar),
                  let source = calendar.source else { return nil }
            return MacReminderList(scope: scope, title: calendar.title, sourceTitle: source.title)
        }.sorted {
            ($0.sourceTitle, $0.title, $0.id) < ($1.sourceTitle, $1.title, $1.id)
        }
    }

    private nonisolated static func scope(_ calendar: EKCalendar) -> MacReminderScope? {
        guard let source = calendar.source else { return nil }
        return MacReminderScope(sourceID: source.sourceIdentifier, listID: calendar.calendarIdentifier)
    }

    private nonisolated static func candidate(_ reminder: EKReminder) -> MacReminderCandidate? {
        guard let calendar = reminder.calendar, let listScope = scope(calendar) else { return nil }
        return MacReminderCandidate(id: reminder.calendarItemIdentifier,
                                    externalID: reminder.calendarItemExternalIdentifier ?? "",
                                    scope: listScope, title: reminder.title ?? "",
                                    notes: reminder.notes ?? "", completed: reminder.isCompleted,
                                    dueLabel: MacReminderCandidate.dueLabel(for: reminder.dueDateComponents), marker: reminder.url)
    }

    func current(_ id: String) -> MacReminderCandidate? {
        guard authorized, let reminder = events.calendarItem(withIdentifier: id) as? EKReminder else { return nil }
        return Self.candidate(reminder)
    }

    private func writableCalendar(_ scope: MacReminderScope) throws -> EKCalendar {
        guard authorized, let list = events.calendar(withIdentifier: scope.listID),
              list.allowsContentModifications, Self.scope(list) == scope else {
            throw PrototypeError.unavailable("提醒事项清单不可用，请重新选择。")
        }
        return list
    }

    func create(title: String, due: Day?, marker: URL, in scope: MacReminderScope) throws -> MacReminderCandidate {
        let list = try writableCalendar(scope)
        let reminder = EKReminder(eventStore: events)
        reminder.calendar = list
        reminder.title = title
        reminder.url = marker
        if let due {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .gmt
            var components = calendar.dateComponents([.year, .month, .day], from: due.date(in: .gmt))
            components.calendar = calendar
            reminder.dueDateComponents = components
        }
        try events.save(reminder, commit: true)
        guard let saved = Self.candidate(reminder) else { throw PrototypeError.unavailable("发送状态待核对。") }
        return saved
    }

    func reminders(in scope: MacReminderScope, includingCompleted: Bool) async throws -> [MacReminderCandidate] {
        let list = try writableCalendar(scope)
        let predicate = includingCompleted ? events.predicateForReminders(in: [list]) :
            events.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: [list])
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

enum MacReminderHandoffStatus: String, Codable {
    case notSent, sent, needsReview
}

private struct ReminderExport: Codable {
    let scope: MacReminderScope
    let marker: URL
    let due: Day?
    var externalID: String?
    var status = MacReminderHandoffStatus.needsReview
    var completionApplied = false
    var pendingCompletionBaseline: Date?
}

// This file contains only associations and the chosen list, never task contents.
// Reserve the task UUID before committing to Core Data so a retry after a crash uses the same UUID.
private struct ReminderLinks: Codable {
    var selected: MacReminderScope?
    var imports: [ReminderImport] = []
    // Optional on disk because the first import-only version had no exports.
    var exports: [UUID: ReminderExport]?

    mutating func updateExport(_ taskID: UUID, _ body: (inout ReminderExport) -> Void) throws {
        guard var link = exports?[taskID] else { throw PrototypeError.unavailable("提醒事项关联不可用。") }
        body(&link)
        exports?[taskID] = link
    }


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

    @Published private var handoffStates: [UUID: MacReminderHandoffStatus] = [:]
    private var handoffs: [UUID: ReminderExport] = [:]
    private var refreshQueued = false
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
        handoffStates = [:]
        handoffs = [:]
        refreshQueued = false
        lists = []
        candidates = []
        selectedListID = nil
        busy = false
        message = nil
        updateAuthorization()
        guard let newStore else { return }
        do {
            let links = try ReminderLinks.read(from: newStore.directory)
            selectedListID = links.selected?.listID
            applyHandoffState(links)
        }
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
            busy = false
            await refresh()
            if self.store != nil && !authorized { message = "未获得提醒事项权限，可在系统设置的隐私与安全性中授权。" }
        } catch {
            guard generation == token else { return }
            busy = false
            updateAuthorization()
            message = error.localizedDescription
        }
    }

    func selectList(_ id: String?) async {
        guard !busy, let store, store.container != nil else { return }
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

    func handoffStatus(for id: UUID) -> MacReminderHandoffStatus { handoffStates[id] ?? .notSent }

    private func applyHandoffState(_ links: ReminderLinks) {
        let exports = links.exports ?? [:]
        handoffStates = exports.mapValues(\.status)
        handoffs = exports
    }

    func handoffListLabel(for id: UUID) -> String? {
        guard let scope = handoffs[id]?.scope, let list = lists.first(where: { $0.scope == scope }) else { return nil }
        return "\(list.sourceTitle) · \(list.title)"
    }

    func canRetryHandoff(for id: UUID) -> Bool {
        guard let link = handoffs[id], link.externalID == nil else { return false }
        return authorized && lists.contains { $0.scope == link.scope }
    }

    func refreshIfConnected() async {
        guard let store, store.container != nil else { return }
        do {
            let links = try ReminderLinks.read(from: store.directory)
            guard links.selected != nil || links.exports?.isEmpty == false else { return }
            await refresh()
        } catch { message = error.localizedDescription }
    }

    private func finish(_ token: UUID) {
        guard generation == token else { return }
        busy = false
        if refreshQueued {
            refreshQueued = false
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                await self.refreshIfConnected()
            }
        }
    }

    private func isCurrent(_ token: UUID, store: TaskStore) -> Bool {
        generation == token && self.store === store && store.container != nil
    }

    func refresh() async {
        guard !busy else { refreshQueued = true; return }
        let token = UUID()
        generation = token
        busy = true
        defer { finish(token) }
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
            let exports = links.exports ?? [:]
            applyHandoffState(links)
            selectedListID = lists.first { $0.scope == links.selected }?.id
            if links.selected != nil && selectedListID == nil { message = "原清单已不可用，请重新选择。" }
            var scopes = Set(exports.values.map(\.scope))
            if let selected = links.selected { scopes.insert(selected) }
            for scope in scopes {
                guard isCurrent(token, store: store) else { return }
                let linked = exports.filter { $0.value.scope == scope }
                guard lists.contains(where: { $0.scope == scope }) else {
                    for id in linked.keys { handoffStates[id] = .needsReview }
                    continue
                }
                do {
                    let items = try await source.reminders(in: scope, includingCompleted: !linked.isEmpty)
                    guard isCurrent(token, store: store) else { return }
                    guard source.authorized, source.lists().contains(where: { $0.scope == scope }) else {
                        updateAuthorization()
                        lists = authorized ? source.lists() : []
                        if selectedListID == scope.listID || !authorized { candidates = []; selectedListID = nil }
                        for id in linked.keys { handoffStates[id] = .needsReview }
                        throw PrototypeError.unavailable("清单或授权已变化，请重新检查。")
                    }
                    let scoped = items.filter { $0.scope == scope }
                    let refreshed = try ReminderLinks.read(from: store.directory)
                    if refreshed.selected == scope { updateCandidates(scoped, links: refreshed) }
                    guard !linked.isEmpty else { continue }
                    let handoffLock = try StoreFileLock(url: store.directory.appendingPathComponent("reminders-handoff.lock"), mode: LOCK_EX)
                    defer { withExtendedLifetime(handoffLock) {} }
                    let byMarker = Dictionary(grouping: scoped.filter { $0.marker != nil }, by: \.marker)
                    for (id, link) in linked {
                        try reconcile(id, link: link, matches: byMarker[link.marker] ?? [], store: store)
                    }
                } catch {
                    guard isCurrent(token, store: store) else { return }
                    message = error.localizedDescription
                }
            }
        } catch { message = error.localizedDescription }
    }

    private func updateCandidates(_ items: [MacReminderCandidate], links: ReminderLinks) {
        let exportedIDs = Set((links.exports ?? [:]).values.filter { $0.scope == links.selected }.compactMap(\.externalID))
        let scoped = items.filter { item in
            guard !item.completed, !exportedIDs.contains(item.externalID) else { return false }
            if let marker = item.marker, case .task? = AppDestination(url: marker) { return false }
            return true
        }
        let groups = Dictionary(grouping: scoped, by: \.externalID)
        candidates = scoped.filter { item in
            !item.externalID.isEmpty && groups[item.externalID]?.count == 1 &&
                !links.imports.contains { $0.committed && $0.matches(item) }
        }.sorted { ($0.title, $0.id) < ($1.title, $1.id) }
        if groups.contains(where: { $0.key.isEmpty || $0.value.count > 1 }) {
            message = "有些提醒事项缺少唯一标识，已暂缓导入。"
        }
    }

    func sendTask(_ id: UUID, due: Day?) async {
        await send(id, due: due, retryConfirmedByUser: false)
    }

    // Call only after the user explicitly checks the original list and confirms retrying.
    func retryHandoff(_ id: UUID, due: Day?) async {
        await send(id, due: due, retryConfirmedByUser: true)
    }

    private func send(_ id: UUID, due: Day?, retryConfirmedByUser: Bool) async {
        guard !busy, let store, store.container != nil, source.authorized else {
            message = "请先授权并选择可写清单。"
            return
        }
        let token = UUID()
        generation = token
        busy = true
        defer { finish(token) }
        do {
            // Multiple host launches must not both retry the same unconfirmed system write.
            let lock = try StoreFileLock(url: store.directory.appendingPathComponent("reminders-handoff.lock"), mode: LOCK_EX)
            defer { withExtendedLifetime(lock) {} }
            let initial = try ReminderLinks.read(from: store.directory)
            let previous = initial.exports?[id]
            let reservation: ReminderExport
            if retryConfirmedByUser {
                guard let previous, previous.externalID == nil else {
                    throw PrototypeError.unavailable("仅可重试尚未确认的发送。")
                }
                reservation = previous
            } else {
                guard previous == nil else { throw PrototypeError.unavailable("此任务已有发送记录，请刷新核对。") }
                guard let selected = initial.selected else { throw PrototypeError.unavailable("请选择可写的提醒事项清单。") }
                reservation = ReminderExport(scope: selected, marker: AppDestination.task(id).url, due: due)
            }
            let scope = reservation.scope
            guard source.lists().contains(where: { $0.scope == scope }) else {
                throw PrototypeError.unavailable("原清单当前不可写，请检查账户和清单。")
            }
            let existing = try await source.reminders(in: scope, includingCompleted: true)
            guard isCurrent(token, store: store) else { return }
            guard source.authorized, source.lists().contains(where: { $0.scope == scope }) else {
                throw PrototypeError.unavailable("清单或授权已变化。")
            }
            let matches = existing.filter { $0.scope == scope && $0.marker == reservation.marker }
            if !matches.isEmpty {
                guard retryConfirmedByUser, matches.count == 1 else {
                    throw PrototypeError.unavailable("清单中已有相同的任务链接，请核对已有提醒。")
                }
                try reconcile(id, link: reservation, matches: matches, store: store)
                message = handoffStatus(for: id) == .sent ? "已找到原提醒。" : "原提醒的身份仍待核对。"
                return
            }
            guard let task = try store.snapshots().first(where: { $0.id == id }),
                  task.deletedAt == nil, !task.isCompleted else {
                throw PrototypeError.unavailable("只能发送当前库中未完成的任务。")
            }
            // Reserve before calling EventKit. An ordinary retry never creates a second reminder.
            try ReminderLinks.update(in: store.directory) { links in
                if retryConfirmedByUser {
                    guard let pending = links.exports?[id], pending.externalID == nil, pending.scope == scope,
                          pending.marker == reservation.marker else { throw PrototypeError.unavailable("发送状态已变化。") }
                } else {
                    guard links.selected == scope, links.exports?[id] == nil else {
                        throw PrototypeError.unavailable("清单或发送状态已变化，请刷新。")
                    }
                    if links.exports == nil { links.exports = [:] }
                    links.exports?[id] = reservation
                }
            }
            handoffStates[id] = .needsReview
            handoffs[id] = reservation
            let item = try source.create(title: task.title, due: reservation.due, marker: reservation.marker, in: scope)
            guard item.scope == scope, item.marker == reservation.marker, !item.externalID.isEmpty else {
                throw PrototypeError.unavailable("发送结果待核对，请刷新。")
            }
            try confirm(id, externalID: item.externalID, directory: store.directory)
            message = "已发送到提醒事项。"
        } catch {
            guard isCurrent(token, store: store) else { return }
            message = error.localizedDescription
        }
    }

    private func confirm(_ id: UUID, externalID: String, directory: URL) throws {
        try ReminderLinks.update(in: directory) { links in
            guard let record = links.exports?[id], record.externalID == nil || record.externalID == externalID else {
                throw PrototypeError.unavailable("提醒事项身份不一致，请核对原清单。")
            }
            try links.updateExport(id) { $0.externalID = externalID; $0.status = .sent }
        }
        handoffStates[id] = .sent
        handoffs[id]?.externalID = externalID
        handoffs[id]?.status = .sent
    }

    private func reconcile(_ id: UUID, link expected: ReminderExport, matches: [MacReminderCandidate], store: TaskStore) throws {
        // Both callers hold the handoff lock; another host could have acknowledged a
        // completion while this host was awaiting its EventKit fetch.
        guard let link = try ReminderLinks.read(from: store.directory).exports?[id],
              link.scope == expected.scope, link.marker == expected.marker else { return }
        guard matches.count == 1, let item = matches.first, !item.externalID.isEmpty,
              link.externalID == nil || link.externalID == item.externalID,
              let live = source.current(item.id), live == item else {
            handoffStates[id] = .needsReview
            return
        }
        if link.externalID == nil || link.status != .sent {
            try confirm(id, externalID: item.externalID, directory: store.directory)
        }
        handoffStates[id] = .sent
        guard item.completed, !link.completionApplied else { return }
        let task = try store.snapshots().first { $0.id == id }
        if let task, task.deletedAt == nil, !task.isCompleted {
            // Record the exact local baseline before changing the task. After an interrupted
            // acknowledgement, don't replay a completion against a task the user has since reopened.
            let baseline = link.pendingCompletionBaseline ?? task.updatedAt
            if link.pendingCompletionBaseline == nil {
                try ReminderLinks.update(in: store.directory) { links in
                    try links.updateExport(id) { $0.pendingCompletionBaseline = baseline }
                }
            }
            if task.updatedAt == baseline { try store.setCompleted(id: id, completed: true) }
        }
        try ReminderLinks.update(in: store.directory) { links in
            try links.updateExport(id) { $0.completionApplied = true; $0.pendingCompletionBaseline = nil }
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
