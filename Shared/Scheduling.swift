import Foundation

/// Errors raised while validating the date and schedule value types used by
/// the calendar projection.
public enum SchedulingError: LocalizedError, Equatable, Sendable {
    case invalidDay(String)
    case invalidSchedule(String)

    public var errorDescription: String? {
        switch self {
        case .invalidDay: "日期无效，请使用有效的公历日期。"
        case .invalidSchedule: "计划的起止日期或时区无效；原安排未改动。"
        }
    }
}

/// A canonical Gregorian calendar day.  A `Day` has no time zone; a time zone
/// is only used when converting it to or from an absolute `Date`.
public struct Day: Hashable, Comparable, Codable, Sendable, Identifiable {
    public let rawValue: String

    public var id: String { rawValue }

    /// Nil when the Monday falls outside the supported day domain.
    public var weekStart: Day? {
        let weekday = Self.gregorian(timeZone: .gmt).component(.weekday, from: date(in: .gmt))
        return addingIfPossible(days: -((weekday + 5) % 7))
    }

    public init(_ rawValue: String) throws {
        let bytes = Array(rawValue.utf8)
        guard bytes.count == 10,
              bytes[4] == 45,
              bytes[7] == 45,
              bytes[0...3].allSatisfy({ $0 >= 48 && $0 <= 57 }),
              bytes[5...6].allSatisfy({ $0 >= 48 && $0 <= 57 }),
              bytes[8...9].allSatisfy({ $0 >= 48 && $0 <= 57 }) else {
            throw SchedulingError.invalidDay(rawValue)
        }

        let year = Self.number(from: bytes[0...3])
        let month = Self.number(from: bytes[5...6])
        let day = Self.number(from: bytes[8...9])
        guard let date = Self.gregorianDate(year: year, month: month, day: day) else {
            throw SchedulingError.invalidDay(rawValue)
        }

        let calendar = Self.gregorian(timeZone: .gmt)
        let normalized = calendar.dateComponents([.era, .year, .month, .day], from: date)
        guard normalized.era == 1,
              normalized.year == year,
              normalized.month == month,
              normalized.day == day else {
            throw SchedulingError.invalidDay(rawValue)
        }

        self.rawValue = rawValue
    }

