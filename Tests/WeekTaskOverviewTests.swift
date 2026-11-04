import XCTest
@testable import TodoM0

final class WeekTaskOverviewTests: XCTestCase {
    private let gmt = TimeZone.gmt

    private func day(_ rawValue: String) throws -> Day {
        try Day(rawValue)
    }

    private func taskID(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!
    }

    private func allDay(
        _ index: Int,
        start: Day,
        endExclusive: Day,
        completed: Bool = false
    ) -> CalendarTask {
        CalendarTask(
            id: taskID(index),
            title: "task-\(index)",
            schedule: .allDay(start: start, endExclusive: endExclusive),
            isCompleted: completed
        )
    }

    private func pending(
        _ index: Int,
        weekStart: Day,
        completed: Bool = false
    ) -> CalendarTask {
        CalendarTask(
            id: taskID(index),
            title: "pending-\(index)",
            schedule: .week(start: weekStart),
            isCompleted: completed
        )
    }

    private func timed(
        _ index: Int,
        start: Date,
        end: Date,
        timeZone: TimeZone,
        completed: Bool = false
    ) -> CalendarTask {
        CalendarTask(
            id: taskID(index),
            title: "timed-\(index)",
            schedule: .timed(start: start, end: end, timeZoneID: timeZone.identifier),
            isCompleted: completed
        )
    }

    func testShowsTodayAndTwoFutureDatesWithPerGroupOverflow() throws {
        let monday = try day("2026-10-26")
        let wednesday = monday.adding(days: 2)
        let friday = monday.adding(days: 4)
        let tasks = (1...2).map { allDay($0, start: monday, endExclusive: monday.adding(days: 1)) }
            + (3...5).map { allDay($0, start: wednesday, endExclusive: wednesday.adding(days: 1)) }
            + (6...9).map { allDay($0, start: friday, endExclusive: friday.adding(days: 1)) }

        let overview = try XCTUnwrap(WeekTaskOverview.make(today: monday, tasks: tasks, timeZone: gmt))
        XCTAssertEqual(overview.today.day, monday)
        XCTAssertEqual(overview.today.totalCount, 2)
        XCTAssertEqual(overview.today.tasks.count, 2)
        XCTAssertEqual(overview.today.hiddenCount, 0)
        XCTAssertEqual(overview.upcoming.map(\.day), [wednesday, friday])
        XCTAssertEqual(overview.upcoming.map(\.totalCount), [3, 4])
        XCTAssertEqual(overview.upcoming.map(\.hiddenCount), [2, 3])
        XCTAssertEqual(overview.otherScheduledCount, 0)
    }

    func testBusyTodayStillLeavesFutureGroupsVisible() throws {
        let monday = try day("2026-10-26")
        let wednesday = monday.adding(days: 2)
        let friday = monday.adding(days: 4)
        let tasks = (1...5).map { allDay($0, start: monday, endExclusive: monday.adding(days: 1)) }
            + [allDay(6, start: wednesday, endExclusive: wednesday.adding(days: 1)),
               allDay(7, start: friday, endExclusive: friday.adding(days: 1))]

        let overview = try XCTUnwrap(WeekTaskOverview.make(today: monday, tasks: tasks, timeZone: gmt))
        XCTAssertEqual(overview.today.totalCount, 5)
        XCTAssertEqual(overview.today.tasks.count, 2)
        XCTAssertEqual(overview.today.hiddenCount, 3)
        XCTAssertEqual(overview.upcoming.map(\.day), [wednesday, friday])
        XCTAssertEqual(overview.upcoming.map(\.tasks.count), [1, 1])
    }

    func testSingleFutureGroupShowsTwoItemsAndItsOverflow() throws {
        let monday = try day("2026-10-26")
        let wednesday = monday.adding(days: 2)
        let tasks = (1...2).map { allDay($0, start: monday, endExclusive: monday.adding(days: 1)) }
            + (3...9).map { allDay($0, start: wednesday, endExclusive: wednesday.adding(days: 1)) }

        let overview = try XCTUnwrap(WeekTaskOverview.make(today: monday, tasks: tasks, timeZone: gmt))
        let group = try XCTUnwrap(overview.upcoming.first)
        XCTAssertEqual(overview.upcoming.count, 1)
        XCTAssertEqual(group.day, wednesday)
        XCTAssertEqual(group.totalCount, 7)
        XCTAssertEqual(group.tasks.count, 2)
        XCTAssertEqual(group.hiddenCount, 5)
    }

    func testUUIDDeduplicationAndReorderedInputHaveStableRepresentatives() throws {
        let monday = try day("2026-10-26")
        let wednesday = monday.adding(days: 2)
        let first = allDay(1, start: wednesday, endExclusive: wednesday.adding(days: 1))
        let second = allDay(2, start: wednesday, endExclusive: wednesday.adding(days: 1))
        let duplicate = first

        let firstProjection = try XCTUnwrap(
            WeekTaskOverview.make(today: monday, tasks: [second, duplicate, first], timeZone: gmt)
        )
        let reorderedProjection = try XCTUnwrap(
            WeekTaskOverview.make(today: monday, tasks: [first, second, duplicate], timeZone: gmt)
        )

        XCTAssertEqual(firstProjection.upcoming.first?.totalCount, 2)
        XCTAssertEqual(firstProjection.upcoming.first?.tasks.map(\.id), [taskID(1), taskID(2)])
        XCTAssertEqual(
            firstProjection.upcoming.first?.tasks.map(\.id),
            reorderedProjection.upcoming.first?.tasks.map(\.id)
        )
    }

