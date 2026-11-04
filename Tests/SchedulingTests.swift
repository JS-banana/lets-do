import XCTest
@testable import TodoM0

final class SchedulingTests: XCTestCase {
    func testDayUsesCanonicalGregorianDates() throws {
        XCTAssertEqual(try Day("2024-02-29").rawValue, "2024-02-29")
        XCTAssertEqual(try Day("2000-02-29").rawValue, "2000-02-29")

        for rawValue in [
            "2024-2-29",
            "2024/02/29",
            "2024-02-30",
            "1900-02-29",
            "0000-01-01",
            "2024-02-29 "
        ] {
            XCTAssertThrowsError(try Day(rawValue), "Expected (rawValue) to be rejected")
        }
    }

    func testDayArithmeticCrossesMonthAndYearWithCalendarDays() throws {
        XCTAssertEqual(day("2024-02-28").adding(days: 1), day("2024-02-29"))
        XCTAssertEqual(day("2024-02-29").adding(days: 1), day("2024-03-01"))
        XCTAssertEqual(day("2024-12-31").adding(days: 1), day("2025-01-01"))
        XCTAssertEqual(day("2025-01-01").adding(days: -1), day("2024-12-31"))

        let tokyo = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        XCTAssertEqual(Day(date: day("2024-02-29").date(in: tokyo), timeZone: tokyo), day("2024-02-29"))
    }

    func testAllDayRangeIsHalfOpenAndMovementPreservesSpan() throws {
        let original = TaskSchedule.allDay(start: day("2024-10-21"), endExclusive: day("2024-10-24"))
        XCTAssertEqual(original.dayRange(in: .gmt), day("2024-10-21")..<day("2024-10-24"))
        XCTAssertThrowsError(try TaskSchedule.allDay(start: day("2024-10-21"), endExclusive: day("2024-10-21")).validated())
        XCTAssertThrowsError(try TaskSchedule.allDay(start: day("2024-10-24"), endExclusive: day("2024-10-21")).validated())

        let moved = try original.moved(to: day("2024-11-02"), displayTimeZone: .gmt)
        guard case let .allDay(start, endExclusive) = moved else {
            return XCTFail("Expected an all-day schedule")
        }
        XCTAssertEqual(start, day("2024-11-02"))
        XCTAssertEqual(endExclusive, day("2024-11-05"))
        let losAngeles = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        XCTAssertEqual(moved.dayRange(in: losAngeles), day("2024-11-02")..<day("2024-11-05"))
        XCTAssertEqual(moved.dayRange(in: .gmt), day("2024-11-02")..<day("2024-11-05"))
    }

    func testTimedValidationRejectsDatesOutsideDayDomainAndProjectionDoesNotCrashAtUpperBound() throws {
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let lastRepresentableDay = localDate("9999-12-31", hour: 23, timeZone: utc)
        let outsideDayDomain = TaskSchedule.timed(
            start: lastRepresentableDay,
            end: lastRepresentableDay.addingTimeInterval(60 * 60),
            timeZoneID: "UTC"
        )
        XCTAssertThrowsError(try outsideDayDomain.validated())
        XCTAssertNil(outsideDayDomain.dayRange(in: utc))

        let firstRepresentableDay = localDate("0001-01-01", hour: 0, timeZone: utc)
        let belowDayDomain = TaskSchedule.timed(
            start: firstRepresentableDay.addingTimeInterval(-60),
            end: firstRepresentableDay,
            timeZoneID: "UTC"
        )
        XCTAssertThrowsError(try belowDayDomain.validated())
        XCTAssertNil(belowDayDomain.dayRange(in: utc))

        let validDatesAtUpperBound = TaskSchedule.timed(
            start: localDate("9999-12-31", hour: 23, timeZone: utc),
            end: localDate("9999-12-31", hour: 23, minute: 30, timeZone: utc),
            timeZoneID: "UTC"
        )
        XCTAssertNoThrow(try validDatesAtUpperBound.validated())
        XCTAssertNil(validDatesAtUpperBound.dayRange(in: utc))
    }