    public init(date: Date, timeZone: TimeZone) {
        guard let valid = Self.from(date: date, timeZone: timeZone) else {
            preconditionFailure("Date cannot be represented as a Gregorian Day")
        }
        self = valid
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func < (lhs: Day, rhs: Day) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Adds calendar days using the Gregorian calendar.  This operation does
    /// not treat a day as a fixed number of seconds.
    public func adding(days: Int) -> Day {
        guard let result = addingIfPossible(days: days) else {
            preconditionFailure("Day arithmetic overflowed the supported YYYY-MM-DD range")
        }
        return result
    }

    /// Returns local midnight for this day in `timeZone`.
    public func date(in timeZone: TimeZone) -> Date {
        let components = calendarComponents
        let calendar = Self.gregorian(timeZone: timeZone)
        let dateComponents = DateComponents(
            calendar: calendar,
            timeZone: timeZone,
            year: components.year,
            month: components.month,
            day: components.day,
            hour: 0,
            minute: 0,
            second: 0,
            nanosecond: 0
        )
        guard let date = calendar.date(from: dateComponents) else {
            preconditionFailure("Day has no representable midnight in the supplied time zone")
        }
        return date
    }

    fileprivate var calendarComponents: (year: Int, month: Int, day: Int) {
        let bytes = Array(rawValue.utf8)
        return (
            Self.number(from: bytes[0...3]),
            Self.number(from: bytes[5...6]),
            Self.number(from: bytes[8...9])
        )
    }

    fileprivate static func from(date: Date, timeZone: TimeZone) -> Day? {
        guard date.timeIntervalSinceReferenceDate.isFinite else { return nil }
        let calendar = Self.gregorian(timeZone: timeZone)
        let components = calendar.dateComponents([.era, .year, .month, .day], from: date)
        guard components.era == 1,
              let year = components.year,
              let month = components.month,
              let day = components.day,
              let rawValue = Self.canonicalString(year: year, month: month, day: day) else {
            return nil
        }
        return try? Self(rawValue)
    }

    public func addingIfPossible(days: Int) -> Day? {
        let components = calendarComponents
        let calendar = Self.gregorian(timeZone: .gmt)
        let baseComponents = DateComponents(
            calendar: calendar,
            timeZone: .gmt,
            year: components.year,
            month: components.month,
            day: components.day,
            hour: 12,
            minute: 0,
            second: 0,
            nanosecond: 0
        )
        guard let base = calendar.date(from: baseComponents),
              let result = calendar.date(byAdding: .day, value: days, to: base) else {
            return nil
        }

        let resultComponents = calendar.dateComponents([.era, .year, .month, .day], from: result)
        guard resultComponents.era == 1,
              let year = resultComponents.year,
              let month = resultComponents.month,
              let day = resultComponents.day,
              let rawValue = Self.canonicalString(year: year, month: month, day: day) else {
            return nil
        }
        return try? Day(rawValue)
    }

    fileprivate static func distance(from start: Day, to end: Day) -> Int? {
        let calendar = Self.gregorian(timeZone: .gmt)
        return calendar.dateComponents(
            [.day],
            from: start.date(in: .gmt),
            to: end.date(in: .gmt)
        ).day
    }

    fileprivate static func make(year: Int, month: Int, day: Int) -> Day {
        guard let rawValue = canonicalString(year: year, month: month, day: day),
              let result = try? Day(rawValue) else {
            preconditionFailure("Invalid Gregorian Day components")
        }
        return result
    }

    private static func gregorian(timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    private static func gregorianDate(year: Int, month: Int, day: Int) -> Date? {
        let calendar = gregorian(timeZone: .gmt)
        let components = DateComponents(
            calendar: calendar,
            timeZone: .gmt,
            year: year,
            month: month,
            day: day,
            hour: 0,
            minute: 0,
            second: 0,
            nanosecond: 0
        )
        return calendar.date(from: components)
    }

    private static func canonicalString(year: Int, month: Int, day: Int) -> String? {
        guard (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day) else {
            return nil
        }
        return "\(padded(year, width: 4))-\(padded(month, width: 2))-\(padded(day, width: 2))"
    }

    private static func padded(_ value: Int, width: Int) -> String {
        let text = String(value)
        return String(repeating: "0", count: max(0, width - text.count)) + text
    }

    private static func number(from bytes: ArraySlice<UInt8>) -> Int {
        bytes.reduce(into: 0) { result, byte in
            result = result * 10 + Int(byte - 48)
        }
    }
}

public enum TaskSchedule: Codable, Equatable, Sendable {
    case none
    /// A commitment to a week, without occupying any particular calendar day.
    case week(start: Day)
    case allDay(start: Day, endExclusive: Day)
    case timed(start: Date, end: Date, timeZoneID: String)

    public func validated() throws -> Self {
        switch self {
        case .none:
            return self
        case .week(let start):
            guard start == start.weekStart, start.addingIfPossible(days: 7) != nil else {
                throw SchedulingError.invalidSchedule("weekly plan must begin on a Monday and fit the day domain")
            }
            return self
        case let .allDay(start, endExclusive):
            guard start < endExclusive else {
                throw SchedulingError.invalidSchedule("all-day schedule must have a positive half-open range")
            }
            return self
        case let .timed(start, end, timeZoneID):
            guard start.timeIntervalSinceReferenceDate.isFinite,
                  end.timeIntervalSinceReferenceDate.isFinite,
                  start < end else {
                throw SchedulingError.invalidSchedule("timed schedule must have finite start and end with start < end")
            }
            guard !timeZoneID.isEmpty,
                  let timeZone = TimeZone(identifier: timeZoneID) else {
                throw SchedulingError.invalidSchedule("timed schedule has an unknown time zone identifier")
            }
            guard Day.from(date: start, timeZone: timeZone) != nil,
                  Day.from(date: end, timeZone: timeZone) != nil else {
                throw SchedulingError.invalidSchedule("timed schedule dates must fit the YYYY-MM-DD day domain")
            }
            return self
        }
    }

    public static func singleDay(_ day: Day) -> Self {
        .allDay(start: day, endExclusive: day.addingIfPossible(days: 1) ?? day)
    }

    /// Moves the schedule by the difference between the source day displayed
    /// in `displayTimeZone` and `day`.  A timed schedule keeps its original
    /// time zone's local clock where possible and keeps its elapsed duration.
    /// Foundation's Gregorian calendar resolves a nonexistent local clock
    /// (for example, during a spring DST jump) to its normalized valid instant.
    /// If that normalization cannot land on `day` in the display time zone,
    /// the move throws instead of silently selecting an adjacent day.
    public func moved(to day: Day, displayTimeZone: TimeZone) throws -> Self {
        let schedule = try validated()
        switch schedule {
        case .none:
            return .none
        case .week:
            guard let end = day.addingIfPossible(days: 1) else {
                throw SchedulingError.invalidSchedule("weekly plan cannot be placed outside the day domain")
            }
            return .allDay(start: day, endExclusive: end)
        case let .allDay(start, endExclusive):
            guard let length = Day.distance(from: start, to: endExclusive), length > 0,
                  let movedEnd = day.addingIfPossible(days: length) else {
                throw SchedulingError.invalidSchedule("all-day schedule cannot be moved")
            }
            return .allDay(start: day, endExclusive: movedEnd)
        case let .timed(start, end, timeZoneID):
            let duration = end.timeIntervalSince(start)
            guard let sourceDisplayDay = Day.from(date: start, timeZone: displayTimeZone),
                  let originalTimeZone = TimeZone(identifier: timeZoneID),
                  let dayDelta = Day.distance(from: sourceDisplayDay, to: day),
                  duration.isFinite else {
                throw SchedulingError.invalidSchedule("timed schedule cannot be moved in the requested display time zone")
            }

            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = originalTimeZone
            guard let movedStart = calendar.date(byAdding: .day, value: dayDelta, to: start) else {
                throw SchedulingError.invalidSchedule("timed schedule cannot be moved across the requested days")
            }
            let movedEnd = movedStart.addingTimeInterval(duration)
            guard movedStart.timeIntervalSinceReferenceDate.isFinite,
                  movedEnd.timeIntervalSinceReferenceDate.isFinite,
                  Day.from(date: movedStart, timeZone: originalTimeZone) != nil,
                  Day.from(date: movedEnd, timeZone: originalTimeZone) != nil,
                  movedStart < movedEnd else {
                throw SchedulingError.invalidSchedule("timed schedule move produced an invalid range")
            }
            guard Day.from(date: movedStart, timeZone: displayTimeZone) == day else {
                throw SchedulingError.invalidSchedule("timed schedule move could not land on the requested display day")
            }
            return .timed(start: movedStart, end: movedEnd, timeZoneID: timeZoneID)
        }
    }

    /// Projects the schedule onto local calendar days.  The returned range is
    /// half-open; a timed interval ending exactly at local midnight does not
    /// include the following day.
    public func dayRange(in timeZone: TimeZone) -> Range<Day>? {
        guard (try? validated()) != nil else { return nil }
        switch self {
        case .none, .week:
            return nil
        case let .allDay(start, endExclusive):
            return start..<endExclusive
        case let .timed(start, end, _):
            guard let startDay = Day.from(date: start, timeZone: timeZone),
                  let endDay = Day.from(date: end, timeZone: timeZone) else {
                return nil
            }
            let endExclusive: Day
            if Self.isLocalMidnight(end, timeZone: timeZone) {
                endExclusive = endDay
            } else {
                guard let nextDay = endDay.addingIfPossible(days: 1) else { return nil }
                endExclusive = nextDay
            }

            if endExclusive <= startDay {
                guard let nextDay = startDay.addingIfPossible(days: 1) else { return nil }
                return startDay..<nextDay
            }
            return startDay..<endExclusive
        }
    }

    private static func isLocalMidnight(_ date: Date, timeZone: TimeZone) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
        return components.hour == 0 && components.minute == 0 && components.second == 0 && components.nanosecond == 0
    }
}

public struct CalendarTask: Identifiable, Sendable {
    public let id: UUID
    public let title: String
    public let schedule: TaskSchedule
    public let isCompleted: Bool
    public let preview: String

