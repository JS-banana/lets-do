import XCTest
@testable import TodoM0

final class CalendarPlanningTests: XCTestCase {
    func testDateFormRejectsUnrepresentableExclusiveEndWithoutOverflow() throws {
        var form = ScheduleForm()
        form.placement = .day
        form.start = try Day("9999-12-31").date(in: .current)
        form.end = form.start
        XCTAssertNotNil(form.error)
        XCTAssertThrowsError(try form.schedule.validated())
        form.start = try Day("9999-12-30").date(in: .current)
        form.end = form.start
        XCTAssertNil(form.error)
        XCTAssertEqual(form.schedule, .allDay(start: try Day("9999-12-30"), endExclusive: try Day("9999-12-31")))
    }

    func testWeeklyPlanHasNoDayOccupancyAndCanBeAssignedWithoutDuplicating() throws {
        let monday = try Day("2026-10-26")
        let plan = TaskSchedule.week(start: monday)
        XCTAssertEqual(try plan.validated(), plan)
        XCTAssertNil(plan.dayRange(in: .current))
        XCTAssertEqual(try JSONDecoder().decode(TaskSchedule.self, from: JSONEncoder().encode(plan)), plan)
        let task = CalendarTask(id: UUID(), title: "本周要做", schedule: plan, isCompleted: false)
        let layout = MonthLayout.make(month: monday, tasks: [task], timeZone: .current)
        XCTAssertTrue(layout.segments.isEmpty)
        XCTAssertTrue(layout.hiddenCounts.values.allSatisfy { $0 == 0 })
        let friday = try Day("2026-10-30")
        XCTAssertEqual(try plan.moved(to: friday, displayTimeZone: .current),
                       .allDay(start: friday, endExclusive: friday.adding(days: 1)))
        XCTAssertThrowsError(try TaskSchedule.week(start: monday.adding(days: 1)).validated())
        XCTAssertThrowsError(try TaskSchedule.week(start: Day("9999-12-27")).validated())
        let lowerBound = try Day("0001-01-01")
        XCTAssertNil(lowerBound.weekStart)
        XCTAssertThrowsError(try TaskSchedule.week(start: lowerBound).validated())
        XCTAssertNotNil(ScheduleForm(schedule: .week(start: lowerBound)).error)
    }

    func testWeeklyPlanUsesMondayAcrossYearAndScheduleFormPreservesIt() throws {
        let day = try Day("2027-01-01")
        XCTAssertEqual(day.weekStart, try Day("2026-12-28"))
        let plan = TaskSchedule.week(start: try XCTUnwrap(day.weekStart))
        let form = ScheduleForm(schedule: plan)
        XCTAssertTrue(form.enabled)
        XCTAssertTrue(form.weekly)
        XCTAssertNil(form.error)
        XCTAssertEqual(form.schedule, plan)
    }

    func testDesktopRoutesRoundTripAndRejectMalformedInput() throws {
        let day = try Day("2026-10-31")
        let monday = try XCTUnwrap(day.weekStart)
        let destinations: [AppDestination] = [.weekList(monday, .previousWeeks), .weekList(monday, .pending), .today, .inbox, .task(UUID()), .calendar(day, .week), .calendar(day, .month), .calendar(day, .agenda),
            .capture(.none), .capture(.week(start: try XCTUnwrap(day.weekStart))),
            .capture(.allDay(start: day, endExclusive: day.adding(days: 1)))]
        for destination in destinations { XCTAssertEqual(AppDestination(url: destination.url), destination) }
        let scheme = AppDestination.scheme
        for text in ["https://capture", "\(scheme)://open/nope", "\(scheme)://open/today?date=bad", "\(scheme)://task/not-a-uuid", "\(scheme)://calendar/2026-02-30",
                     "\(scheme)://calendar/2026-10-31?view=unknown", "\(scheme)://calendar/2026-10-31?view",
                     "\(scheme)://calendar/2026-10-31?view=previous-weeks", "\(scheme)://calendar/2026-10-31?view=pending",
                     "\(scheme)://calendar/2026-10-26?view=pending&view=previous-weeks",
                     "\(scheme)://capture?day=9999-12-31", "\(scheme)://capture?week=9999-12-31",
                     "\(scheme)://capture?week=0001-01-01", "\(scheme)://calendar/0001-01-01?view=month",
                     "\(scheme)://capture?day=2026-10-31&day=2026-11-01", "\(scheme)://capture?secret=anything",
                     "\(scheme)://user@capture", "\(scheme)://capture#anything"] {
            XCTAssertNil(AppDestination(url: try XCTUnwrap(URL(string: text))), text)
        }
    }