    func testTimedRangeExcludesAnEndAtLocalMidnight() throws {
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let sameDay = TaskSchedule.timed(
            start: localDate("2024-01-10", hour: 10, timeZone: utc),
            end: localDate("2024-01-10", hour: 11, timeZone: utc),
            timeZoneID: "UTC"
        )
        XCTAssertEqual(sameDay.dayRange(in: utc), day("2024-01-10")..<day("2024-01-11"))

        let endsAtMidnight = TaskSchedule.timed(
            start: localDate("2024-01-10", hour: 23, timeZone: utc),
            end: localDate("2024-01-11", hour: 0, timeZone: utc),
            timeZoneID: "UTC"
        )
        XCTAssertEqual(endsAtMidnight.dayRange(in: utc), day("2024-01-10")..<day("2024-01-11"))

        let endsAfterMidnight = TaskSchedule.timed(
            start: localDate("2024-01-10", hour: 23, timeZone: utc),
            end: localDate("2024-01-11", hour: 0, minute: 1, timeZone: utc),
            timeZoneID: "UTC"
        )
        XCTAssertEqual(endsAfterMidnight.dayRange(in: utc), day("2024-01-10")..<day("2024-01-12"))
    }

    func testTimedMovementUsesCalendarDaysAcrossDSTAndPreservesDuration() throws {
        let newYork = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let springSchedule = TaskSchedule.timed(
            start: localDate("2024-03-09", hour: 2, minute: 30, timeZone: newYork),
            end: localDate("2024-03-09", hour: 3, minute: 30, timeZone: newYork),
            timeZoneID: "America/New_York"
        )
        let springMoved = try springSchedule.moved(to: day("2024-03-10"), displayTimeZone: newYork)
        guard case let .timed(springStart, springEnd, springTimeZoneID) = springMoved else {
            return XCTFail("Expected a timed schedule")
        }
        XCTAssertEqual(springTimeZoneID, "America/New_York")
        XCTAssertEqual(Day(date: springStart, timeZone: newYork), day("2024-03-10"))
        XCTAssertEqual(localHour(springStart, in: newYork), 3, "02:30 is normalized to the first valid local time after the spring jump")
        XCTAssertEqual(springEnd.timeIntervalSince(springStart), 60 * 60, accuracy: 0.001)

        let fallSchedule = TaskSchedule.timed(
            start: localDate("2024-11-02", hour: 1, minute: 30, timeZone: newYork),
            end: localDate("2024-11-02", hour: 2, minute: 30, timeZone: newYork),
            timeZoneID: "America/New_York"
        )
        let fallMoved = try fallSchedule.moved(to: day("2024-11-03"), displayTimeZone: newYork)
        guard case let .timed(fallStart, fallEnd, _) = fallMoved else {
            return XCTFail("Expected a timed schedule")
        }
        XCTAssertEqual(Day(date: fallStart, timeZone: newYork), day("2024-11-03"))
        XCTAssertEqual(localHour(fallStart, in: newYork), 1)
        XCTAssertEqual(fallEnd.timeIntervalSince(fallStart), 60 * 60, accuracy: 0.001)
    }

    func testMonthStartsOnMondayAndProducesFourToSixWeeks() throws {
        let layout = MonthLayout.make(month: day("2024-02-29"), tasks: [], timeZone: .gmt)
        XCTAssertEqual(layout.days.first, day("2024-01-29"))
        XCTAssertEqual(layout.days.last, day("2024-03-03"))
        XCTAssertTrue([28, 35, 42].contains(layout.days.count))
        XCTAssertEqual(layout.days.count % 7, 0)
        XCTAssertEqual(layout.hiddenCounts.count, layout.days.count)
    }