    public init(id: UUID, title: String, schedule: TaskSchedule, isCompleted: Bool, preview: String = "") {
        self.id = id
        self.title = title
        self.schedule = schedule
        self.isCompleted = isCompleted
        self.preview = String((preview.split(whereSeparator: \.isNewline).first ?? "").prefix(160))
    }
}

public struct MonthSegment: Identifiable, Sendable {
    public let taskID: UUID
    public let weekStart: Day
    public let startColumn: Int
    public let dayCount: Int
    public let lane: Int
    public let continuesBefore: Bool
    public let continuesAfter: Bool

    public var id: String {
        "\(taskID.uuidString)|\(weekStart.rawValue)"
    }

    public init(
        taskID: UUID,
        weekStart: Day,
        startColumn: Int,
        dayCount: Int,
        lane: Int,
        continuesBefore: Bool,
        continuesAfter: Bool
    ) {
        self.taskID = taskID
        self.weekStart = weekStart
        self.startColumn = startColumn
        self.dayCount = dayCount
        self.lane = lane
        self.continuesBefore = continuesBefore
        self.continuesAfter = continuesAfter
    }
}

public struct MonthLayout: Sendable {
    public let days: [Day]
    public let segments: [MonthSegment]
    public let hiddenCounts: [Day: Int]
    public let visibleLaneCount: Int