    func testCompletedItemsStayOutOfGroupsButRemainInCounts() throws {
        let monday = try day("2026-10-26")
        let wednesday = monday.adding(days: 2)
        let tasks = [
            allDay(1, start: monday, endExclusive: monday.adding(days: 1)),
            allDay(2, start: monday, endExclusive: monday.adding(days: 1), completed: true),
            allDay(3, start: wednesday, endExclusive: wednesday.adding(days: 1), completed: true),
            pending(4, weekStart: monday, completed: true),
            pending(5, weekStart: monday)
        ]

        let overview = try XCTUnwrap(WeekTaskOverview.make(today: monday, tasks: tasks, timeZone: gmt))
        XCTAssertEqual(overview.today.totalCount, 1)
        XCTAssertEqual(overview.today.tasks.map(\.id), [taskID(1)])
        XCTAssertEqual(overview.pendingCount, 1)
        XCTAssertEqual(overview.upcoming.map(\.day), [nil])
        XCTAssertEqual(overview.completedTodayCount, 1)
        XCTAssertEqual(overview.completedWeekCount, 3)

        let empty = try XCTUnwrap(WeekTaskOverview.make(today: monday, tasks: [], timeZone: gmt))
        XCTAssertEqual(empty.today.totalCount, 0)
        XCTAssertTrue(empty.upcoming.isEmpty)
        XCTAssertEqual(empty.pendingCount, 0)
        XCTAssertEqual(empty.otherScheduledCount, 0)
        XCTAssertEqual(empty.completedTodayCount, 0)
        XCTAssertEqual(empty.completedWeekCount, 0)
    }

    func testCrossDayTasksAppearInOnlyTheirAssignedGroup() throws {
        let monday = try day("2026-10-26")
        let wednesday = monday.adding(days: 2)
        let thursday = monday.adding(days: 3)
        let friday = monday.adding(days: 4)
        let saturday = monday.adding(days: 5)
        let sunday = monday.adding(days: 6)
        let tasks = [
            // It starts before today and continues into the future, but today owns it.
            allDay(1, start: monday, endExclusive: friday),
            // A future cross-day task belongs to its first future day only.
            allDay(2, start: thursday, endExclusive: sunday),
            allDay(3, start: friday, endExclusive: saturday)
        ]

        let overview = try XCTUnwrap(WeekTaskOverview.make(today: wednesday, tasks: tasks, timeZone: gmt))
        let displayed = overview.today.tasks + overview.upcoming.flatMap(\.tasks)
        XCTAssertEqual(displayed.map(\.id).filter { $0 == taskID(1) }.count, 1)
        XCTAssertEqual(displayed.map(\.id).filter { $0 == taskID(2) }.count, 1)
        XCTAssertEqual(displayed.map(\.id).filter { $0 == taskID(3) }.count, 1)
        XCTAssertEqual(overview.upcoming.map(\.day), [thursday, friday])
        XCTAssertEqual(overview.upcoming.first?.tasks.first?.id, taskID(2))
        XCTAssertEqual(overview.upcoming.last?.tasks.first?.id, taskID(3))
        XCTAssertNotEqual(overview.upcoming.first?.day, saturday)
    }

    func testPendingGroupIsLastAndUnselectedPendingRemainsCounted() throws {
        let monday = try day("2026-10-26")
        let wednesday = monday.adding(days: 2)
        let friday = monday.adding(days: 4)
        let sunday = monday.adding(days: 6)
        let tasks = [
            allDay(1, start: wednesday, endExclusive: wednesday.adding(days: 1)),
            allDay(2, start: friday, endExclusive: friday.adding(days: 1)),
            allDay(3, start: sunday, endExclusive: monday.adding(days: 7)),
            pending(4, weekStart: monday)
        ]

        let overview = try XCTUnwrap(WeekTaskOverview.make(today: monday, tasks: tasks, timeZone: gmt))
        XCTAssertEqual(overview.pendingCount, 1)
        XCTAssertEqual(overview.upcoming.map(\.day), [wednesday, friday])
        XCTAssertFalse(overview.upcoming.contains { $0.day == nil })
        XCTAssertEqual(overview.otherScheduledCount, 1)

        let pendingOnly = try XCTUnwrap(
            WeekTaskOverview.make(today: monday, tasks: [pending(5, weekStart: monday)], timeZone: gmt)
        )
        XCTAssertEqual(pendingOnly.upcoming.map(\.id), ["pending"])
        XCTAssertEqual(pendingOnly.upcoming.first?.tasks.count, 1)
    }

