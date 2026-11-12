import Foundation

/// A Monday–Sunday projection for the medium week widget.
public struct WeekTaskOverview: Sendable {
    public struct DayCount: Identifiable, Sendable {
        public let day: Day
        public let unfinishedCount: Int
        /// Tasks covering this day whose titles are absent from the summary.
        public let unshownCount: Int
        public var id: Day { day }
    }

    public struct Row: Identifiable, Sendable {
        public let task: CalendarTask
        /// The day represented in the summary. A week-only task has no day.
        public let day: Day?
        public var id: UUID { task.id }
    }

    public let weekStart: Day
    public let days: [DayCount]
    public let rows: [Row]
    public let unfinishedCount: Int
    public let pendingCount: Int
    public let completedWeekCount: Int

    public static func make(today: Day, tasks: [CalendarTask], timeZone: TimeZone, rowLimit: Int = 3) -> Self? {
        guard let weekStart = today.weekStart,
              let weekEnd = weekStart.addingIfPossible(days: 7) else { return nil }
        let weekDays = (0..<7).map { weekStart.adding(days: $0) }
        var counts: [Day: Int] = [:]
        var past: [Row] = []
        var current: [Row] = []
        var future: [Row] = []
        var pending: [Row] = []
        var completed = 0
        var seen: Set<UUID> = []

        for task in tasks where seen.insert(task.id).inserted {
            if case let .week(start) = task.schedule {
                guard start == weekStart else { continue }
                if task.isCompleted { completed += 1 }
                else { pending.append(Row(task: task, day: nil)) }
                continue
            }
            guard let range = task.schedule.dayRange(in: timeZone),
                  range.overlaps(weekStart..<weekEnd) else { continue }
            if task.isCompleted {
                completed += 1
                continue
            }

            // Each occupied day gets a count, but each task gets just one row.
            for day in weekDays where range.contains(day) {
                counts[day, default: 0] += 1
            }
            if range.contains(today) {
                current.append(Row(task: task, day: today))
            } else if range.upperBound <= today {
                past.append(Row(task: task, day: range.upperBound.adding(days: -1)))
            } else {
                future.append(Row(task: task, day: range.lowerBound))
            }
        }

        func rowOrder(_ lhs: Row, _ rhs: Row) -> Bool {
            let leftDay = lhs.day ?? weekEnd
            let rightDay = rhs.day ?? weekEnd
            if leftDay != rightDay { return leftDay < rightDay }
            switch (lhs.task.schedule, rhs.task.schedule) {
            case (.allDay, .timed): return true
            case (.timed, .allDay): return false
            case let (.timed(a, _, _), .timed(b, _, _)) where a != b: return a < b
            default: return lhs.id.uuidString < rhs.id.uuidString
            }
        }
        past.sort { lhs, rhs in
            if let leftDay = lhs.day, let rightDay = rhs.day, leftDay != rightDay {
                return leftDay > rightDay
            }
            return rowOrder(lhs, rhs)
        }
        current.sort(by: rowOrder)
        future.sort(by: rowOrder)
        pending.sort(by: rowOrder)

        let limit = max(1, rowLimit)
        func differentDaysFirst(_ rows: [Row]) -> [Row] {
            var seenDays: Set<Day?> = []
            var distinctDays: [Row] = []
            var sameDay: [Row] = []
            for row in rows {
                if seenDays.insert(row.day).inserted {
                    distinctDays.append(row)
                    if distinctDays.count == limit { return distinctDays }
                } else if sameDay.count < limit - 1 {
                    sameDay.append(row)
                }
            }
            return Array((distinctDays + sameDay).prefix(limit))
        }
        let groups = [differentDaysFirst(past), current, differentDaysFirst(future), pending]
        // Reserve a title for each kind of work before filling any spare lines.
        let firstRows = groups.compactMap(\.first)
        let extraRows = groups.flatMap { $0.dropFirst().prefix(limit - 1) }
        let visible = (firstRows + extraRows).prefix(limit).sorted(by: rowOrder)
        let visibleRanges = visible.compactMap { $0.task.schedule.dayRange(in: timeZone) }
        return Self(
            weekStart: weekStart,
            days: weekDays.map { day in
                let count = counts[day, default: 0]
                let shown = visibleRanges.filter { $0.contains(day) }.count
                return DayCount(day: day, unfinishedCount: count, unshownCount: count - shown)
            },
            rows: visible,
            unfinishedCount: past.count + current.count + future.count + pending.count,
            pendingCount: pending.count,
            completedWeekCount: completed
        )
    }
}
