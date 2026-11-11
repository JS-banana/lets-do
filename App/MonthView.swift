import SwiftUI

struct MonthView: View {
    @ObservedObject var model: PrototypeModel
    @Environment(\.colorScheme) private var colorScheme
    @Binding var selectedDay: Day
    let create: (Day) -> Void
    let inspectDay: (Day) -> Void
    @State private var draggingTaskID: UUID?

    private var month: Day { Self.monthContaining(selectedDay) }

    private static let macSegmentTop: CGFloat = 34
    private static let macLaneHeight: CGFloat = 22

    private var layout: MonthLayout {
        MonthLayout.make(
            month: month,
            tasks: model.active.map {
                CalendarTask(id: $0.id, title: $0.title, schedule: $0.schedule, isCompleted: $0.isCompleted)
            },
            timeZone: .current,
            visibleLaneCount: visibleMonthLanes
        )
    }

    private var visibleMonthLanes: Int {
        #if os(macOS)
        2
        #else
        3
        #endif
    }

    private var today: Day {
        Day(date: Date(), timeZone: .current)
    }

    private var monthTitle: String {
        AppStyle.monthLabel(month)
    }

    var body: some View {
        Group {
        #if os(macOS)
        macBody
        #else
        phoneBody
        #endif
        }
    }

    private var monthHeader: some View {
        HStack(spacing: 8) {
            CalendarDateButton(day: Binding(get: { selectedDay }, set: { selectedDay = $0; inspectDay($0) }), title: monthTitle)
                .accessibilityIdentifier("calendarMonth")

            Spacer(minLength: 12)

            Button { create(selectedDay) } label: { Image(systemName: "plus").frame(width: 32, height: 32) }
                .buttonStyle(.borderless).accessibilityLabel("在所选日期新建任务")

            Divider().frame(height: 18).padding(.horizontal, 4)

            Button {
                shiftMonth(-1)
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("上月")
            .accessibilityHint("显示上一个月")
            .help("显示上一个月")
            .accessibilityIdentifier("previousMonth")

            Button {
                selectedDay = today
                inspectDay(today)
            } label: { Text("今天").frame(width: 44, height: 32) }
            .buttonStyle(.borderless)
            .tint(AppStyle.accentText(colorScheme))
            .accessibilityLabel("今天")
            .accessibilityHint("回到今天并显示当天任务")
            .help("回到今天")
            .accessibilityIdentifier("todayMonth")

            Button {
                shiftMonth(1)
            } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("下月")
            .accessibilityHint("显示下一个月")
            .help("显示下一个月")
            .accessibilityIdentifier("nextMonth")
        }
    }

    private var weekdayHeader: some View {
        HStack(spacing: 0) {
            ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) { day in
                Text(day)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("星期一至星期日")
    }

    #if os(macOS)
    private var macBody: some View {
        let currentLayout = layout
        return GeometryReader { geometry in
            let rowHeight = max(104, min(124, (geometry.size.height - 240) / CGFloat(currentLayout.days.count / 7)))
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    monthHeader
                    weekdayHeader

                    VStack(spacing: 0) {
                        ForEach(0..<(currentLayout.days.count / 7), id: \.self) { week in
                            weekRow(layout: currentLayout, week: week, rowHeight: rowHeight)
                        }
                    }
                    .coordinateSpace(name: "monthGrid")
                    .background(AppStyle.surface(colorScheme), in: RoundedRectangle(cornerRadius: 16))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.secondary.opacity(0.16), lineWidth: 0.5)
                    }

                    Text("拖动日历条可调整开始日期，任务跨度保持不变。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
            }
        }
        .background(AppStyle.canvas(colorScheme).ignoresSafeArea())
        .accessibilityIdentifier("monthCalendar")
    }

    private func weekRow(layout: MonthLayout, week: Int, rowHeight: CGFloat) -> some View {
        let days = Array(layout.days[(week * 7)..<(week * 7 + 7)])
        let segments = layout.segments.filter { $0.weekStart == days[0] && $0.lane < layout.visibleLaneCount }
        return GeometryReader { geometry in
            let width = geometry.size.width / 7
            weekRowContent(
                layout: layout,
                days: days,
                segments: segments,
                width: width,
                gridWidth: geometry.size.width,
                rowHeight: rowHeight
            )
            .dropDestination(for: String.self) { values, point in
                guard let value = values.first,
                      let id = UUID(uuidString: value) else { return false }
                let column = min(6, max(0, Int(point.x / width)))
                selectedDay = days[column]
                model.move(id: id, to: days[column])
                return true
            }
        }
        .frame(height: rowHeight)
    }