    func testMonthLayoutClipsCrossMonthAndYearTaskAtVisibleBoundary() throws {
        let task = calendarTask(
            "00000000-0000-0000-0000-000000000011",
            schedule: .allDay(start: day("2022-12-31"), endExclusive: day("2023-01-03"))
        )
        let layout = MonthLayout.make(month: day("2023-01-10"), tasks: [task], timeZone: .gmt)
        XCTAssertEqual(layout.segments.count, 2)
        let firstSegment = try XCTUnwrap(layout.segments.first)
        let secondSegment = try XCTUnwrap(layout.segments.last)

        XCTAssertEqual(firstSegment.weekStart, day("2022-12-26"))
        XCTAssertEqual(firstSegment.startColumn, 5)
        XCTAssertEqual(firstSegment.dayCount, 2)
        XCTAssertFalse(firstSegment.continuesBefore)
        XCTAssertTrue(firstSegment.continuesAfter)
        XCTAssertEqual(secondSegment.weekStart, day("2023-01-02"))
        XCTAssertEqual(secondSegment.startColumn, 0)
        XCTAssertEqual(secondSegment.dayCount, 1)
        XCTAssertTrue(secondSegment.continuesBefore)
        XCTAssertFalse(secondSegment.continuesAfter)
    }

    func testMonthLanesAreStableAndHiddenCountsUseDistinctTasks() throws {
        let weekOfMaySixth = day("2024-05-06")
        let taskA = calendarTask(
            "00000000-0000-0000-0000-000000000001",
            schedule: .allDay(start: weekOfMaySixth, endExclusive: day("2024-05-09"))
        )
        let taskB = calendarTask(
            "00000000-0000-0000-0000-000000000002",
            schedule: .allDay(start: weekOfMaySixth, endExclusive: day("2024-05-07"))
        )
        let taskC = calendarTask(
            "00000000-0000-0000-0000-000000000003",
            schedule: .allDay(start: weekOfMaySixth, endExclusive: day("2024-05-07"))
        )

        let first = MonthLayout.make(
            month: day("2024-05-15"),
            tasks: [taskC, taskA, taskB, taskB],
            timeZone: .gmt,
            visibleLaneCount: 1
        )
        let second = MonthLayout.make(
            month: day("2024-05-15"),
            tasks: [taskB, taskA, taskC],
            timeZone: .gmt,
            visibleLaneCount: 1
        )

        let firstWeekSegments = first.segments.filter { $0.weekStart == weekOfMaySixth }
        XCTAssertEqual(firstWeekSegments.count, 3, "Duplicate task IDs must not create duplicate segments")
        XCTAssertEqual(first.segments.map(\.id), second.segments.map(\.id))
        XCTAssertEqual(first.segments.map(\.lane), second.segments.map(\.lane))

        let lanesByTask = Dictionary(uniqueKeysWithValues: firstWeekSegments.map { ($0.taskID, $0.lane) })
        XCTAssertEqual(lanesByTask[taskA.id], 0)
        XCTAssertEqual(lanesByTask[taskB.id], 1)
        XCTAssertEqual(lanesByTask[taskC.id], 2)
        XCTAssertEqual(first.hiddenCounts[weekOfMaySixth], 2)
    }

    func testCrossWeekSegmentsPreserveContinuationAndDoNotDoubleCount() throws {
        let task = calendarTask(
            "00000000-0000-0000-0000-000000000010",
            schedule: .allDay(start: day("2024-04-28"), endExclusive: day("2024-05-15"))
        )
        let layout = MonthLayout.make(
            month: day("2024-05-15"),
            tasks: [task, task],
            timeZone: .gmt,
            visibleLaneCount: 0
        )

        XCTAssertEqual(layout.segments.count, 3)
        XCTAssertTrue(layout.segments.allSatisfy { $0.taskID == task.id && $0.lane == 0 })
        XCTAssertTrue(layout.segments[0].continuesBefore)
        XCTAssertTrue(layout.segments[0].continuesAfter)
        XCTAssertTrue(layout.segments[1].continuesBefore)
        XCTAssertTrue(layout.segments[1].continuesAfter)
        XCTAssertTrue(layout.segments[2].continuesBefore)
        XCTAssertFalse(layout.segments[2].continuesAfter)
        XCTAssertEqual(layout.hiddenCounts[day("2024-05-06")], 1)
    }

