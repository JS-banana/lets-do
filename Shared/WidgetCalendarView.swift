import Foundation
import SwiftUI
import WidgetKit

enum CalendarWidgetMode {
    case week
    case month
    case today
}

struct WidgetCalendarView: View {
    let date: Date
    let tasks: [CalendarTask]
    let mode: CalendarWidgetMode
    let family: WidgetFamily
    var message: String = ""
    var unavailable: Bool = false
    var storeNamespace: String = ""
    var complete: ((UUID) -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.widgetRenderingMode) private var widgetRenderingMode

    private var anchorDay: Day {
        Day(date: date, timeZone: .current)
    }

    private var weekStart: Day {
        anchorDay.weekStart ?? anchorDay
    }

    private var weekDays: [Day] {
        (0..<7).compactMap { weekStart.addingIfPossible(days: $0) }
    }

    private var monthStart: Day {
        let rawValue = "\(anchorDay.rawValue.prefix(7))-01"
        return (try? Day(rawValue)) ?? anchorDay
    }

    private var uniqueTasks: [CalendarTask] {
        var ids = Set<UUID>()
        return tasks.filter { ids.insert($0.id).inserted }
    }

    private func makeMonthLayout(visibleLaneCount: Int) -> MonthLayout {
        MonthLayout.make(
            month: monthStart,
            tasks: uniqueTasks,
            timeZone: .current,
            visibleLaneCount: min(2, max(0, visibleLaneCount))
        )
    }

    private var usesFullColor: Bool {
        widgetRenderingMode == .fullColor
    }

    private var accentForeground: Color {
        usesFullColor ? AppStyle.accentText(colorScheme) : .primary
    }

