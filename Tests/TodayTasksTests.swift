import XCTest
@testable import TodoM0

final class TodayTasksTests: XCTestCase {
    private func task(_ title: String, _ schedule: TaskSchedule, done: Bool = false) -> CalendarTask {
        CalendarTask(id: UUID(), title: title, schedule: schedule, isCompleted: done)
    }

    func testRolloverKeepsOriginalTaskAndScheduleUntilCompleted() throws {
        let sunday = try Day("2026-11-08")
        let monday = sunday.adding(days: 1)
        let plan = TaskSchedule.allDay(start: sunday, endExclusive: monday)
        let item = task("周日的事", plan)
        let onSunday = TodayTasks([item], on: sunday, timeZone: .gmt)
        XCTAssertEqual(onSunday.scheduled.map(\.id), [item.id])
        let onMonday = TodayTasks([item, item], on: monday, timeZone: .gmt)
        XCTAssertTrue(onMonday.scheduled.isEmpty)
        XCTAssertEqual(onMonday.earlier.map(\.id), [item.id])
        XCTAssertEqual(onMonday.earlier.first?.schedule, plan)
        let finished = CalendarTask(id: item.id, title: item.title, schedule: plan, isCompleted: true)
        XCTAssertTrue(TodayTasks([finished], on: monday, timeZone: .gmt).earlier.isEmpty)
    }

    func testPastWeeksRangesAndInboxStayDistinct() throws {
        let monday = try Day("2026-11-09")
        let previousMonday = monday.adding(days: -7)
        let prior = task("上周", .week(start: previousMonday))
        let current = task("本周", .week(start: monday))
        let future = task("下周", .week(start: monday.adding(days: 7)))
        let spansToday = task("跨到今天", .allDay(start: monday.adding(days: -2), endExclusive: monday.adding(days: 1)))
        let done = task("已完成", spansToday.schedule, done: true)
        let items = [prior, current, future, spansToday, done, task("未安排", .none), task("已结束", .none, done: true)]
        let result = TodayTasks(items, on: monday, timeZone: .gmt)
        XCTAssertEqual(result.earlier.map(\.id), [prior.id])
        XCTAssertEqual(result.scheduled.map(\.id), [spansToday.id])
        XCTAssertEqual(result.finishedToday.map(\.id), [done.id])
        XCTAssertEqual(result.inboxCount, 1)
        XCTAssertTrue(TodayTasks([prior], on: monday.adding(days: -1), timeZone: .gmt).earlier.isEmpty)
        XCTAssertEqual(TodayTasks([current], on: monday.adding(days: 7), timeZone: .gmt).earlier.map(\.id), [current.id])
    }

    func testLocalMidnightAcrossDaylightSavingAndZones() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let day = try Day("2026-11-02")
        let midnight = day.date(in: zone)
        let exact = task("零点结束", .timed(start: midnight.addingTimeInterval(-7200), end: midnight, timeZoneID: zone.identifier))
        let overlaps = task("过零点", .timed(start: midnight.addingTimeInterval(-7200), end: midnight.addingTimeInterval(1), timeZoneID: zone.identifier))
        let local = TodayTasks([exact, overlaps], on: day, timeZone: zone)
        XCTAssertEqual(local.earlier.map(\.id), [exact.id])
        XCTAssertEqual(local.scheduled.map(\.id), [overlaps.id])
        XCTAssertEqual(Set(TodayTasks([exact, overlaps], on: day, timeZone: .gmt).scheduled.map(\.id)), [exact.id, overlaps.id])
    }

    func testWidgetBudgetsReserveVisibleCarryOverAndFillUnusedRows() throws {
        let day = try Day("2026-11-11")
        let today = TaskSchedule.allDay(start: day, endExclusive: day.adding(days: 1))
        let earlier = TaskSchedule.allDay(start: day.adding(days: -1), endExclusive: day)
        let oldest = task("更早", .allDay(start: day.adding(days: -5), endExclusive: day.adding(days: -4)))
        let recent = task("昨天", earlier)
        let todayTasks = [task("今天 A", today), task("今天 B", today)]
        let mixed = TodayTasks([oldest, recent] + todayTasks, on: day, timeZone: .gmt)
        XCTAssertEqual(mixed.visibleRows(limit: 1).earlier.map(\.id), [recent.id])
        XCTAssertTrue(mixed.visibleRows(limit: 1).scheduled.isEmpty)
        XCTAssertEqual(mixed.visibleRows(limit: 2).scheduled.count, 1)
        XCTAssertEqual(mixed.visibleRows(limit: 2).earlier.map(\.id), [recent.id])
        XCTAssertEqual(TodayTasks([oldest, recent], on: day, timeZone: .gmt).visibleRows(limit: 2).earlier.map(\.id), [recent.id, oldest.id])
        XCTAssertEqual(TodayTasks(todayTasks, on: day, timeZone: .gmt).visibleRows(limit: 2).scheduled.count, 2)
    }
}
