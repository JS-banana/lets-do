import XCTest
#if os(macOS)
import SwiftUI
import WidgetKit
#endif
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

    func testWeekShowsAllSevenDaysAndReservesTitlesForPastTodayAndFuture() throws {
        let monday = try day("2026-11-09")
        let tuesday = monday.adding(days: 1)
        let wednesday = monday.adding(days: 2)
        let thursday = monday.adding(days: 3)
        let ongoing = allDay(1, start: monday, endExclusive: thursday)
        let past = timed(2, start: wednesday.date(in: gmt).addingTimeInterval(-1800),
                         end: wednesday.date(in: gmt), timeZone: gmt)
        let future = allDay(3, start: thursday, endExclusive: monday.adding(days: 5))
        let tasks = [
            ongoing, past, future, pending(4, weekStart: monday), ongoing,
            allDay(5, start: thursday, endExclusive: monday.adding(days: 7), completed: true),
            allDay(6, start: monday.adding(days: -3), endExclusive: monday.adding(days: -2)),
            pending(7, weekStart: monday.adding(days: -7)),
            CalendarTask(id: taskID(8), title: "收集箱", schedule: .none, isCompleted: false)
        ]

        let week = try XCTUnwrap(WeekTaskOverview.make(today: wednesday, tasks: tasks, timeZone: gmt))
        XCTAssertEqual(week.days.map(\.day), (0..<7).map { monday.adding(days: $0) })
        XCTAssertEqual(week.days.map(\.unfinishedCount), [1, 2, 1, 1, 1, 0, 0])
        XCTAssertEqual(week.unfinishedCount, 4)
        XCTAssertEqual(week.pendingCount, 1)
        XCTAssertEqual(week.completedWeekCount, 1)
        XCTAssertEqual(week.rows.map(\.id), [past.id, ongoing.id, future.id])
        XCTAssertEqual(week.rows.map(\.day), [tuesday, wednesday, thursday])
        XCTAssertEqual(week.rows.map(\.task.schedule), [past.schedule, ongoing.schedule, future.schedule])
    }

    func testPastTitleStaysAtOriginalDayUntilFollowingMonday() throws {
        let monday = try day("2026-11-09")
        let sunday = monday.adding(days: 6)
        let nextMonday = monday.adding(days: 7)
        let original = allDay(1, start: monday, endExclusive: monday.adding(days: 1))
        let spansWeeks = allDay(2, start: sunday, endExclusive: nextMonday.adding(days: 1))
        let tasks = [original, spansWeeks, pending(3, weekStart: monday), pending(4, weekStart: nextMonday)]

        let thisWeek = try XCTUnwrap(WeekTaskOverview.make(today: sunday, tasks: tasks, timeZone: gmt))
        XCTAssertEqual(thisWeek.rows.map(\.id), [original.id, spansWeeks.id, taskID(3)])
        XCTAssertEqual(thisWeek.rows.map(\.day), [monday, sunday, nil])

        let nextWeek = try XCTUnwrap(WeekTaskOverview.make(today: nextMonday, tasks: tasks, timeZone: gmt))
        XCTAssertEqual(nextWeek.days.map(\.unfinishedCount), [1, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(nextWeek.rows.map(\.id), [spansWeeks.id, taskID(4)])
        XCTAssertEqual(nextWeek.rows.first?.task.schedule, spansWeeks.schedule)
        XCTAssertEqual(nextWeek.unfinishedCount, 2)
        XCTAssertEqual(nextWeek.pendingCount, 1)
    }

    func testBusyDaysReserveOtherCategoriesAndPreferMostRecentPastAndNearestFuture() throws {
        let monday = try day("2026-11-09")
        let today = monday.adding(days: 3)
        let dated: [Day] = [monday, monday.adding(days: 1), today, today, today,
                            monday.adding(days: 6), monday.adding(days: 4)]
        let tasks = dated.enumerated().map { index, date in
            allDay(index + 1, start: date, endExclusive: date.adding(days: 1))
        } + [pending(8, weekStart: monday)]

        let week = try XCTUnwrap(WeekTaskOverview.make(today: today, tasks: tasks, timeZone: gmt))
        XCTAssertEqual(week.rows.map(\.id), [taskID(2), taskID(3), taskID(7)])
        XCTAssertEqual(week.days.map(\.unfinishedCount), [1, 1, 0, 3, 1, 0, 1])
        XCTAssertEqual(week.unfinishedCount, 8)
        XCTAssertEqual(week.pendingCount, 1)
    }

    func testSpareLinesCoverDistinctDatesBeforeRepeatingABusyDay() throws {
        let monday = try day("2026-11-09")
        let thursday = monday.adding(days: 3)
        let friday = monday.adding(days: 4)
        let tasks = (1...5).map { allDay($0, start: thursday, endExclusive: friday) }
            + [allDay(6, start: friday, endExclusive: friday.adding(days: 1))]
        for today in [monday, monday.adding(days: 6)] {
            let week = try XCTUnwrap(WeekTaskOverview.make(today: today, tasks: tasks, timeZone: gmt))
            XCTAssertEqual(week.rows.map(\.id), [taskID(1), taskID(2), taskID(6)])
            XCTAssertEqual(week.days.map(\.unfinishedCount), [0, 0, 0, 5, 1, 0, 0])
        }
    }

    func testSpareLinesShowMoreUnfinishedTasksIncludingWeekOnlyTasks() throws {
        let monday = try day("2026-11-09")
        let sunday = monday.adding(days: 6)
        let dated = (1...5).map { allDay($0, start: monday, endExclusive: monday.adding(days: 1)) }
        let weekOnly = (6...9).map { pending($0, weekStart: monday) }

        let pastOnly = try XCTUnwrap(WeekTaskOverview.make(today: sunday, tasks: dated, timeZone: gmt))
        XCTAssertEqual(pastOnly.rows.map(\.id), [taskID(1), taskID(2), taskID(3)])
        XCTAssertEqual(pastOnly.days.first?.unfinishedCount, 5)

        let mixed = try XCTUnwrap(WeekTaskOverview.make(today: sunday, tasks: dated + weekOnly, timeZone: gmt))
        XCTAssertEqual(mixed.rows.map(\.id), [taskID(1), taskID(2), taskID(6)])
        XCTAssertEqual(mixed.pendingCount, 4)

        let pendingOnly = try XCTUnwrap(WeekTaskOverview.make(today: sunday, tasks: weekOnly, timeZone: gmt))
        XCTAssertEqual(pendingOnly.rows.map(\.id), [taskID(6), taskID(7), taskID(8)])
        XCTAssertTrue(pendingOnly.rows.allSatisfy { $0.day == nil })
        XCTAssertTrue(pendingOnly.days.allSatisfy { $0.unfinishedCount == 0 })
        XCTAssertEqual(pendingOnly.unfinishedCount, 4)
    }

    func testUUIDDeduplicationAndReorderingHaveStableRepresentatives() throws {
        let monday = try day("2026-11-09")
        let midnight = monday.date(in: gmt)
        let all = allDay(3, start: monday, endExclusive: monday.adding(days: 1))
        let early = timed(2, start: midnight, end: midnight.addingTimeInterval(90), timeZone: gmt)
        let late = timed(1, start: midnight.addingTimeInterval(180), end: midnight.addingTimeInterval(240),
                         timeZone: gmt)
        let tasks = [early, late, all, early]
        for input in [tasks, Array(tasks.reversed())] {
            let week = try XCTUnwrap(WeekTaskOverview.make(today: monday, tasks: input, timeZone: gmt))
            XCTAssertEqual(week.rows.map(\.id), [all.id, early.id, late.id])
            XCTAssertEqual(week.days.first?.unfinishedCount, 3)
            XCTAssertEqual(week.unfinishedCount, 3)
        }

        let done = allDay(3, start: monday, endExclusive: monday.adding(days: 1), completed: true)
        let duplicateID = try XCTUnwrap(WeekTaskOverview.make(today: monday, tasks: [done, all], timeZone: gmt))
        XCTAssertEqual(duplicateID.unfinishedCount, 0)
        XCTAssertEqual(duplicateID.completedWeekCount, 1)
    }

    func testEmptyAndAllCompletedWeeksRemainDistinguishable() throws {
        let monday = try day("2026-11-09")
        let complete = allDay(1, start: monday, endExclusive: monday.adding(days: 7), completed: true)
        let week = try XCTUnwrap(WeekTaskOverview.make(today: monday, tasks: [
            complete, pending(2, weekStart: monday, completed: true)
        ], timeZone: gmt))
        XCTAssertTrue(week.rows.isEmpty)
        XCTAssertTrue(week.days.allSatisfy { $0.unfinishedCount == 0 })
        XCTAssertEqual(week.completedWeekCount, 2)
        XCTAssertEqual(week.unfinishedCount, 0)
        XCTAssertEqual(week.pendingCount, 0)

        let empty = try XCTUnwrap(WeekTaskOverview.make(today: monday, tasks: [], timeZone: gmt))
        XCTAssertEqual(empty.days.count, 7)
        XCTAssertTrue(empty.rows.isEmpty)
        XCTAssertEqual(empty.completedWeekCount, 0)
    }

    func testCrossYearWeekKeepsSundayAndExcludesNextMondayAndInvalidSchedules() throws {
        let friday = try day("2027-01-01")
        let sunday = try day("2027-01-03")
        let nextMonday = try day("2027-01-04")
        let tasks = [
            allDay(1, start: sunday, endExclusive: nextMonday),
            allDay(2, start: nextMonday, endExclusive: nextMonday.adding(days: 1)),
            allDay(3, start: friday, endExclusive: friday),
            pending(4, weekStart: nextMonday), pending(5, weekStart: friday),
            timed(6, start: friday.date(in: gmt), end: friday.date(in: gmt), timeZone: gmt)
        ]

        let week = try XCTUnwrap(WeekTaskOverview.make(today: friday, tasks: tasks, timeZone: gmt))
        XCTAssertEqual(week.weekStart, try day("2026-12-28"))
        XCTAssertEqual(week.days.map(\.unfinishedCount), [0, 0, 0, 0, 0, 0, 1])
        XCTAssertEqual(week.rows.map(\.id), [taskID(1)])
        XCTAssertEqual(week.rows.map(\.day), [sunday])
        XCTAssertEqual(week.unfinishedCount, 1)
    }

    func testMidnightAndDSTUseTheDisplayTimeZone() throws {
        let eastern = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let sunday = try day("2026-03-08")
        let monday = sunday.adding(days: 1)
        let saturday = sunday.adding(days: -1)
        let midnight = sunday.date(in: eastern)
        let endedAtMidnight = timed(1, start: midnight.addingTimeInterval(-1800), end: midnight, timeZone: eastern)
        let crossesDST = timed(2, start: midnight.addingTimeInterval(5400),
                               end: monday.date(in: eastern).addingTimeInterval(1800), timeZone: eastern)
        let tasks = [endedAtMidnight, crossesDST]
        let local = try XCTUnwrap(WeekTaskOverview.make(today: sunday, tasks: tasks, timeZone: eastern))
        XCTAssertEqual(local.days.map(\.unfinishedCount), [0, 0, 0, 0, 0, 1, 1])
        XCTAssertEqual(local.rows.map(\.day), [saturday, sunday])

        let utc = try XCTUnwrap(WeekTaskOverview.make(today: sunday, tasks: tasks, timeZone: gmt))
        XCTAssertEqual(utc.days.map(\.unfinishedCount), [0, 0, 0, 0, 0, 0, 2])
        XCTAssertEqual(utc.rows.map(\.day), [sunday, sunday])
    }

    #if os(macOS)
    @MainActor
    func testMediumWeekFitsMacPreviewWithThreeTitlesAndBothListLinks() throws {
        let monday = try day("2026-11-09")
        let today = monday.adding(days: 2)
        let friday = monday.adding(days: 4)
        let tasks = [allDay(1, start: monday, endExclusive: monday.adding(days: 1)),
                     allDay(2, start: today, endExclusive: today.adding(days: 1)),
                     allDay(3, start: friday, endExclusive: friday.adding(days: 1)),
                     pending(4, weekStart: monday), pending(5, weekStart: monday.adding(days: -7))]
        let widget = WidgetCalendarView(date: today.date(in: .current), tasks: tasks, mode: .week,
                                        family: .systemMedium, message: "本机完成 · 打开应用后同步", complete: { _ in })
            .frame(width: 344)
            .fixedSize(horizontal: false, vertical: true)
        let image = try XCTUnwrap(ImageRenderer(content: widget).nsImage)
        XCTAssertEqual(image.size.width, 344, accuracy: 1)
        XCTAssertGreaterThan(image.size.height, 0)
        XCTAssertLessThanOrEqual(image.size.height, 164)
    }
    #endif

    func testIncompleteWeekBoundariesReturnNil() throws {
        XCTAssertNil(WeekTaskOverview.make(today: try day("0001-01-01"), tasks: [], timeZone: gmt))
        XCTAssertNil(WeekTaskOverview.make(today: try day("9999-12-31"), tasks: [], timeZone: gmt))
    }
}