    private func timed(_ index: Int, day: Day, start: Double, end: Double, zone: TimeZone = .gmt) -> CalendarTask {
        CalendarTask(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!, title: "task",
                     schedule: .timed(start: day.date(in: zone).addingTimeInterval(start * 60),
                                      end: day.date(in: zone).addingTimeInterval(end * 60), timeZoneID: zone.identifier),
                     isCompleted: false)
    }

    func testTimelineOverlapLanesAreStableAndTouchingTasksCanReuseLane() throws {
        let day = try Day("2026-10-29")
        let tasks = [timed(1, day: day, start: 540, end: 600), timed(2, day: day, start: 570, end: 660),
                     timed(3, day: day, start: 600, end: 720), timed(4, day: day, start: 720, end: 780)]
        let layout = DayTimelineLayout.make(day: day, tasks: tasks, timeZone: .gmt)
        XCTAssertEqual(layout.blocks.map(\.lane), [0, 1, 0, 0])
        XCTAssertEqual(layout.blocks.map(\.laneCount), [2, 2, 2, 1])
        let reordered = DayTimelineLayout.make(day: day, tasks: tasks.reversed(), timeZone: .gmt)
        XCTAssertEqual(layout.blocks.map(\.id), reordered.blocks.map(\.id))
    }

    func testTimelineClipsAtMidnightAndExcludesExclusiveEnd() throws {
        let day = try Day("2026-10-29")
        let tasks = [timed(1, day: day, start: -30, end: 0), timed(2, day: day, start: -30, end: 30),
                     timed(3, day: day, start: 1_380, end: 1_500), timed(4, day: day, start: 400, end: 400)]
        let layout = DayTimelineLayout.make(day: day, tasks: tasks, timeZone: .gmt)
        XCTAssertEqual(layout.blocks.count, 2)
        XCTAssertEqual(layout.blocks.map(\.startMinute), [0, 1_380])
        XCTAssertEqual(layout.blocks.map(\.endMinute), [30, 1_440])
        let next = DayTimelineLayout.make(day: day.adding(days: 1), tasks: tasks, timeZone: .gmt)
        XCTAssertEqual(next.blocks.count, 1)
        XCTAssertEqual(next.blocks.first?.startMinute, 0)
        XCTAssertEqual(next.blocks.first?.endMinute, 60)
    }

