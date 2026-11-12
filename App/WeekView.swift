import SwiftUI

struct WeekView: View {
    @ObservedObject var model: PrototypeModel
    @Binding var selectedDay: Day
    let create: (Day) -> Void
    #if os(iOS)
    let createWeek: (Day) -> Void
    #endif
    let inspectDay: (Day) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoveredDay: Day?
    @State private var dropDay: Day?
    @State private var draggingTaskID: UUID?
    @State private var taskBoardViewportFrame: CGRect = .zero
    @State private var taskBoardContentFrame: CGRect = .zero

    private var days: [Day] {
        (0..<7).compactMap { (selectedDay.weekStart ?? selectedDay).addingIfPossible(days: $0) }
    }

    var body: some View {
        #if os(iOS)
        phoneAgenda
        #else
        taskBoard
        #endif
    }

    #if os(iOS)
    private var phoneAgenda: some View {
        let week = days
        let dated = model.scheduled(on: selectedDay)
        let pending = model.active.filter { !$0.isCompleted && $0.schedule == .week(start: week[0]) }
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    CalendarDateButton(day: $selectedDay, title: AppStyle.dayLabel(selectedDay))
                    Spacer()
                    Button { if let day = selectedDay.addingIfPossible(days: -7) { selectedDay = day } }
                        label: { Image(systemName: "chevron.left").frame(width: 36, height: 44) }.accessibilityLabel("上一周")
                    Button("今天") { selectedDay = Day(date: Date(), timeZone: .current) }
                    Button { if let day = selectedDay.addingIfPossible(days: 7) { selectedDay = day } }
                        label: { Image(systemName: "chevron.right").frame(width: 36, height: 44) }.accessibilityLabel("下一周")
                }
                HStack(spacing: 0) {
                    ForEach(week) { day in
                        Button { selectedDay = day } label: {
                            VStack(spacing: 4) {
                                Text(String(AppStyle.weekdayLabel(day).suffix(1))).font(.caption)
                                Text(String(Int(day.rawValue.suffix(2)) ?? 0)).font(.headline)
                            }.frame(maxWidth: .infinity, minHeight: 48)
                                .background(day == selectedDay ? AppStyle.accent.opacity(0.12) : .clear,
                                            in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain).accessibilityLabel(AppStyle.dayLabel(day))
                            .accessibilityAddTraits(day == selectedDay ? .isSelected : [])
                    }
                }
                HStack {
                    Text("当天任务").font(.headline)
                    Spacer()
                    Button("添加任务", systemImage: "plus") { create(selectedDay) }
                }
                if dated.isEmpty { Text("这一天没有安排").foregroundStyle(.secondary) }
                ForEach(dated) { phoneRow($0) }
                Divider()
                HStack {
                    Text("本周待安排").font(.headline)
                    Spacer()
                    Button("加入本周", systemImage: "plus") { createWeek(week[0]) }
                }
                ForEach(pending) { phoneRow($0) }
            }.padding()
        }
    }

    private func phoneRow(_ task: TaskSnapshot) -> some View {
        TaskAgendaRow(task: task, complete: { model.toggleCompletion(task) }, open: { model.selection = task.id })
    }
    #else

    private var taskBoard: some View {
        let weekDays = days
        let today = Day(date: .now, timeZone: .current)
        let spanning = model.active.filter {
            guard let range = $0.schedule.dayRange(in: .current),
                  let nextDay = range.lowerBound.addingIfPossible(days: 1) else { return false }
            return nextDay < range.upperBound
        }
        let layout = MonthLayout.make(month: selectedDay, tasks: spanning.map {
            CalendarTask(id: $0.id, title: $0.title, schedule: $0.schedule, isCompleted: $0.isCompleted)
        }, timeZone: .current, visibleLaneCount: max(1, spanning.count))
        let segments = layout.segments.filter { $0.weekStart == weekDays[0] }
        let spanHeight = CGFloat((segments.map(\.lane).max() ?? -1) + 1) * 26
        return VStack(spacing: 0) {
            GeometryReader { geometry in
                let column = max(108, geometry.size.width / 7)
                WorkspaceScrollView([.horizontal, .vertical]) {
                    VStack(spacing: 0) {
                        HStack(spacing: 0) {
                            ForEach(Array(weekDays.enumerated()), id: \.element) { index, day in
                                Button { selectDay(day) } label: {
                                    VStack(spacing: 6) {
                                        Text("周" + ["一", "二", "三", "四", "五", "六", "日"][index]).font(.caption).foregroundStyle(.secondary)
                                        Text(String(Int(day.rawValue.suffix(2))!)).font(.title2.weight(.medium))
                                            .frame(width: 34, height: 34)
                                            .foregroundStyle(day == today ? Color.white : .primary)
                                            .background {
                                                if day == today { Circle().fill(AppStyle.accent) }
                                                else if day == selectedDay { Circle().stroke(AppStyle.accent.opacity(0.5), lineWidth: 1) }
                                            }
                                    }.frame(width: column, height: 68)
                                        .background(dayFill(day))
                                        .overlay(alignment: .trailing) { Rectangle().fill(Color.secondary.opacity(0.18)).frame(width: 1) }
                                }.buttonStyle(.plain).accessibilityLabel(AppStyle.dayLabel(day) + (day == today ? "，今天" : ""))
                                    .onHover { updateHover(for: day, inside: $0) }
                                    .accessibilityHint("查看当天任务")
                                    .accessibilityAddTraits(day == selectedDay ? .isSelected : [])
                                    .accessibilityIdentifier("week-day-\(day.rawValue)")
                            }
                        }
                        HStack(alignment: .top, spacing: 0) {
                            ForEach(weekDays) { day in
                                let dayTasks = model.scheduled(on: day).filter { task in !spanning.contains(where: { $0.id == task.id }) }
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(dayTasks) { task in planningTask(task, weekDays: weekDays) }
                                    Spacer(minLength: 24)
                                }
                                .padding(.horizontal, 7).padding(.top, spanHeight + 8)
                                .frame(width: column, alignment: .topLeading)
                                .frame(minHeight: max(0, geometry.size.height - 68), alignment: .top)
                            }
                        }
                        .background {
                            HStack(spacing: 0) {
                                ForEach(weekDays) { day in
                                    MacCalendarDayBackground(day: day,
                                        fill: dayFill(day),
                                        identifier: "week-blank-\(day.rawValue)",
                                        hover: { updateHover(for: day, inside: $0) }) {
                                        selectedDay = day
                                        create(day)
                                    }.frame(width: column)
                                        .overlay(alignment: .trailing) {
                                            Rectangle().fill(Color.secondary.opacity(0.18)).frame(width: 1)
                                                .allowsHitTesting(false).accessibilityHidden(true)
                                        }
                                }
                            }
                        }
                        .overlay(alignment: .topLeading) {
                            ZStack(alignment: .topLeading) {
                                ForEach(segments) { segment in
                                    if let task = spanning.first(where: { $0.id == segment.taskID }) {
                                        Button { model.selection = task.id } label: {
                                            HStack(spacing: 4) {
                                                if segment.continuesBefore {
                                                    Image(systemName: "chevron.left").accessibilityHidden(true)
                                                }
                                                Text(task.title).lineLimit(1).strikethrough(task.isCompleted)
                                                Spacer(minLength: 0)
                                                if segment.continuesAfter {
                                                    Image(systemName: "chevron.right").accessibilityHidden(true)
                                                }
                                            }
                                            .font(.system(size: 12, weight: .medium)).padding(.horizontal, 7)
                                            .frame(width: max(1, column * CGFloat(segment.dayCount) - 6), height: 22, alignment: .leading)
                                            .background(AppStyle.teal.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                                        }.buttonStyle(.plain)
                                            .accessibilityLabel("\(task.title)，跨日任务")
                                            .accessibilityHint("打开任务详情")
                                            .highPriorityGesture(taskDragGesture(for: task.id, weekDays: weekDays))
                                            .opacity(draggingTaskID == task.id ? 0.5 : 1)
                                            .offset(x: column * CGFloat(segment.startColumn) + 3, y: CGFloat(segment.lane) * 26 + 2)
                                    }
                                }
                            }
                        }
                    }
                    .frame(width: column * CGFloat(weekDays.count))
                    .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named("weekTaskBoard")) }) {
                        taskBoardContentFrame = $0
                    }
                    .contentShape(Rectangle())
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hoveredDay)
                    .dropDestination(for: String.self) { values, point in
                        guard let value = values.first,
                              let id = UUID(uuidString: value),
                              model.active.contains(where: { $0.id == id }) else { return false }
                        let location = CGPoint(
                            x: taskBoardContentFrame.minX + point.x,
                            y: taskBoardContentFrame.minY + point.y
                        )
                        guard let day = taskBoardDay(at: location, weekDays: weekDays) else { return false }
                        selectedDay = day
                        model.move(id: id, to: day)
                        return true
                    }
                }
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named("weekTaskBoard")) }) {
                    taskBoardViewportFrame = $0
                }
            }
            .background(AppStyle.surface(colorScheme))
            .overlay(alignment: .top) { Divider() }
        }
        .background(AppStyle.canvas(colorScheme))
        .coordinateSpace(.named("weekTaskBoard"))
        .accessibilityIdentifier("weekPlanner")
    }

    private func dayFill(_ day: Day) -> Color {
        if dropDay == day { return AppStyle.accent.opacity(colorScheme == .dark ? 0.26 : 0.16) }
        if hoveredDay == day { return MacCalendarDayBackground.highlight(in: colorScheme) }
        return AppStyle.surface(colorScheme)
    }

    private func updateHover(for day: Day, inside: Bool) {
        if inside { hoveredDay = day }
        else if hoveredDay == day { hoveredDay = nil }
    }

    private func selectDay(_ day: Day) {
        selectedDay = day
        inspectDay(day)
    }

    private func planningTask(_ task: TaskSnapshot, weekDays: [Day]) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Button { model.toggleCompletion(task) } label: {
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle").foregroundStyle(.secondary)
            }.buttonStyle(.plain).accessibilityLabel(task.isCompleted ? "设为未完成：\(task.title)" : "完成：\(task.title)")
            Button { model.selection = task.id } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(task.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(3)
                        .layoutPriority(1)
                        .strikethrough(task.isCompleted)
                    if let body = task.currentNote?.body,
                       !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(body.replacingOccurrences(of: "\n", with: " "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain)
                .highPriorityGesture(taskDragGesture(for: task.id, weekDays: weekDays))
        }
        .padding(9)
        .background(task.isCompleted ? Color.secondary.opacity(0.07) : AppStyle.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { model.selection = task.id }
        .opacity(draggingTaskID == task.id ? 0.5 : 1)
        .accessibilityIdentifier("plan-task-\(task.id)")
    }

    private func taskDragGesture(for taskID: UUID, weekDays: [Day]) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .named("weekTaskBoard"))
            .onChanged { value in
                draggingTaskID = taskID
                dropDay = taskBoardDay(at: value.location, weekDays: weekDays)
            }
            .onEnded { value in
                defer {
                    draggingTaskID = nil
                    dropDay = nil
                }
                guard let day = taskBoardDay(at: value.location, weekDays: weekDays),
                      model.active.contains(where: { $0.id == taskID }) else { return }
                selectedDay = day
                model.move(id: taskID, to: day)
            }
    }

    private func taskBoardDay(at location: CGPoint, weekDays: [Day]) -> Day? {
        guard !weekDays.isEmpty,
              taskBoardViewportFrame.width > 0,
              taskBoardViewportFrame.height > 0,
              taskBoardContentFrame.width > 0,
              taskBoardContentFrame.height > 0,
              taskBoardViewportFrame.contains(location),
              taskBoardContentFrame.contains(location) else { return nil }
        let columnWidth = taskBoardContentFrame.width / CGFloat(weekDays.count)
        guard columnWidth > 0 else { return nil }
        let index = Int((location.x - taskBoardContentFrame.minX) / columnWidth)
        guard weekDays.indices.contains(index) else { return nil }
        return weekDays[index]
    }
    #endif
}
