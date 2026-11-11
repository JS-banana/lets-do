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
    let inboxCount: Int

    init(_ items: [Item], on day: Day, timeZone: TimeZone) {
        var scheduled: [Item] = []
        var earlier: [(item: Item, end: Day)] = []
        var finished: [Item] = []
        var inboxCount = 0
        var seen: Set<UUID> = []
        for item in items where seen.insert(item.id).inserted {
            switch item.schedule {
            case .none:
                if !item.isCompleted { inboxCount += 1 }
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
        self.inboxCount = inboxCount
    }

    /// On a small widget, keep one actionable carry-over. On medium, show both groups.
    func visibleRows(limit: Int) -> (scheduled: [Item], earlier: [Item]) {
        let count = max(0, limit)
        let todayCount = earlier.isEmpty ? count : max(0, count - 1)
        let todayRows = Array(scheduled.prefix(todayCount))
        return (todayRows, Array(earlier.prefix(count - todayRows.count)))
    }
}