    public static func make(
        month: Day,
        tasks: [CalendarTask],
        timeZone: TimeZone,
        visibleLaneCount: Int = 3
    ) -> MonthLayout {
        let firstOfMonth = Day.make(
            year: month.calendarComponents.year,
            month: month.calendarComponents.month,
            day: 1
        )
        let calendar = Self.gregorianUTC
        let firstWeekday = calendar.component(.weekday, from: firstOfMonth.date(in: .gmt))
        let firstColumn = (firstWeekday + 5) % 7 // Monday = 0
        let visibleStart = firstOfMonth.adding(days: -firstColumn)

        let daysInMonth = calendar.range(
            of: .day,
            in: .month,
            for: firstOfMonth.date(in: .gmt)
        )?.count ?? 1
        let lastOfMonth = firstOfMonth.adding(days: daysInMonth - 1)
        let lastWeekday = calendar.component(.weekday, from: lastOfMonth.date(in: .gmt))
        let lastColumn = (lastWeekday + 5) % 7
        let visibleEndExclusive = lastOfMonth.adding(days: 7 - lastColumn)
        let dayCount = Day.distance(from: visibleStart, to: visibleEndExclusive) ?? 0
        let days = (0..<max(0, dayCount)).map { visibleStart.adding(days: $0) }
        let normalizedVisibleLaneCount = max(0, visibleLaneCount)

        var uniqueTaskIDs = Set<UUID>()
        var items: [LayoutItem] = []
        for task in tasks {
            guard uniqueTaskIDs.insert(task.id).inserted,
                  let taskRange = task.schedule.dayRange(in: timeZone),
                  taskRange.lowerBound < visibleEndExclusive,
                  visibleStart < taskRange.upperBound,
                  let spanLength = Day.distance(from: taskRange.lowerBound, to: taskRange.upperBound),
                  spanLength > 0 else {
                continue
            }
            items.append(LayoutItem(taskID: task.id, range: taskRange, spanLength: spanLength))
        }

        var segments: [MonthSegment] = []
        var hiddenTaskIDsByDay = Dictionary(uniqueKeysWithValues: days.map { ($0, Set<UUID>()) })

        for weekOffset in stride(from: 0, to: days.count, by: 7) {
            let weekStart = visibleStart.adding(days: weekOffset)
            let weekEndExclusive = weekStart.adding(days: 7)
            let candidates = items.compactMap { item -> SegmentCandidate? in
                let start = max(max(item.range.lowerBound, weekStart), visibleStart)
                let end = min(min(item.range.upperBound, weekEndExclusive), visibleEndExclusive)
                guard start < end,
                      let startColumn = Day.distance(from: weekStart, to: start),
                      let dayCount = Day.distance(from: start, to: end),
                      dayCount > 0 else {
                    return nil
                }
                return SegmentCandidate(
                    taskID: item.taskID,
                    originalRange: item.range,
                    start: start,
                    end: end,
                    startColumn: startColumn,
                    dayCount: dayCount,
                    spanLength: item.spanLength
                )
            }.sorted { lhs, rhs in
                if lhs.start != rhs.start { return lhs.start < rhs.start }
                if lhs.spanLength != rhs.spanLength { return lhs.spanLength > rhs.spanLength }
                return lhs.taskID.uuidString < rhs.taskID.uuidString
            }

            var occupiedLanes: [[Range<Int>]] = []
            for candidate in candidates {
                var lane = 0
                let candidateColumns = candidate.startColumn..<(candidate.startColumn + candidate.dayCount)
                while true {
                    if lane == occupiedLanes.count {
                        occupiedLanes.append([])
                    }
                    let overlaps = occupiedLanes[lane].contains { occupied in
                        candidateColumns.lowerBound < occupied.upperBound && occupied.lowerBound < candidateColumns.upperBound
                    }
                    if !overlaps {
                        occupiedLanes[lane].append(candidateColumns)
                        break
                    }
                    lane += 1
                }

                let segment = MonthSegment(
                    taskID: candidate.taskID,
                    weekStart: weekStart,
                    startColumn: candidate.startColumn,
                    dayCount: candidate.dayCount,
                    lane: lane,
                    continuesBefore: candidate.originalRange.lowerBound < candidate.start,
                    continuesAfter: candidate.end < candidate.originalRange.upperBound
                )
                segments.append(segment)

                for offset in 0..<candidate.dayCount {
                    let day = candidate.start.adding(days: offset)
                    if lane >= normalizedVisibleLaneCount {
                        hiddenTaskIDsByDay[day, default: Set<UUID>()].insert(candidate.taskID)
                    }
                }
            }
        }

        segments.sort { lhs, rhs in
            if lhs.weekStart != rhs.weekStart { return lhs.weekStart < rhs.weekStart }
            if lhs.lane != rhs.lane { return lhs.lane < rhs.lane }
            if lhs.startColumn != rhs.startColumn { return lhs.startColumn < rhs.startColumn }
            return lhs.taskID.uuidString < rhs.taskID.uuidString
        }

        let hiddenCounts = Dictionary(uniqueKeysWithValues: days.map { ($0, hiddenTaskIDsByDay[$0]?.count ?? 0) })
        return MonthLayout(
            days: days,
            segments: segments,
            hiddenCounts: hiddenCounts,
            visibleLaneCount: normalizedVisibleLaneCount
        )
    }

    private static var gregorianUTC: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }
}

private struct LayoutItem {
    let taskID: UUID
    let range: Range<Day>
    let spanLength: Int
}

private struct SegmentCandidate {
    let taskID: UUID
    let originalRange: Range<Day>
    let start: Day
    let end: Day
    let startColumn: Int
    let dayCount: Int
    let spanLength: Int
}
