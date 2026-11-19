import Combine
import Darwin
@preconcurrency import EventKit
import Foundation

enum ReminderDue: Codable, Equatable, Sendable {
    case day(Day)
    case time(Date, timeZoneID: String)

    var components: DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        switch self {
        case let .day(day):
            calendar.timeZone = .gmt
            var result = calendar.dateComponents([.year, .month, .day], from: day.date(in: .gmt))
            result.calendar = calendar
            return result
        case let .time(date, zone):
            calendar.timeZone = TimeZone(identifier: zone) ?? .current
            var result = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            result.calendar = calendar
            result.timeZone = calendar.timeZone
            return result
        }
    }
}

struct ReminderPatch {
    var title: String?
    // An absent patch preserves the deadline; a present nil clears it.
    var due: ReminderDue??
    var completed: Bool?
    var marker: URL?

    var isEmpty: Bool { title == nil && due == nil && completed == nil && marker == nil }
}

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

    var dueDay: Day?
    var recurring = false
    var requiresManualImport: Bool { marker != nil || recurring }
    var canAutoImport: Bool {
        !requiresManualImport && (try? TaskStore.validTitle(title)) != nil && notes.utf8.count <= 1_000_000
    }

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
    func create(title: String, due: ReminderDue?, marker: URL, in scope: MacReminderScope) throws -> MacReminderCandidate
    func update(_ localID: String, expecting scope: MacReminderScope, marker: URL?, externalID: String,
                _ patch: ReminderPatch) throws -> MacReminderCandidate
    func remove(_ localID: String, expecting scope: MacReminderScope, marker: URL, externalID: String) throws
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
        let components = reminder.dueDateComponents
        var dueDay: Day?
        if let y = components?.year, let m = components?.month, let d = components?.day {
            dueDay = try? Day(String(format: "%04d-%02d-%02d", y, m, d))
        }
        return MacReminderCandidate(id: reminder.calendarItemIdentifier,
                                    externalID: reminder.calendarItemExternalIdentifier ?? "",
                                    scope: listScope, title: reminder.title ?? "",
                                    notes: reminder.notes ?? "", completed: reminder.isCompleted,
                                    dueLabel: MacReminderCandidate.dueLabel(for: components), marker: reminder.url,
                                    dueDay: dueDay, recurring: reminder.hasRecurrenceRules)
    }

    func current(_ id: String) -> MacReminderCandidate? {
        guard authorized, let reminder = events.calendarItem(withIdentifier: id) as? EKReminder else { return nil }
        return Self.candidate(reminder)
    }

    private func writableCalendar(_ scope: MacReminderScope) throws -> EKCalendar {
        guard authorized, let list = events.calendar(withIdentifier: scope.listID),
              list.allowsContentModifications, Self.scope(list) == scope else {
            throw AppError.unavailable("提醒事项清单不可用，请重新选择。")
        }
        return list
    }

    func create(title: String, due: ReminderDue?, marker: URL, in scope: MacReminderScope) throws -> MacReminderCandidate {
        let list = try writableCalendar(scope)
        let reminder = EKReminder(eventStore: events)
        reminder.calendar = list
        reminder.title = title
        reminder.url = marker
        reminder.dueDateComponents = due?.components
        try events.save(reminder, commit: true)
        guard let saved = Self.candidate(reminder) else { throw AppError.unavailable("发送状态待核对。") }
        return saved
    }

    private func checkedReminder(_ localID: String, scope: MacReminderScope, marker: URL?,
                                 externalID: String) throws -> EKReminder? {
        _ = try writableCalendar(scope)
        guard let item = events.calendarItem(withIdentifier: localID) else { return nil }
        guard let reminder = item as? EKReminder, let list = reminder.calendar,
              list.allowsContentModifications, Self.scope(list) == scope, reminder.url == marker,
              !externalID.isEmpty, reminder.calendarItemExternalIdentifier == externalID else {
            throw AppError.unavailable("提醒事项身份已变化，请刷新核对。")
        }
        return reminder
    }

    func update(_ localID: String, expecting scope: MacReminderScope, marker: URL?, externalID: String,
                _ patch: ReminderPatch) throws -> MacReminderCandidate {
        guard let reminder = try checkedReminder(localID, scope: scope, marker: marker, externalID: externalID),
              !reminder.hasRecurrenceRules else {
            throw AppError.unavailable("原提醒已变化，请刷新核对。")
        }
        if let title = patch.title { reminder.title = title }
        if let due = patch.due { reminder.dueDateComponents = due?.components }
        if let completed = patch.completed { reminder.isCompleted = completed }
        if let marker = patch.marker { reminder.url = marker }
        try events.save(reminder, commit: true)
        guard let saved = Self.candidate(reminder) else { throw AppError.unavailable("提醒事项更新待核对。") }
        return saved
    }

    func remove(_ localID: String, expecting scope: MacReminderScope, marker: URL, externalID: String) throws {
        guard let reminder = try checkedReminder(localID, scope: scope, marker: marker, externalID: externalID) else {
            // EventKit can change local identifiers during a full sync.
            let stillPresent = events.calendarItems(withExternalIdentifier: externalID).contains { item in
                guard let list = item.calendar else { return false }
                return Self.scope(list) == scope && item.url == marker
            }
            if stillPresent { throw AppError.unavailable("提醒事项标识已更新，请刷新核对。") }
            return
        }
        guard !reminder.hasRecurrenceRules else { throw AppError.unavailable("原提醒已成为重复提醒，已保留原系列。") }
        try events.remove(reminder, commit: true)
    }

    func reminders(in scope: MacReminderScope, includingCompleted: Bool) async throws -> [MacReminderCandidate] {
        let list = try writableCalendar(scope)
        let predicate = includingCompleted ? events.predicateForReminders(in: [list]) :
            events.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: [list])
        return try await withCheckedThrowingContinuation { continuation in
            events.fetchReminders(matching: predicate) { @Sendable reminders in
                guard let reminders else {
                    continuation.resume(throwing: AppError.unavailable("读取提醒事项失败，请稍后刷新。"))
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
    var copyOnly: Bool?

    func matches(_ item: MacReminderCandidate) -> Bool {
        scope == item.scope && externalID == item.externalID
    }
}

enum MacReminderHandoffStatus: String, Codable {
    case notSent, sent, needsReview
}

private struct SyncedState: Codable, Equatable {
    var title: String
    var due: ReminderDue?
    var completed: Bool
}

struct ReminderSyncSummary: Equatable {
    var synced = 0
    var needsReview = 0
    var unlinked = 0
}

private struct ReminderExport: Codable, Equatable {
    let scope: MacReminderScope
    let marker: URL
    let due: Day?
    var externalID: String?
    var status = MacReminderHandoffStatus.needsReview
    var completionApplied = false
    var pendingCompletionActionID: UUID?
    // Legacy receipts could not distinguish a failed write from a later user edit.
    var pendingCompletionBaseline: Date?
    var synced: SyncedState?
    // A crash after the system save must not turn an automatic creation into a legacy manual link.
    var pendingCreation: SyncedState?
}

// The sidecar holds link identities, completion receipts and the last synchronized fields.
// Reserve the task UUID before committing to Core Data so a retry after a crash uses the same UUID.
private struct ReminderLinks: Codable {
    var selected: MacReminderScope?
    var autoSync: Bool?
    var imports: [ReminderImport] = []
    // Optional on disk because the first import-only version had no exports.
    var exports: [UUID: ReminderExport]?

    mutating func updateExport(_ taskID: UUID, _ body: (inout ReminderExport) -> Void) throws {
        guard var link = exports?[taskID] else { throw AppError.unavailable("提醒事项关联不可用。") }
        body(&link)
        exports?[taskID] = link
    }

    static func read(from directory: URL) throws -> Self {
        let url = directory.appendingPathComponent("reminders-links.json")
        do { return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return Self() }
    }

    static func changeHandoff<T>(in directory: URL, _ body: (inout Self) throws -> T) throws -> T {
        let lock = try StoreFileLock(url: directory.appendingPathComponent("reminders-handoff.lock"), mode: LOCK_EX)
        defer { withExtendedLifetime(lock) {} }
        return try update(in: directory, body)
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
    @Published private(set) var autoSync = false
    @Published private(set) var syncSummary = ReminderSyncSummary()
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
    private(set) var hasPriorLinks = false
    private var previewItems: [MacReminderScope: [MacReminderCandidate]] = [:]

    static func reminderDue(for schedule: TaskSchedule) -> ReminderDue? {
        switch schedule {
        case .none, .week: return nil
        case let .allDay(start, _): return .day(start)
        case let .timed(start, _, zone): return .time(start, timeZoneID: zone)
        }
    }

    var manualCandidates: [MacReminderCandidate] {
        autoSync ? candidates.filter(\.requiresManualImport) : candidates
    }

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
        hasPriorLinks = false
        autoSync = false
        syncSummary = ReminderSyncSummary()
        previewItems = [:]
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
            let paused = try ReminderLinks.changeHandoff(in: store.directory) { links in
                let changed = links.selected != selected?.scope && links.autoSync == true
                if changed { links.autoSync = false }
                links.selected = selected?.scope
                return changed
            }
            await refresh()
            if self.store === store, paused { message = "已切换清单，同步已暂停，请在设置中重新开启。" }
        } catch { message = error.localizedDescription }
    }

    func handoffStatus(for id: UUID) -> MacReminderHandoffStatus { handoffStates[id] ?? .notSent }

    private func applyHandoffState(_ links: ReminderLinks) {
        autoSync = links.autoSync == true
        hasPriorLinks = !(links.exports ?? [:]).isEmpty || !links.imports.isEmpty
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

    func refresh(forPreview: Bool = false) async {
        guard !busy else { refreshQueued = true; return }
        let token = UUID()
        generation = token
        busy = true
        defer { finish(token) }
        candidates = []
        previewItems = [:]
        message = nil
        updateAuthorization()
        guard let store, store.container != nil else { return }
        do {
            let links = try ReminderLinks.read(from: store.directory)
            applyHandoffState(links)
            guard authorized else {
                lists = []
                selectedListID = nil
                if autoSync { message = "提醒事项同步已暂停，请恢复访问权限。" }
                return
            }
            lists = source.lists()
            let exports = links.exports ?? [:]
            selectedListID = lists.first { $0.scope == links.selected }?.id
            if links.selected != nil && selectedListID == nil { message = "原清单已不可用，请重新选择。" }
            var fetched: [MacReminderScope: [MacReminderCandidate]] = [:]
            var verified: [UUID: MacReminderCandidate] = [:]
            var examined: [UUID: ReminderExport] = [:]
            let includeAll = autoSync || forPreview
            var scopes = Set(exports.values.map(\.scope))
            if includeAll {
                scopes.formUnion(links.imports.filter { exports[$0.taskID] == nil && $0.copyOnly != true }.map(\.scope))
            }
            if let selected = links.selected { scopes.insert(selected) }
            for scope in scopes {
                guard isCurrent(token, store: store) else { return }
                let linked = exports.filter { $0.value.scope == scope }
                guard lists.contains(where: { $0.scope == scope }) else {
                    for id in linked.keys { handoffStates[id] = .needsReview }
                    continue
                }
                do {
                    let items = try await source.reminders(in: scope, includingCompleted: includeAll || !linked.isEmpty)
                    guard isCurrent(token, store: store) else { return }
                    guard source.authorized, source.lists().contains(where: { $0.scope == scope }) else {
                        updateAuthorization()
                        lists = authorized ? source.lists() : []
                        if selectedListID == scope.listID || !authorized { candidates = []; selectedListID = nil }
                        for id in linked.keys { handoffStates[id] = .needsReview }
                        throw AppError.unavailable("清单或授权已变化，请重新检查。")
                    }
                    let scoped = items.filter { $0.scope == scope }
                    fetched[scope] = scoped
                    let refreshed = try ReminderLinks.read(from: store.directory)
                    if refreshed.selected == scope { updateCandidates(scoped, links: refreshed, allItemsFetched: includeAll) }
                    guard !linked.isEmpty else { continue }
                    let handoffLock = try StoreFileLock(url: store.directory.appendingPathComponent("reminders-handoff.lock"), mode: LOCK_EX)
                    defer { withExtendedLifetime(handoffLock) {} }
                    let byMarker = Dictionary(grouping: scoped.filter { $0.marker != nil }, by: \.marker)
                    let before = try ReminderLinks.read(from: store.directory).exports ?? [:]
                    let readable = try store.readableSnapshots()
                    var checked: [UUID] = []
                    for (id, link) in linked where before[id] == link && !readable.unreadableIDs.contains(id) {
                        do {
                            verified[id] = try reconcile(id, link: link, matches: byMarker[link.marker] ?? [],
                                                         store: store, readable: readable)
                            checked.append(id)
                        } catch { message = error.localizedDescription }
                    }
                    let after = try ReminderLinks.read(from: store.directory).exports ?? [:]
                    for id in checked { examined[id] = after[id] }
                } catch {
                    guard isCurrent(token, store: store) else { return }
                    message = error.localizedDescription
                }
            }
            guard isCurrent(token, store: store) else { return }
            previewItems = fetched
            let latest = try ReminderLinks.read(from: store.directory)
            autoSync = latest.autoSync == true
            guard autoSync, links.autoSync == true, links.selected == latest.selected else {
                updateSummary(unlinked: 0)
                return
            }
            let lock: StoreFileLock
            do { lock = try StoreFileLock(url: store.directory.appendingPathComponent("reminders-handoff.lock"), mode: LOCK_EX) }
            catch AppError.busy { return }
            defer { withExtendedLifetime(lock) {} }
            try synchronize(store: store, token: token, fetched: fetched, verified: verified,
                            examined: examined, selected: latest.selected)
        } catch { message = error.localizedDescription }
    }

    private func updateSummary(unlinked: Int) {
        syncSummary = ReminderSyncSummary(
            synced: handoffs.filter { handoffStates[$0.key] == .sent && $0.value.synced != nil }.count,
            needsReview: handoffStates.values.filter { $0 == .needsReview }.count,
            unlinked: unlinked)
    }

    func setAutoSync(_ on: Bool, expecting scope: MacReminderScope? = nil) async {
        guard let store, store.container != nil else { return }
        do {
            try ReminderLinks.changeHandoff(in: store.directory) { links in
                if on {
                    guard source.authorized, let selected = links.selected, selected.listID == selectedListID,
                          scope == nil || selected == scope,
                          source.lists().contains(where: { $0.scope == selected }) else {
                        throw AppError.unavailable("请先授权并选择可写的提醒事项清单。")
                    }
                }
                links.autoSync = on
            }
            autoSync = on
            if on { await refresh() }
        } catch { message = error.localizedDescription }
    }

    func canResetHandoff(for id: UUID) -> Bool {
        guard !busy, autoSync, authorized, let link = handoffs[id], link.status == .needsReview,
              previewItems[link.scope] != nil, let selected = lists.first(where: { $0.id == selectedListID }) else { return false }
        return previewItems[selected.scope] != nil
    }

    func resetHandoff(_ id: UUID) async {
        guard let store, canResetHandoff(for: id), let expected = handoffs[id] else { return }
        do {
            try ReminderLinks.changeHandoff(in: store.directory) { links in
                let writable = Set(source.lists().map(\.scope))
                guard links.autoSync == true, links.exports?[id] == expected, writable.contains(expected.scope),
                      let scope = links.selected, scope.listID == selectedListID, writable.contains(scope),
                      try store.readableSnapshots().tasks.contains(where: { $0.id == id && $0.deletedAt == nil && !$0.isCompleted }) else {
                    throw AppError.unavailable("清单或关联已变化，请刷新核对。")
                }
                links.exports?.removeValue(forKey: id)
            }
            await refresh()
        } catch { message = error.localizedDescription }
    }

    // Keep both identity lookups scoped to lists successfully fetched in this round.
    private struct FetchedList {
        let markers: [URL: [MacReminderCandidate]]
        let externalIDs: [String: [MacReminderCandidate]]

        init(_ items: [MacReminderCandidate]) {
            markers = Dictionary(grouping: items.compactMap { item in item.marker.map { ($0, item) } },
                                 by: \.0).mapValues { $0.map(\.1) }
            externalIDs = Dictionary(grouping: items, by: \.externalID)
        }
    }

    private enum NewLink {
        case create, skip, copyOnly, unlinked, ambiguous
        case adopt(MacReminderCandidate)
    }

    private func newLink(for id: UUID, imported: ReminderImport?, selected: MacReminderScope,
                         lists: [MacReminderScope: FetchedList]) -> NewLink {
        guard let destination = lists[selected] else { return .skip }
        let marker = AppDestination.task(id).url
        if let imported {
            if imported.copyOnly == true { return .skip }
            guard let original = lists[imported.scope] else { return .skip }
            let matches = original.externalIDs[imported.externalID] ?? []
            if matches.count > 1 { return .unlinked }
            if let item = matches.first {
                if item.recurring { return .copyOnly }
                if item.marker == marker || !item.completed {
                    guard item.marker == nil || item.marker == marker else { return .unlinked }
                    let marked = original.markers[marker] ?? []
                    guard marked.isEmpty || (marked.count == 1 && marked.first == item) else { return .unlinked }
                    return .adopt(item)
                }
            }
        }
        let matches = destination.markers[marker] ?? []
        if matches.isEmpty { return .create }
        guard matches.count == 1, let item = matches.first, !item.externalID.isEmpty, !item.recurring else { return .ambiguous }
        return .adopt(item)
    }

    var attachedStoreID: ObjectIdentifier? { store.map(ObjectIdentifier.init) }

    var canPreviewSync: Bool {
        guard let id = selectedListID, let list = lists.first(where: { $0.id == id }) else { return false }
        return !busy && authorized && previewItems[list.scope] != nil
    }

    func syncPreview() -> (push: Int, importCount: Int) {
        guard let store else { return (0, 0) }
        do {
            let links = try ReminderLinks.read(from: store.directory)
            guard let selected = links.selected, previewItems[selected] != nil else { return (0, 0) }
            let fetched = previewItems.mapValues(FetchedList.init)
            let imports = Dictionary(grouping: links.imports, by: \.taskID)
            let readable = try store.readableSnapshots()
            let present = Set(readable.tasks.map(\.id)).union(readable.unreadableIDs)
            let push = readable.tasks.filter { task in
                guard task.deletedAt == nil, !task.isCompleted, links.exports?[task.id] == nil else { return false }
                if case .create = newLink(for: task.id, imported: imports[task.id]?.first, selected: selected,
                                          lists: fetched) { return true }
                return false
            }.count
            let alreadyCreated = Set(links.imports.filter { $0.scope == selected && present.contains($0.taskID) }.map(\.externalID))
            let count = candidates.filter { $0.canAutoImport && !alreadyCreated.contains($0.externalID) }.count
            return (push, count)
        } catch {
            message = error.localizedDescription
            previewItems = [:]
            return (0, 0)
        }
    }

    private func synchronize(store: TaskStore, token: UUID, fetched: [MacReminderScope: [MacReminderCandidate]],
                             verified: [UUID: MacReminderCandidate], examined: [UUID: ReminderExport],
                             selected: MacReminderScope?) throws {
        let links = try ReminderLinks.read(from: store.directory)
        guard isCurrent(token, store: store), links.autoSync == true, links.selected == selected, source.authorized else { return }
        let writable = Set(source.lists().map(\.scope))
        let indexes = fetched.filter { writable.contains($0.key) }.mapValues(FetchedList.init)
        var readable = try store.readableSnapshots()
        var unlinked = 0
        if let selected, indexes[selected] != nil, let items = fetched[selected] {
            // The handoff lock is now held. Another host may have imported an item during fetch.
            updateCandidates(items, links: links, allItemsFetched: true)
            unlinked = candidates.filter(\.requiresManualImport).count
            if try autoImport(links: links, unreadable: readable.unreadableIDs, store: store, token: token) {
                readable = try store.readableSnapshots()
            }
        }
        try updateLinkedTasks(readable: readable, indexes: indexes, verified: verified,
                              examined: examined, store: store, token: token)
        if let selected, indexes[selected] != nil, source.lists().contains(where: { $0.scope == selected }) {
            unlinked += try linkNewTasks(readable.tasks, selected: selected, indexes: indexes, store: store, token: token)
        }
        let final = try ReminderLinks.read(from: store.directory)
        applyHandoffState(final)
        for (id, link) in final.exports ?? [:] where !writable.contains(link.scope) {
            handoffStates[id] = .needsReview
        }
        updateSummary(unlinked: unlinked)
    }

    private func autoImport(links: ReminderLinks, unreadable: Set<UUID>, store: TaskStore, token: UUID) throws -> Bool {
        var importedAny = false
        var invalidItems = 0
        for item in candidates where !item.requiresManualImport {
            guard isCurrent(token, store: store), source.current(item.id) == item else { continue }
            guard item.canAutoImport else { invalidItems += 1; continue }
            let existing = links.imports.first { $0.matches(item) }
            if let existing, unreadable.contains(existing.taskID) { continue }
            var schedule = TaskSchedule.none
            if let day = item.dueDay, let end = day.addingIfPossible(days: 1) {
                schedule = .allDay(start: day, endExclusive: end)
            }
            try importItem(item, schedule: schedule, store: store)
            candidates.removeAll { $0.id == item.id }
            importedAny = true
        }
        if invalidItems > 0 { message = "\(invalidItems) 条提醒的标题或备注不符合导入条件，已跳过。" }
        return importedAny
    }

    private func updateLinkedTasks(readable: TaskStore.ReadableTasks, indexes: [MacReminderScope: FetchedList],
                                   verified: [UUID: MacReminderCandidate], examined: [UUID: ReminderExport],
                                   store: TaskStore, token: UUID) throws {
        let byID = Dictionary(uniqueKeysWithValues: readable.tasks.map { ($0.id, $0) })
        let directory = store.directory
        let current = try ReminderLinks.read(from: directory)
        for (id, export) in current.exports ?? [:] {
            // Never act on a link first created (or replaced) during this round's fetch.
            guard isCurrent(token, store: store), source.authorized, let index = indexes[export.scope],
                  examined[id] == export,
                  !readable.unreadableIDs.contains(id) else { continue }
            do {
                guard let task = byID[id] else {
                    try markForReview(id, directory: directory)
                    continue
                }
                let item = verified[id]
                if let item, source.current(item.id) != item { continue }
                if task.deletedAt != nil {
                    if !(index.markers[export.marker] ?? []).isEmpty && export.synced != nil {
                        guard let item, item.externalID == export.externalID else { continue }
                        try source.remove(item.id, expecting: export.scope, marker: export.marker, externalID: item.externalID)
                    }
                    try ReminderLinks.update(in: directory) { $0.exports?[id] = nil }
                } else if let item, item.externalID == export.externalID {
                    try push(task, export: export, item: item, directory: directory)
                }
            } catch {
                try markForReview(id, directory: directory)
                message = error.localizedDescription
            }
        }
    }

    private func linkNewTasks(_ tasks: [TaskSnapshot], selected: MacReminderScope, indexes: [MacReminderScope: FetchedList],
                              store: TaskStore, token: UUID) throws -> Int {
        var unlinked = 0
        let directory = store.directory
        let current = try ReminderLinks.read(from: directory)
        let imports = Dictionary(grouping: current.imports, by: \.taskID)
        newTasks: for task in tasks where !task.isCompleted && task.deletedAt == nil && current.exports?[task.id] == nil {
            guard isCurrent(token, store: store), source.authorized else { break }
            let marker = AppDestination.task(task.id).url
            switch newLink(for: task.id, imported: imports[task.id]?.first, selected: selected, lists: indexes) {
            case .skip: continue
            case .copyOnly:
                // Import records written before recurrence was recorded can still be identified in their original list.
                try ReminderLinks.update(in: directory) { links in
                    if let index = links.imports.firstIndex(where: { $0.taskID == task.id }) {
                        links.imports[index].copyOnly = true
                    }
                }
            case .unlinked: unlinked += 1
            case .ambiguous:
                try saveExport(ReminderExport(scope: selected, marker: marker, due: nil), for: task.id, in: directory)
            case let .adopt(item):
                // The persisted import already reserves this UUID and the original reminder's identity.
                do { try adopt(item, for: task, marker: marker, directory: directory) }
                catch { message = error.localizedDescription; unlinked += 1 }
            case .create:
                do { try createReminder(for: task, scope: selected, marker: marker, directory: directory) }
                catch {
                    message = error.localizedDescription
                    break newTasks
                }
            }
        }
        return unlinked
    }

    private func markForReview(_ id: UUID, directory: URL) throws {
        let saved = try ReminderLinks.read(from: directory)
        if let export = saved.exports?[id], export.status != .needsReview {
            try ReminderLinks.update(in: directory) { try $0.updateExport(id) { $0.status = .needsReview } }
        }
        handoffStates[id] = .needsReview
    }

    private func saveExport(_ export: ReminderExport, for id: UUID, in directory: URL) throws {
        try ReminderLinks.update(in: directory) { links in
            if links.exports == nil { links.exports = [:] }
            links.exports?[id] = export
        }
    }

    private func push(_ task: TaskSnapshot, export: ReminderExport, item: MacReminderCandidate, directory: URL) throws {
        let due = Self.reminderDue(for: task.schedule)
        // Initializing a legacy link preserves the deadline previously chosen on the reminder.
        let previous = export.synced ?? SyncedState(title: item.title, due: due, completed: item.completed)
        var patch = ReminderPatch()
        if previous.title != task.title { patch.title = task.title }
        if previous.due != due { patch.due = .some(due) }
        if previous.completed != task.isCompleted { patch.completed = task.isCompleted }
        if !patch.isEmpty {
            let saved = try source.update(item.id, expecting: export.scope, marker: export.marker, externalID: item.externalID, patch)
            guard saved.scope == export.scope, saved.marker == export.marker, saved.externalID == item.externalID,
                  patch.title == nil || patch.title == saved.title,
                  patch.completed == nil || patch.completed == saved.completed else {
                throw AppError.unavailable("提醒事项更新结果待核对，请刷新。")
            }
        }
        let next = SyncedState(title: task.title, due: due, completed: task.isCompleted)
        if export.synced != next || export.status != .sent {
            try ReminderLinks.update(in: directory) { links in
                try links.updateExport(task.id) {
                    $0.synced = next
                    $0.status = .sent
                    if let completed = patch.completed {
                        $0.completionApplied = completed
                        $0.pendingCompletionActionID = nil
                        $0.pendingCompletionBaseline = nil
                    }
                }
            }
        }
    }

    private func adopt(_ item: MacReminderCandidate, for task: TaskSnapshot, marker: URL, directory: URL) throws {
        guard source.current(item.id) == item else { throw AppError.unavailable("原提醒已变化，请刷新核对。") }
        var patch = ReminderPatch()
        if item.marker == nil { patch.marker = marker }
        if item.title != task.title { patch.title = task.title }
        let due = Self.reminderDue(for: task.schedule)
        var link = ReminderExport(scope: item.scope, marker: marker, due: nil, externalID: item.externalID,
                                  status: .sent, synced: SyncedState(title: item.title, due: due, completed: item.completed))
        if item.marker == marker && !patch.isEmpty {
            // A recovered marker may have no import reservation. Save its verified identity before editing.
            try saveExport(link, for: task.id, in: directory)
        }
        var saved = item
        if !patch.isEmpty {
            saved = try source.update(item.id, expecting: item.scope, marker: item.marker, externalID: item.externalID, patch)
        }
        guard saved.marker == marker, saved.externalID == item.externalID, saved.scope == item.scope else {
            throw AppError.unavailable("关联结果待核对，请刷新。")
        }
        link.synced = SyncedState(title: task.title, due: due, completed: saved.completed)
        try saveExport(link, for: task.id, in: directory)
        if saved.completed { refreshQueued = true }
    }

    private func createReminder(for task: TaskSnapshot, scope: MacReminderScope, marker: URL, directory: URL) throws {
        let due = Self.reminderDue(for: task.schedule)
        let initial = SyncedState(title: task.title, due: due, completed: false)
        var link = ReminderExport(scope: scope, marker: marker, due: nil, pendingCreation: initial)
        try saveExport(link, for: task.id, in: directory)
        let item = try source.create(title: task.title, due: due, marker: marker, in: scope)
        guard item.scope == scope, item.marker == marker, !item.externalID.isEmpty else {
            throw AppError.unavailable("发送结果待核对，请刷新。")
        }
        link.externalID = item.externalID
        link.status = .sent
        link.synced = initial
        link.pendingCreation = nil
        try saveExport(link, for: task.id, in: directory)
    }

    private func updateCandidates(_ items: [MacReminderCandidate], links: ReminderLinks, allItemsFetched: Bool) {
        let exportedIDs = Set((links.exports ?? [:]).values.filter { $0.scope == links.selected }.compactMap(\.externalID))
        let scoped = items.filter { item in
            guard !item.completed, !exportedIDs.contains(item.externalID) else { return false }
            if let marker = item.marker, case .task? = AppDestination(url: marker) { return false }
            return true
        }
        let groups = Dictionary(grouping: allItemsFetched ? items : scoped, by: \.externalID)
        candidates = scoped.filter { item in
            !item.externalID.isEmpty && groups[item.externalID]?.count == 1 &&
                !links.imports.contains { $0.committed && $0.matches(item) }
        }.sorted { ($0.title, $0.id) < ($1.title, $1.id) }
        if scoped.contains(where: { $0.externalID.isEmpty || groups[$0.externalID]?.count != 1 }) {
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
        guard !autoSync, !busy, let store, store.container != nil, source.authorized else {
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
            guard initial.autoSync != true else { throw AppError.unavailable("已开启提醒事项同步。") }
            let previous = initial.exports?[id]
            let reservation: ReminderExport
            if retryConfirmedByUser {
                guard let previous, previous.externalID == nil else {
                    throw AppError.unavailable("仅可重试尚未确认的发送。")
                }
                reservation = previous
            } else {
                guard previous == nil else { throw AppError.unavailable("此任务已有发送记录，请刷新核对。") }
                guard let selected = initial.selected else { throw AppError.unavailable("请选择可写的提醒事项清单。") }
                reservation = ReminderExport(scope: selected, marker: AppDestination.task(id).url, due: due)
            }
            let scope = reservation.scope
            guard source.lists().contains(where: { $0.scope == scope }) else {
                throw AppError.unavailable("原清单当前不可写，请检查账户和清单。")
            }
            let existing = try await source.reminders(in: scope, includingCompleted: true)
            guard isCurrent(token, store: store) else { return }
            guard source.authorized, source.lists().contains(where: { $0.scope == scope }) else {
                throw AppError.unavailable("清单或授权已变化。")
            }
            let matches = existing.filter { $0.scope == scope && $0.marker == reservation.marker }
            if !matches.isEmpty {
                guard retryConfirmedByUser, matches.count == 1 else {
                    throw AppError.unavailable("清单中已有相同的任务链接，请核对已有提醒。")
                }
                _ = try reconcile(id, link: reservation, matches: matches, store: store, readable: store.readableSnapshots())
                message = handoffStatus(for: id) == .sent ? "已找到原提醒。" : "原提醒的身份仍待核对。"
                return
            }
            guard let task = try store.snapshots().first(where: { $0.id == id }),
                  task.deletedAt == nil, !task.isCompleted else {
                throw AppError.unavailable("只能发送当前库中未完成的任务。")
            }
            // Reserve before calling EventKit. An ordinary retry never creates a second reminder.
            try ReminderLinks.update(in: store.directory) { links in
                if retryConfirmedByUser {
                    guard let pending = links.exports?[id], pending.externalID == nil, pending.scope == scope,
                          pending.marker == reservation.marker else { throw AppError.unavailable("发送状态已变化。") }
                } else {
                    guard links.selected == scope, links.exports?[id] == nil else {
                        throw AppError.unavailable("清单或发送状态已变化，请刷新。")
                    }
                    if links.exports == nil { links.exports = [:] }
                    links.exports?[id] = reservation
                }
            }
            handoffStates[id] = .needsReview
            handoffs[id] = reservation
            let item = try source.create(title: task.title, due: reservation.due.map(ReminderDue.day), marker: reservation.marker, in: scope)
            guard item.scope == scope, item.marker == reservation.marker, !item.externalID.isEmpty else {
                throw AppError.unavailable("发送结果待核对，请刷新。")
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
                throw AppError.unavailable("提醒事项身份不一致，请核对原清单。")
            }
            try links.updateExport(id) {
                $0.externalID = externalID
                $0.status = .sent
                if let initial = $0.pendingCreation {
                    $0.synced = initial
                    $0.pendingCreation = nil
                }
            }
        }
        handoffStates[id] = .sent
        handoffs[id]?.externalID = externalID
        handoffs[id]?.status = .sent
    }

    private func reconcile(_ id: UUID, link expected: ReminderExport, matches: [MacReminderCandidate],
                           store: TaskStore, readable: TaskStore.ReadableTasks) throws -> MacReminderCandidate? {
        // Both callers hold the handoff lock; another host could have acknowledged a
        // completion while this host was awaiting its EventKit fetch.
        guard let link = try ReminderLinks.read(from: store.directory).exports?[id],
              link.scope == expected.scope, link.marker == expected.marker else { return nil }
        guard matches.count == 1, let item = matches.first, !item.externalID.isEmpty,
              link.externalID == nil || link.externalID == item.externalID,
              (!autoSync || !item.recurring), source.current(item.id) == item else {
            if link.status != .needsReview {
                try ReminderLinks.update(in: store.directory) { try $0.updateExport(id) { $0.status = .needsReview } }
            }
            handoffStates[id] = .needsReview
            return nil
        }
        guard link.completionApplied || link.pendingCompletionBaseline == nil || link.pendingCompletionActionID != nil else {
            try ReminderLinks.update(in: store.directory) { links in
                try links.updateExport(id) { $0.status = .needsReview }
            }
            handoffStates[id] = .needsReview
            handoffs[id]?.status = .needsReview
            message = "旧版完成回收曾中断，无法确认是否已执行。请在本机核对任务完成状态。"
            return nil
        }
        if link.externalID == nil || link.status != .sent {
            try confirm(id, externalID: item.externalID, directory: store.directory)
        }
        handoffStates[id] = .sent
        guard item.completed, !link.completionApplied else { return item }
        guard !readable.unreadableIDs.contains(id), let task = readable.tasks.first(where: { $0.id == id }) else { return nil }
        if task.deletedAt == nil {
            // Reserve a stable action before writing. TaskStore records the action in the
            // same transaction as completion, so a retry never overwrites a later reopening.
            let actionID = link.pendingCompletionActionID ?? UUID()
            if link.pendingCompletionActionID == nil {
                try ReminderLinks.update(in: store.directory) { links in
                    try links.updateExport(id) { $0.pendingCompletionActionID = actionID }
                }
            }
            try store.setCompleted(id: id, completed: true, actionID: actionID)
        }
        try ReminderLinks.update(in: store.directory) { links in
            try links.updateExport(id) {
                $0.completionApplied = true
                $0.synced?.completed = true
                $0.pendingCompletionActionID = nil
                $0.pendingCompletionBaseline = nil
            }
        }
        return item
    }

    func importCandidate(_ candidate: MacReminderCandidate) {
        guard !busy, let store, store.container != nil, candidates.contains(candidate),
              source.authorized, source.lists().contains(where: { $0.scope == candidate.scope }),
              source.current(candidate.id) == candidate else {
            message = "提醒事项或授权已变化，请刷新后重试。"
            return
        }
        do {
            try importItem(candidate, schedule: .none, store: store)
            candidates.removeAll { $0.id == candidate.id }
            message = "已导入到「待办」。"
        } catch { message = error.localizedDescription }
    }

    private func importItem(_ candidate: MacReminderCandidate, schedule: TaskSchedule, store: TaskStore) throws {
        _ = try TaskStore.validTitle(candidate.title)
        let taskID = try ReminderLinks.update(in: store.directory) { links in
            guard links.selected == candidate.scope else { throw AppError.unavailable("清单已变化，请刷新。") }
            if let existing = links.imports.first(where: { $0.matches(candidate) }) { return existing.taskID }
            let id = UUID()
            links.imports.append(ReminderImport(scope: candidate.scope, externalID: candidate.externalID, taskID: id,
                                               copyOnly: candidate.recurring ? true : nil))
            return id
        }
        try store.createTask(id: taskID, title: candidate.title, schedule: schedule, body: candidate.notes)
        try ReminderLinks.update(in: store.directory) { links in
            guard let index = links.imports.firstIndex(where: { $0.taskID == taskID }) else {
                throw AppError.unavailable("导入关联不可用，请检查本机数据。")
            }
            links.imports[index].committed = true
            if candidate.recurring { links.imports[index].copyOnly = true }
        }
    }
}