    func testTimelineKeepsRepeatedDSTHourAndRealDayLength() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let fall = try Day("2026-11-01")
        let tasks = [timed(1, day: fall, start: 90, end: 120, zone: zone),
                     timed(2, day: fall, start: 150, end: 180, zone: zone)]
        let layout = DayTimelineLayout.make(day: fall, tasks: tasks, timeZone: zone)
        XCTAssertEqual(layout.minuteCount, 1_500)
        XCTAssertEqual(layout.blocks.map(\.startMinute), [90, 150])
        XCTAssertEqual(layout.blocks.map(\.laneCount), [1, 1])
        XCTAssertEqual(DayTimelineLayout.make(day: try Day("2026-03-08"), tasks: [], timeZone: zone).minuteCount, 1_380)
    }

    func testScheduleFormShowsInclusiveEndAndRetainsTimedZone() throws {
        let first = try Day("2026-10-29"), end = try Day("2026-11-03")
        let schedule = TaskSchedule.allDay(start: first, endExclusive: end)
        var form = ScheduleForm(schedule: schedule)
        XCTAssertEqual(Day(date: form.end, timeZone: .current), try Day("2026-11-02"))
        XCTAssertEqual(form.schedule, schedule)
        form.end = first.adding(days: -1).date(in: .current)
        XCTAssertNotNil(form.error)
        XCTAssertThrowsError(try form.schedule.validated())
        let timed = TaskSchedule.timed(start: first.date(in: .gmt), end: first.date(in: .gmt).addingTimeInterval(3_600),
                                       timeZoneID: "Europe/Paris")
        XCTAssertEqual(ScheduleForm(schedule: timed).schedule, timed)
    }
    func testDateOnlyFormPreservesLegacyTimeUntilDatesAreChanged() throws {
        let first = try Day("2026-11-02")
        let start = first.date(in: .current).addingTimeInterval(14 * 3_600 + 30 * 60)
        let original = TaskSchedule.timed(start: start, end: start.addingTimeInterval(3_600), timeZoneID: "Asia/Singapore")
        var form = ScheduleForm(schedule: original)
        XCTAssertEqual(form.schedule, original)
        XCTAssertTrue(form.retainsExistingTime)
        form.start = first.adding(days: 2).date(in: .current)
        form.end = form.start
        XCTAssertEqual(form.schedule, .allDay(start: first.adding(days: 2), endExclusive: first.adding(days: 3)))
        XCTAssertFalse(form.retainsExistingTime)
    }

    func testDateOnlySingleDayDoesNotRequireASecondDate() throws {
        var form = ScheduleForm()
        form.placement = .day
        let day = try Day("2026-11-20")
        form.start = day.date(in: .current)
        XCTAssertEqual(form.schedule, .allDay(start: day, endExclusive: day.adding(days: 1)))
        XCTAssertNil(form.error)
        form.spansDays = true
        form.end = day.adding(days: -1).date(in: .current)
        XCTAssertNotNil(form.error)
        form.end = day.adding(days: 2).date(in: .current)
        XCTAssertEqual(form.schedule, .allDay(start: day, endExclusive: day.adding(days: 3)))
    }

    @MainActor
    func testExplicitTodayReplacesLegacyOvernightPlanWithoutChangingTaskOrNotes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TodayPlanning-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TaskStore(directory: directory)
        defer { try? store.close() }
        let originalDay = try Day("2026-11-09"), today = try Day("2026-11-11")
        let originalStart = originalDay.date(in: .gmt).addingTimeInterval(23 * 3_600)
        let original = TaskSchedule.timed(start: originalStart, end: originalStart.addingTimeInterval(2 * 3_600),
                                          timeZoneID: TimeZone.gmt.identifier)
        let id = UUID()
        try store.createTask(id: id, title: "夜间任务", schedule: original, body: "保留备注")
        let before = try XCTUnwrap(store.snapshots().first)

        // The context menu and date popover use this same explicit single-day rule.
        try store.scheduleTask(id: id, schedule: .singleDay(today))
        let snapshots = try store.snapshots()
        let after = try XCTUnwrap(snapshots.first)
        XCTAssertEqual(snapshots.map(\.id), [id])
        XCTAssertEqual(after.revisions, before.revisions)
        XCTAssertEqual(after.schedule, .allDay(start: today, endExclusive: today.adding(days: 1)))
        let item = CalendarTask(id: id, title: after.title, schedule: after.schedule, isCompleted: false)
        XCTAssertEqual(TodayTasks([item], on: today, timeZone: .gmt).scheduled.map(\.id), [id])
        XCTAssertTrue(TodayTasks([item], on: today.adding(days: 1), timeZone: .gmt).scheduled.isEmpty)

        // Dragging is a move and continues to preserve the old two-hour span.
        let dragged = try original.moved(to: today, displayTimeZone: .gmt)
        XCTAssertTrue(try XCTUnwrap(dragged.dayRange(in: .gmt)).contains(today.adding(days: 1)))
        XCTAssertThrowsError(try TaskSchedule.singleDay(Day("9999-12-31")).validated())
    }

}
