import Foundation

protocol ScheduledTask: Identifiable where ID == UUID {
    var schedule: TaskSchedule { get }
    var isCompleted: Bool { get }
}

extension CalendarTask: ScheduledTask {}
extension TaskSnapshot: ScheduledTask {}

/// A read-only view across calendar days. Never reschedules the underlying tasks.
struct TodayTasks<Item: ScheduledTask> {
    let scheduled: [Item]
    let earlier: [Item]
    let finishedToday: [Item]

    init(_ items: [Item], on day: Day, timeZone: TimeZone) {
        var scheduled: [Item] = []
        var earlier: [(item: Item, end: Day)] = []
        var finished: [Item] = []
        var seen: Set<UUID> = []
        for item in items where seen.insert(item.id).inserted {
            switch item.schedule {
            case .none:
                continue
            case .week(let start):
                if !item.isCompleted, (try? item.schedule.validated()) != nil,
                   let end = start.addingIfPossible(days: 7), end <= day {
                    earlier.append((item, end))
                }
            case .allDay, .timed:
                guard let range = item.schedule.dayRange(in: timeZone) else { continue }
                if range.contains(day) {
                    if item.isCompleted { finished.append(item) }
                    else { scheduled.append(item) }
                } else if !item.isCompleted && range.upperBound <= day {
                    earlier.append((item, range.upperBound))
                }
            }
        }

        func scheduledOrder(_ first: Item, _ second: Item) -> Bool {
            switch (first.schedule, second.schedule) {
            case (.allDay, .timed): return true
            case (.timed, .allDay): return false
            case let (.timed(a, _, _), .timed(b, _, _)) where a != b: return a < b
            default: return first.id.uuidString < second.id.uuidString
            }
        }
        self.scheduled = scheduled.sorted(by: scheduledOrder)
        self.finishedToday = finished.sorted(by: scheduledOrder)
        self.earlier = earlier.sorted { a, b in
            a.end == b.end ? a.item.id.uuidString < b.item.id.uuidString : a.end > b.end
        }.map(\.item)
    }

    /// On a small widget, keep one actionable carry-over. On medium, show both groups.
    func visibleRows(limit: Int) -> (scheduled: [Item], earlier: [Item]) {
        let count = max(0, limit)
        let todayCount = earlier.isEmpty ? count : max(0, count - 1)
        let todayRows = Array(scheduled.prefix(todayCount))
        return (todayRows, Array(earlier.prefix(count - todayRows.count)))
    }
}

/// Groups unfinished tasks for the to-do list by their plan. Read-only like TodayTasks,
/// whose rules decide the carry-over and today groups so both pages agree.
struct TodoSections<Item: ScheduledTask> {
    enum Group: CaseIterable, Sendable {
        case earlier, today, thisWeek, later, unscheduled

        var title: String {
            switch self {
            case .earlier: "此前未完成"
            case .today: "今天"
            case .thisWeek: "本周"
            case .later: "以后"
            case .unscheduled: "未安排"
            }
        }
    }

    struct Section: Identifiable {
        let group: Group
        let items: [Item]
        var id: Group { group }
    }

    /// Non-empty groups in display order.
    let groups: [Section]

    init(_ items: [Item], on day: Day, timeZone: TimeZone) {
        var seen = Set<UUID>()
        let open = items.filter { !$0.isCompleted && seen.insert($0.id).inserted }
        let overview = TodayTasks(open, on: day, timeZone: timeZone)
        let placed = Set(overview.earlier.map(\.id) + overview.scheduled.map(\.id))
        let nextMonday = (day.weekStart ?? day).addingIfPossible(days: 7)
        typealias Entry = (item: Item, start: Day?, wholeWeek: Bool)
        var thisWeek: [Entry] = []
        var later: [Entry] = []
        var unscheduled: [Item] = []
        for item in open where !placed.contains(item.id) {
            let entry: Entry
            switch item.schedule {
            case .none:
                unscheduled.append(item)
                continue
            case .week(let monday):
                entry = (item, monday, true)
            case .allDay, .timed:
                entry = (item, item.schedule.dayRange(in: timeZone)?.lowerBound, false)
            }
            if let start = entry.start, let nextMonday, start < nextMonday { thisWeek.append(entry) }
            else { later.append(entry) }
        }
        // By first planned day; a whole-week plan sorts after the days of its week.
        func ordered(_ entries: [Entry]) -> [Item] {
            func order(_ entry: Entry) -> Day? { entry.wholeWeek ? entry.start?.addingIfPossible(days: 7) : entry.start }
            return entries.sorted { a, b in
                let (first, second) = (order(a), order(b))
                if first != second {
                    guard let first else { return false }
                    guard let second else { return true }
                    return first < second
                }
                if a.wholeWeek != b.wholeWeek { return !a.wholeWeek }
                return a.item.id.uuidString < b.item.id.uuidString
            }.map(\.item)
        }
        groups = [
            Section(group: .earlier, items: overview.earlier), Section(group: .today, items: overview.scheduled),
            Section(group: .thisWeek, items: ordered(thisWeek)), Section(group: .later, items: ordered(later)),
            Section(group: .unscheduled, items: unscheduled)
        ].filter { !$0.items.isEmpty }
    }
}

enum WeekTaskList: String, Sendable {
    case previousWeeks = "previous-weeks"
    case pending = "pending"

    var title: String {
        switch self {
        case .previousWeeks: "往周未完成"
        case .pending: "本周待安排"
        }
    }

    func tasks<Item: ScheduledTask>(from items: [Item], weekStart: Day, timeZone: TimeZone) -> [Item] {
        switch self {
        case .previousWeeks:
            return TodayTasks(items, on: weekStart, timeZone: timeZone).earlier
        case .pending:
            var seen = Set<UUID>()
            return items.filter {
                seen.insert($0.id).inserted && !$0.isCompleted && $0.schedule == .week(start: weekStart)
            }
        }
    }
}