    func testTimedMovementPreservesLocalClockAndDurationOnOrdinaryDays() throws {
        let shanghai = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let schedule = TaskSchedule.timed(
            start: localDate("2024-06-10", hour: 14, minute: 15, timeZone: shanghai),
            end: localDate("2024-06-10", hour: 16, minute: 45, timeZone: shanghai),
            timeZoneID: "Asia/Shanghai"
        )
        let moved = try schedule.moved(to: day("2024-06-13"), displayTimeZone: shanghai)
        guard case let .timed(start, end, timeZoneID) = moved else {
            return XCTFail("Expected a timed schedule")
        }
        XCTAssertEqual(timeZoneID, "Asia/Shanghai")
        XCTAssertEqual(Day(date: start, timeZone: shanghai), day("2024-06-13"))
        XCTAssertEqual(localHour(start, in: shanghai), 14)
        XCTAssertEqual(localMinute(start, in: shanghai), 15)
        XCTAssertEqual(end.timeIntervalSince(start), 150 * 60, accuracy: 0.001)
    }

    func testTimedMovementThrowsWhenDisplayDayCannotBePreservedAcrossTimeZones() throws {
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let apia = try XCTUnwrap(TimeZone(identifier: "Pacific/Apia"))
        let schedule = TaskSchedule.timed(
            start: localDate("2011-12-29", hour: 10, timeZone: utc),
            end: localDate("2011-12-29", hour: 11, timeZone: utc),
            timeZoneID: "UTC"
        )

        XCTAssertThrowsError(try schedule.moved(to: day("2011-12-30"), displayTimeZone: apia)) { error in
            guard case let SchedulingError.invalidSchedule(message) = error else {
                return XCTFail("Expected an explainable invalid schedule error")
            }
            XCTAssertTrue(message.contains("display day"))
        }
    }

    func testTimedMovementPreservesLandingWhenDisplayTimeZoneDiffers() throws {
        let shanghai = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let losAngeles = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let schedule = TaskSchedule.timed(
            start: localDate("2024-06-10", hour: 14, minute: 15, timeZone: shanghai),
            end: localDate("2024-06-10", hour: 16, minute: 15, timeZone: shanghai),
            timeZoneID: "Asia/Shanghai"
        )

        let moved = try schedule.moved(to: day("2024-06-10"), displayTimeZone: losAngeles)
        guard case let .timed(start, end, _) = moved else {
            return XCTFail("Expected a timed schedule")
        }
        XCTAssertEqual(Day(date: start, timeZone: losAngeles), day("2024-06-10"))
        XCTAssertEqual(Day(date: start, timeZone: shanghai), day("2024-06-11"))
        XCTAssertEqual(localHour(start, in: shanghai), 14)
        XCTAssertEqual(localMinute(start, in: shanghai), 15)
        XCTAssertEqual(end.timeIntervalSince(start), 120 * 60, accuracy: 0.001)
    }

    private func day(_ rawValue: String) -> Day {
        do {
            return try Day(rawValue)
        } catch {
            fatalError("Invalid test day \(rawValue): \(error)")
        }
    }

    private func calendarTask(_ uuid: String, schedule: TaskSchedule) -> CalendarTask {
        CalendarTask(id: UUID(uuidString: uuid)!, title: uuid, schedule: schedule, isCompleted: false)
    }

    private func localDate(
        _ rawDay: String,
        hour: Int,
        minute: Int = 0,
        second: Int = 0,
        timeZone: TimeZone
    ) -> Date {
        let base = day(rawDay).date(in: timeZone)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let dateParts = calendar.dateComponents([.year, .month, .day], from: base)
        return calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: timeZone,
            year: dateParts.year,
            month: dateParts.month,
            day: dateParts.day,
            hour: hour,
            minute: minute,
            second: second,
            nanosecond: 0
        ))!
    }

    private func localHour(_ date: Date, in timeZone: TimeZone) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.component(.hour, from: date)
    }

    private func localMinute(_ date: Date, in timeZone: TimeZone) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.component(.minute, from: date)
    }
}