    var body: some View {
        Group {
            if unavailable {
                unavailableBody
            } else {
                switch mode {
                case .week:
                    weekBody
                case .month:
                    monthBody
                case .today:
                    todayBody
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(.primary)
    }

    @ViewBuilder
    private var weekBody: some View {
        switch family {
        case .systemMedium:
            weekMediumBody
        case .systemExtraLarge:
            weekExtraLargeBody
        default:
            weekLargeBody
        }
    }

    @ViewBuilder
    private var weekMediumBody: some View {
        if let overview = WeekTaskOverview.make(today: anchorDay, tasks: tasks, timeZone: .current) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Link(destination: calendarURL(for: overview.weekStart, view: .week)) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("本周").font(.system(size: 16, weight: .semibold))
                            Text("\(compactDayLabel(overview.weekStart)) – \(compactDayLabel(overview.weekStart.adding(days: 6))) · 待办 \(overview.unfinishedCount)")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .lineLimit(1)
                    .accessibilityLabel("本周计划，\(AppStyle.dayLabel(overview.weekStart)) 起，\(overview.unfinishedCount) 项待办，打开周历")
                    Spacer(minLength: 4)
                    previousWeeksLink
                }
                HStack(spacing: 2) {
                    ForEach(overview.days) { entry in
                        let today = entry.day == anchorDay
                        Link(destination: calendarURL(for: entry.day, view: .agenda)) {
                            VStack(spacing: 0) {
                                Text(weekdayLabel(entry.day)).font(.system(size: 10))
                                Text("\(entry.unfinishedCount)").font(.system(size: 12, weight: .semibold))
                                    .monospacedDigit()
                            }
                            .foregroundStyle(today ? accentForeground : entry.unfinishedCount > 0 ? Color.primary : Color.secondary)
                            .frame(maxWidth: .infinity, minHeight: 28)
                            .background(today ? accentForeground.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(today ? "今天，" : "")\(AppStyle.dayLabel(entry.day))，\(weekdayLabel(entry.day))，\(entry.unfinishedCount) 项未完成，查看当天任务")
                    }
                }
                if overview.rows.isEmpty {
                    Text(overview.completedWeekCount > 0 ? "本周任务已完成" : "本周暂无安排")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    ForEach(overview.rows) { row in
                        HStack(spacing: 6) {
                            Text(weekRowLabel(row))
                                .font(.system(size: 11))
                                .foregroundStyle(row.day == anchorDay ? accentForeground : Color.secondary)
                                .lineLimit(1)
                                .frame(width: 68, alignment: .leading)
                                .accessibilityLabel(AppStyle.scheduleLabel(row.task.schedule))
                            completionButton(row.task)
                            taskTitleLink(row.task, lineLimit: 1)
                        }
                        .frame(minHeight: 17)
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    pendingWeekLink(count: overview.pendingCount)
                    Spacer(minLength: 0)
                    quickCaptureLink
                }
                .font(.system(size: 11, weight: .semibold))
                messageView
            }
            .accessibilityIdentifier("weekIndexWidget")
        } else {
            unavailableBody
        }
    }

    private func weekRowLabel(_ row: WeekTaskOverview.Row) -> String {
        guard let day = row.day else { return "待安排" }
        if let range = row.task.schedule.dayRange(in: .current),
           let last = range.upperBound.addingIfPossible(days: -1), last != range.lowerBound {
            func label(_ endpoint: Day) -> String {
                endpoint.weekStart == weekStart ? weekdayLabel(endpoint) : compactDayLabel(endpoint)
            }
            return "\(label(range.lowerBound))–\(label(last))"
        }
        return day == anchorDay ? "今天" : weekdayLabel(day)
    }

    private var weekExtraLargeBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            calendarHeader(
                title: "本周",
                subtitle: "\(compactDayLabel(weekStart)) – \(compactDayLabel(weekDays.last ?? weekStart))",
                day: weekStart,
                view: .week
            )

            HStack(alignment: .top, spacing: 0) {
                ForEach(weekDays) { day in
                    weekColumn(day: day)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            widgetFooter(
                leading: pendingWeekLink(count: WeekTaskList.pending.tasks(from: tasks, weekStart: weekStart, timeZone: .current).count),
                trailing: quickCaptureLink
            )
            messageView
        }
    }

    private func weekColumn(day: Day) -> some View {
        let dayTasks = tasks(on: day)
        let shownTasks = Array(dayTasks.prefix(2))
        let overflow = max(0, dayTasks.count - shownTasks.count)
        let isToday = day == anchorDay

        return VStack(alignment: .leading, spacing: 5) {
            Link(destination: calendarURL(for: day, view: .agenda)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(isToday ? "今天" : weekdayLabel(day))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isToday ? accentForeground : .secondary)
                    Text(dayNumber(day))
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(isToday ? (usesFullColor ? Color.white : Color.primary) : .primary)
                        .frame(width: 27, height: 27)
                        .background {
                            if isToday {
                                Circle().fill(usesFullColor ? AppStyle.accent : Color.primary.opacity(0.16))
                            }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isToday ? "今天，\(AppStyle.dayLabel(day))" : AppStyle.dayLabel(day))

            if shownTasks.isEmpty {
                Text("暂无安排")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 4)
            } else {
                ForEach(shownTasks) { task in
                    taskRow(task, showDescription: true, filled: true, lineLimit: 2)
                }
            }

            if overflow > 0 {
                Link(destination: calendarURL(for: day, view: .agenda)) {
                    Text("+\(overflow) 项")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(accentForeground)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(AppStyle.dayLabel(day))还有\(overflow)项")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 3)
        .padding(.bottom, 4)
        .background {
            if isToday {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.07))
            }
        }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.secondary.opacity(0.18))
                .frame(width: 0.5)
        }
    }

    private var weekLargeBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            calendarHeader(
                title: "本周",
                subtitle: "\(compactDayLabel(weekStart)) – \(compactDayLabel(weekDays.last ?? weekStart))",
                day: weekStart,
                view: .week
            )

            VStack(spacing: 0) {
                ForEach(weekDays) { day in
                    weekSummaryRow(day: day)
                }
            }

            widgetFooter(
                leading: pendingWeekLink(count: WeekTaskList.pending.tasks(from: tasks, weekStart: weekStart, timeZone: .current).count),
                trailing: quickCaptureLink
            )
            messageView
        }
    }

    private func weekSummaryRow(day: Day) -> some View {
        let dayTasks = tasks(on: day)
        let firstTask = dayTasks.first
        let overflow = max(0, dayTasks.count - (firstTask == nil ? 0 : 1))
        let isToday = day == anchorDay

        return HStack(alignment: .center, spacing: 6) {
            Link(destination: calendarURL(for: day, view: .agenda)) {
                HStack(spacing: 4) {
                    Text(dayNumber(day))
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                    Text(isToday ? "今天" : weekdayLabel(day))
                        .font(.system(size: 11, weight: isToday ? .semibold : .regular))
                }
                .foregroundStyle(isToday ? accentForeground : .secondary)
                .frame(width: 58, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isToday ? "今天，\(AppStyle.dayLabel(day))" : AppStyle.dayLabel(day))

            if let firstTask {
                taskRow(firstTask, showDescription: false, filled: false, lineLimit: 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("暂无安排")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if overflow > 0 {
                Link(destination: calendarURL(for: day, view: .agenda)) {
                    Text("+\(overflow)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(accentForeground)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(AppStyle.dayLabel(day))还有\(overflow)项")
            }
        }
        .padding(.vertical, 4)
        .frame(maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.secondary.opacity(0.14)).frame(height: 0.5)
        }
    }

    @ViewBuilder
    private var monthBody: some View {
        switch family {
        case .systemExtraLarge:
            monthExtraLargeBody
        default:
            monthLargeBody
        }
    }

    private var monthExtraLargeBody: some View {
        GeometryReader { geometry in
            let twoLaneLayout = makeMonthLayout(visibleLaneCount: 2)
            let rowCount = max(1, twoLaneLayout.days.count / 7)
            let messageReserve: CGFloat = message.isEmpty ? 0 : 26
            let rowHeight = max(32, (geometry.size.height - 70 - messageReserve) / CGFloat(rowCount))
            let laneCount = rowHeight >= 50 ? 2 : (rowHeight >= 35 ? 1 : 0)
            let layout = makeMonthLayout(visibleLaneCount: laneCount)

            VStack(alignment: .leading, spacing: 5) {
                calendarHeader(
                    title: AppStyle.monthLabel(monthStart),
                    subtitle: "",
                    day: monthStart,
                    view: .month
                )

                weekdayHeader

                VStack(spacing: 0) {
                    ForEach(Array(stride(from: 0, to: layout.days.count, by: 7)), id: \.self) { index in
                        monthWeekRow(layout: layout, startIndex: index, rowHeight: rowHeight)
                    }
                }
                .overlay {
                    Rectangle().stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
                }

                widgetFooter(
                    leading: weekPlanLink,
                    trailing: quickCaptureLink
                )
                messageView
            }
        }
    }

    private func monthWeekRow(layout: MonthLayout, startIndex: Int, rowHeight: CGFloat) -> some View {
        let endIndex = min(startIndex + 7, layout.days.count)
        let days = Array(layout.days[startIndex..<endIndex])
        let segments = layout.segments.filter {
            $0.weekStart == days[0] && $0.lane < layout.visibleLaneCount
        }

        let segmentHeight = layout.visibleLaneCount == 2 ? 14 : max(14, rowHeight - 21)
        let segmentStep = segmentHeight + 1

        return GeometryReader { geometry in
            let cellWidth = geometry.size.width / 7
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    ForEach(days) { day in
                        monthDayCell(day: day, layout: layout, width: cellWidth, height: rowHeight)
                    }
                }

                ForEach(segments) { segment in
                    if let task = uniqueTasks.first(where: { $0.id == segment.taskID }) {
                        monthSegment(
                            segment: segment,
                            task: task,
                            width: max(1, cellWidth * CGFloat(segment.dayCount) - 5),
                            height: segmentHeight
                        )
                        .offset(
                            x: cellWidth * CGFloat(segment.startColumn) + 2,
                            y: 21 + CGFloat(segment.lane) * segmentStep
                        )
                    }
                }
            }
        }
        .frame(height: rowHeight)
    }

    private func monthDayCell(day: Day, layout: MonthLayout, width: CGFloat, height: CGFloat) -> some View {
        let isCurrentMonth = day.rawValue.prefix(7) == monthStart.rawValue.prefix(7)
        let isToday = day == anchorDay
        let hiddenCount = layout.hiddenCounts[day] ?? 0

        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                Link(destination: calendarURL(for: day, view: .month)) {
                    Text(dayNumber(day))
                        .font(.system(size: 12, weight: isToday ? .bold : .semibold, design: .rounded))
                        .foregroundStyle(isToday ? (usesFullColor ? Color.white : Color.primary) : (isCurrentMonth ? .primary : .secondary))
                        .frame(width: 22, height: 20)
                        .background {
                            if isToday {
                                Circle().fill(usesFullColor ? AppStyle.accent : Color.primary.opacity(0.17))
                            }
                        }
                        .padding(.horizontal, 3)
                        .padding(.top, 2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isToday ? "今天，\(AppStyle.dayLabel(day))" : AppStyle.dayLabel(day))

                Spacer(minLength: 0)

                if hiddenCount > 0 {
                    Link(destination: calendarURL(for: day, view: .month)) {
                        Text("+\(hiddenCount)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(accentForeground)
                            .lineLimit(1)
                            .padding(.horizontal, 3)
                            .padding(.top, 3)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(AppStyle.dayLabel(day))还有\(hiddenCount)项")
                }
            }

            Spacer(minLength: 0)
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .background(isCurrentMonth ? Color.clear : Color.secondary.opacity(0.045))
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color.secondary.opacity(0.13)).frame(width: 0.5)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.secondary.opacity(0.13)).frame(height: 0.5)
        }
    }

    @ViewBuilder
    private func monthSegment(segment: MonthSegment, task: CalendarTask, width: CGFloat, height: CGFloat) -> some View {
        let segmentLabel = HStack(spacing: 2) {
            if segment.continuesBefore {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
            }
            Text(taskTitle(task))
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
            if segment.continuesAfter {
                Spacer(minLength: 1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
            }
        }
        .foregroundStyle(task.isCompleted ? Color.secondary : accentForeground)
        .strikethrough(task.isCompleted)
        .padding(.horizontal, 3)

        Link(destination: taskURL(for: task.id)) {
            segmentLabel
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: width, height: height, alignment: .leading)
        .background(taskBackground(task), in: RoundedRectangle(cornerRadius: 4))
        .opacity(task.isCompleted ? 0.72 : 1)
        .accessibilityLabel("\(taskTitle(task))，\(AppStyle.scheduleLabel(task.schedule))")
    }

    private var monthLargeBody: some View {
        VStack(alignment: .leading, spacing: 7) {
            calendarHeader(
                title: AppStyle.monthLabel(monthStart),
                subtitle: "",
                day: monthStart,
                view: .month
            )

            compactMonthGrid

            Rectangle()
                .fill(Color.secondary.opacity(0.16))
                .frame(height: 0.5)

            todayAgenda
        }
    }

    private var compactMonthGrid: some View {
        let layout = makeMonthLayout(visibleLaneCount: 0)

        return VStack(spacing: 0) {
            weekdayHeader
            ForEach(Array(stride(from: 0, to: layout.days.count, by: 7)), id: \.self) { index in
                let days = Array(layout.days[index..<(index + 7)])
                HStack(spacing: 0) {
                    ForEach(days) { day in
                        compactMonthDay(day: day)
                    }
                }
                .frame(height: 20)
            }
        }
    }

    private func compactMonthDay(day: Day) -> some View {
        let isCurrentMonth = day.rawValue.prefix(7) == monthStart.rawValue.prefix(7)
        let isToday = day == anchorDay
        let count = tasks(on: day).count

        return Link(destination: calendarURL(for: day, view: .month)) {
            VStack(spacing: 1) {
                Text(dayNumber(day))
                    .font(.system(size: 11, weight: isToday ? .bold : .regular, design: .rounded))
                    .foregroundStyle(isToday ? (usesFullColor ? Color.white : Color.primary) : (isCurrentMonth ? .primary : .secondary))
                    .frame(width: 19, height: 18)
                    .background {
                        if isToday {
                            Circle().fill(usesFullColor ? AppStyle.accent : Color.primary.opacity(0.17))
                        }
                    }
                if count > 0 {
                    Circle()
                        .fill(usesFullColor ? AppStyle.teal : Color.primary)
                        .frame(width: 3, height: 3)
                        .accessibilityHidden(true)
                } else {
                    Color.clear.frame(width: 3, height: 3)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isToday ? "今天，\(AppStyle.dayLabel(day))，\(count)项" : "\(AppStyle.dayLabel(day))，\(count)项")
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.secondary.opacity(0.11)).frame(height: 0.5)
        }
    }

    private var todayBody: some View {
        let overview = TodayTasks(tasks, on: anchorDay, timeZone: .current)
        return VStack(alignment: .leading, spacing: 4) {
            Link(destination: AppDestination.today.url) {
                HStack {
                    Text("今天").font(.headline)
                    Spacer(minLength: 4)
                    Text(compactDayLabel(anchorDay)).font(.caption).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("查看今天和此前未完成的任务")
            todayRows(overview, limit: family == .systemSmall ? 1 : 2)
            Spacer(minLength: 0)
            captureFooter(inboxCount: overview.inboxCount)
            messageView
        }
        .widgetURL(AppDestination.today.url)
    }

    @ViewBuilder
    private func todayRows(_ overview: TodayTasks<CalendarTask>, limit: Int) -> some View {
        let rows = overview.visibleRows(limit: limit)
        ForEach(rows.scheduled) { task in
            taskRow(task, showDescription: false, filled: true, lineLimit: 1)
        }
        ForEach(rows.earlier) { task in
            HStack(spacing: 4) {
                Text(earlierLabel(task)).font(.caption2).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                    .accessibilityLabel("此前未完成，原计划" + AppStyle.scheduleLabel(task.schedule))
                taskRow(task, showDescription: false, filled: true, lineLimit: 1)
            }
        }
        let moreToday = overview.scheduled.count - rows.scheduled.count
        let moreEarlier = overview.earlier.count - rows.earlier.count
        if moreToday > 0 || moreEarlier > 0 {
            let parts = [moreToday > 0 ? "今天 +\(moreToday)" : nil,
                         moreEarlier > 0 ? "此前 +\(moreEarlier)" : nil].compactMap { $0 }
            Link(parts.joined(separator: " · "), destination: AppDestination.today.url)
                .font(.caption2).buttonStyle(.plain).foregroundStyle(accentForeground)
                .accessibilityLabel("查看其余任务，今天还有\(moreToday)项，此前未完成还有\(moreEarlier)项")
        }
        if rows.scheduled.isEmpty && rows.earlier.isEmpty {
            Text(overview.finishedToday.isEmpty ? "今天没有安排" : "今天的任务已完成")
                .font(.subheadline).foregroundStyle(.secondary)
            if let next = nextUnfinished {
                HStack(spacing: 4) {
                    Text(compactDayLabel(next.day)).font(.caption2).foregroundStyle(.secondary)
                        .accessibilityLabel("下一项，" + AppStyle.dayLabel(next.day))
                    taskRow(next.task, showDescription: false, filled: false, lineLimit: 1)
                }
            }
        }
    }

    private func earlierLabel(_ task: CalendarTask) -> String {
        if case .week(let monday) = task.schedule { return compactDayLabel(monday) + "周" }
        if let last = task.schedule.dayRange(in: .current)?.upperBound.addingIfPossible(days: -1) {
            return last == anchorDay.addingIfPossible(days: -1) ? "昨天" : compactDayLabel(last)
        }
        return "此前"
    }

    private var nextUnfinished: (day: Day, task: CalendarTask)? {
        for offset in 1...7 {
            if let day = anchorDay.addingIfPossible(days: offset),
               let task = tasks(on: day).first(where: { !$0.isCompleted }) { return (day, task) }
        }
        return nil
    }

    private func captureFooter(inboxCount: Int) -> some View {
        widgetFooter(leading: Group {
            if inboxCount > 0 {
                Link("收集箱 \(inboxCount)", destination: AppDestination.inbox.url)
                    .accessibilityLabel("查看收集箱里的\(inboxCount)项未安排任务")
            }
        }, trailing: quickCaptureLink)
    }

    private var todayAgenda: some View {
        let overview = TodayTasks(tasks, on: anchorDay, timeZone: .current)
        return VStack(alignment: .leading, spacing: 4) {
            Link("今天的任务", destination: AppDestination.today.url)
                .font(.subheadline.bold()).buttonStyle(.plain)
            todayRows(overview, limit: 2)
            Spacer(minLength: 0)
            widgetFooter(leading: weekPlanLink, trailing: quickCaptureLink)
            messageView
        }
    }

    @ViewBuilder
    private var earlierLink: some View {
        let count = TodayTasks(tasks, on: anchorDay, timeZone: .current).earlier.count
        if count > 0 {
            Link("此前未完成 \(count)", destination: AppDestination.today.url)
                .font(.caption2).buttonStyle(.plain).foregroundStyle(accentForeground)
                .accessibilityLabel("查看所有此前未完成的\(count)项任务")
        }
    }

    @ViewBuilder
    private var previousWeeksLink: some View {
        let list = WeekTaskList.previousWeeks
        let count = list.tasks(from: tasks, weekStart: weekStart, timeZone: .current).count
        if count > 0 {
            Link("\(list.title) · \(count)", destination: AppDestination.weekList(weekStart, list).url)
                .font(.caption2).buttonStyle(.plain).foregroundStyle(accentForeground)
                .accessibilityLabel("查看往周未完成的 \(count) 项任务")
        }
    }

    private var unavailableBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "arrow.clockwise.circle")
                .font(.system(size: 23, weight: .semibold))
                .foregroundStyle(accentForeground)
                .accessibilityHidden(true)
            Text("暂时无法读取任务")
                .font(.system(size: 15, weight: .semibold))
            Text(message.isEmpty ? "请打开 Let’s Do 完成恢复，再回来查看。" : message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(4)
            Link(destination: AppDestination.capture(.none).url) {
                Label("打开 Let’s Do 恢复", systemImage: "arrow.up.forward.app")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(accentForeground)
            }
            .accessibilityLabel("打开 Let’s Do 恢复任务")
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func calendarHeader(title: String, subtitle: String, day: Day, view: CalendarPresentation) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Link(destination: calendarURL(for: day, view: view)) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(1)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("打开\(title)日历")
            Spacer(minLength: 0)
            if view == .week { previousWeeksLink } else { earlierLink }
            Image(systemName: view == .month ? "calendar" : "calendar.day.timeline.left")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(accentForeground)
                .accessibilityHidden(true)
        }
    }

    private var weekdayHeader: some View {
        HStack(spacing: 0) {
            ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) { label in
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("星期一至星期日")
    }

    @ViewBuilder
    private func widgetFooter<Leading: View, Trailing: View>(leading: Leading, trailing: Trailing) -> some View {
        HStack(alignment: .center, spacing: 8) {
            leading
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.top, 5)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.secondary.opacity(0.16)).frame(height: 0.5)
        }
        .font(.system(size: 11, weight: .semibold))
    }

    @ViewBuilder
    private func pendingWeekLink(count: Int) -> some View {
        if count > 0 {
            Link("本周待安排 · \(count)", destination: AppDestination.weekList(weekStart, .pending).url)
                .buttonStyle(.plain).foregroundStyle(accentForeground)
                .accessibilityLabel("查看本周待安排的 \(count) 项任务")
        }
    }

    private var weekPlanLink: some View {
        Link(destination: AppDestination.calendar(weekStart, .week).url) {
            Label("查看本周计划", systemImage: "chevron.right")
                .foregroundStyle(accentForeground)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("查看本周计划")
    }

    @ViewBuilder
    private var quickCaptureLink: some View {
        Link(destination: AppDestination.capture(.none).url) {
            Label("快速记", systemImage: "plus")
                .foregroundStyle(accentForeground)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("快速记")
    }

    @ViewBuilder
    private var messageView: some View {
        if !message.isEmpty {
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private func emptyState(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 4)
    }

    private func taskRow(_ task: CalendarTask, showDescription: Bool, filled: Bool, lineLimit: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                completionButton(task)
                taskTitleLink(task, lineLimit: lineLimit)
            }
            if showDescription && !task.preview.isEmpty {
                Text(task.preview)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.leading, 20)
            }
        }
        .padding(.horizontal, filled ? 5 : 0)
        .padding(.vertical, filled ? 4 : 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if filled {
                RoundedRectangle(cornerRadius: 5).fill(taskBackground(task))
            }
        }
        .opacity(task.isCompleted ? 0.72 : 1)
    }

    @ViewBuilder
    private func completionButton(_ task: CalendarTask) -> some View {
        let label = task.isCompleted ? "已完成 \(taskTitle(task))" : "完成 \(taskTitle(task))"
        if let complete {
            Button {
                complete(task.id)
            } label: {
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(task.isCompleted ? Color.secondary : accentForeground)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .disabled(task.isCompleted)
            .accessibilityLabel(label)
        } else {
            Button(intent: SetTaskCompletedIntent(taskID: task.id, completed: true, namespace: storeNamespace)) {
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(task.isCompleted ? Color.secondary : accentForeground)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .disabled(task.isCompleted)
            .accessibilityLabel(label)
        }
    }

    @ViewBuilder
    private func taskTitleLink(_ task: CalendarTask, lineLimit: Int) -> some View {
        let title = taskTitle(task)
        Link(destination: taskURL(for: task.id)) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(task.isCompleted ? Color.secondary : Color.primary)
                .strikethrough(task.isCompleted)
                .lineLimit(lineLimit, reservesSpace: lineLimit > 1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private func tasks(on day: Day) -> [CalendarTask] {
        uniqueTasks.filter { task in
            task.schedule.dayRange(in: .current)?.contains(day) == true
        }
        .sorted {
            if $0.isCompleted != $1.isCompleted {
                return !$0.isCompleted
            }
            let firstDate = sortDate($0.schedule)
            let secondDate = sortDate($1.schedule)
            if firstDate != secondDate {
                return firstDate < secondDate
            }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private func sortDate(_ schedule: TaskSchedule) -> Date {
        switch schedule {
        case .none:
            return .distantFuture
        case .week(let start), .allDay(let start, _):
            return start.date(in: .current)
        case .timed(let start, _, _):
            return start
        }
    }

    private func taskTitle(_ task: CalendarTask) -> String {
        task.title.isEmpty ? "未命名任务" : task.title
    }

    private func taskBackground(_ task: CalendarTask) -> Color {
        let base = usesFullColor ? AppStyle.scheduleAccent(task.schedule) : Color.primary
        return base.opacity(task.isCompleted ? 0.07 : 0.12)
    }

    private func dayNumber(_ day: Day) -> String {
        String(Int(day.rawValue.suffix(2)) ?? 0)
    }

    private func compactDayLabel(_ day: Day) -> String {
        let parts = day.rawValue.split(separator: "-")
        guard parts.count == 3,
              let month = Int(parts[1]),
              let number = Int(parts[2]) else {
            return day.rawValue
        }
        return "\(month).\(number)"
    }

    private func weekdayLabel(_ day: Day) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let weekday = calendar.component(.weekday, from: day.date(in: .gmt))
        return ["周一", "周二", "周三", "周四", "周五", "周六", "周日"][(weekday + 5) % 7]
    }

    private func taskURL(for id: UUID) -> URL {
        AppDestination.task(id).url
    }

    private func calendarURL(for day: Day, view: CalendarPresentation) -> URL {
        AppDestination.calendar(day, view).url
    }
}
