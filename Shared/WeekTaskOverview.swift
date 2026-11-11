import Foundation

/// The deterministic, data-only projection used by the medium single-column
/// week widget.
public struct WeekTaskOverview: Sendable {
    public struct Group: Identifiable, Sendable {
        public let day: Day?
        public let tasks: [CalendarTask]
        public let totalCount: Int

        public var hiddenCount: Int {
            max(0, totalCount - tasks.count)
        }

        public var id: String {
            day?.rawValue ?? "pending"
        }

        public init(day: Day?, tasks: [CalendarTask], totalCount: Int) {
            self.day = day
            self.tasks = tasks
            self.totalCount = totalCount
        }
    }

    public let weekStart: Day
    public let today: Group
    public let upcoming: [Group]
    public let pendingCount: Int
    public let pastScheduledCount: Int
    public let otherScheduledCount: Int
    public let completedTodayCount: Int
    public let completedWeekCount: Int

    private struct ResolvedTask {
        let task: CalendarTask
        let range: Range<Day>?
        let start: Date?
    }

    private struct Candidate {
        let day: Day?
        let tasks: [ResolvedTask]
    }

    /// Makes a projection for the Monday–Sunday week containing `today`.
    /// Invalid schedules and schedules outside that week are ignored.
    public static func make(
        today: Day,
        tasks: [CalendarTask],
        timeZone: TimeZone
    ) -> WeekTaskOverview? {
        guard let weekStart = today.weekStart,
              let weekEndExclusive = weekStart.addingIfPossible(days: 7) else {
            return nil
        }

        // Keep the same first-occurrence behavior as the existing calendar
        // views, then sort every output group independently below.
        var seenIDs = Set<UUID>()
        let uniqueTasks = tasks.filter { seenIDs.insert($0.id).inserted }

        let resolvedTasks = uniqueTasks.compactMap { task -> ResolvedTask? in
            switch task.schedule {
            case .none:
                return nil
            case let .week(start):
                guard start == weekStart, (try? task.schedule.validated()) != nil else {
                    return nil
                }
                return ResolvedTask(task: task, range: nil, start: nil)
            case .allDay, .timed:
                guard let range = task.schedule.dayRange(in: timeZone),
                      range.lowerBound < weekEndExclusive,
                      weekStart < range.upperBound else {
                    return nil
                }
                let start: Date
                switch task.schedule {
                case let .allDay(startDay, _):
                    start = startDay.date(in: timeZone)
                case let .timed(startDate, _, _):
                    start = startDate
                case .none, .week:
                    return nil
                }
                return ResolvedTask(task: task, range: range, start: start)
            }
        }

        var completedTodayCount = 0
        var completedWeekCount = 0
        for item in resolvedTasks where item.task.isCompleted {
            if let range = item.range {
                if range.contains(today) {
                    completedTodayCount += 1
                }
                if range.lowerBound < weekEndExclusive && weekStart < range.upperBound {
                    completedWeekCount += 1
                }
            } else {
                // A current-week `.week` task has no day occupancy, but is a
                // completed item in this week's total.
                completedWeekCount += 1
            }
        }

        var todayTasks: [ResolvedTask] = []
        var futureByDay: [Day: [ResolvedTask]] = [:]
        var pastTaskCount = 0
        var pendingTasks: [ResolvedTask] = []

        for item in resolvedTasks where !item.task.isCompleted {
            guard let range = item.range else {
                pendingTasks.append(item)
                continue
            }

            if range.contains(today) {
                todayTasks.append(item)
            } else if range.lowerBound > today {
                // The intersection check above makes the lower bound the
                // first day this task touches in the current week.
                futureByDay[range.lowerBound, default: []].append(item)
            } else {
                // The task intersects this week but its half-open range ended
                // before today. Keep it available through the other count.
                pastTaskCount += 1
            }
        }

        todayTasks.sort(by: areOrderedBefore)
        pendingTasks.sort(by: areOrderedBefore)
        for day in futureByDay.keys {
            futureByDay[day]?.sort(by: areOrderedBefore)
        }

        let futureCandidates = futureByDay.keys.sorted().map { day in
            Candidate(day: day, tasks: futureByDay[day] ?? [])
        }
        var candidates = futureCandidates
        if !pendingTasks.isEmpty {
            candidates.append(Candidate(day: nil, tasks: pendingTasks))
        }

        let visibleTasksPerGroup = candidates.count == 1 ? 2 : 1
        let selectedCandidates = Array(candidates.prefix(2))
        let upcoming = selectedCandidates.map {
            Group(
                day: $0.day,
                tasks: $0.tasks.prefix(visibleTasksPerGroup).map(\.task),
                totalCount: $0.tasks.count
            )
        }

        var selectedFutureDays = Set<Day>()
        for candidate in selectedCandidates {
            if let day = candidate.day {
                selectedFutureDays.insert(day)
            }
        }

        var otherScheduledCount = pastTaskCount
        for (day, dayTasks) in futureByDay where !selectedFutureDays.contains(day) {
            otherScheduledCount += dayTasks.count
        }

        return WeekTaskOverview(
            weekStart: weekStart,
            today: Group(
                day: today,
                tasks: todayTasks.prefix(2).map(\.task),
                totalCount: todayTasks.count
            ),
            upcoming: upcoming,
            pendingCount: pendingTasks.count,
            pastScheduledCount: pastTaskCount,
            otherScheduledCount: otherScheduledCount,
            completedTodayCount: completedTodayCount,
            completedWeekCount: completedWeekCount
        )
    }

    private static func areOrderedBefore(_ lhs: ResolvedTask, _ rhs: ResolvedTask) -> Bool {
        if let leftRange = lhs.range,
           let rightRange = rhs.range,
           leftRange.lowerBound != rightRange.lowerBound {
            return leftRange.lowerBound < rightRange.lowerBound
        }
        if let leftStart = lhs.start,
           let rightStart = rhs.start,
           leftStart != rightStart {
            return leftStart < rightStart
        }
        return lhs.task.id.uuidString < rhs.task.id.uuidString
    }
}