    private func weekRowContent(
        layout: MonthLayout,
        days: [Day],
        segments: [MonthSegment],
        width: CGFloat,
        gridWidth: CGFloat,
        rowHeight: CGFloat
    ) -> some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                ForEach(days) { day in
                    macDayCell(day, width: width, layout: layout, rowHeight: rowHeight)
                }
            }

            ForEach(segments) { segment in
                calendarSegment(
                    segment,
                    days: days,
                    width: width,
                    gridWidth: gridWidth,
                    allDays: layout.days,
                    rowHeight: rowHeight
                )
            }
        }
    }

    @ViewBuilder
    private func calendarSegment(
        _ segment: MonthSegment,
        days: [Day],
        width: CGFloat,
        gridWidth: CGFloat,
        allDays: [Day],
        rowHeight: CGFloat
    ) -> some View {
        if let task = model.active.first(where: { $0.id == segment.taskID }) {
            HStack(spacing: 3) {
                if segment.continuesBefore {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 8, weight: .semibold))
                }
                Text(task.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .strikethrough(task.isCompleted)
                Spacer(minLength: 0)
                if segment.continuesAfter {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                }
            }
            .padding(.horizontal, 5)
            .frame(height: 20)
            .frame(width: max(1, width * CGFloat(segment.dayCount) - 6))
            .foregroundStyle(task.isCompleted ? Color.secondary : Color.primary)
            .background(
                task.isCompleted ? Color.secondary.opacity(0.10) : AppStyle.scheduleAccent(task.schedule).opacity(0.12),
                in: RoundedRectangle(cornerRadius: 4)
            )
            .contentShape(Rectangle())
            .onTapGesture { model.selection = task.id }
            .gesture(
                DragGesture(minimumDistance: 8, coordinateSpace: .named("monthGrid"))
                    .onChanged { _ in draggingTaskID = task.id }
                    .onEnded { value in
                        draggingTaskID = nil
                        let point = value.location
                        guard point.x >= 0,
                              point.x < gridWidth,
                              point.y >= 0,
                              point.y < CGFloat(allDays.count / 7) * rowHeight else { return }
                        let index = Int(point.y / rowHeight) * 7 + Int(point.x / width)
                        guard allDays.indices.contains(index) else { return }
                        selectedDay = allDays[index]
                        model.selection = task.id
                        model.move(id: task.id, to: selectedDay)
                    }
            )
            .opacity(draggingTaskID == task.id ? 0.5 : 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(task.title)，\(AppStyle.scheduleLabel(task.schedule))")
            .accessibilityHint("打开任务详情")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { model.selection = task.id }
            .accessibilityIdentifier("segment-\(task.id.uuidString)-\(days[0].rawValue)")
            .offset(
                x: width * CGFloat(segment.startColumn) + 3,
                y: Self.macSegmentTop + Self.macLaneHeight * CGFloat(segment.lane)
            )
        }
    }

    private func macDayCell(_ day: Day, width: CGFloat, layout: MonthLayout, rowHeight: CGFloat) -> some View {
        let isCurrentMonth = String(day.rawValue.prefix(7)) == String(month.rawValue.prefix(7))
        let isSelected = day == selectedDay
        let isToday = day == today
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                selectedDay = day
                inspectDay(day)
            } label: {
                Text(String(Int(day.rawValue.suffix(2))!))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isSelected ? Color.white : (isCurrentMonth ? Color.primary : Color.secondary))
                    .frame(width: 24, height: 24)
                    .background {
                        if isSelected {
                            Circle().fill(AppStyle.accent)
                        } else if isToday {
                            Circle().stroke(AppStyle.accentText(colorScheme), lineWidth: 1.5)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(dayAccessibilityLabel(day, isToday: isToday, isSelected: isSelected))
            .accessibilityHint("选择这一天并查看当天任务")
            .help("选择\(AppStyle.dayLabel(day))")
            .accessibilityIdentifier("day-\(day.rawValue)")
            .contextMenu { Button("在这一天新建任务") { create(day) } }

            Spacer(minLength: 0)

            if let count = layout.hiddenCounts[day], count > 0 {
                Button("+\(count)") {
                    selectedDay = day
                    inspectDay(day)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppStyle.accentText(colorScheme))
                .buttonStyle(.plain)
                .help("打开当天完整任务")
                .padding(5)
                .accessibilityLabel("\(AppStyle.dayLabel(day))有\(count)个未显示任务")
                .accessibilityHint("打开当天完整任务")
                .accessibilityIdentifier("overflow-\(day.rawValue)")
            }
        }
        .frame(width: width, height: rowHeight)
        .background {
            Button { selectedDay = day; create(day) } label: {
                Rectangle().fill(isCurrentMonth ? AppStyle.surface(colorScheme) : Color.secondary.opacity(0.045))
                    .contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityLabel("在\(AppStyle.dayLabel(day))添加任务")
                .accessibilityIdentifier("month-blank-\(day.rawValue)")
        }
        .overlay { Rectangle().stroke(Color.secondary.opacity(0.20), lineWidth: 0.5).allowsHitTesting(false) }
    }

    #endif

    #if os(iOS)
    private var phoneBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                weekdayHeader

                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 0), count: 7),
                    spacing: 0
                ) {
                    ForEach(layout.days) { day in
                        phoneDayCell(day)
                    }
                }
                .background(AppStyle.surface(colorScheme), in: RoundedRectangle(cornerRadius: 16))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay { RoundedRectangle(cornerRadius: 14).stroke(Color.secondary.opacity(0.15), lineWidth: 0.5) }

            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .padding(.bottom, 88)
        }
        .background(AppStyle.canvas(colorScheme).ignoresSafeArea())
        .simultaneousGesture(DragGesture(minimumDistance: 40).onEnded { value in
            if abs(value.translation.width) > abs(value.translation.height) * 1.5 {
                shiftMonth(value.translation.width < 0 ? 1 : -1)
            }
        })
        .accessibilityIdentifier("monthCalendar")
    }

    private func phoneDayCell(_ day: Day) -> some View {
        let isCurrentMonth = String(day.rawValue.prefix(7)) == String(month.rawValue.prefix(7))
        let isSelected = day == selectedDay
        let isToday = day == today
        let dayTasks = tasks(on: day)
        let hasTasks = !dayTasks.isEmpty

        return Button {
            selectedDay = day
            inspectDay(day)
        } label: {
            VStack(spacing: 2) {
                Text(String(Int(day.rawValue.suffix(2))!))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isSelected ? Color.white : (isCurrentMonth ? Color.primary : Color.secondary))
                    .frame(width: 30, height: 30)
                    .background {
                        if isSelected {
                            Circle().fill(AppStyle.accent)
                        } else if isToday {
                            Circle().stroke(AppStyle.accentText(colorScheme), lineWidth: 1.5)
                        }
                    }

                HStack(spacing: 3) {
                    ForEach(Array(dayTasks.prefix(3))) { task in
                        Circle().fill(task.isCompleted ? Color.secondary : AppStyle.scheduleAccent(task.schedule))
                            .frame(width: 4, height: 4)
                    }
                }.frame(height: 5).accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: 46)
            .background(isSelected ? AppStyle.accent.opacity(0.04) : Color.clear)
            .overlay { Rectangle().stroke(Color.secondary.opacity(0.12), lineWidth: 0.5) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(hasTasks ? "查看当天任务" : "选择这一天")
        .opacity(isCurrentMonth ? 1 : 0.42)
        .accessibilityLabel(dayAccessibilityLabel(day, isToday: isToday, isSelected: isSelected))
        .accessibilityValue("\(dayTasks.count)项，\(dayTasks.filter { !$0.isCompleted }.count)项未完成")
        .accessibilityHint(hasTasks ? "查看当天任务" : "选择这一天")
        .accessibilityIdentifier("day-\(day.rawValue)")
    }

    #endif

    private func tasks(on day: Day) -> [TaskSnapshot] {
        model.scheduled(on: day)
    }

    private func dayAccessibilityLabel(_ day: Day, isToday: Bool, isSelected: Bool) -> String {
        var label = AppStyle.dayLabel(day)
        if isToday { label += "，今天" }
        if isSelected { label += "，已选中" }
        return label
    }

    private func shiftMonth(_ offset: Int) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        guard let date = calendar.date(byAdding: .month, value: offset, to: month.date(in: .current)) else { return }
        selectedDay = Self.monthContaining(Day(date: date, timeZone: .current))
    }

    private static func monthContaining(_ day: Day) -> Day {
        try! Day(String(day.rawValue.prefix(7)) + "-01")
    }
}