    func testSundayDoesNotShowNextWeekSchedulesOrPending() throws {
        let sunday = try day("2026-11-01")
        let monday = try day("2026-11-02")
        let currentWeek = try XCTUnwrap(sunday.weekStart)
        let tasks = [
            allDay(1, start: sunday, endExclusive: monday),
            allDay(2, start: monday, endExclusive: monday.adding(days: 1)),
            pending(3, weekStart: currentWeek),
            pending(4, weekStart: monday)
        ]

        let overview = try XCTUnwrap(WeekTaskOverview.make(today: sunday, tasks: tasks, timeZone: gmt))
        XCTAssertEqual(overview.weekStart, currentWeek)
        XCTAssertEqual(overview.today.totalCount, 1)
        XCTAssertEqual(overview.pendingCount, 1)
        XCTAssertEqual(overview.upcoming.map(\.day), [nil])
        XCTAssertEqual(overview.otherScheduledCount, 0)
    }

    func testCrossYearWeekKeepsSundayAndExcludesNextMonday() throws {
        let friday = try day("2027-01-01")
        let sunday = try day("2027-01-03")
        let nextMonday = try day("2027-01-04")
        let tasks = [
            allDay(1, start: sunday, endExclusive: nextMonday),
            allDay(2, start: nextMonday, endExclusive: nextMonday.adding(days: 1))
        ]

        let overview = try XCTUnwrap(WeekTaskOverview.make(today: friday, tasks: tasks, timeZone: gmt))
        XCTAssertEqual(overview.weekStart, try day("2026-12-28"))
        XCTAssertEqual(overview.upcoming.map(\.day), [sunday])
        XCTAssertEqual(overview.upcoming.first?.tasks.map(\.id), [taskID(1)])
    }

    func testPastUncompletedSchedulesCountAsOther() throws {
        let monday = try day("2026-10-26")
        let tuesday = monday.adding(days: 1)
        let wednesday = monday.adding(days: 2)
        let thursday = monday.adding(days: 3)
        let friday = monday.adding(days: 4)
        let tasks = [
            allDay(1, start: monday, endExclusive: tuesday),
            allDay(2, start: monday, endExclusive: thursday),
            allDay(3, start: thursday, endExclusive: friday)
        ]

        let overview = try XCTUnwrap(WeekTaskOverview.make(today: wednesday, tasks: tasks, timeZone: gmt))
        XCTAssertEqual(overview.today.tasks.map(\.id), [taskID(2)])
        XCTAssertEqual(overview.otherScheduledCount, 1)
        XCTAssertFalse(overview.today.tasks.contains { $0.id == taskID(1) })
    }

    func testHalfOpenMidnightAndDSTDayProjection() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let sunday = try day("2026-03-08")
        let monday = sunday.adding(days: 1)
        let saturday = sunday.adding(days: -1)
        let midnight = sunday.date(in: zone)
        let endedAtMidnight = timed(
            1,
            start: saturday.date(in: zone).addingTimeInterval(23 * 60 * 60 + 30 * 60),
            end: midnight,
            timeZone: zone
        )
        let crossesDST = timed(
            2,
            start: midnight.addingTimeInterval(90 * 60),
            end: monday.date(in: zone).addingTimeInterval(30 * 60),
            timeZone: zone
        )

        XCTAssertEqual(endedAtMidnight.schedule.dayRange(in: zone), saturday..<sunday)
        XCTAssertEqual(crossesDST.schedule.dayRange(in: zone), sunday..<monday.adding(days: 1))
        let overview = try XCTUnwrap(
            WeekTaskOverview.make(today: sunday, tasks: [endedAtMidnight, crossesDST], timeZone: zone)
        )
        XCTAssertEqual(overview.today.tasks.map(\.id), [taskID(2)])
        XCTAssertEqual(overview.otherScheduledCount, 1)
        XCTAssertTrue(overview.upcoming.isEmpty)
    }

    func testNoneOtherWeekAndInvalidSchedulesAreExcluded() throws {
        let monday = try day("2026-10-26")
        let todayTask = allDay(1, start: monday, endExclusive: monday.adding(days: 1))
        let invalid = CalendarTask(
            id: taskID(2), title: "invalid",
            schedule: .allDay(start: monday, endExclusive: monday), isCompleted: false
        )
        let tasks = [
            todayTask,
            CalendarTask(id: taskID(3), title: "inbox", schedule: .none, isCompleted: false),
            pending(4, weekStart: monday.adding(days: 7)),
            invalid
        ]

        let overview = try XCTUnwrap(WeekTaskOverview.make(today: monday, tasks: tasks, timeZone: gmt))
        XCTAssertEqual(overview.today.tasks.map(\.id), [taskID(1)])
        XCTAssertTrue(overview.upcoming.isEmpty)
        XCTAssertEqual(overview.pendingCount, 0)
        XCTAssertEqual(overview.completedWeekCount, 0)
    }

    func testIncompleteWeekBoundariesReturnNil() throws {
        XCTAssertNil(WeekTaskOverview.make(today: try day("0001-01-01"), tasks: [], timeZone: gmt))
        XCTAssertNil(WeekTaskOverview.make(today: try day("9999-12-31"), tasks: [], timeZone: gmt))
    }
}
